"""The direction -> action defaults live in two places and must agree.

The GSettings schema is what GNOME Shell, prefs.js and `gsettings` report.
The daemon's DEFAULT_ACTIONS is its fallback when GSettings cannot answer -
an uncompiled schema, or a harness without dconf.  Swapping one and not the
other would make the mapping depend on which half of the product you asked.

Run from the repository root:

    python3 -m unittest discover -s tests -v
"""

import importlib.util
import pathlib
import sys
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = ROOT / "daemon" / "middle-drag-daemon.py"
SCHEMA = (ROOT / "extension" / "middle-drag-gestures@swad" / "schemas" /
          "org.gnome.shell.extensions.middle-drag.gschema.xml")

_spec = importlib.util.spec_from_file_location("middle_drag_daemon", DAEMON)
daemon = importlib.util.module_from_spec(_spec)
sys.modules["middle_drag_daemon"] = daemon
_spec.loader.exec_module(daemon)


def schema_defaults():
    """{'left-action': 'next-workspace', ...} parsed out of the schema XML."""
    defaults = {}
    for key in ET.parse(SCHEMA).getroot().iter("key"):
        name, default = key.get("name"), key.find("default")
        if name.endswith("-action") and default is not None:
            defaults[name] = default.text.strip().strip("'")
    return defaults


class ActionDefaultTests(unittest.TestCase):
    def test_schema_defaults_match_the_daemon_fallback(self):
        self.assertEqual(schema_defaults(), daemon.DEFAULT_ACTIONS)

    def test_every_default_is_a_known_action(self):
        for key, action in schema_defaults().items():
            with self.subTest(key=key):
                self.assertIn(action, daemon.ACTION_METHODS)

    def test_all_four_directions_are_declared(self):
        self.assertEqual(sorted(schema_defaults()),
                         ["down-action", "left-action",
                          "right-action", "up-action"])

    def test_orientation_matches_the_documentation(self):
        # README and docs/architecture.md both draw it this way: dragging up
        # opens the Overview, dragging down closes it again.
        defaults = schema_defaults()
        self.assertEqual(defaults["up-action"], "show-overview")
        self.assertEqual(defaults["down-action"], "hide-overview")
        self.assertEqual(defaults["left-action"], "next-workspace")
        self.assertEqual(defaults["right-action"], "previous-workspace")


if __name__ == "__main__":
    unittest.main()
