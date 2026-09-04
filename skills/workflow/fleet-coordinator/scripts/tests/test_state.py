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

from herdr_fixtures import ENVELOPES, herdr_json, make_herdr_run_handler  # noqa: E402

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

    @mock.patch("subprocess.run")
    def test_state_next_actions_verdict_pending(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler().side_effect
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["phase"] = "verdict-pending"
        config["streams"][0]["baseTip"] = subprocess.run(
            ["git", "-C", str(self.seed), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        with mock.patch("sys.stdout", new_callable=StringIO) as out:
            rc = fleet.cmd_state(self.args())
        self.assertEqual(rc, 0)
        self.assertIn("next=fleet verdict T094.1", out.getvalue())

    @mock.patch("subprocess.run")
    def test_state_next_action_approved(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler().side_effect
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["phase"] = "approved"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        with mock.patch("sys.stdout", new_callable=StringIO) as out:
            rc = fleet.cmd_state(self.args())
        self.assertEqual(rc, 0)
        self.assertIn("next=fleet land T094.1", out.getvalue())

    @mock.patch("subprocess.run")
    def test_state_drift_warning(self, mock_run: mock.Mock) -> None:
        mock_run.side_effect = make_herdr_run_handler(
            agent_list=herdr_json(ENVELOPES["agent_list"]),
        ).side_effect
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

    @mock.patch("fleet.git_tip", return_value="a" * 40)
    def test_terminal_dispatches_do_not_warn_when_absent(
        self, _mock_git_tip: mock.Mock
    ) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]

        for dispatch_state in ("closed", "resolved"):
            with self.subTest(dispatch_state=dispatch_state):
                stream["agents"] = {
                    "impl": {
                        "name": "finished-agent",
                        "dispatchState": dispatch_state,
                    }
                }
                self.assertEqual(fleet.drift_warnings(config, stream, []), [])

    @mock.patch("fleet.git_tip", return_value="a" * 40)
    def test_incomplete_startup_dispatches_warn_with_recovery_context(
        self, _mock_git_tip: mock.Mock
    ) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        expected_hints = {
            "reserved": "tab creation was not recorded; reconcile before retrying",
            "tab-created": "agent start was not recorded; inspect the tab before retrying",
            "started": "prompting was not recorded; inspect the agent before retrying",
            "prompting": (
                "prompt completion is unknown; inspect or capture the agent before retrying"
            ),
        }

        for dispatch_state, hint in expected_hints.items():
            with self.subTest(dispatch_state=dispatch_state):
                stream["agents"] = {
                    "impl": {
                        "name": "incomplete-agent",
                        "dispatchState": dispatch_state,
                    }
                }
                self.assertEqual(
                    fleet.drift_warnings(config, stream, []),
                    [
                        "T094.1: agent incomplete-agent (impl) startup incomplete "
                        f"at {dispatch_state}; {hint}"
                    ],
                )

    @mock.patch("fleet.git_tip", return_value="a" * 40)
    def test_active_dispatch_missing_from_herdr_always_warns(
        self, _mock_git_tip: mock.Mock
    ) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "verdict-pending"
        stream["agents"] = {
            "review": {
                "name": "missing-reviewer",
                "dispatchState": "active",
            }
        }

        self.assertEqual(
            fleet.drift_warnings(config, stream, []),
            ["T094.1: agent missing-reviewer (review) not in herdr list"],
        )

    def test_herdr_agent_list_parses_envelope(self) -> None:
        config = json.loads(self.config_path.read_text())
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = subprocess.CompletedProcess(
                ["herdr", "agent", "list"],
                0,
                herdr_json(ENVELOPES["agent_list"]),
                "",
            )
            agents = fleet.herdr_agent_list(config)
        self.assertEqual(len(agents), 2)
        self.assertEqual(agents[0]["name"], "t094-1-impl")


if __name__ == "__main__":
    unittest.main()
