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

    @mock.patch.object(fleet, "save_config")
    @mock.patch.object(fleet, "herdr_agent_prompt")
    @mock.patch.object(fleet, "herdr_agent_start")
    @mock.patch.object(fleet, "herdr_tab_create")
    def test_dispatch_dry_run(
        self,
        mock_tab: mock.Mock,
        mock_start: mock.Mock,
        mock_prompt: mock.Mock,
        _mock_save: mock.Mock,
    ) -> None:
        mock_tab.return_value = {"tab_id": "tab-1", "pane_id": "pane-1"}
        args = fleet.build_parser().parse_args(
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
        with mock.patch("builtins.print"):
            rc = fleet.cmd_dispatch(args)
        self.assertEqual(rc, 0)
        mock_tab.assert_called_once()
        mock_start.assert_called_once()
        mock_prompt.assert_called_once()
        self.assertEqual(mock_tab.call_args.kwargs.get("dry_run"), True)


if __name__ == "__main__":
    unittest.main()
