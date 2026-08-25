"""Tests for fleet capture subcommand."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402

from herdr_fixtures import ENVELOPES, herdr_json, make_herdr_run_handler  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"

ECHOED_REVIEW_TAIL = """
End with exactly one of:
APPROVE: yes
APPROVE: no

[P1] (A) fleet.py:433: first match is echoed template
APPROVE: no
"""


class ParseCaptureTests(unittest.TestCase):
    def test_parse_approve_uses_last_line_not_echoed_template(self) -> None:
        approve = fleet.parse_approve_verdict(ECHOED_REVIEW_TAIL)
        self.assertIsNotNone(approve)
        self.assertFalse(approve)

    def test_parse_approve_yes_when_only_template_lines(self) -> None:
        text = "End with exactly one of:\nAPPROVE: yes\nAPPROVE: no\n"
        self.assertIsNone(fleet.parse_approve_verdict(text))


class CaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.checkout = Path(self.tmp.name) / "clone"
        self.checkout.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=self.checkout, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "f@t"], cwd=self.checkout, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "F"], cwd=self.checkout, check=True, capture_output=True)
        (self.checkout / "README.md").write_text("x\n")
        subprocess.run(["git", "add", "README.md"], cwd=self.checkout, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=self.checkout, check=True, capture_output=True)
        self.branch_tip = subprocess.run(
            ["git", "-C", str(self.checkout), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        config["streams"][0]["checkout"] = str(self.checkout)
        config["streams"][0]["agents"] = {
            "review": {
                "name": "t094-1-review",
                "role": "review",
                "tabId": "tab-1",
                "paneId": "pane-1",
            },
            "impl": {
                "name": "t094-1-impl",
                "role": "impl",
                "tabId": "tab-2",
                "paneId": "pane-2",
            },
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    def args(self, *extra: str) -> fleet.argparse.Namespace:
        return fleet.build_parser().parse_args(["--config", str(self.config_path), "capture", *extra])

    @mock.patch("subprocess.run")
    def test_capture_review_ready_records_tip(self, mock_run: mock.Mock) -> None:
        transcript = f"Done.\nREVIEW-READY\ntip: {self.branch_tip}\n"
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-impl": transcript},
        ).side_effect
        rc = fleet.cmd_capture(self.args("t094-1-impl"))
        self.assertEqual(rc, 0)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["tip"], self.branch_tip)
        self.assertTrue(stream["phase"].startswith("review-"))

    @mock.patch("subprocess.run")
    def test_capture_approve_no_with_echoed_template(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": ECHOED_REVIEW_TAIL},
        ).side_effect
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        verdict = json.loads(self.config_path.read_text())["streams"][0]["verdicts"][-1]
        self.assertFalse(verdict["approve"])

    @mock.patch("subprocess.run")
    def test_capture_approve_no_with_findings(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": "[P2] (A) src/foo.py:10: missing guard\nAPPROVE: no\n"},
        ).side_effect
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        findings = json.loads(self.config_path.read_text())["streams"][0]["verdicts"][-1]["findings"]
        self.assertEqual(findings[0]["sev"], "P2")
        self.assertEqual(findings[0]["tag"], "(A)")

    @mock.patch("subprocess.run")
    def test_capture_no_verdict_refuses_close(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": "still working\n"},
        ).side_effect
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_capture(self.args("t094-1-review", "--close"))
        close_calls = [c for c in mock_run.call_args_list if c.args[0][:3] == ["herdr", "tab", "close"]]
        self.assertEqual(close_calls, [])

    @mock.patch("subprocess.run")
    def test_capture_pane_fallback_on_agent_not_found(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={},
            pane_read={"pane-1": "APPROVE: yes\n"},
        ).side_effect
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        pane_calls = [c for c in mock_run.call_args_list if c.args[0][:3] == ["herdr", "pane", "read"]]
        self.assertEqual(len(pane_calls), 1)


if __name__ == "__main__":
    unittest.main()
