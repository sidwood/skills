"""Tests for fleet capture subcommand."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


FAKE_TIP = "a" * 40


class CaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
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
        parser = fleet.build_parser()
        argv = ["--config", str(self.config_path), "capture", *extra]
        return parser.parse_args(argv)

    @mock.patch.object(fleet, "herdr_agent_read")
    def test_capture_review_ready_records_tip(self, mock_read: mock.Mock) -> None:
        mock_read.return_value = f"Done.\nREVIEW-READY\ntip: {FAKE_TIP}\n"
        rc = fleet.cmd_capture(self.args("t094-1-impl"))
        self.assertEqual(rc, 0)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["tip"], FAKE_TIP)
        self.assertTrue(stream["phase"].startswith("review-"))

    @mock.patch.object(fleet, "herdr_agent_read")
    def test_capture_approve_yes(self, mock_read: mock.Mock) -> None:
        mock_read.return_value = "Looks good.\nAPPROVE: yes\n"
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        config = json.loads(self.config_path.read_text())
        verdict = config["streams"][0]["verdicts"][-1]
        self.assertTrue(verdict["approve"])
        self.assertEqual(config["streams"][0]["phase"], "verdict-pending")

    @mock.patch.object(fleet, "herdr_agent_read")
    def test_capture_approve_no_with_findings(self, mock_read: mock.Mock) -> None:
        mock_read.return_value = "[P2] (A) src/foo.py:10: missing guard\nAPPROVE: no\n"
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        findings = json.loads(self.config_path.read_text())["streams"][0]["verdicts"][-1]["findings"]
        self.assertEqual(findings[0]["sev"], "P2")
        self.assertEqual(findings[0]["tag"], "(A)")
        self.assertEqual(findings[0]["loc"], "src/foo.py:10")

    @mock.patch.object(fleet, "herdr_tab_close")
    @mock.patch.object(fleet, "herdr_agent_read")
    def test_capture_no_verdict_refuses_close(self, mock_read: mock.Mock, mock_close: mock.Mock) -> None:
        mock_read.return_value = "still working\n"
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_capture(self.args("t094-1-review", "--close"))
        mock_close.assert_not_called()

    @mock.patch.object(fleet, "herdr_pane_read")
    @mock.patch.object(fleet, "herdr_agent_read")
    def test_capture_pane_fallback(self, mock_read: mock.Mock, mock_pane: mock.Mock) -> None:
        mock_read.side_effect = fleet.FleetError("agent_not_found")
        mock_pane.return_value = "APPROVE: yes\n"
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        mock_pane.assert_called_once()


if __name__ == "__main__":
    unittest.main()
