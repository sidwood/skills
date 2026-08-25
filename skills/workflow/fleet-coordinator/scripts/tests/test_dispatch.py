"""Tests for fleet dispatch subcommand."""

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

from herdr_fixtures import ENVELOPES, completed, herdr_json, make_herdr_run_handler  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class DispatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        self.prompt = Path(self.tmp.name) / "prompt.txt"
        self.prompt.write_text("hello\n")
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    def test_derive_agent_name(self) -> None:
        self.assertEqual(fleet.derive_agent_name("T094.1", "impl"), "t094-1-impl")
        self.assertEqual(fleet.derive_agent_name("T094.1", "review"), "t094-1-review")
        self.assertRegex(fleet.derive_agent_name("T094.1", "impl"), r"^[a-z][a-z0-9_-]{0,31}$")

    def test_derive_agent_name_keeps_suffix_on_long_ticket(self) -> None:
        long_ticket = "T" + "0" * 40 + ".1"
        impl = fleet.derive_agent_name(long_ticket, "impl")
        review = fleet.derive_agent_name(long_ticket, "review")
        self.assertTrue(impl.endswith("-impl"))
        self.assertTrue(review.endswith("-review"))
        self.assertLessEqual(len(impl), 32)
        self.assertLessEqual(len(review), 32)
        self.assertNotEqual(impl, review)

    @mock.patch("subprocess.run")
    def test_dispatch_dry_run(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler().side_effect
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
                "--dry-run",
            ]
        )
        with mock.patch("builtins.print") as mock_print:
            rc = fleet.cmd_dispatch(args)
        self.assertEqual(rc, 0)
        printed = "\n".join(str(c) for c in mock_print.call_args_list)
        self.assertIn("tab create", printed)
        config = json.loads(self.config_path.read_text())
        self.assertEqual(config["streams"][0].get("agents"), {})

    @mock.patch("subprocess.run")
    def test_dispatch_dry_run_before_subcommand(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler().side_effect
        config_before = self.config_path.read_text()
        rc = fleet.main(
            [
                "--config",
                str(self.config_path),
                "--dry-run",
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        self.assertEqual(rc, 0)
        self.assertEqual(self.config_path.read_text(), config_before)
        config = json.loads(self.config_path.read_text())
        self.assertEqual(config["streams"][0].get("agents"), {})

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_agent_start_retries_pane_busy(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        busy = herdr_json(ENVELOPES["agent_pane_busy"])
        mock_run.side_effect = [
            completed(["herdr"], returncode=1, stdout=busy),
            completed(["herdr"]),
        ]
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        fleet.herdr_agent_start(
            config, "t094-1-review", "w1:p99", {"kind": "claude", "args": []}
        )
        self.assertEqual(mock_run.call_count, 2)
        mock_sleep.assert_called_once_with(fleet.AGENT_START_RETRY_SECONDS)

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_agent_start_gives_up_after_attempts(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        busy = herdr_json(ENVELOPES["agent_pane_busy"])
        mock_run.return_value = completed(["herdr"], returncode=1, stdout=busy)
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        with self.assertRaises(fleet.FleetError):
            fleet.herdr_agent_start(
                config, "t094-1-review", "w1:p99", {"kind": "claude", "args": []}
            )
        self.assertEqual(mock_run.call_count, fleet.AGENT_START_ATTEMPTS)

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_agent_start_other_error_raises_immediately(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        mock_run.return_value = completed(
            ["herdr"], returncode=1, stderr="agent name already in use"
        )
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        with self.assertRaises(fleet.FleetError):
            fleet.herdr_agent_start(
                config, "t094-1-review", "w1:p99", {"kind": "claude", "args": []}
            )
        self.assertEqual(mock_run.call_count, 1)
        mock_sleep.assert_not_called()

    @mock.patch("subprocess.run")
    def test_herdr_tab_create_parses_envelope(self, mock_run: mock.Mock) -> None:
        mock_run.return_value = completed(
            ["herdr", "tab", "create"],
            stdout=herdr_json(ENVELOPES["tab_create"]),
        )
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        ids = fleet.herdr_tab_create(config, "/tmp", "probe", dry_run=False)
        self.assertEqual(ids, {"tab_id": "w1:t99", "pane_id": "w1:p99"})


if __name__ == "__main__":
    unittest.main()
