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

from herdr_fixtures import ENVELOPES, herdr_json, make_herdr_run_handler, match_herdr  # noqa: E402

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

    def test_parse_indented_claude_verdict_before_prompt_footer(self) -> None:
        text = (
            "  Findings:\n\n"
            "  None.\n\n"
            "  APPROVE: yes\n\n"
            "✻ Worked for 25s\n"
            "────────────────────────\n"
            "❯ create a pr\n"
        )
        self.assertTrue(fleet.parse_approve_verdict(text))

    def test_indented_echoed_template_is_not_a_verdict(self) -> None:
        text = (
            "End with exactly one of:\n"
            "  APPROVE: yes\n"
            "  APPROVE: no\n"
        )
        self.assertIsNone(fleet.parse_approve_verdict(text))

    def test_review_ready_tip_formats(self) -> None:
        sha = "abc1234567890"
        checkout = Path("/tmp/unused")
        cases = [
            ("newline tip colon", f"Done.\nREVIEW-READY\ntip: {sha}\n"),
            ("bullet tip", f"Done.\nREVIEW-READY\n- tip: {sha}\n"),
            ("bullet new tip SHA", f"Done.\nREVIEW-READY\n- new tip SHA: {sha}\n"),
            ("bold tip", f"Done.\nREVIEW-READY\n**tip:** {sha}\n"),
            ("indented tip", f"Done.\nREVIEW-READY\n  tip: {sha}\n"),
            ("same line", f"Done.\nREVIEW-READY tip: {sha}\n"),
            ("prose new tip SHA", f"Done.\nREVIEW-READY\nThe new tip SHA is {sha}\n"),
            ("new tip colon", f"Done.\nREVIEW-READY\nnew tip: {sha}\n"),
            ("indented bullet", f"Done.\nREVIEW-READY\n  - tip: {sha}\n"),
        ]
        for label, text in cases:
            with self.subTest(label=label):
                with mock.patch.object(fleet, "verify_tip_in_checkout", return_value=sha):
                    captured = fleet.parse_capture(text, "impl", checkout)
                self.assertEqual(captured.kind, "review-ready")
                self.assertEqual(captured.tip, sha)

    def test_review_ready_uses_codex_final_block_after_echoed_instruction(self) -> None:
        sha = "abc1234567890"
        text = (
            "Output REVIEW-READY with: tip SHA, gate table, deferral notes.\n"
            "\n"
            "• REVIEW-READY\n"
            "\n"
            f"  - Tip SHA: {sha}\n"
            "  - python3 -m unittest: passed\n"
        )
        with mock.patch.object(fleet, "verify_tip_in_checkout", return_value=sha):
            captured = fleet.parse_capture(text, "impl", Path("/tmp/unused"))
        self.assertEqual(captured.tip, sha)

    def test_review_ready_tip_ignores_pre_fix_label(self) -> None:
        pre = "aaaaaaa"
        new = "bbbbbbb"
        checkout = Path("/tmp/unused")
        cases = [
            (
                "pre-fix then new tip",
                f"Done.\nREVIEW-READY\npre-fix tip: {pre}\nnew tip: {new}\n",
            ),
            (
                "new tip then pre-fix",
                f"Done.\nREVIEW-READY\nnew tip: {new}\npre-fix tip: {pre}\n",
            ),
            (
                "bullet pre-fix then bullet new tip",
                f"Done.\nREVIEW-READY\n- pre-fix tip: {pre}\n- new tip: {new}\n",
            ),
            (
                "bullet new tip then bullet pre-fix",
                f"Done.\nREVIEW-READY\n- new tip: {new}\n- pre-fix tip: {pre}\n",
            ),
        ]
        for label, text in cases:
            with self.subTest(label=label):
                with mock.patch.object(fleet, "verify_tip_in_checkout", return_value=new):
                    captured = fleet.parse_capture(text, "impl", checkout)
                self.assertEqual(captured.kind, "review-ready")
                self.assertEqual(captured.tip, new)
                self.assertEqual(captured.pre_fix_tip, pre)

    def test_review_ready_rejects_prose_without_sha(self) -> None:
        text = "Done.\nREVIEW-READY\nThe reviewer effaced tip defaced concerns\n"
        with self.assertRaisesRegex(fleet.FleetError, "missing tip SHA"):
            fleet.parse_capture(text, "impl", Path("/tmp/unused"))

    def test_review_ready_rejects_unlabeled_hex(self) -> None:
        sha = "abc1234567890"
        text = f"Done.\nREVIEW-READY\ncommit {sha} landed\n"
        with self.assertRaisesRegex(fleet.FleetError, "missing tip SHA"):
            fleet.parse_capture(text, "impl", Path("/tmp/unused"))

    def test_reviewer_ignores_review_ready_text_and_requires_approve(self) -> None:
        text = "Prior implementer said REVIEW-READY\ntip: abc1234\nAPPROVE: yes\n"
        captured = fleet.parse_capture(text, "review")
        self.assertEqual(captured.kind, "verdict")
        self.assertTrue(captured.approve)

    def test_implementer_rejects_approve_instead_of_review_ready(self) -> None:
        with self.assertRaisesRegex(fleet.FleetError, "missing REVIEW-READY"):
            fleet.parse_capture("APPROVE: yes\n", "impl")

    def test_reviewer_rejects_review_ready_instead_of_approve(self) -> None:
        with self.assertRaisesRegex(fleet.FleetError, "missing APPROVE"):
            fleet.parse_capture("REVIEW-READY\ntip: abc1234\n", "review")


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
        (self.checkout / "fix-1.txt").write_text("one\n")
        subprocess.run(["git", "add", "fix-1.txt"], cwd=self.checkout, check=True)
        subprocess.run(
            ["git", "commit", "-m", "fix one"],
            cwd=self.checkout,
            check=True,
            capture_output=True,
        )
        self.fix_one_tip = subprocess.run(
            ["git", "-C", str(self.checkout), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        (self.checkout / "fix-2.txt").write_text("two\n")
        subprocess.run(["git", "add", "fix-2.txt"], cwd=self.checkout, check=True)
        subprocess.run(
            ["git", "commit", "-m", "fix two"],
            cwd=self.checkout,
            check=True,
            capture_output=True,
        )
        self.fix_two_tip = subprocess.run(
            ["git", "-C", str(self.checkout), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "checkout", "-b", "divergent", self.branch_tip],
            cwd=self.checkout,
            check=True,
            capture_output=True,
        )
        (self.checkout / "divergent.txt").write_text("divergent\n")
        subprocess.run(["git", "add", "divergent.txt"], cwd=self.checkout, check=True)
        subprocess.run(
            ["git", "commit", "-m", "divergent fix"],
            cwd=self.checkout,
            check=True,
            capture_output=True,
        )
        self.divergent_tip = subprocess.run(
            ["git", "-C", str(self.checkout), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "checkout", "main"],
            cwd=self.checkout,
            check=True,
            capture_output=True,
        )

        self.config_path = Path(self.tmp.name) / "fleet.json"
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        fleet.sync_recipe_catalog(config)
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
        self.prompt = Path(self.tmp.name) / "prompt.txt"
        self.prompt.write_text("finish the implementation\n")

    def args(self, *extra: str) -> fleet.argparse.Namespace:
        return fleet.build_parser().parse_args(["--config", str(self.config_path), "capture", *extra])

    def update_stream(self, **updates: object) -> None:
        config = json.loads(self.config_path.read_text())
        config["streams"][0].update(updates)
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

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
        self.assertEqual(stream["phase"], "review-1")
        self.assertEqual(
            stream["reviewRange"], f"{stream['baseTip']}..{self.branch_tip}"
        )

    @mock.patch("subprocess.run")
    def test_malformed_capture_records_transcript_without_acknowledging_event(
        self, mock_run: mock.Mock
    ) -> None:
        transcript = "Agent stopped before writing its completion marker.\n"
        event_id = "t094-1-impl@9"
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-impl": transcript},
        ).side_effect

        with self.assertRaisesRegex(fleet.FleetError, "transcript saved at"):
            fleet.cmd_capture(
                self.args("t094-1-impl", "--event-id", event_id)
            )

        stream = json.loads(self.config_path.read_text())["streams"][0]
        failure = stream["agents"]["impl"]["lastCaptureFailure"]
        self.assertEqual(failure["eventId"], event_id)
        capture_path = Path(failure["capturePath"])
        self.assertTrue(capture_path.is_file())
        self.assertEqual(capture_path.read_text(), transcript)
        self.assertFalse(
            any(event.get("eventId") == event_id for event in stream.get("events", []))
        )

    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "replacement-tab", "pane_id": "replacement-pane"},
    )
    @mock.patch("fleet.herdr_tab_close")
    def test_hard_limit_dispatches_cursor_grok_fallback_automatically(
        self,
        mock_tab_close: mock.Mock,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        event_id = "t094-1-impl@9"
        capture_file = Path(self.tmp.name) / "grok-limit.txt"
        capture_file.write_text(
            "You hit your weekly limit.\n"
            "You can continue by purchasing more credits.\n"
            "Weekly limit left: 0% · Grok 4.6 (xhigh)\n"
        )
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["implRecipe"] = "grok-xhigh"
        stream["dispatchCounters"] = {"impl": 1}
        stream["agents"]["review"]["dispatchState"] = "closed"
        stream["agents"]["impl"].update(
            {
                "dispatchNumber": 1,
                "requestedRecipe": "grok-xhigh",
                "recipe": "grok-xhigh",
                "dispatchState": "active",
                "promptFile": str(self.prompt),
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        args = self.args(
            "t094-1-impl",
            "--event-id",
            event_id,
            "--capture-file",
            str(capture_file),
            "--close",
        )
        self.assertEqual(fleet.cmd_capture(args), 0)
        self.assertEqual(fleet.cmd_capture(args), 0)

        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        replacement = stream["agents"]["impl"]
        self.assertEqual(config["usagePools"]["grok-native"]["state"], "spent")
        self.assertEqual(replacement["requestedRecipe"], "grok-xhigh")
        self.assertEqual(replacement["recipe"], "grok-xhigh-cursor")
        self.assertEqual(replacement["dispatchState"], "active")
        event = next(e for e in stream["events"] if e.get("eventId") == event_id)
        self.assertEqual(event["resolutionClass"], "capacity")
        self.assertEqual(event["usagePool"], "grok-native")
        self.assertEqual(event["replacementAgent"], replacement["name"])
        self.assertEqual(event["replacementRecipe"], "grok-xhigh-cursor")
        mock_tab_close.assert_called_once()
        mock_tab_create.assert_called_once()
        mock_agent_start.assert_called_once()
        mock_agent_prompt.assert_called_once()

    @mock.patch("fleet.herdr_tab_close")
    def test_hard_limit_refuses_incomplete_recipe_catalog_before_teardown(
        self, mock_tab_close: mock.Mock
    ) -> None:
        event_id = "t094-1-impl@9"
        capture_file = Path(self.tmp.name) / "grok-limit.txt"
        capture_file.write_text("You hit your weekly limit.\n")
        config = json.loads(self.config_path.read_text())
        config["recipes"].pop("grok-xhigh-cursor")
        stream = config["streams"][0]
        stream["implRecipe"] = "grok-xhigh"
        stream["agents"]["impl"].update(
            {
                "requestedRecipe": "grok-xhigh",
                "recipe": "grok-xhigh",
                "dispatchState": "active",
                "promptFile": str(self.prompt),
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "RECIPE-DRIFT"):
            fleet.cmd_capture(
                self.args(
                    "t094-1-impl",
                    "--event-id",
                    event_id,
                    "--capture-file",
                    str(capture_file),
                    "--close",
                )
            )

        mock_tab_close.assert_not_called()
        config = json.loads(self.config_path.read_text())
        self.assertEqual(config["usagePools"]["grok-native"]["state"], "available")

    @mock.patch("fleet.herdr_recipe_pre_start", return_value=True)
    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "glm-tab", "pane_id": "glm-pane"},
    )
    @mock.patch("fleet.herdr_tab_close")
    def test_cursor_grok_limit_advances_original_route_to_glm(
        self,
        mock_tab_close: mock.Mock,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
        mock_pre_start: mock.Mock,
    ) -> None:
        event_id = "t094-1-cursor-impl@10"
        capture_file = Path(self.tmp.name) / "cursor-limit.txt"
        capture_file.write_text("No usage credits remaining.\n")
        config = json.loads(self.config_path.read_text())
        config["usagePools"]["grok-native"]["state"] = "spent"
        stream = config["streams"][0]
        stream["implRecipe"] = "grok-xhigh"
        stream["dispatchCounters"] = {"impl": 2}
        stream["agents"]["review"]["dispatchState"] = "closed"
        stream["agents"]["impl"].update(
            {
                "name": "t094-1-cursor-impl",
                "dispatchNumber": 2,
                "requestedRecipe": "grok-xhigh",
                "recipe": "grok-xhigh-cursor",
                "dispatchState": "active",
                "promptFile": str(self.prompt),
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        self.assertEqual(
            fleet.cmd_capture(
                self.args(
                    "t094-1-cursor-impl",
                    "--event-id",
                    event_id,
                    "--capture-file",
                    str(capture_file),
                    "--close",
                )
            ),
            0,
        )

        config = json.loads(self.config_path.read_text())
        replacement = config["streams"][0]["agents"]["impl"]
        self.assertEqual(config["usagePools"]["cursor-grok"]["state"], "spent")
        self.assertEqual(replacement["requestedRecipe"], "grok-xhigh")
        self.assertEqual(replacement["recipe"], "glm-53")
        self.assertEqual(mock_agent_start.call_args.args[3]["kind"], "claude")
        mock_tab_close.assert_called_once()
        mock_tab_create.assert_called_once()
        mock_agent_prompt.assert_called_once()
        mock_pre_start.assert_called_once()

    @mock.patch("fleet.herdr_agent_read")
    def test_capture_retries_a_saved_transcript_without_reading_herdr(
        self, mock_agent_read: mock.Mock
    ) -> None:
        event_id = "t094-1-impl@9"
        capture_file = Path(self.tmp.name) / "saved-capture.txt"
        capture_file.write_text(
            f"• REVIEW-READY\n\n  - Tip SHA: {self.branch_tip[:7]}\n"
        )

        rc = fleet.cmd_capture(
            self.args(
                "t094-1-impl",
                "--event-id",
                event_id,
                "--capture-file",
                str(capture_file),
            )
        )

        self.assertEqual(rc, 0)
        mock_agent_read.assert_not_called()
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["events"][-1]["eventId"], event_id)
        self.assertEqual(
            stream["events"][-1]["capturePath"], str(capture_file.resolve())
        )

    def test_capture_file_requires_an_event_id(self) -> None:
        capture_file = Path(self.tmp.name) / "saved-capture.txt"
        capture_file.write_text("REVIEW-READY\nTip SHA: abc1234\n")
        with self.assertRaisesRegex(fleet.FleetError, "requires --event-id"):
            fleet.cmd_capture(
                self.args(
                    "t094-1-impl", "--capture-file", str(capture_file)
                )
            )

    @mock.patch("subprocess.run")
    def test_capture_persists_event_id(self, mock_run: mock.Mock) -> None:
        event_id = "t094-1-review@7"
        self.update_stream(phase="review-1")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": ECHOED_REVIEW_TAIL},
        ).side_effect

        rc = fleet.cmd_capture(
            self.args("t094-1-review", "--event-id", event_id)
        )

        self.assertEqual(rc, 0)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["events"][-1]["eventId"], event_id)
        self.assertEqual(stream["events"][-1]["agent"], "t094-1-review")
        capture_path = Path(stream["events"][-1]["capturePath"])
        self.assertTrue(capture_path.is_file())
        self.assertEqual(capture_path.read_text(), ECHOED_REVIEW_TAIL)

    @mock.patch("subprocess.run")
    def test_duplicate_event_id_resumes_close_without_duplicate_capture(
        self, mock_run: mock.Mock
    ) -> None:
        event_id = "t094-1-review@7"
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "agent": "t094-1-review",
                "kind": "verdict",
                "approve": False,
                "eventId": event_id,
            }
        ]
        stream["agents"]["review"].update(
            {
                "dispatchState": "captured",
                "capturedAt": "2026-09-04T00:00:00+00:00",
                "captureEventId": event_id,
            }
        )
        stream["verdicts"] = [
            {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []}
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        mock_run.side_effect = make_herdr_run_handler().side_effect

        rc = fleet.cmd_capture(
            self.args("t094-1-review", "--event-id", event_id, "--close")
        )

        self.assertEqual(rc, 0)
        reads = [
            call
            for call in mock_run.call_args_list
            if match_herdr(call.args[0], "agent", "read")
        ]
        closes = [
            call
            for call in mock_run.call_args_list
            if match_herdr(call.args[0], "tab", "close")
        ]
        self.assertEqual(reads, [])
        self.assertEqual(len(closes), 1)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(len(stream["events"]), 1)
        self.assertEqual(len(stream["verdicts"]), 1)
        self.assertEqual(stream["agents"]["review"]["dispatchState"], "closed")
        self.assertEqual(
            stream["events"][0]["closedAt"],
            stream["agents"]["review"]["closedAt"],
        )

    @mock.patch("subprocess.run")
    def test_close_retry_accepts_already_absent_tab(self, mock_run: mock.Mock) -> None:
        event_id = "t094-1-review@7"
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "agent": "t094-1-review",
                "kind": "verdict",
                "approve": False,
                "eventId": event_id,
            }
        ]
        stream["agents"]["review"].update(
            {
                "dispatchState": "captured",
                "capturedAt": "2026-09-04T00:00:00+00:00",
                "captureEventId": event_id,
            }
        )
        stream["verdicts"] = [
            {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []}
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        def close_not_found(cmd: list[str], **_kwargs: object):
            self.assertTrue(match_herdr(cmd, "tab", "close"))
            return subprocess.CompletedProcess(
                cmd,
                1,
                "",
                json.dumps(
                    {
                        "error": {
                            "code": "tab_not_found",
                            "message": "tab target not found",
                        }
                    }
                ),
            )

        mock_run.side_effect = close_not_found

        rc = fleet.cmd_capture(
            self.args("t094-1-review", "--event-id", event_id, "--close")
        )

        self.assertEqual(rc, 0)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["agents"]["review"]["dispatchState"], "closed")
        self.assertIn("closedAt", stream["events"][0])

    @mock.patch("subprocess.run")
    def test_existing_event_refuses_to_close_reused_agent_name(
        self, mock_run: mock.Mock
    ) -> None:
        event_id = "t094-1-review@7"
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "agent": "t094-1-review",
                "kind": "verdict",
                "approve": False,
                "eventId": event_id,
            }
        ]
        stream["agents"]["review"].update(
            {
                "dispatchState": "active",
                "dispatchedAt": "2026-09-04T01:00:00+00:00",
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "different dispatch"):
            fleet.cmd_capture(
                self.args("t094-1-review", "--event-id", event_id, "--close")
            )

        mock_run.assert_not_called()

    @mock.patch("subprocess.run")
    def test_duplicate_event_id_across_streams_is_rejected(
        self, mock_run: mock.Mock
    ) -> None:
        event_id = "shared-review@7"
        config = json.loads(self.config_path.read_text())
        first = config["streams"][0]
        first["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "agent": "t094-1-review",
                "kind": "verdict",
                "eventId": event_id,
            }
        ]
        second = json.loads(json.dumps(first))
        second["ticket"] = "T095.1"
        second["events"][0]["agent"] = "other-review"
        second["agents"] = {}
        config["streams"].append(second)
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "recorded more than once"):
            fleet.cmd_capture(
                self.args("t094-1-review", "--event-id", event_id)
            )

        mock_run.assert_not_called()

    @mock.patch("subprocess.run")
    def test_historical_same_name_capture_does_not_mask_current_dispatch(
        self, mock_run: mock.Mock
    ) -> None:
        event_id = "t094-1-review@8"
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "review-1"
        stream["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "agent": "t094-1-review",
                "kind": "verdict",
                "approve": False,
                "closedAt": "2026-09-04T00:01:00+00:00",
            }
        ]
        stream["agents"]["review"].update(
            {
                "dispatchState": "active",
                "dispatchedAt": "2026-09-04T01:00:00+00:00",
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": "APPROVE: yes\n"},
        ).side_effect

        self.assertEqual(
            fleet.cmd_capture(
                self.args("t094-1-review", "--event-id", event_id)
            ),
            0,
        )

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(len(stream["events"]), 2)
        self.assertNotIn("eventId", stream["events"][0])
        self.assertEqual(stream["events"][1]["eventId"], event_id)

    @mock.patch("subprocess.run")
    def test_reused_event_id_for_another_agent_fails_before_read(
        self, mock_run: mock.Mock
    ) -> None:
        event_id = "t094-1-review@7"
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "agent": "t094-1-impl",
                "kind": "review-ready",
                "eventId": event_id,
            }
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "already belongs"):
            fleet.cmd_capture(
                self.args("t094-1-review", "--event-id", event_id)
            )

        mock_run.assert_not_called()

    @mock.patch("subprocess.run")
    def test_duplicate_agent_capture_is_no_op_without_event_id(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(phase="review-1")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": "APPROVE: yes\n"},
        ).side_effect

        self.assertEqual(fleet.cmd_capture(self.args("t094-1-review")), 0)
        self.assertEqual(fleet.cmd_capture(self.args("t094-1-review")), 0)

        reads = [
            call
            for call in mock_run.call_args_list
            if match_herdr(call.args[0], "agent", "read")
        ]
        self.assertEqual(len(reads), 1)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(len(stream["verdicts"]), 1)
        self.assertEqual(len(stream["events"]), 1)

    @mock.patch("subprocess.run")
    def test_reviewer_verdict_pass_matches_active_review(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(
            phase="review-3",
            verdicts=[
                {"pass": 1, "tip": self.branch_tip, "approve": False},
                {"pass": 2, "tip": self.fix_one_tip, "approve": False},
            ],
        )
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": "APPROVE: yes\n"},
        ).side_effect

        self.assertEqual(fleet.cmd_capture(self.args("t094-1-review")), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["verdicts"][-1]["pass"], 3)
        self.assertEqual(stream["events"][-1]["pass"], 3)

    @mock.patch("subprocess.run")
    def test_reviewer_capture_rejects_implementing_phase_before_read(
        self, mock_run: mock.Mock
    ) -> None:
        with self.assertRaisesRegex(fleet.FleetError, "requires phase review-N"):
            fleet.cmd_capture(self.args("t094-1-review"))

        mock_run.assert_not_called()

    @mock.patch("subprocess.run")
    def test_implementer_capture_rejects_review_phase_before_read(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(phase="review-1")

        with self.assertRaisesRegex(fleet.FleetError, "requires phase implementing"):
            fleet.cmd_capture(self.args("t094-1-impl"))

        mock_run.assert_not_called()

    @mock.patch("subprocess.run")
    def test_capture_rejects_role_that_disagrees_with_agent_slot(
        self, mock_run: mock.Mock
    ) -> None:
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["agents"]["review"]["role"] = "impl"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "does not match slot"):
            fleet.cmd_capture(self.args("t094-1-review"))

        mock_run.assert_not_called()

    @mock.patch("subprocess.run")
    def test_second_implementation_capture_advances_to_review_two(
        self, mock_run: mock.Mock
    ) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "implementing"
        stream["verdicts"] = [
            {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []}
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        transcript = (
            "Done.\nREVIEW-READY\n"
            f"pre-fix tip: {self.branch_tip}\n"
            f"new tip: {self.fix_one_tip}\n"
        )
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-impl": transcript},
        ).side_effect

        rc = fleet.cmd_capture(self.args("t094-1-impl"))

        self.assertEqual(rc, 0)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "review-2")
        self.assertEqual(stream["preFixTip"], self.branch_tip)
        self.assertEqual(stream["tip"], self.fix_one_tip)
        self.assertEqual(
            stream["reviewRange"], f"{self.branch_tip}..{self.fix_one_tip}"
        )

    @mock.patch("subprocess.run")
    def test_third_review_uses_latest_fix_range(self, mock_run: mock.Mock) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "implementing"
        stream["verdicts"] = [
            {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []},
            {"pass": 2, "tip": self.fix_one_tip, "approve": False, "findings": []},
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        transcript = (
            "Done.\nREVIEW-READY\n"
            f"pre-fix tip: {self.fix_one_tip}\n"
            f"new tip: {self.fix_two_tip}\n"
        )
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-impl": transcript},
        ).side_effect

        rc = fleet.cmd_capture(self.args("t094-1-impl"))

        self.assertEqual(rc, 0)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "review-3")
        self.assertEqual(stream["preFixTip"], self.fix_one_tip)
        self.assertEqual(stream["tip"], self.fix_two_tip)
        self.assertEqual(
            stream["reviewRange"], f"{self.fix_one_tip}..{self.fix_two_tip}"
        )

    @mock.patch("subprocess.run")
    def test_bounced_review_ready_requires_pre_fix_tip(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(
            phase="implementing",
            verdicts=[
                {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []}
            ],
        )
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={
                "t094-1-impl": f"Done.\nREVIEW-READY\nnew tip: {self.fix_one_tip}\n"
            },
        ).side_effect

        with self.assertRaisesRegex(fleet.FleetError, "missing pre-fix tip"):
            fleet.cmd_capture(self.args("t094-1-impl"))

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertNotEqual(stream["tip"], self.fix_one_tip)
        self.assertEqual(len(stream.get("events", [])), 0)
        failure = stream["agents"]["impl"]["lastCaptureFailure"]
        self.assertIn("missing pre-fix tip", failure["error"])
        self.assertTrue(Path(failure["capturePath"]).is_file())

    @mock.patch("subprocess.run")
    def test_bounced_review_ready_rejects_non_ancestor_pre_fix_tip(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(
            phase="implementing",
            verdicts=[
                {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []}
            ],
        )
        transcript = (
            "Done.\nREVIEW-READY\n"
            f"pre-fix tip: {self.divergent_tip}\n"
            f"new tip: {self.fix_two_tip}\n"
        )
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-impl": transcript},
        ).side_effect

        with self.assertRaisesRegex(fleet.FleetError, "not an ancestor"):
            fleet.cmd_capture(self.args("t094-1-impl"))

        stream = json.loads(self.config_path.read_text())["streams"][0]
        failure = stream["agents"]["impl"]["lastCaptureFailure"]
        self.assertIn("not an ancestor", failure["error"])
        self.assertTrue(Path(failure["capturePath"]).is_file())

    @mock.patch("subprocess.run")
    def test_bounced_review_ready_rejects_empty_abbreviated_range(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(
            phase="implementing",
            verdicts=[
                {"pass": 1, "tip": self.branch_tip, "approve": False, "findings": []}
            ],
        )
        transcript = (
            "Done.\nREVIEW-READY\n"
            f"pre-fix tip: {self.fix_one_tip[:8]}\n"
            f"new tip: {self.fix_one_tip}\n"
        )
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-impl": transcript},
        ).side_effect

        with self.assertRaisesRegex(fleet.FleetError, "empty review range"):
            fleet.cmd_capture(self.args("t094-1-impl"))

    @mock.patch("subprocess.run")
    def test_capture_approve_no_with_echoed_template(self, mock_run: mock.Mock) -> None:
        self.update_stream(phase="review-1")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": ECHOED_REVIEW_TAIL},
        ).side_effect
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        verdict = json.loads(self.config_path.read_text())["streams"][0]["verdicts"][-1]
        self.assertFalse(verdict["approve"])

    @mock.patch("subprocess.run")
    def test_capture_approve_no_with_findings(self, mock_run: mock.Mock) -> None:
        self.update_stream(phase="review-1")
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
        self.update_stream(phase="review-1")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": "still working\n"},
        ).side_effect
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_capture(self.args("t094-1-review", "--close"))
        close_calls = [c for c in mock_run.call_args_list if match_herdr(c.args[0], "tab", "close")]
        self.assertEqual(close_calls, [])
        captures = list((self.config_path.parent / "captures").glob("*.txt"))
        self.assertEqual(len(captures), 1)
        self.assertEqual(captures[0].read_text(), "still working\n")

    @mock.patch("subprocess.run")
    def test_capture_pane_fallback_on_agent_not_found(self, mock_run: mock.Mock) -> None:
        self.update_stream(phase="review-1")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={},
            pane_read={"pane-1": "APPROVE: yes\n"},
        ).side_effect
        rc = fleet.cmd_capture(self.args("t094-1-review"))
        self.assertEqual(rc, 0)
        pane_calls = [c for c in mock_run.call_args_list if match_herdr(c.args[0], "pane", "read")]
        self.assertEqual(len(pane_calls), 1)

    @mock.patch("subprocess.run")
    def test_capture_pane_fallback_on_any_agent_read_failure(
        self, mock_run: mock.Mock
    ) -> None:
        self.update_stream(phase="review-1")
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={
                "t094-1-review": '{"error":{"code":"server_busy"}}'
            },
            pane_read={"pane-1": "APPROVE: yes\n"},
        ).side_effect

        rc = fleet.cmd_capture(self.args("t094-1-review"))

        self.assertEqual(rc, 0)
        pane_calls = [
            call
            for call in mock_run.call_args_list
            if match_herdr(call.args[0], "pane", "read")
        ]
        self.assertEqual(len(pane_calls), 1)


if __name__ == "__main__":
    unittest.main()
