"""Tests for fleet prompt subcommand."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FLEET_PY = Path(__file__).resolve().parent.parent / "fleet.py"
REPO_ROOT = Path(__file__).resolve().parents[5]


def run_fleet(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        [sys.executable, str(FLEET_PY), *args],
        capture_output=True,
        text=True,
        env=merged,
        check=False,
    )


class PromptRenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        config["seed"] = self.tmp.name + "/seed"
        config["streams"][0]["checkout"] = self.tmp.name + "/clone"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        self.seed = Path(config["seed"])
        self.seed.mkdir(parents=True)
        self.clone = Path(config["streams"][0]["checkout"])
        self.clone.mkdir(parents=True)
        subprocess.run(["git", "init", "-b", "main"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(
            ["git", "config", "user.email", "fleet@test"],
            cwd=self.seed,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Fleet Test"],
            cwd=self.seed,
            check=True,
            capture_output=True,
        )
        (self.seed / "README.md").write_text("seed\n")
        subprocess.run(["git", "add", "README.md"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "seed commit"],
            cwd=self.seed,
            check=True,
            capture_output=True,
        )
        subprocess.run(["git", "clone", str(self.seed), str(self.clone)], check=True, capture_output=True)
        subprocess.run(
            ["git", "checkout", "-b", "fleet/t094-1"],
            cwd=self.clone,
            check=True,
            capture_output=True,
        )
        (self.clone / "work.txt").write_text("work\n")
        subprocess.run(["git", "add", "work.txt"], cwd=self.clone, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "implement"],
            cwd=self.clone,
            check=True,
            capture_output=True,
        )
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
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["baseTip"] = base_tip
        config["streams"][0]["tip"] = branch_tip
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    def test_implementer_prompt_renders_without_placeholders(self) -> None:
        out = Path(self.tmp.name) / "impl.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "implementer",
            "--out",
            str(out),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        text = out.read_text()
        self.assertIn("T094.1 — Add fleet scripts", text)
        self.assertIn("Local dev; P0 is data loss.", text)
        self.assertNotIn("{{", text)
        self.assertNotIn("<", text)

    def test_review_prompt_renders_range(self) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "review-1"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        expected_range = f"{stream['baseTip']}..{stream['tip']}"
        out = Path(self.tmp.name) / "review.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "review",
            "--out",
            str(out),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        text = out.read_text()
        self.assertIn(f"Review range: {expected_range}", text)
        self.assertIn(f"First pass: {expected_range}", text)
        self.assertNotIn("{{", text)

    def test_first_review_range_stays_at_recorded_base_when_seed_moves(self) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "review-1"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        expected_range = f"{stream['baseTip']}..{stream['tip']}"

        (self.seed / "later.txt").write_text("later\n")
        subprocess.run(["git", "add", "later.txt"], cwd=self.seed, check=True)
        subprocess.run(
            ["git", "commit", "-m", "advance seed"],
            cwd=self.seed,
            check=True,
            capture_output=True,
        )
        moved_seed_tip = subprocess.run(
            ["git", "-C", str(self.seed), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        out = Path(self.tmp.name) / "review.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "review",
            "--out",
            str(out),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        text = out.read_text()
        self.assertIn(f"Review range: {expected_range}", text)
        self.assertIn(f"First pass: {expected_range}", text)
        self.assertNotIn(f"{moved_seed_tip}..{stream['tip']}", text)

    def test_second_review_uses_exact_pre_fix_range(self) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        pre_fix_tip = stream["tip"]
        (self.clone / "fix.txt").write_text("fix\n")
        subprocess.run(["git", "add", "fix.txt"], cwd=self.clone, check=True)
        subprocess.run(
            ["git", "commit", "-m", "fix review finding"],
            cwd=self.clone,
            check=True,
            capture_output=True,
        )
        new_tip = subprocess.run(
            ["git", "-C", str(self.clone), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        stream.update(
            {
                "phase": "review-2",
                "tip": new_tip,
                "preFixTip": pre_fix_tip,
                "reviewRange": "stale..range",
                "verdicts": [
                    {"pass": 1, "tip": pre_fix_tip, "approve": False, "findings": []}
                ],
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        expected_range = f"{pre_fix_tip}..{new_tip}"

        out = Path(self.tmp.name) / "review-2.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "review",
            "--out",
            str(out),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        text = out.read_text()
        self.assertIn(f"Review range: {expected_range}", text)
        self.assertIn(f"Re-review: {expected_range}", text)
        self.assertNotIn("stale..range", text)

    def test_second_review_without_pre_fix_tip_fails(self) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream.update(
            {
                "phase": "review-2",
                "verdicts": [
                    {"pass": 1, "tip": stream["tip"], "approve": False, "findings": []}
                ],
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        out = Path(self.tmp.name) / "bad-review.txt"

        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "review",
            "--out",
            str(out),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("review-2 missing preFixTip", result.stderr)
        self.assertFalse(out.exists())

    def test_bounce_prompt_renders_findings(self) -> None:
        config = json.loads(self.config_path.read_text())
        tip = config["streams"][0]["tip"]
        config["streams"][0]["phase"] = "bounce-1"
        config["streams"][0]["bounceCount"] = 1
        config["streams"][0]["verdicts"] = [
            {
                "pass": 1,
                "tip": tip,
                "approve": False,
                "findings": [
                    {
                        "sev": "P2",
                        "tag": "(A)",
                        "loc": "fleet.py:10",
                        "title": "missing dry-run",
                    }
                ],
            }
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        out = Path(self.tmp.name) / "bounce.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "bounce",
            "--out",
            str(out),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        text = out.read_text()
        self.assertIn("bounce — review 1", text)
        self.assertIn("[P2]", text)
        self.assertIn("fleet.py:10", text)
        self.assertNotIn("{{", text)

    def test_hard_fail_on_missing_required_config(self) -> None:
        config = json.loads(self.config_path.read_text())
        del config["user"]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        out = Path(self.tmp.name) / "bad.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "implementer",
            "--out",
            str(out),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("user", result.stderr)
        self.assertFalse(out.exists())

    def test_hard_fail_on_unfilled_placeholder(self) -> None:
        config = json.loads(self.config_path.read_text())
        del config["streams"][0]["title"]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        out = Path(self.tmp.name) / "bad.txt"
        result = run_fleet(
            "--config",
            str(self.config_path),
            "prompt",
            "T094.1",
            "implementer",
            "--out",
            str(out),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TITLE", result.stderr)
        self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
