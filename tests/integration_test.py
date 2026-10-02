#!/usr/bin/env python3
"""End-to-end integration test for the input daemon.

Creates a *synthetic* mouse with ``uinput`` ("Middle Drag Test Mouse"), runs
the daemon against it, injects a scripted gesture sequence and asserts that:

* the four gestures are detected exactly once each,
* the D-Bus dispatch happens for the workspace methods,
* normal events are re-emitted on the virtual mouse,
* middle-button events are **never** forwarded.

Nothing leaks into the live desktop session: the daemon grabs the fake mouse
and the test grabs the virtual mouse, so neither the synthetic events nor the
re-emitted ones reach GNOME's input stack.

Run from the repository root::

    python3 tests/integration_test.py
"""

from __future__ import annotations

import pathlib
import select
import signal
import subprocess
import sys
import threading
import time

from evdev import InputDevice, UInput, ecodes, list_devices

ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = ROOT / "daemon" / "middle-drag-daemon.py"

#: Set in main() so failures can always print the daemon log.
DAEMON_PROC = None

FAKE_NAME = "Middle Drag Test Mouse"
VIRTUAL_NAME = "Middle Drag Virtual Mouse"
THRESHOLD = 20

FAKE_CAPS = {
    ecodes.EV_KEY: [
        ecodes.BTN_LEFT,
        ecodes.BTN_RIGHT,
        ecodes.BTN_MIDDLE,
    ],
    ecodes.EV_REL: [
        ecodes.REL_X,
        ecodes.REL_Y,
        ecodes.REL_WHEEL,
    ],
}


class TestFailure(Exception):
    pass


def find_event_path(name: str, timeout: float = 6.0, exclude: set | None = None) -> str:
    """Return the path of a device called *name*.

    With *exclude*, only devices whose path is not in that set are
    considered - useful when a second daemon (e.g. the installed service)
    has already created a device with the same name.
    """
    exclude = exclude or set()
    deadline = time.time() + timeout
    while time.time() < deadline:
        for path in list_devices():
            if path in exclude:
                continue
            try:
                device = InputDevice(path)
            except OSError:
                continue
            try:
                if device.name == name:
                    return device.path
            finally:
                device.close()
        time.sleep(0.1)
    raise TestFailure(f"device {name!r} did not appear within {timeout}s")


def device_paths_named(name: str) -> set:
    paths = set()
    for path in list_devices():
        try:
            device = InputDevice(path)
        except OSError:
            continue
        try:
            if device.name == name:
                paths.add(path)
        finally:
            device.close()
    return paths


def wait_for(predicate, timeout: float, what: str):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise TestFailure(f"timed out waiting for {what}")


class DaemonProcess:
    """Runs the daemon and collects its log lines."""

    def __init__(self, device_path: str) -> None:
        self.proc = subprocess.Popen(
            [
                sys.executable,
                str(DAEMON),
                "--device",
                device_path,
                "--threshold",
                str(THRESHOLD),
                "--verbose",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self.lines: list[str] = []
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.lines.append(line.rstrip("\n"))

    def find(self, needle: str) -> bool:
        return any(needle in line for line in self.lines)

    def matching(self, needle: str) -> list[str]:
        return [line for line in self.lines if needle in line]

    def dump(self) -> str:
        return "\n".join(self.lines)

    def stop(self) -> int:
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self._reader.join(timeout=2)
        return self.proc.returncode or 0


class EventCollector:
    """Reads (and grabs) the virtual mouse so events never reach the session."""

    def __init__(self, path: str) -> None:
        self.device = InputDevice(path)
        self.device.grab()
        self.events: list[tuple[int, int, int]] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                readable, _, _ = select.select([self.device.fd], [], [], 0.1)
            except (OSError, ValueError):
                return
            if not readable:
                continue
            try:
                for event in self.device.read():
                    if event.type in (ecodes.EV_KEY, ecodes.EV_REL):
                        self.events.append(
                            (event.type, event.code, event.value)
                        )
            except OSError:
                return

    def codes(self, ev_type: int) -> list[int]:
        return [code for kind, code, _ in self.events if kind == ev_type]

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2)
        try:
            self.device.ungrab()
        except OSError:
            pass
        self.device.close()


def inject(ui: UInput, events: list[tuple[int, int, int]]) -> None:
    for ev_type, code, value in events:
        ui.write(ev_type, code, value)
    ui.syn()
    time.sleep(0.05)


def middle_down(ui):
    inject(ui, [(ecodes.EV_KEY, ecodes.BTN_MIDDLE, 1)])


def middle_up(ui):
    inject(ui, [(ecodes.EV_KEY, ecodes.BTN_MIDDLE, 0)])


def drag(ui, axis: int, step: int, extra: int = 0) -> None:
    """Move in three sub-threshold steps, then optionally overshoot."""
    for _ in range(3):
        inject(ui, [(ecodes.EV_REL, axis, step)])
    if extra:
        inject(ui, [(ecodes.EV_REL, axis, extra)])


def check(condition: bool, message: str, failures: list[str]) -> None:
    if condition:
        print(f"  ok   - {message}")
    else:
        print(f"  FAIL - {message}")
        failures.append(message)


def skip(message: str, skips: list[str], reason: str) -> None:
    """An assertion that does not apply in this session's current state."""
    print(f"  SKIP - {message} ({reason})")
    skips.append(message)


def main() -> int:
    global DAEMON_PROC
    failures: list[str] = []
    skips: list[str] = []

    fake = UInput(FAKE_CAPS, name=FAKE_NAME, version=1)
    time.sleep(0.6)
    fake_path = find_event_path(FAKE_NAME)
    print(f"synthetic mouse: {fake_path}")

    # The installed service may already own a virtual mouse; make sure we
    # attach to the one this test's daemon creates.
    preexisting_virtual = device_paths_named(VIRTUAL_NAME)

    daemon = DaemonProcess(fake_path)
    DAEMON_PROC = daemon
    collector = None
    try:
        wait_for(
            lambda: daemon.find("physical mouse grabbed"),
            8,
            "the daemon to grab the synthetic mouse",
        )
        print("daemon grabbed the synthetic mouse")

        virtual_path = find_event_path(VIRTUAL_NAME, exclude=preexisting_virtual)
        collector = EventCollector(virtual_path)
        print(f"virtual mouse grabbed by test: {virtual_path}")

        # --- gesture 1: LEFT (plus an overshoot that must not re-fire) ----
        middle_down(fake)
        drag(fake, ecodes.REL_X, -8, extra=-100)
        middle_up(fake)

        # --- gesture 2: RIGHT ---------------------------------------------
        middle_down(fake)
        drag(fake, ecodes.REL_X, +8)
        middle_up(fake)

        # --- gesture 3: UP -------------------------------------------------
        middle_down(fake)
        drag(fake, ecodes.REL_Y, -8)
        middle_up(fake)

        # --- gesture 4: DOWN -----------------------------------------------
        middle_down(fake)
        drag(fake, ecodes.REL_Y, +8)
        middle_up(fake)

        # --- normal input must still be forwarded ---------------------------
        inject(fake, [(ecodes.EV_REL, ecodes.REL_X, 5)])
        inject(fake, [(ecodes.EV_REL, ecodes.REL_WHEEL, -1)])
        inject(
            fake,
            [
                (ecodes.EV_KEY, ecodes.BTN_LEFT, 1),
                (ecodes.EV_KEY, ecodes.BTN_LEFT, 0),
            ],
        )

        wait_for(
            lambda: len(daemon.matching("gesture ")) >= 4,
            6,
            "four gesture detections in the daemon log",
        )
        time.sleep(0.5)

        print("\nassertions:")
        gesture_lines = [
            line for line in daemon.lines if "gesture " in line and "->" not in line
        ]
        directions = []
        for line in gesture_lines:
            for direction in ("LEFT", "RIGHT", "UP", "DOWN"):
                if f"gesture {direction} " in line:
                    directions.append(direction)

        check(
            directions == ["LEFT", "RIGHT", "UP", "DOWN"],
            f"gestures detected in order (got {directions})",
            failures,
        )
        check(
            len(daemon.matching("gesture LEFT")) == 1,
            "the overshoot did not fire a second LEFT gesture",
            failures,
        )
        # The three dispatch assertions need the extension to be installed,
        # enabled and loaded in *this* GNOME session - it owns
        # org.gnome.Shell.Extensions.MiddleDrag, and without that name the
        # daemon logs a warning and deliberately ignores the gesture.  On a
        # machine where the product has been uninstalled (the state
        # verify-clean.sh is meant to produce) there is nothing to assert
        # against, so they are skipped rather than reported as failures.
        extension_live = not daemon.find("extension is not owning")
        dispatch = [
            ("LEFT gesture dispatched NextWorkspace()", lambda: daemon.find("NextWorkspace()")),
            ("RIGHT gesture dispatched PreviousWorkspace()", lambda: daemon.find("PreviousWorkspace()")),
            (
                "UP/DOWN gestures targeted HideOverview()/ShowOverview()",
                lambda: bool(daemon.find("ShowOverview")) and bool(daemon.find("HideOverview")),
            ),
        ]
        if extension_live:
            for message, predicate in dispatch:
                check(predicate(), message, failures)
        else:
            reason = (
                "extension not installed/enabled in this session - "
                "run scripts/install.sh, log in again, then re-run"
            )
            for message, _ in dispatch:
                skip(message, skips, reason)

        check(
            not daemon.find("unknown action"),
            "no unknown action warnings",
            failures,
        )

        forwarded_keys = collector.codes(ecodes.EV_KEY)
        check(
            ecodes.BTN_LEFT in forwarded_keys,
            "BTN_LEFT was forwarded to the virtual mouse",
            failures,
        )
        check(
            ecodes.BTN_MIDDLE not in forwarded_keys,
            "BTN_MIDDLE was never forwarded (consumed)",
            failures,
        )
        check(
            ecodes.REL_X in collector.codes(ecodes.EV_REL),
            "REL_X was forwarded to the virtual mouse",
            failures,
        )
        check(
            ecodes.REL_WHEEL in collector.codes(ecodes.EV_REL),
            "REL_WHEEL was forwarded to the virtual mouse",
            failures,
        )
        check(
            len(collector.events) > 0,
            f"virtual mouse emitted events ({len(collector.events)} seen)",
            failures,
        )

    finally:
        if collector is not None:
            collector.stop()
        returncode = daemon.stop()
        print(f"\ndaemon exited with code {returncode}")

    # The daemon must have released the fake device on SIGTERM.  Probe while
    # the fake device still exists (closing the uinput fd removes it).
    time.sleep(0.3)
    try:
        probe = InputDevice(fake_path)
        probe.grab()
        probe.ungrab()
        probe.close()
        released = True
    except OSError:
        released = False
    fake.close()
    print("\nassertions (shutdown):")
    check(
        returncode == 0,
        "daemon exited cleanly on SIGTERM",
        failures,
    )
    check(
        released,
        "physical device grab was released on shutdown",
        failures,
    )

    if skips:
        print(
            f"\n{len(skips)} assertion(s) skipped - the extension is not "
            "active in this session"
        )

    if failures:
        print("\n--- daemon log ---")
        print(daemon.dump())
        print(f"\n{len(failures)} assertion(s) failed")
        return 1

    print("\nall integration assertions passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except TestFailure as exc:
        print(f"\nFAIL: {exc}", file=sys.stderr)
        if DAEMON_PROC is not None:
            print("\n--- daemon log ---", file=sys.stderr)
            print(DAEMON_PROC.dump(), file=sys.stderr)
            DAEMON_PROC.stop()
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
