"""Tests for fleet land subcommand."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FLEET_PY = Path(__file__).resolve().parent.parent / "fleet.py"


def run_fleet(*args: str) -> subprocess.CompletedProcess[str]:
    config = os.environ["FLEET_CONFIG"]
    return subprocess.run(
        [sys.executable, str(FLEET_PY), "--config", config, *args],
        capture_output=True,
        text=True,
        check=False,
    )


class LandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.seed = Path(self.tmp.name) / "seed"
        self.clone = Path(self.tmp.name) / "clone"
        self.seed.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "f@t"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "F"], cwd=self.seed, check=True, capture_output=True)
        (self.seed / "README.md").write_text("seed\n")
        subprocess.run(["git", "add", "README.md"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "seed"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.seed), str(self.clone)], check=True, capture_output=True)
        subprocess.run(["git", "checkout", "-b", "fleet/t094-1"], cwd=self.clone, check=True, capture_output=True)
        (self.clone / "work.txt").write_text("work\n")
        subprocess.run(["git", "add", "work.txt"], cwd=self.clone, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "work"], cwd=self.clone, check=True, capture_output=True)
        self.base_tip = subprocess.run(
            ["git", "-C", str(self.seed), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        self.branch_tip = subprocess.run(
            ["git", "-C", str(self.clone), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        config["seed"] = str(self.seed)
        config["postLandChecks"] = []
        config["streams"][0]["checkout"] = str(self.clone)
        config["streams"][0]["baseTip"] = self.base_tip
        config["streams"][0]["tip"] = self.branch_tip
        config["streams"][0]["approvedTip"] = self.branch_tip
        config["streams"][0]["phase"] = "approved"
        self.config_path = Path(self.tmp.name) / "fleet.json"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        os.environ["FLEET_CONFIG"] = str(self.config_path)

    def test_land_happy_path(self) -> None:
        result = run_fleet("land", "T094.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.config_path.read_text())
        self.assertEqual(config["streams"][0]["phase"], "landed")
        self.assertTrue((self.seed / "work.txt").exists())

    def test_land_refuses_dirty_seed(self) -> None:
        (self.seed / "dirty.txt").write_text("x\n")
        result = run_fleet("land", "T094.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dirty", result.stderr.lower())

    def test_land_refuses_moved_seed(self) -> None:
        (self.seed / "move.txt").write_text("m\n")
        subprocess.run(["git", "add", "move.txt"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "move"], cwd=self.seed, check=True, capture_output=True)
        result = run_fleet("land", "T094.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rebase", result.stderr.lower())

    def test_land_refuses_fetch_head_mismatch(self) -> None:
        subprocess.run(
            ["git", "-C", str(self.clone), "commit", "--allow-empty", "-m", "after approval"],
            check=True,
            capture_output=True,
        )
        new_tip = subprocess.run(
            ["git", "-C", str(self.clone), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["tip"] = new_tip
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        result = run_fleet("land", "T094.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FETCH_HEAD", result.stderr)
        self.assertIn("approved", result.stderr.lower())
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertNotEqual(stream.get("phase"), "landed")

    def test_land_dry_run_after_subcommand(self) -> None:
        result = run_fleet("land", "T094.1", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("merge", result.stdout)

    def test_land_records_before_post_check_failure(self) -> None:
        config = json.loads(self.config_path.read_text())
        config["postLandChecks"] = ['sh -c "exit 1"']
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        result = run_fleet("land", "T094.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("post-land check failed", result.stderr)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "landed")

    def test_land_refuses_non_ff(self) -> None:
        (self.seed / "diverge.txt").write_text("d\n")
        subprocess.run(["git", "add", "diverge.txt"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "diverge"], cwd=self.seed, check=True, capture_output=True)
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["baseTip"] = subprocess.run(
            ["git", "-C", str(self.seed), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        result = run_fleet("land", "T094.1")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
