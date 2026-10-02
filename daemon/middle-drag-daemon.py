#!/usr/bin/env python3
"""Middle-Drag Gestures input daemon.

Grabs the physical mouse with ``evdev``, creates a virtual mouse with
``uinput`` and re-emits every event except the middle button.  While the
middle button is held, pointer movement is accumulated and turned into one of
four gestures (left / right / up / down), which are then sent to the GNOME
Shell extension over D-Bus.

The daemon is deliberately GNOME-agnostic: it only knows how to call the
``org.gnome.Shell.Extensions.MiddleDrag`` methods.  Everything GNOME-specific
lives in the extension.

Run as the logged-in user (never as root)::

    middle-drag-daemon.py [--device auto|PATH] [--threshold N]
                          [--list-devices] [--verbose]
"""

from __future__ import annotations

import argparse
import logging
import os
import select
import signal
import sys
import threading
import time

from evdev import InputDevice, UInput, ecodes, list_devices

try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except Exception:  # pragma: no cover - optional dependency
    Gio = None
    GLib = None

try:
    import dbus
    import dbus.lowlevel
    from dbus.exceptions import DBusException
except Exception:  # pragma: no cover - optional dependency
    dbus = None
    DBusException = Exception


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LOG = logging.getLogger("middle-drag-daemon")

VIRTUAL_MOUSE_NAME = "Middle Drag Virtual Mouse"

DEFAULT_THRESHOLD = 100
DEFAULT_DEVICE = "auto"

SCHEMA_ID = "org.gnome.shell.extensions.middle-drag"

BUS_DEST = "org.gnome.Shell.Extensions.MiddleDrag"
OBJECT_PATH = "/org/gnome/Shell/Extensions/MiddleDrag"
IFACE = "org.gnome.Shell.Extensions.MiddleDrag"

#: Configuration key -> D-Bus method exposed by the extension.
ACTION_METHODS = {
    "next-workspace": "NextWorkspace",
    "previous-workspace": "PreviousWorkspace",
    "show-overview": "ShowOverview",
    "hide-overview": "HideOverview",
    "none": None,
}

DEFAULT_ACTIONS = {
    "left-action": "next-workspace",
    "right-action": "previous-workspace",
    "up-action": "hide-overview",
    "down-action": "show-overview",
}

DIRECTION_KEYS = {
    "left": "left-action",
    "right": "right-action",
    "up": "up-action",
    "down": "down-action",
}

#: Minimum capabilities a device must expose to be treated as "the mouse".
REQUIRED_KEYS = frozenset(
    {
        ecodes.BTN_LEFT,
        ecodes.BTN_RIGHT,
        ecodes.BTN_MIDDLE,
    }
)
REQUIRED_REL = frozenset(
    {
        ecodes.REL_X,
        ecodes.REL_Y,
    }
)

#: Capabilities advertised by the virtual mouse.
VIRTUAL_KEY_CAPS = [
    ecodes.BTN_LEFT,
    ecodes.BTN_RIGHT,
    ecodes.BTN_MIDDLE,
    ecodes.BTN_SIDE,
    ecodes.BTN_EXTRA,
    ecodes.BTN_FORWARD,
    ecodes.BTN_BACK,
    ecodes.BTN_TASK,
]
VIRTUAL_REL_CAPS = [
    ecodes.REL_X,
    ecodes.REL_Y,
    ecodes.REL_Z,
    ecodes.REL_WHEEL,
    ecodes.REL_HWHEEL,
    ecodes.REL_WHEEL_HI_RES,
    ecodes.REL_HWHEEL_HI_RES,
]

VIRTUAL_CAPABILITIES = {
    ecodes.EV_KEY: VIRTUAL_KEY_CAPS,
    ecodes.EV_REL: VIRTUAL_REL_CAPS,
}


class DeviceGone(Exception):
    """Raised when the physical device disappears."""


# ---------------------------------------------------------------------------
# Device discovery
# ---------------------------------------------------------------------------


def stable_path(path: str) -> str:
    """Return the ``/dev/input/by-id`` symlink for *path* when one exists.

    ``/dev/input/eventN`` numbering changes between reboots and re-plugs, so
    the stable by-id name is preferred for logging and configuration.
    """
    try:
        real = os.path.realpath(path)
        by_id = "/dev/input/by-id"
        for name in sorted(os.listdir(by_id)):
            if "-event-" not in name:
                continue
            candidate = os.path.join(by_id, name)
            try:
                if os.path.realpath(candidate) == real:
                    return candidate
            except OSError:
                continue
    except OSError:
        pass
    return path


def device_capabilities(device: InputDevice) -> tuple[set, set]:
    caps = device.capabilities()
    keys = set(caps.get(ecodes.EV_KEY, []))
    rels = set(caps.get(ecodes.EV_REL, []))
    return keys, rels


def capabilities_ok(keys: set, rels: set) -> bool:
    """True when a device advertises the capabilities we need (pure)."""
    return REQUIRED_KEYS <= keys and REQUIRED_REL <= rels


def is_suitable(device: InputDevice) -> bool:
    """True when *device* looks like a mouse we can drive gestures from."""
    if device.name == VIRTUAL_MOUSE_NAME:
        return False

    keys, rels = device_capabilities(device)
    return capabilities_ok(keys, rels)


def scan_devices() -> list[tuple[str, str]]:
    """Return ``(stable_path, name)`` for every suitable mouse."""
    found = []
    for path in list_devices():
        try:
            device = InputDevice(path)
        except (OSError, PermissionError):
            continue
        try:
            if not is_suitable(device):
                continue
            found.append((stable_path(device.path), device.name))
        finally:
            try:
                device.close()
            except OSError:
                pass
    return found


def discover_device(preferred: str = DEFAULT_DEVICE) -> str | None:
    """Pick the device to grab.

    ``preferred`` may be an explicit device path (``/dev/input/...``) or
    ``"auto"``.  Returns ``None`` when no suitable device is available.
    """
    if preferred and preferred != "auto":
        return preferred if os.path.exists(preferred) else None

    candidates = scan_devices()
    if not candidates:
        return None
    if len(candidates) > 1:
        LOG.debug(
            "multiple suitable devices found: %s",
            ", ".join(f"{name} ({path})" for path, name in candidates),
        )
    return candidates[0][0]


# ---------------------------------------------------------------------------
# Gesture detection (pure function, unit-tested)
# ---------------------------------------------------------------------------


def detect_gesture(dx: int, dy: int, threshold: int) -> str | None:
    """Return ``left``/``right``/``up``/``down`` once the threshold is hit.

    The dominant axis decides the direction.  Linux reports positive Y
    downwards, hence ``dy < 0`` means "up".
    """
    if max(abs(dx), abs(dy)) < threshold:
        return None
    if abs(dx) > abs(dy):
        return "left" if dx < 0 else "right"
    return "up" if dy < 0 else "down"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


class Config:
    """Effective configuration = GSettings values overlaid with CLI flags."""

    def __init__(self, cli: argparse.Namespace) -> None:
        self._lock = threading.Lock()
        self._cli = cli
        self._enabled = True
        self._threshold = DEFAULT_THRESHOLD
        self._device = DEFAULT_DEVICE
        self._actions = dict(DEFAULT_ACTIONS)
        self.has_settings = False

    # -- writers -----------------------------------------------------------
    def update(
        self,
        enabled: bool | None = None,
        threshold: int | None = None,
        device: str | None = None,
        actions: dict | None = None,
    ) -> None:
        with self._lock:
            if enabled is not None:
                self._enabled = bool(enabled)
            if threshold is not None:
                self._threshold = int(threshold)
            if device is not None:
                self._device = device or DEFAULT_DEVICE
            if actions:
                self._actions.update(actions)

    # -- readers -----------------------------------------------------------
    @property
    def enabled(self) -> bool:
        with self._lock:
            return self._enabled

    @property
    def threshold(self) -> int:
        if self._cli.threshold is not None:
            return self._cli.threshold
        with self._lock:
            return self._threshold

    @property
    def device(self) -> str:
        if self._cli.device:
            return self._cli.device
        with self._lock:
            return self._device

    def action(self, direction: str) -> str | None:
        with self._lock:
            return self._actions.get(DIRECTION_KEYS[direction])

    def describe(self) -> str:
        return (
            f"enabled={self.enabled} threshold={self.threshold} "
            f"device={self.device}"
        )


class SettingsWatcher:
    """Feeds GSettings changes into a :class:`Config`.

    A tiny GLib main loop runs in a background thread so that GSettings
    change notifications are actually dispatched while the main thread is
    busy reading the evdev device.
    """

    def __init__(self, config: Config) -> None:
        self.config = config
        self.settings = None
        self.loop = None
        self._thread = None

    def start(self) -> None:
        if Gio is None:
            LOG.warning(
                "python3-gobject not available; configuration is fixed "
                "at startup"
            )
            return

        source = Gio.SettingsSchemaSource.get_default()
        schema = source.lookup(SCHEMA_ID, True) if source else None
        if schema is None:
            LOG.warning(
                "GSettings schema %s not found (run scripts/install.sh or "
                "glib-compile-schemas); using built-in defaults",
                SCHEMA_ID,
            )
            return

        self.settings = Gio.Settings.new_full(schema, None, None)
        self.config.has_settings = True
        self._load()
        self.settings.connect("changed", self._on_changed)

        self.loop = GLib.MainLoop()
        self._thread = threading.Thread(
            target=self.loop.run, name="glib-main-loop", daemon=True
        )
        self._thread.start()
        LOG.debug("GSettings watcher started")

    def stop(self) -> None:
        if self.loop is not None:
            self.loop.quit()

    def _on_changed(self, _settings, key: str) -> None:
        LOG.debug("setting changed: %s", key)
        self._load()

    def _load(self) -> None:
        actions = {
            key: self.settings.get_string(key) for key in DEFAULT_ACTIONS
        }
        self.config.update(
            enabled=self.settings.get_boolean("enabled"),
            threshold=self.settings.get_int("threshold"),
            device=self.settings.get_string("device"),
            actions=actions,
        )


# ---------------------------------------------------------------------------
# D-Bus bridge
# ---------------------------------------------------------------------------


class GnomeBridge:
    """Calls the GNOME Shell extension over the session bus.

    Uses a persistent ``dbus-python`` connection instead of spawning
    ``gdbus`` for every gesture.  Failures (extension disabled, session bus
    gone) are logged once instead of spamming the journal.
    """

    def __init__(self) -> None:
        self._bus = None
        self._missing = False
        self._failed = False

    def call(self, method: str | None) -> bool:
        if method is None:
            LOG.debug("action is 'none'; nothing to do")
            return True

        if dbus is None:
            if not self._missing:
                self._missing = True
                LOG.error("python3-dbus is not installed; gestures disabled")
            return False

        try:
            if self._bus is None:
                self._bus = dbus.SessionBus()
                LOG.debug("connected to the session bus")

            if not self._bus.name_has_owner(BUS_DEST):
                self._warn_missing()
                return False

            message = dbus.lowlevel.MethodCallMessage(
                BUS_DEST, OBJECT_PATH, IFACE, method
            )
            # NB: this C-level API only accepts positional arguments.
            self._bus.send_message_with_reply_and_block(message, 2.0)
        except DBusException as exc:
            self._failed = True
            LOG.warning("D-Bus call %s() failed: %s", method, exc)
            self._bus = None
            return False
        except Exception as exc:  # never let a bus problem kill the daemon
            self._failed = True
            LOG.error("unexpected D-Bus error calling %s(): %r", method, exc)
            self._bus = None
            return False

        if self._failed:
            LOG.info("D-Bus connection to the extension recovered")
        self._failed = False
        self._missing = False
        LOG.debug("D-Bus %s() ok", method)
        return True

    def _warn_missing(self) -> None:
        if not self._missing:
            self._missing = True
            LOG.warning(
                "extension is not owning %s (is "
                "'gnome-extensions enable middle-drag-gestures@swad' run?); "
                "gestures will be ignored",
                BUS_DEST,
            )

    def close(self) -> None:
        self._bus = None


# ---------------------------------------------------------------------------
# Virtual mouse
# ---------------------------------------------------------------------------


def create_virtual_mouse() -> UInput:
    ui = UInput(
        VIRTUAL_CAPABILITIES,
        name=VIRTUAL_MOUSE_NAME,
        version=1,
    )
    # Give udev / libinput a moment to pick the new device up.
    time.sleep(0.2)
    LOG.info("virtual mouse created (%s)", VIRTUAL_MOUSE_NAME)
    return ui


# ---------------------------------------------------------------------------
# Drag state machine
# ---------------------------------------------------------------------------


class DragState:
    """Tracks one middle-button hold: ``fired`` keeps it one-gesture-per-press."""

    __slots__ = ("dragging", "fired", "dx", "dy")

    def __init__(self) -> None:
        self.dragging = False
        self.fired = False
        self.dx = 0
        self.dy = 0

    def press(self) -> None:
        self.dragging = True
        self.fired = False
        self.dx = 0
        self.dy = 0
        LOG.debug("MIDDLE DOWN")

    def release(self) -> None:
        if self.dragging:
            LOG.debug("MIDDLE UP")
        self.dragging = False
        self.fired = False


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------


class Daemon:
    def __init__(self, config: Config, bridge: GnomeBridge) -> None:
        self.config = config
        self.bridge = bridge
        self.stopping = threading.Event()
        self.ui: UInput | None = None
        self._logged_waiting_device = False
        self._logged_disabled = False
        self._write_errors = 0

    # -- lifecycle ---------------------------------------------------------
    def request_stop(self, *_args) -> None:
        self.stopping.set()

    def run(self) -> int:
        self.ui = create_virtual_mouse()

        while not self.stopping.is_set():
            if not self.config.enabled:
                if not self._logged_disabled:
                    self._logged_disabled = True
                    LOG.info("gestures disabled via settings; idle")
                self.stopping.wait(1.0)
                continue
            self._logged_disabled = False

            path = discover_device(self.config.device)
            if path is None:
                if not self._logged_waiting_device:
                    self._logged_waiting_device = True
                    LOG.warning(
                        "no suitable mouse found (device=%s); waiting",
                        self.config.device,
                    )
                self.stopping.wait(2.0)
                continue
            self._logged_waiting_device = False

            try:
                self._run_session(path)
            except Exception:
                # One bad event or device must not take the whole service
                # down: log it, back off and start over.
                LOG.exception("unexpected error while driving %s", path)
                self.stopping.wait(2.0)

        self._cleanup()
        return 0

    def _cleanup(self) -> None:
        if self.ui is not None:
            try:
                self.ui.close()
                LOG.info("virtual mouse removed")
            except Exception:
                pass
            self.ui = None
        self.bridge.close()

    # -- one grab session --------------------------------------------------
    def _run_session(self, path: str) -> None:
        try:
            device = InputDevice(path)
        except (OSError, PermissionError) as exc:
            LOG.error("cannot open %s: %s", path, exc)
            self.stopping.wait(2.0)
            return

        grabbed = False
        try:
            LOG.info("using %s (%s)", path, device.name)
            device.grab()
            grabbed = True
            LOG.info(
                "physical mouse grabbed; middle button reserved "
                "(threshold=%dpx, Ctrl+C or SIGTERM to stop)",
                self.config.threshold,
            )

            state = DragState()
            self._read_events(device, state)

        except DeviceGone:
            LOG.info("device %s disconnected; releasing", path)
        except OSError as exc:
            LOG.info("device %s went away: %s", path, exc)
        except PermissionError as exc:
            LOG.error(
                "permission denied on %s (is your user in the 'input' "
                "group?): %s",
                path,
                exc,
            )
            self.stopping.wait(5.0)
        finally:
            if grabbed:
                try:
                    device.ungrab()
                    LOG.debug("physical mouse released")
                except OSError:
                    pass
            try:
                device.close()
            except OSError:
                pass

    def _read_events(self, device: InputDevice, state: DragState) -> None:
        while not self.stopping.is_set():
            snapshot = self.config
            if not snapshot.enabled:
                LOG.info("gestures disabled via settings; releasing grab")
                return

            try:
                readable, _, _ = select.select([device.fd], [], [], 1.0)
            except (OSError, ValueError) as exc:
                raise DeviceGone(str(exc)) from exc

            if not readable:
                continue

            try:
                # ``read()`` is a generator: the OSError surfaces while
                # iterating, not when it is created.
                for event in device.read():
                    self._handle_event(event, snapshot, state)
            except (OSError, ValueError) as exc:
                raise DeviceGone(str(exc)) from exc

    # -- event plumbing ----------------------------------------------------
    def _handle_event(self, event, config: Config, state: DragState) -> None:
        if event.type == ecodes.EV_KEY:
            if event.code == ecodes.BTN_MIDDLE:
                if event.value == 1:
                    state.press()
                elif event.value == 0:
                    state.release()
                # Never forward the middle button: it is the gesture modifier.
                return
            self._forward(event)
            return

        if event.type == ecodes.EV_REL:
            self._forward(event)

            if state.dragging and not state.fired:
                if event.code == ecodes.REL_X:
                    state.dx += event.value
                elif event.code == ecodes.REL_Y:
                    state.dy += event.value
                else:
                    return

                direction = detect_gesture(
                    state.dx, state.dy, config.threshold
                )
                if direction is None:
                    return

                state.fired = True
                LOG.info(
                    "gesture %s (dx=%d, dy=%d)",
                    direction.upper(),
                    state.dx,
                    state.dy,
                )
                self._dispatch(direction, config)

    def _dispatch(self, direction: str, config: Config) -> None:
        action = config.action(direction)
        method = ACTION_METHODS.get(action)
        if action not in ACTION_METHODS:
            LOG.warning("unknown action %r for %s gesture", action, direction)
            return
        if method is None:
            LOG.debug("%s gesture is mapped to 'none'", direction)
            return
        if self.bridge.call(method):
            LOG.info("%s → %s()", direction, method)

    def _forward(self, event) -> None:
        if self.ui is None:
            return
        if event.type == ecodes.EV_KEY and event.code not in VIRTUAL_KEY_CAPS:
            return
        if event.type == ecodes.EV_REL and event.code not in VIRTUAL_REL_CAPS:
            return
        try:
            self.ui.write(event.type, event.code, event.value)
            self.ui.syn()
        except OSError as exc:
            self._write_errors += 1
            if self._write_errors == 1:
                LOG.error("cannot write to virtual mouse: %s", exc)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="middle-drag-daemon",
        description="System-wide middle-mouse drag gestures (evdev/uinput).",
    )
    parser.add_argument(
        "--device",
        metavar="PATH",
        default=None,
        help="input device to grab, or 'auto' (default: from settings)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        metavar="PIXELS",
        default=None,
        help="drag distance in pixels before a gesture fires "
        "(default: from settings, 100)",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="print suitable input devices and exit",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="enable debug logging",
    )
    return parser.parse_args(argv)


def setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    logging.getLogger("dbus").setLevel(logging.WARNING)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    setup_logging(args.verbose)

    if args.list_devices:
        devices = scan_devices()
        if not devices:
            print("No suitable devices found.")
            return 1
        for path, name in devices:
            print(f"{path}\t{name}")
        return 0

    if args.device:
        if args.device != "auto" and not os.path.exists(args.device):
            LOG.error("device %s does not exist", args.device)
            return 1

    config = Config(args)

    watcher = SettingsWatcher(config)
    watcher.start()

    if args.threshold is None and args.device is None:
        LOG.debug("configuration: %s", config.describe())

    bridge = GnomeBridge()
    daemon = Daemon(config, bridge)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(
            sig,
            lambda signum, _frame: (
                LOG.info("received %s; shutting down", signal.Signals(signum).name),
                daemon.request_stop(),
            ),
        )

    try:
        return daemon.run()
    except KeyboardInterrupt:
        LOG.info("interrupted; shutting down")
        daemon.request_stop()
        return 0
    finally:
        daemon.request_stop()
        daemon._cleanup()
        watcher.stop()
        LOG.info("stopped; physical mouse released")


if __name__ == "__main__":
    sys.exit(main())
