"""Guard: a test never reaches the live services dir."""

import isolate  # noqa: I001
import os
import unittest
from pathlib import Path


class IsolationTest(unittest.TestCase):
    def test_services_dir_is_scratch(self):
        services = Path(os.path.expanduser("~/claude/.services")).resolve()
        self.assertEqual(Path.home(), Path(isolate.HOME))
        self.assertTrue(str(services).startswith(isolate.HOME))
        if isolate.REAL_HOME and isolate.REAL_HOME != isolate.HOME:
            real = Path(isolate.REAL_HOME, "claude/.services").resolve()
            self.assertNotEqual(services, real)

    def test_bus_is_scratch(self):
        self.assertTrue(os.environ["HOMUN_BUS"].startswith(isolate.HOME))


if __name__ == "__main__":
    unittest.main()
