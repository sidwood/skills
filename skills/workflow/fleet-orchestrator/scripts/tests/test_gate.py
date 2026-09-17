"""Tests for fleet gate subcommand."""

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


class GateTests(unittest.TestCase):
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
        api_dir = self.clone / "apps" / "api"
        api_dir.mkdir(parents=True)
        (api_dir / "handler.py").write_text("print('ok')\n")
        subprocess.run(["git", "add", "apps"], cwd=self.clone, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "api"], cwd=self.clone, check=True, capture_output=True)
        base_tip = subprocess.run(
            ["git", "-C", str(self.seed), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        branch_tip = subprocess.run(
            ["git", "-C", str(self.clone), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        config["seed"] = str(self.seed)
        config["streams"][0]["checkout"] = str(self.clone)
        config["streams"][0]["baseTip"] = base_tip
        config["streams"][0]["tip"] = branch_tip
        self.config_path = Path(self.tmp.name) / "fleet.json"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        os.environ["FLEET_CONFIG"] = str(self.config_path)

    def test_gate_selects_prefix_suite(self) -> None:
        result = run_fleet("gate", "T094.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("npm ci", result.stdout)
        self.assertIn("npm test --workspace=api", result.stdout)
        self.assertNotIn("npm test -- lib", result.stdout)


if __name__ == "__main__":
    unittest.main()
