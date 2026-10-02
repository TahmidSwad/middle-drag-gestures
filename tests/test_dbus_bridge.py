"""Unit tests for the GNOME Shell D-Bus bridge.

Run from the repository root:

    python3 -m unittest discover -s tests -v
"""

import importlib.util
import pathlib
import sys
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = ROOT / "daemon" / "middle-drag-daemon.py"

_spec = importlib.util.spec_from_file_location("middle_drag_daemon", DAEMON)
daemon = importlib.util.module_from_spec(_spec)
sys.modules["middle_drag_daemon"] = daemon
_spec.loader.exec_module(daemon)

HAVE_DBUS = daemon.dbus is not None


class FakeMethodCallMessage:
    """Stand-in for ``dbus.lowlevel.MethodCallMessage``."""

    def __init__(self, dest, path, iface, member):
        self.dest = dest
        self.path = path
        self.iface = iface
        self.member = member

    def get_member(self):
        return self.member


class FakeBus:
    """Records method calls and raises the configured error for a name."""

    def __init__(self, errors=None, owns=True):
        self.calls = []
        self.errors = errors or {}
        self.owns = owns

    def name_has_owner(self, _dest):
        return self.owns

    def send_message_with_reply_and_block(self, message, _timeout):
        name = message.get_member()
        self.calls.append(name)
        error = self.errors.get(name)
        if error is not None:
            raise error
        return True


def make_dbus(bus):
    """A minimal ``dbus`` module replacement backed by ``bus``."""
    return types.SimpleNamespace(
        SessionBus=lambda: bus,
        lowlevel=types.SimpleNamespace(
            MethodCallMessage=FakeMethodCallMessage
        ),
    )


def unknown_method(name):
    return daemon.DBusException(
        f'org.freedesktop.DBus.Error.UnknownMethod: No such method "{name}"'
    )


@unittest.skipUnless(HAVE_DBUS, "python3-dbus is not installed")
class BridgeTests(unittest.TestCase):
    def setUp(self):
        self._real_dbus = daemon.dbus

    def tearDown(self):
        daemon.dbus = self._real_dbus

    def bridge(self, errors=None, owns=True):
        bus = FakeBus(errors, owns=owns)
        daemon.dbus = make_dbus(bus)
        return daemon.GnomeBridge(), bus

    def warnings(self, logs):
        return "\n".join(logs.output)

    def test_current_method_is_called_directly(self):
        bridge, bus = self.bridge()
        with self.assertLogs("middle-drag-daemon", level="DEBUG"):
            self.assertTrue(bridge.call("ShowOverview"))
        self.assertEqual(bus.calls, ["ShowOverview"])

    def test_no_action_skips_the_bus(self):
        bridge, bus = self.bridge()
        with self.assertLogs("middle-drag-daemon", level="DEBUG"):
            self.assertTrue(bridge.call(None))
        self.assertEqual(bus.calls, [])

    def test_show_overview_falls_back_to_overview_up(self):
        bridge, bus = self.bridge(
            {"ShowOverview": unknown_method("ShowOverview")}
        )
        with self.assertLogs("middle-drag-daemon", level="WARNING") as logs:
            self.assertTrue(bridge.call("ShowOverview"))
        self.assertEqual(bus.calls, ["ShowOverview", "OverviewUp"])
        self.assertIn("legacy OverviewUp()", self.warnings(logs))

    def test_hide_overview_falls_back_to_overview_down(self):
        bridge, bus = self.bridge(
            {"HideOverview": unknown_method("HideOverview")}
        )
        with self.assertLogs("middle-drag-daemon", level="WARNING") as logs:
            self.assertTrue(bridge.call("HideOverview"))
        self.assertEqual(bus.calls, ["HideOverview", "OverviewDown"])
        self.assertIn("legacy OverviewDown()", self.warnings(logs))

    def test_legacy_fallback_is_announced_only_once(self):
        errors = {
            "ShowOverview": unknown_method("ShowOverview"),
            "HideOverview": unknown_method("HideOverview"),
        }
        bridge, bus = self.bridge(errors)
        with self.assertLogs("middle-drag-daemon", level="WARNING") as logs:
            self.assertTrue(bridge.call("ShowOverview"))
            self.assertTrue(bridge.call("HideOverview"))
        notices = [
            line
            for line in logs.output
            if "predates the D-Bus method rename" in line
        ]
        self.assertEqual(len(notices), 1)
        self.assertEqual(bus.calls, ["ShowOverview", "OverviewUp",
                                     "HideOverview", "OverviewDown"])

    def test_unknown_method_without_a_fallback_keeps_the_hint(self):
        bridge, bus = self.bridge(
            {"NextWorkspace": unknown_method("NextWorkspace")}
        )
        with self.assertLogs("middle-drag-daemon", level="WARNING") as logs:
            self.assertFalse(bridge.call("NextWorkspace"))
        self.assertEqual(bus.calls, ["NextWorkspace"])
        self.assertIn("Log out and log back in", self.warnings(logs))

    def test_both_names_unknown_fails_with_a_hint(self):
        errors = {
            "ShowOverview": unknown_method("ShowOverview"),
            "OverviewUp": unknown_method("OverviewUp"),
        }
        bridge, bus = self.bridge(errors)
        with self.assertLogs("middle-drag-daemon", level="WARNING") as logs:
            self.assertFalse(bridge.call("ShowOverview"))
        self.assertEqual(bus.calls, ["ShowOverview", "OverviewUp"])
        self.assertIn("Log out and log back in", self.warnings(logs))

    def test_other_errors_do_not_trigger_the_fallback(self):
        error = daemon.DBusException(
            "org.freedesktop.DBus.Error.NoReply: timeout"
        )
        bridge, bus = self.bridge({"ShowOverview": error})
        with self.assertLogs("middle-drag-daemon", level="WARNING"):
            self.assertFalse(bridge.call("ShowOverview"))
        self.assertEqual(bus.calls, ["ShowOverview"])

    def test_missing_owner_skips_the_call_and_the_fallback(self):
        bridge, bus = self.bridge(owns=False)
        with self.assertLogs("middle-drag-daemon", level="WARNING") as logs:
            self.assertFalse(bridge.call("ShowOverview"))
        self.assertEqual(bus.calls, [])
        self.assertIn("extension is not owning", self.warnings(logs))

    def test_failed_call_can_recover(self):
        bridge, bus = self.bridge(
            {"NextWorkspace": unknown_method("NextWorkspace")}
        )
        with self.assertLogs("middle-drag-daemon", level="WARNING"):
            self.assertFalse(bridge.call("NextWorkspace"))
        bus.errors.clear()
        with self.assertLogs("middle-drag-daemon", level="INFO") as logs:
            self.assertTrue(bridge.call("NextWorkspace"))
        self.assertIn("recovered", self.warnings(logs))


class LegacyMappingTests(unittest.TestCase):
    def test_only_renamed_methods_have_a_legacy_name(self):
        self.assertEqual(
            set(daemon.LEGACY_METHODS),
            {"ShowOverview", "HideOverview"},
        )

    def test_every_legacy_target_is_a_callable_method(self):
        for current, legacy in daemon.LEGACY_METHODS.items():
            self.assertIn(current, daemon.ACTION_METHODS.values())
            self.assertIsInstance(legacy, str)
            self.assertNotEqual(current, legacy)


if __name__ == "__main__":
    unittest.main()
