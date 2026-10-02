"""Unit tests for device selection logic.

Run from the repository root:

    python3 -m unittest discover -s tests -v
"""

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = ROOT / "daemon" / "middle-drag-daemon.py"

_spec = importlib.util.spec_from_file_location("middle_drag_daemon", DAEMON)
daemon = importlib.util.module_from_spec(_spec)
sys.modules["middle_drag_daemon"] = daemon
_spec.loader.exec_module(daemon)

ecodes = daemon.ecodes

MOUSE_KEYS = {ecodes.BTN_LEFT, ecodes.BTN_RIGHT, ecodes.BTN_MIDDLE}
MOUSE_REL = {ecodes.REL_X, ecodes.REL_Y, ecodes.REL_WHEEL}


class CapabilityTests(unittest.TestCase):
    def test_full_mouse_is_accepted(self):
        self.assertTrue(daemon.capabilities_ok(MOUSE_KEYS, MOUSE_REL))

    def test_keyboard_is_rejected(self):
        # Keyboards have plenty of EV_KEY codes but no relative axes.
        keys = {ecodes.KEY_A, ecodes.KEY_B, ecodes.KEY_ENTER}
        self.assertFalse(daemon.capabilities_ok(keys, set()))

    def test_touchpad_is_rejected(self):
        # Touchpads report absolute coordinates (EV_ABS) and have no
        # EV_REL axes at all, so the capability dict has no REL_X/REL_Y.
        class FakeTouchpad:
            name = "SynPS/2 Synaptics TouchPad"

            @staticmethod
            def capabilities():
                return {
                    ecodes.EV_KEY: [
                        ecodes.BTN_LEFT,
                        ecodes.BTN_RIGHT,
                        ecodes.BTN_MIDDLE,
                        ecodes.BTN_TOOL_FINGER,
                    ],
                    ecodes.EV_ABS: [ecodes.ABS_X, ecodes.ABS_Y],
                }

        self.assertFalse(daemon.is_suitable(FakeTouchpad()))

    def test_missing_middle_button_is_rejected(self):
        keys = {ecodes.BTN_LEFT, ecodes.BTN_RIGHT}
        self.assertFalse(daemon.capabilities_ok(keys, MOUSE_REL))

    def test_missing_axes_is_rejected(self):
        rels = {ecodes.REL_WHEEL}
        self.assertFalse(daemon.capabilities_ok(MOUSE_KEYS, rels))


class VirtualMouseTests(unittest.TestCase):
    def test_virtual_mouse_is_never_a_candidate(self):
        """The daemon must not grab the device it created itself."""

        class FakeDevice:
            name = daemon.VIRTUAL_MOUSE_NAME

            @staticmethod
            def capabilities():
                return {
                    ecodes.EV_KEY: list(MOUSE_KEYS),
                    ecodes.EV_REL: list(MOUSE_REL),
                }

        self.assertFalse(daemon.is_suitable(FakeDevice()))

    def test_virtual_mouse_advertises_required_capabilities(self):
        keys = set(daemon.VIRTUAL_CAPABILITIES[ecodes.EV_KEY])
        rels = set(daemon.VIRTUAL_CAPABILITIES[ecodes.EV_REL])
        self.assertTrue(daemon.capabilities_ok(keys, rels))

    def test_middle_button_is_advertised_but_consumed(self):
        # Advertising BTN_MIDDLE on the virtual device keeps it a valid
        # pointer device; the daemon simply never writes middle events.
        keys = set(daemon.VIRTUAL_CAPABILITIES[ecodes.EV_KEY])
        self.assertIn(ecodes.BTN_MIDDLE, keys)


class ActionMappingTests(unittest.TestCase):
    def test_every_default_action_has_a_method(self):
        for action in daemon.DEFAULT_ACTIONS.values():
            self.assertIn(action, daemon.ACTION_METHODS)

    def test_none_action_maps_to_no_method(self):
        self.assertIsNone(daemon.ACTION_METHODS["none"])

    def test_all_directions_are_mapped(self):
        self.assertEqual(
            set(daemon.DIRECTION_KEYS), {"left", "right", "up", "down"}
        )


class StaleExtensionHintTests(unittest.TestCase):
    """A Shell with pre-rename extension code must be reported usefully."""

    def test_unknown_method_is_detected(self):
        error = (
            "org.freedesktop.DBus.Error.UnknownMethod: No such interface "
            "'org.gnome.Shell.Extensions.MiddleDrag' on object "
            "/org/gnome/Shell/Extensions/MiddleDrag"
        )
        self.assertTrue(daemon.is_unknown_method_error(error))

    def test_method_name_variant_is_detected(self):
        error = "GDBus.Error:...UnknownMethod: Method \"ShowOverview\" not found"
        self.assertTrue(daemon.is_unknown_method_error(error))

    def test_unrelated_errors_are_not_flagged(self):
        self.assertFalse(
            daemon.is_unknown_method_error(
                "org.freedesktop.DBus.Error.ServiceUnknown: "
                "Name 'org.gnome.Shell.Extensions.MiddleDrag' is not"
            )
        )
        self.assertFalse(
            daemon.is_unknown_method_error(
                "org.freedesktop.DBus.Error.Timeout: Timeout was reached"
            )
        )


if __name__ == "__main__":
    unittest.main()
