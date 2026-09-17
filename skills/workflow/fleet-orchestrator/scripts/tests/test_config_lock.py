"""Tests for serialized fleet.json read-modify-write operations."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402


WORKER = """
import sys
import time
from pathlib import Path

import fleet

path = Path(sys.argv[1])
with fleet.config_lock(path):
    config = fleet.load_config(path)
    time.sleep(0.15)
    config.setdefault("writers", []).append(sys.argv[2])
    fleet.save_config(path, config)
"""


class ConfigLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        self.config_path.write_text('{"writers": []}\n')

    def test_concurrent_updates_are_serialized(self) -> None:
        env = os.environ.copy()
        env["PYTHONPATH"] = str(SCRIPTS_DIR)
        processes = [
            subprocess.Popen(
                [sys.executable, "-c", WORKER, str(self.config_path), name],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for name in ("first", "second")
        ]
        results = [process.communicate(timeout=5) for process in processes]
        self.assertEqual(len(processes), len(results))
        for process, (_stdout, stderr) in zip(processes, results):
            self.assertEqual(process.returncode, 0, stderr)

        config = fleet.load_config(self.config_path)
        self.assertCountEqual(config["writers"], ["first", "second"])

    def test_body_oserror_is_not_mislabeled_as_a_lock_failure(self) -> None:
        with self.assertRaisesRegex(OSError, "body failed"):
            with fleet.config_lock(self.config_path):
                raise OSError("body failed")


if __name__ == "__main__":
    unittest.main()
