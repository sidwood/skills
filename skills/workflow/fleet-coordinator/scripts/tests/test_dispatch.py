"""Tests for fleet dispatch subcommand."""

from __future__ import annotations

import json
import os
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
        fleet.sync_recipe_catalog(config)
        self.prompt = Path(self.tmp.name) / "prompt.txt"
        self.prompt.write_text("hello\n")
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    def test_derive_agent_name(self) -> None:
        self.assertEqual(
            fleet.derive_agent_name("T094.1", "impl", 1),
            "t094-1-73421147-impl-1",
        )
        self.assertEqual(
            fleet.derive_agent_name("T094.1", "review", 2),
            "t094-1-73421147-review-2",
        )
        self.assertRegex(
            fleet.derive_agent_name("T094.1", "impl", 1),
            r"^[a-z][a-z0-9_-]{0,31}$",
        )

    def test_derive_agent_name_keeps_suffix_on_long_ticket(self) -> None:
        long_ticket = "T" + "0" * 40 + ".1"
        impl = fleet.derive_agent_name(long_ticket, "impl", 123)
        review = fleet.derive_agent_name(long_ticket, "review", 456)
        self.assertTrue(impl.endswith("-impl-123"))
        self.assertTrue(review.endswith("-review-456"))
        self.assertLessEqual(len(impl), 32)
        self.assertLessEqual(len(review), 32)
        self.assertNotEqual(impl, review)

    def test_ticket_normalization_and_truncation_cannot_collide(self) -> None:
        punctuation_a = fleet.derive_agent_name("T094.1", "impl", 1)
        punctuation_b = fleet.derive_agent_name("T094-1", "impl", 1)
        long_a = fleet.derive_agent_name("T" + "a" * 80, "review", 1)
        long_b = fleet.derive_agent_name("T" + "a" * 79 + "b", "review", 1)
        self.assertNotEqual(punctuation_a, punctuation_b)
        self.assertNotEqual(long_a, long_b)

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
        self.assertNotIn("dispatchCounters", config["streams"][0])

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
        self.assertNotIn("dispatchCounters", config["streams"][0])

    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_dispatch_persists_independent_role_counters(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        for role in ("impl", "impl", "review", "review"):
            config = json.loads(self.config_path.read_text())
            config["streams"][0]["phase"] = (
                "implementing" if role == "impl" else "review-1"
            )
            self.config_path.write_text(json.dumps(config, indent=2) + "\n")
            args = fleet.build_parser().parse_args(
                [
                    "--config",
                    str(self.config_path),
                    "dispatch",
                    "T094.1",
                    role,
                    "--prompt-file",
                    str(self.prompt),
                ]
            )
            self.assertEqual(fleet.cmd_dispatch(args), 0)
            config = json.loads(self.config_path.read_text())
            config["streams"][0]["agents"][role]["dispatchState"] = "closed"
            self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        self.assertEqual(stream["dispatchCounters"], {"impl": 2, "review": 2})
        self.assertEqual(
            stream["agents"]["impl"]["name"], "t094-1-73421147-impl-2"
        )
        self.assertEqual(stream["agents"]["impl"]["dispatchNumber"], 2)
        self.assertEqual(
            stream["agents"]["review"]["name"], "t094-1-73421147-review-2"
        )
        self.assertEqual(stream["agents"]["review"]["dispatchNumber"], 2)
        started_names = [call.args[1] for call in mock_agent_start.call_args_list]
        self.assertEqual(
            started_names,
            [
                "t094-1-73421147-impl-1",
                "t094-1-73421147-impl-2",
                "t094-1-73421147-review-1",
                "t094-1-73421147-review-2",
            ],
        )

    @mock.patch("fleet.herdr_tab_create", side_effect=fleet.FleetError("tab failed"))
    def test_dispatch_reserves_unique_name_before_external_side_effect(
        self, mock_tab_create: mock.Mock
    ) -> None:
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        with self.assertRaisesRegex(fleet.FleetError, "tab failed"):
            fleet.cmd_dispatch(args)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["dispatchCounters"]["impl"], 1)
        self.assertEqual(
            stream["agents"]["impl"]["name"], "t094-1-73421147-impl-1"
        )
        self.assertEqual(stream["agents"]["impl"]["dispatchState"], "reserved")
        with self.assertRaisesRegex(
            fleet.FleetError, "live, uncaptured, or unclosed impl dispatch"
        ):
            fleet.cmd_dispatch(args)
        self.assertEqual(mock_tab_create.call_count, 1)

    @mock.patch("fleet.herdr_agent_prompt", side_effect=fleet.FleetError("prompt lost"))
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_dispatch_persists_prompt_attempt_before_sending(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        with self.assertRaisesRegex(fleet.FleetError, "prompt lost"):
            fleet.cmd_dispatch(args)

        record = json.loads(self.config_path.read_text())["streams"][0]["agents"][
            "impl"
        ]
        self.assertEqual(record["dispatchState"], "prompting")
        self.assertIn("promptAttemptedAt", record)
        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "implementing")

    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_dispatch_does_not_overwrite_an_active_agent(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        self.assertEqual(fleet.cmd_dispatch(args), 0)

        with self.assertRaisesRegex(fleet.FleetError, "active"):
            fleet.cmd_dispatch(args)
        review_args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "review",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        with self.assertRaisesRegex(fleet.FleetError, "impl dispatch.*active"):
            fleet.cmd_dispatch(review_args)

        self.assertEqual(mock_tab_create.call_count, 1)
        record = json.loads(self.config_path.read_text())["streams"][0]["agents"][
            "impl"
        ]
        self.assertEqual(record["dispatchState"], "active")
        self.assertEqual(record["dispatchNumber"], 1)

    def test_dispatch_rejects_role_that_does_not_match_phase(self) -> None:
        review_args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "review",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        with self.assertRaisesRegex(fleet.FleetError, "cannot dispatch review"):
            fleet.cmd_dispatch(review_args)

        config = json.loads(self.config_path.read_text())
        config["streams"][0]["phase"] = "review-1"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        impl_args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        with self.assertRaisesRegex(fleet.FleetError, "cannot dispatch impl"):
            fleet.cmd_dispatch(impl_args)

    def test_dispatch_rejects_verdict_pending_and_unrecoverable_hold(self) -> None:
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        for phase in ("verdict-pending", "approved"):
            config = json.loads(self.config_path.read_text())
            config["streams"][0]["phase"] = phase
            self.config_path.write_text(json.dumps(config, indent=2) + "\n")
            with self.assertRaisesRegex(fleet.FleetError, "cannot dispatch impl"):
                fleet.cmd_dispatch(args)

        config = json.loads(self.config_path.read_text())
        config["streams"][0]["phase"] = "hold"
        config["streams"][0].pop("resumePhase", None)
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        with self.assertRaisesRegex(fleet.FleetError, "without a recoverable resumePhase"):
            fleet.cmd_dispatch(args)

    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_dispatch_preserves_captured_agent_until_it_is_closed(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )
        self.assertEqual(fleet.cmd_dispatch(args), 0)
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["agents"]["impl"]["dispatchState"] = "captured"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "unclosed impl dispatch"):
            fleet.cmd_dispatch(args)

        record = json.loads(self.config_path.read_text())["streams"][0]["agents"][
            "impl"
        ]
        self.assertEqual(record["tabId"], "w1:t99")
        self.assertEqual(record["dispatchNumber"], 1)
        self.assertEqual(mock_tab_create.call_count, 1)

    @mock.patch("fleet.herdr_recipe_pre_start", return_value=True)
    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_dispatch_records_requested_and_selected_fallback_recipe(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
        mock_pre_start: mock.Mock,
    ) -> None:
        config = json.loads(self.config_path.read_text())
        config["recipes"]["composer-2.5"]["enabled"] = False
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        self.assertEqual(fleet.cmd_dispatch(args), 0)

        record = json.loads(self.config_path.read_text())["streams"][0]["agents"][
            "impl"
        ]
        self.assertEqual(record["requestedRecipe"], "composer-2.5")
        self.assertEqual(record["recipe"], "glm-53")
        self.assertEqual(mock_agent_start.call_args.args[3]["kind"], "claude")
        mock_pre_start.assert_called_once()

    @mock.patch("fleet.herdr_tab_create")
    def test_dispatch_refuses_catalog_drift_before_side_effects(
        self, mock_tab_create: mock.Mock
    ) -> None:
        config = json.loads(self.config_path.read_text())
        config["recipes"]["grok-xhigh"]["fallbacks"] = ["glm-53"]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        with self.assertRaisesRegex(fleet.FleetError, "RECIPE-DRIFT"):
            fleet.cmd_dispatch(args)

        mock_tab_create.assert_not_called()

    def test_config_path_defaults_below_fleet_seed(self) -> None:
        args = fleet.build_parser().parse_args(["state"])
        seed = Path(self.tmp.name) / "seed"
        with mock.patch.dict(os.environ, {"FLEET_SEED": str(seed)}, clear=True):
            path = fleet.config_path_from_args(args)
        self.assertEqual(path, (seed / "temp" / "fleet" / "fleet.json").resolve())

    def test_config_path_precedence(self) -> None:
        explicit = Path(self.tmp.name) / "explicit.json"
        configured = Path(self.tmp.name) / "configured.json"
        seed = Path(self.tmp.name) / "seed"
        explicit_args = fleet.build_parser().parse_args(
            ["--config", str(explicit), "state"]
        )
        default_args = fleet.build_parser().parse_args(["state"])
        with mock.patch.dict(
            os.environ,
            {"FLEET_CONFIG": str(configured), "FLEET_SEED": str(seed)},
            clear=True,
        ):
            self.assertEqual(
                fleet.config_path_from_args(explicit_args), explicit.resolve()
            )
            self.assertEqual(
                fleet.config_path_from_args(default_args), configured.resolve()
            )

    def test_state_dir_precedes_seed_default(self) -> None:
        state_dir = Path(self.tmp.name) / "custom-state"
        seed = Path(self.tmp.name) / "seed"
        args = fleet.build_parser().parse_args(["state"])
        with mock.patch.dict(
            os.environ,
            {"FLEET_STATE_DIR": str(state_dir), "FLEET_SEED": str(seed)},
            clear=True,
        ):
            self.assertEqual(
                fleet.config_path_from_args(args),
                (state_dir / "fleet.json").resolve(),
            )

    def test_config_path_without_any_binding_fails(self) -> None:
        args = fleet.build_parser().parse_args(["state"])
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(fleet.FleetError, "FLEET_SEED"):
                fleet.config_path_from_args(args)

    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_second_review_dispatch_keeps_review_two_phase(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "review-2"
        stream["verdicts"] = [
            {"pass": 1, "tip": stream["tip"], "approve": False, "findings": []}
        ]
        stream["dispatchCounters"] = {"review": 1}
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "review",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        self.assertEqual(fleet.cmd_dispatch(args), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "review-2")
        self.assertEqual(
            stream["agents"]["review"]["name"], "t094-1-73421147-review-2"
        )

    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch(
        "fleet.herdr_tab_create",
        return_value={"tab_id": "w1:t99", "pane_id": "w1:p99"},
    )
    def test_resolved_review_can_resume_its_held_pass(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
    ) -> None:
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "hold"
        stream["resumePhase"] = "review-2"
        stream["holdReason"] = "lost reviewer output"
        stream["verdicts"] = [
            {"pass": 1, "tip": stream["tip"], "approve": False, "findings": []}
        ]
        stream["dispatchCounters"] = {"review": 1}
        stream["agents"]["review"] = {
            "name": "old-review",
            "role": "review",
            "dispatchState": "resolved",
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "review",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        self.assertEqual(fleet.cmd_dispatch(args), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "review-2")
        self.assertNotIn("resumePhase", stream)
        self.assertNotIn("holdReason", stream)

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

    @mock.patch("fleet.time.sleep")
    @mock.patch("fleet.run_cmd")
    def test_agent_start_accepts_codex_workspace_trust_before_ready(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        not_ready = completed(
            ["herdr"],
            returncode=1,
            stdout='{"error":{"code":"agent_not_ready"}}',
        )

        def side_effect(cmd, **_kwargs):
            if "start" in cmd:
                return not_ready
            if "pane" in cmd and "read" in cmd:
                return completed(
                    cmd,
                    stdout="Do you trust the contents of this directory?\n1. Yes, continue",
                )
            if "pane" in cmd and "send-keys" in cmd:
                return completed(cmd)
            if "agent" in cmd and "get" in cmd:
                return completed(
                    cmd,
                    stdout='{"result":{"agent":{"agent_status":"idle"}}}',
                )
            return completed(cmd, returncode=1, stderr="unexpected command")

        mock_run.side_effect = side_effect
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        fleet.herdr_agent_start(
            config, "t094-1-review", "w1:p99", {"kind": "codex", "args": []}
        )
        key_calls = [
            call.args[0]
            for call in mock_run.call_args_list
            if "pane" in call.args[0] and "send-keys" in call.args[0]
        ]
        self.assertEqual(key_calls[0][-4:], ["send-keys", "w1:p99", "1", "enter"])
        mock_sleep.assert_not_called()

    @mock.patch("fleet.time.sleep")
    @mock.patch("fleet.run_cmd")
    def test_agent_start_accepts_claude_trusted_folder_before_ready(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        not_ready = completed(
            ["herdr"],
            returncode=1,
            stdout='{"error":{"code":"agent_not_ready"}}',
        )

        def side_effect(cmd, **_kwargs):
            if "start" in cmd:
                return not_ready
            if "pane" in cmd and "read" in cmd:
                return completed(
                    cmd,
                    stdout=(
                        "Quick safety check: Is this a project you created or one "
                        "you trust?\n❯ 1. Yes, I trust this folder"
                    ),
                )
            if "pane" in cmd and "send-keys" in cmd:
                return completed(cmd)
            if "agent" in cmd and "get" in cmd:
                return completed(
                    cmd,
                    stdout='{"result":{"agent":{"agent_status":"idle"}}}',
                )
            return completed(cmd, returncode=1, stderr="unexpected command")

        mock_run.side_effect = side_effect
        with open(FIXTURES / "fleet.json") as fh:
            config = json.load(fh)
        fleet.herdr_agent_start(
            config, "t094-1-review", "w1:p99", {"kind": "claude", "args": []}
        )
        key_calls = [
            call.args[0]
            for call in mock_run.call_args_list
            if "pane" in call.args[0] and "send-keys" in call.args[0]
        ]
        self.assertEqual(key_calls[0][-3:], ["send-keys", "w1:p99", "enter"])
        mock_sleep.assert_not_called()

    @mock.patch("fleet.codex_restart_required", return_value=True)
    @mock.patch("fleet.herdr_tab_close")
    @mock.patch("fleet.herdr_agent_prompt")
    @mock.patch("fleet.herdr_agent_start")
    @mock.patch("fleet.herdr_tab_create")
    def test_dispatch_restarts_codex_once_after_self_update(
        self,
        mock_tab_create: mock.Mock,
        mock_agent_start: mock.Mock,
        mock_agent_prompt: mock.Mock,
        mock_tab_close: mock.Mock,
        mock_restart_required: mock.Mock,
    ) -> None:
        config = json.loads(self.config_path.read_text())
        config["recipes"]["codex-mini"] = {
            "kind": "codex",
            "args": ["--model", "gpt-5.4-mini"],
        }
        config["streams"][0]["implRecipe"] = "codex-mini"
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        mock_tab_create.side_effect = [
            {"tab_id": "w1:t99", "pane_id": "w1:p99"},
            {"tab_id": "w1:t100", "pane_id": "w1:p100"},
        ]
        mock_agent_prompt.side_effect = [fleet.FleetError("prompt lost"), None]
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "dispatch",
                "T094.1",
                "impl",
                "--prompt-file",
                str(self.prompt),
            ]
        )

        self.assertEqual(fleet.cmd_dispatch(args), 0)

        record = json.loads(self.config_path.read_text())["streams"][0]["agents"][
            "impl"
        ]
        self.assertEqual(record["dispatchState"], "active")
        self.assertEqual(record["tabId"], "w1:t100")
        self.assertEqual(record["paneId"], "w1:p100")
        self.assertIn("codexRestartedAt", record)
        self.assertEqual(mock_agent_prompt.call_count, 2)
        self.assertEqual(mock_agent_start.call_count, 2)
        self.assertEqual(mock_tab_close.call_count, 1)
        self.assertEqual(mock_tab_close.call_args.args[1], "w1:t99")
        mock_restart_required.assert_called_once()

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


class PromptReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        with open(FIXTURES / "fleet.json") as fh:
            self.config = json.load(fh)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.prompt = Path(self.tmp.name) / "prompt.txt"
        self.prompt.write_text(
            "T094.1 REVIEW - judge the diff against the wiki notes in scope.\n"
        )

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_prompt_echoed_first_try(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        echo = "> T094.1 REVIEW - judge the diff\n  against the wiki notes in scope."
        mock_run.side_effect = make_herdr_run_handler(
            agent_read={"t094-1-review": echo}
        ).side_effect
        fleet.herdr_agent_prompt(self.config, "t094-1-review", self.prompt)
        prompts = [
            c for c in mock_run.call_args_list if "prompt" in c.args[0]
        ]
        self.assertEqual(len(prompts), 1)
        mock_sleep.assert_not_called()

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_swallowed_prompt_is_resent_once(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        blank = "> _ codex started\n\nAsk Codex to do anything"
        echo = "> T094.1 REVIEW - judge the diff against the wiki notes in scope."
        reads = iter([blank] * (fleet.PROMPT_RECEIPT_ATTEMPTS + 1) + [echo, echo])
        handler = make_herdr_run_handler().side_effect

        def side_effect(cmd, **kwargs):
            if "herdr" in cmd[:1] and "read" in cmd:
                return completed(cmd, stdout=next(reads))
            return handler(cmd, **kwargs)

        mock_run.side_effect = side_effect
        fleet.herdr_agent_prompt(self.config, "t094-1-review", self.prompt)
        prompts = [
            c for c in mock_run.call_args_list if "prompt" in c.args[0]
        ]
        self.assertEqual(len(prompts), 2)

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_never_echoed_raises(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        blank = "> _ codex started\n\nAsk Codex to do anything"
        handler = make_herdr_run_handler().side_effect

        def side_effect(cmd, **kwargs):
            if "herdr" in cmd[:1] and "read" in cmd:
                return completed(cmd, stdout=blank)
            return handler(cmd, **kwargs)

        mock_run.side_effect = side_effect
        with self.assertRaises(fleet.FleetError):
            fleet.herdr_agent_prompt(self.config, "t094-1-review", self.prompt)


class LoginMarkerTests(unittest.TestCase):
    def setUp(self) -> None:
        with open(FIXTURES / "fleet.json") as fh:
            self.config = json.load(fh)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.prompt = Path(self.tmp.name) / "prompt.txt"
        self.prompt.write_text("T094.1 REVIEW - judge the diff.\n")

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_login_demand_raises_without_resend(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        pane = "> T094.1 REVIEW - judge the diff.\n  Login expired · Please run /login"
        handler = make_herdr_run_handler().side_effect

        def side_effect(cmd, **kwargs):
            if "herdr" in cmd[:1] and "read" in cmd:
                return completed(cmd, stdout=pane)
            return handler(cmd, **kwargs)

        mock_run.side_effect = side_effect
        with self.assertRaises(fleet.FleetError) as ctx:
            fleet.herdr_agent_prompt(self.config, "t094-1-review", self.prompt)
        self.assertIn("authentication", str(ctx.exception))
        prompts = [c for c in mock_run.call_args_list if "prompt" in c.args[0]]
        self.assertEqual(len(prompts), 1)


class WorkingStatusReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        with open(FIXTURES / "fleet.json") as fh:
            self.config = json.load(fh)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.prompt = Path(self.tmp.name) / "prompt.txt"
        self.prompt.write_text("AUTH-9 - encode approved fixes.\n")

    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_working_agent_counts_as_receipt(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        blank = "#1 AUTH-9 ... (+15 lines) collapsed queue render"
        handler = make_herdr_run_handler().side_effect

        def side_effect(cmd, **kwargs):
            if "herdr" in cmd[:1] and "read" in cmd:
                return completed(cmd, stdout=blank)
            if "herdr" in cmd[:1] and "get" in cmd:
                return completed(
                    cmd, stdout='{"result":{"agent":{"agent_status":"working"}}}'
                )
            return handler(cmd, **kwargs)

        mock_run.side_effect = side_effect
        fleet.herdr_agent_prompt(self.config, "t094-1-review", self.prompt)
        prompts = [c for c in mock_run.call_args_list if "prompt" in c.args[0]]
        self.assertEqual(len(prompts), 1)
        mock_sleep.assert_called_once()


    @mock.patch("fleet.time.sleep")
    @mock.patch("subprocess.run")
    def test_boot_flicker_working_is_not_receipt(
        self, mock_run: mock.Mock, mock_sleep: mock.Mock
    ) -> None:
        blank = "codex banner, empty composer"
        statuses = iter(["working"] + ["idle"] * 20)
        handler = make_herdr_run_handler().side_effect

        def side_effect(cmd, **kwargs):
            if "herdr" in cmd[:1] and "read" in cmd:
                return completed(cmd, stdout=blank)
            if "herdr" in cmd[:1] and "get" in cmd:
                status = next(statuses)
                return completed(
                    cmd,
                    stdout='{"result":{"agent":{"agent_status":"%s"}}}' % status,
                )
            return handler(cmd, **kwargs)

        mock_run.side_effect = side_effect
        with self.assertRaises(fleet.FleetError):
            fleet.herdr_agent_prompt(self.config, "t094-1-review", self.prompt)
        prompts = [c for c in mock_run.call_args_list if "prompt" in c.args[0]]
        self.assertEqual(len(prompts), 2)


class RecipeAvailabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = {
            "usagePools": {
                "native": {"state": "available"},
                "cursor": {"state": "available"},
                "glm": {"state": "available"},
            },
            "recipes": {
                "grok-xhigh": {
                    "kind": "grok",
                    "enabled": True,
                    "usagePool": "native",
                    "fallbacks": ["grok-xhigh-cursor", "glm-53"],
                },
                "grok-xhigh-cursor": {
                    "kind": "cursor",
                    "enabled": True,
                    "usagePool": "cursor",
                    "fallbacks": [],
                },
                "glm-53": {
                    "kind": "claude",
                    "enabled": True,
                    "usagePool": "glm",
                    "fallbacks": ["grok-xhigh"],
                },
            },
        }
        self.stream = {"implRecipe": "grok-xhigh"}

    def test_uses_primary_when_available(self) -> None:
        requested, selected, recipe = fleet.recipe_choice_for_stream(
            self.config, self.stream, "impl"
        )
        self.assertEqual((requested, selected), ("grok-xhigh", "grok-xhigh"))
        self.assertEqual(recipe["kind"], "grok")

    def test_skips_disabled_and_spent_candidates_in_declared_order(self) -> None:
        self.config["recipes"]["grok-xhigh"]["enabled"] = False
        self.config["usagePools"]["cursor"]["state"] = "spent"
        requested, selected, _ = fleet.recipe_choice_for_stream(
            self.config, self.stream, "impl"
        )
        self.assertEqual((requested, selected), ("grok-xhigh", "glm-53"))

    def test_fallbacks_are_flat_not_recursive(self) -> None:
        self.config["usagePools"]["native"]["state"] = "spent"
        self.config["usagePools"]["cursor"]["state"] = "spent"
        self.config["usagePools"]["glm"]["state"] = "spent"
        with self.assertRaisesRegex(fleet.FleetError, "operator alert"):
            fleet.recipe_choice_for_stream(self.config, self.stream, "impl")

    @mock.patch("fleet.run_cmd")
    def test_glm_pre_start_loads_environment_before_agent_start(
        self, mock_run: mock.Mock
    ) -> None:
        mock_run.return_value = completed(["herdr"])
        recipe = {
            "envPreStep": 'set -a; source "$HOME/.claude-glm/lane.env"; set +a'
        }
        self.assertTrue(
            fleet.herdr_recipe_pre_start(
                {"session": "test-session"}, "t1-impl-1", "w1:p2", recipe
            )
        )
        commands = [call.args[0] for call in mock_run.call_args_list]
        self.assertEqual(commands[0][-4:-1], ["pane", "send-text", "w1:p2"])
        self.assertIn(".claude-glm/lane.env", commands[0][-1])
        self.assertEqual(commands[1][-3:], ["send-keys", "w1:p2", "enter"])
        self.assertEqual(commands[2][-1], "w1:p2")
        self.assertIn("--match", commands[2])

    @mock.patch("fleet.run_cmd")
    def test_failed_environment_pre_start_stops_dispatch(
        self, mock_run: mock.Mock
    ) -> None:
        mock_run.return_value = completed(
            ["herdr"], returncode=1, stderr="missing lane.env"
        )
        with self.assertRaisesRegex(fleet.FleetError, "environment pre-step failed"):
            fleet.herdr_recipe_pre_start(
                {"session": "test-session"},
                "t1-impl-1",
                "w1:p2",
                {"envPreStep": "false"},
            )


class RecipeCatalogTests(unittest.TestCase):
    def test_sync_repairs_routes_and_preserves_availability(self) -> None:
        config = {
            "usagePools": {
                "grok-native": {
                    "state": "spent",
                    "evidence": "weekly limit exhausted",
                }
            },
            "recipes": {
                "grok-xhigh": {
                    "kind": "grok",
                    "enabled": False,
                    "usagePool": "grok-native",
                    "fallbacks": ["glm-53"],
                    "args": [],
                }
            },
        }

        drift = fleet.sync_recipe_catalog(config)

        self.assertIn("missing recipe grok-xhigh-cursor", drift)
        self.assertEqual(config["recipeCatalogVersion"], 2)
        self.assertEqual(
            config["recipes"]["grok-xhigh"]["fallbacks"],
            ["grok-xhigh-cursor", "glm-53"],
        )
        self.assertFalse(config["recipes"]["grok-xhigh"]["enabled"])
        self.assertEqual(config["usagePools"]["grok-native"]["state"], "spent")
        self.assertEqual(
            config["usagePools"]["grok-native"]["evidence"],
            "weekly limit exhausted",
        )
        self.assertEqual(fleet.recipe_catalog_drift(config), [])

    def test_catalog_contains_fable_51_max_recipe(self) -> None:
        catalog = fleet.load_recipe_catalog()

        self.assertEqual(catalog["version"], 2)
        self.assertEqual(
            catalog["usagePools"]["anthropic-fable"], {"state": "available"}
        )
        self.assertEqual(
            catalog["recipes"]["fable-max"],
            {
                "kind": "claude",
                "enabled": True,
                "usagePool": "anthropic-fable",
                "fallbacks": [],
                "args": [
                    "--dangerously-skip-permissions",
                    "--model",
                    "claude-fable-5-1",
                    "--effort",
                    "max",
                ],
            },
        )

    def test_recipes_cli_sync_then_check(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "fleet.json"
            config_path.write_text('{"usagePools":{},"recipes":{},"streams":[]}\n')

            self.assertEqual(
                fleet.main(["--config", str(config_path), "recipes", "sync"]),
                0,
            )
            self.assertEqual(
                fleet.main(["--config", str(config_path), "recipes", "check"]),
                0,
            )
