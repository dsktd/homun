import importlib.machinery
import importlib.util
import os
import unittest

PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "container", "screensavers", "tally", "slots"
)
loader = importlib.machinery.SourceFileLoader("slots_saver", PATH)
slots = importlib.util.module_from_spec(
    importlib.util.spec_from_loader("slots_saver", loader)
)
loader.exec_module(slots)


class ReelTests(unittest.TestCase):
    def test_reels_stop_in_order_on_their_goal(self):
        for reel, stop in enumerate(slots.STOPS):
            goal = slots.TAKEN
            before = slots.position(stop - 0.1, reel, goal)
            self.assertLess(before, len(slots.STRIP) + goal)
            end = int(slots.position(stop, reel, goal))
            self.assertEqual(slots.STRIP[end % len(slots.STRIP)], slots.STRIP[goal])
        self.assertEqual(sorted(slots.STOPS), list(slots.STOPS))

    def test_reels_slow_down(self):
        a = slots.position(0.5, 0, 0) - slots.position(0.0, 0, 0)
        b = slots.position(2.9, 0, 0) - slots.position(2.4, 0, 0)
        self.assertGreater(a, b)

    def test_target_follows_count(self):
        self.assertEqual([slots.target(2, i) for i in range(3)], [0, 0, 2])
        self.assertEqual(slots.target(None, 1), slots.UNKNOWN)


class CaptionTests(unittest.TestCase):
    def test_caption_names_the_count_and_rotates(self):
        for n in range(4):
            self.assertTrue(slots.caption(n, 0).startswith(f"{n} of 3"))
        self.assertNotEqual(slots.caption(3, 0), slots.caption(3, 1))
        self.assertTrue(slots.caption(None, 0).startswith("no count"))


if __name__ == "__main__":
    unittest.main()
