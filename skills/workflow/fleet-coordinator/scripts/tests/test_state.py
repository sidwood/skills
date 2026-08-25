"""Tests for fleet state subcommand."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from io import StringIO
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class StateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        config["seed"] = self.tmp.name + "/seed"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        self.seed = Path(config["seed"])
        self.seed.mkdir(parents=True)
        subprocess.run(["git", "init", "-b", "main"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "f@t"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "F"], cwd=self.seed, check=True, capture_output=True)
        (self.seed / "README.md").write_text("x\n")
        subprocess.run(["git", "add", "README.md"], cwd=self.seed, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=self.seed, check=True, capture_output=True)

    def args(self) -> fleet.argparse.Namespace:
        return fleet.build_parser().parse_args(["--config", str(self.config_path), "state"])

    @mock.patch.object(fleet, "herdr_agent_list", return_value=[])
    @mock.patch.object(fleet, "git_tip")
    def test_state_next_actions(self, mock_tip: mock.Mock, _mock_agents: mock.Mock) -> None:
        mock_tip.return_value = "abc1234"
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["phase"] = "verdict-pending"
        config["streams"][0]["baseTip"] = "abc1234"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        with mock.patch("sys.stdout", new_callable=StringIO) as out:
            rc = fleet.cmd_state(self.args())
        self.assertEqual(rc, 0)
        self.assertIn("next=fleet verdict T094.1", out.getvalue())

    @mock.patch.object(fleet, "herdr_agent_list", return_value=[])
    @mock.patch.object(fleet, "git_tip")
    def test_state_drift_warning(self, mock_tip: mock.Mock, _mock_agents: mock.Mock) -> None:
        mock_tip.return_value = "live0001"
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["baseTip"] = "0" * 40
        config["streams"][0]["agents"] = {
            "impl": {"name": "missing-agent", "tabId": "t", "paneId": "p"}
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        with mock.patch("sys.stderr", new_callable=StringIO) as err:
            rc = fleet.cmd_state(self.args())
        self.assertEqual(rc, 0)
        self.assertIn("baseTip", err.getvalue())
        self.assertIn("missing-agent", err.getvalue())


if __name__ == "__main__":
    unittest.main()
