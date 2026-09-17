"""Tests for custom-lane Herdr readiness handling."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import herdr_agent_ready as ready  # noqa: E402


def completed(stdout: str = "", returncode: int = 0) -> CompletedProcess[str]:
    return CompletedProcess(["herdr"], returncode, stdout=stdout, stderr="")


def agent(status: str, interactive: bool = False) -> str:
    return json.dumps(
        {
            "result": {
                "agent": {
                    "agent_status": status,
                    "interactive_ready": interactive,
                }
            }
        }
    )


class HerdrAgentReadyTests(unittest.TestCase):
    def test_cursor_waits_for_trust_screen_to_disappear(self) -> None:
        trust_screen = """\
Workspace Trust Required
Do you trust the contents of this directory?
[a] Trust this workspace
[q] Quit
Trusting workspace...
"""
        results = iter(
            [
                completed(agent("idle", interactive=True)),
                completed(trust_screen),
                completed(),
                completed(agent("idle", interactive=True)),
                completed(trust_screen),
                completed(agent("idle", interactive=True)),
                completed("Cursor Agent\n→ Plan, search, build anything\n"),
            ]
        )
        with mock.patch.object(ready, "run", side_effect=lambda command: next(results)) as run:
            ok, detail = ready.ensure_ready("worker", "p1", "cursor", timeout=5, poll=0)
        self.assertTrue(ok)
        self.assertEqual(detail, "agent-status=idle")
        self.assertIn(
            ["herdr", "pane", "send-keys", "p1", "a"],
            [call.args[0] for call in run.call_args_list],
        )

    def test_claude_trust_choices_are_not_a_ready_prompt(self) -> None:
        trust_screen = """\
Quick safety check: Is this a project you created or one you trust?

❯ No, exit
  Yes, I trust this folder

Enter to confirm · Esc to cancel
"""
        results = iter(
            [
                completed(agent("blocked")),
                completed(trust_screen),
                completed(),
                completed(agent("idle", interactive=True)),
                completed("Claude Code\n❯\n"),
            ]
        )
        with mock.patch.object(ready, "run", side_effect=lambda command: next(results)) as run:
            ok, detail = ready.ensure_ready("worker", "p1", "claude", timeout=5, poll=0)
        self.assertTrue(ok)
        self.assertEqual(detail, "agent-status=idle")
        self.assertIn(
            ["herdr", "pane", "send-keys", "p1", "down", "enter"],
            [call.args[0] for call in run.call_args_list],
        )

    def test_accepts_claude_trust_then_waits_for_interactive_ready(self) -> None:
        results = iter(
            [
                completed(returncode=1),
                completed("Quick safety check: is this a project you created or one you trust?"),
                completed(),
                completed(agent("idle", interactive=True)),
                completed("❯"),
            ]
        )
        with mock.patch.object(ready, "run", side_effect=lambda command: next(results)) as run:
            ok, detail = ready.ensure_ready("worker", "p1", "claude", timeout=5, poll=0)
        self.assertTrue(ok)
        self.assertEqual(detail, "agent-status=idle")
        self.assertIn(
            ["herdr", "pane", "send-keys", "p1", "down", "enter"],
            [call.args[0] for call in run.call_args_list],
        )

    def test_ready_prompt_overrides_stale_blocked_launch_state(self) -> None:
        results = iter(
            [
                completed(agent("blocked")),
                completed("Claude Code\n❯\n"),
            ]
        )
        with mock.patch.object(ready, "run", side_effect=lambda command: next(results)):
            ok, detail = ready.ensure_ready("worker", "p1", "claude", timeout=5, poll=0)
        self.assertTrue(ok)
        self.assertEqual(detail, "pane-prompt agent-status=blocked")

    def test_refuses_unknown_noninteractive_state(self) -> None:
        with (
            mock.patch.object(ready, "agent_info", return_value={"agent_status": "unknown"}),
            mock.patch.object(ready, "pane_text", return_value="booting"),
            mock.patch.object(ready.time, "monotonic", side_effect=[0.0, 0.0, 2.0]),
            mock.patch.object(ready.time, "sleep"),
        ):
            ok, detail = ready.ensure_ready("worker", "p1", "claude", timeout=1, poll=0)
        self.assertFalse(ok)
        self.assertIn("not prompt-ready", detail)


if __name__ == "__main__":
    unittest.main()
