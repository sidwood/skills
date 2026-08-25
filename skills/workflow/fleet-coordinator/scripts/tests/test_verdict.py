"""Tests for fleet verdict subcommand."""

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


class VerdictTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            self.base_config = json.load(fh)
        os.environ["FLEET_CONFIG"] = str(self.config_path)

    def write_stream(self, **overrides: object) -> None:
        config = json.loads(json.dumps(self.base_config))
        stream = config["streams"][0]
        stream.update(overrides)
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    def test_verdict_commit_land_sets_approved_phase(self) -> None:
        self.write_stream(
            phase="verdict-pending",
            tip="abc1234567890",
            verdicts=[{"pass": 1, "tip": "abc", "approve": True, "findings": []}],
        )
        result = run_fleet("verdict", "T094.1", "--commit")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.config_path.read_text())
        self.assertEqual(config["streams"][0]["phase"], "approved")
        self.assertEqual(config["streams"][0]["approvedTip"], "abc1234567890")

    def test_approve_yes_land(self) -> None:
        self.write_stream(
            phase="verdict-pending",
            verdicts=[{"pass": 1, "tip": "abc", "approve": True, "findings": []}],
        )
        result = run_fleet("verdict", "T094.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LAND", result.stdout)

    def test_approve_no_in_scope_bounce(self) -> None:
        self.write_stream(
            phase="verdict-pending",
            bounceCount=0,
            verdicts=[
                {
                    "pass": 1,
                    "tip": "abc",
                    "approve": False,
                    "findings": [{"sev": "P1", "tag": "(A)", "loc": "a.py:1", "title": "bug"}],
                }
            ],
        )
        result = run_fleet("verdict", "T094.1", "--commit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BOUNCE", result.stdout)
        config = json.loads(self.config_path.read_text())
        self.assertEqual(config["streams"][0]["bounceCount"], 1)

    def test_cap_reached_escalate(self) -> None:
        self.write_stream(
            phase="verdict-pending",
            bounceCount=2,
            verdicts=[
                {
                    "pass": 2,
                    "tip": "abc",
                    "approve": False,
                    "findings": [{"sev": "P2", "tag": "(A)", "loc": "a.py:1", "title": "bug"}],
                }
            ],
        )
        result = run_fleet("verdict", "T094.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ESCALATE", result.stdout)
        self.assertIn("cap", result.stdout.lower())

    def test_deferred_only_prompt_violation(self) -> None:
        self.write_stream(
            phase="verdict-pending",
            verdicts=[
                {
                    "pass": 1,
                    "tip": "abc",
                    "approve": False,
                    "findings": [{"sev": "P2", "tag": "(B)", "loc": "a.py:1", "title": "defer"}],
                }
            ],
        )
        result = run_fleet("verdict", "T094.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ESCALATE", result.stdout)
        self.assertIn("prompt violation", result.stdout)

    def test_no_approve_escalate(self) -> None:
        self.write_stream(
            phase="verdict-pending",
            verdicts=[{"pass": 1, "tip": "abc", "findings": []}],
        )
        result = run_fleet("verdict", "T094.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ESCALATE", result.stdout)
        self.assertIn("no APPROVE", result.stdout)


if __name__ == "__main__":
    unittest.main()
