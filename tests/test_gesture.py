"""Unit tests for the daemon's gesture detection.

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


class DetectGestureTests(unittest.TestCase):
    def test_below_threshold_returns_none(self):
        self.assertIsNone(daemon.detect_gesture(99, 0, 100))
        self.assertIsNone(daemon.detect_gesture(0, 99, 100))
        self.assertIsNone(daemon.detect_gesture(-99, 50, 100))
        self.assertIsNone(daemon.detect_gesture(0, 0, 100))

    def test_exact_threshold_fires(self):
        self.assertEqual(daemon.detect_gesture(100, 0, 100), "right")
        self.assertEqual(daemon.detect_gesture(-100, 0, 100), "left")
        self.assertEqual(daemon.detect_gesture(0, 100, 100), "down")
        self.assertEqual(daemon.detect_gesture(0, -100, 100), "up")

    def test_horizontal_dominant(self):
        # Negative X in Linux pointer coordinates means "left".
        self.assertEqual(daemon.detect_gesture(-250, 30, 100), "left")
        self.assertEqual(daemon.detect_gesture(250, -30, 100), "right")

    def test_vertical_dominant(self):
        # Positive Y in Linux pointer coordinates means "down".
        self.assertEqual(daemon.detect_gesture(30, -250, 100), "up")
        self.assertEqual(daemon.detect_gesture(-30, 250, 100), "down")

    def test_tie_uses_vertical_axis(self):
        # Matches the reference implementation: horizontal only when
        # abs(dx) > abs(dy).
        self.assertEqual(daemon.detect_gesture(-100, 100, 100), "down")
        self.assertEqual(daemon.detect_gesture(100, -100, 100), "up")

    def test_accumulated_drag_can_cross_threshold(self):
        # A drag built from many small REL_X events keeps its sign.
        dx = dy = 0
        fired = None
        for _ in range(30):
            dx += -5  # 30 x -5 = -150
            gesture = daemon.detect_gesture(dx, dy, 100)
            if gesture:
                fired = gesture
                break
        self.assertEqual(fired, "left")

    def test_threshold_is_configurable(self):
        self.assertEqual(daemon.detect_gesture(15, 0, 10), "right")
        self.assertIsNone(daemon.detect_gesture(15, 0, 50))


if __name__ == "__main__":
    unittest.main()
