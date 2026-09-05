import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "fleet-watchdog.py"
SPEC = importlib.util.spec_from_file_location("watchdog", SCRIPT)
watchdog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watchdog)


class WatchdogTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.now = 2000000000
        self.config = {"seed": str(self.root), "workspace": "w8", "streams": []}
        self.config_path = self.root / "fleet.json"
        self.heartbeat = self.root / "fleet-monitor.heartbeat"
        self.pending = self.root / "fleet-monitor.pending"
        self.pending.write_text("")
        self.heartbeat.write_text(str(self.now))
        self.live = [{"name": "coordinator", "workspace_id": "w8", "agent_status": "working"}]
        self.inventory_path = self.root / "inventory.json"
        self.queue_log = self.root / "queue.jsonl"
        self.queue_failure = self.root / "queue-failure"
        self.fake = self.root / "fake-cli"
        self.fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(__file__).parent
if 'queue' in sys.argv:
    with (root / 'queue.jsonl').open('a') as output:
        output.write(json.dumps(sys.argv[1:]) + '\\n')
    print('queue output must stay captured')
    sys.exit(1 if (root / 'queue-failure').exists() else 0)
if 'agent' in sys.argv:
    with (root / 'inventory-calls.jsonl').open('a') as output:
        output.write(json.dumps({'args': sys.argv[1:], 'env': {k:v for k,v in os.environ.items() if k.startswith('HERDR_')}}) + '\\n')
    print((root / 'inventory.json').read_text())
''')
        self.fake.chmod(0o755)
        self.args = watchdog.parser().parse_args([
            "--config", str(self.config_path), "--state-dir", str(self.root),
            "--thread", "11111111-1111-4111-8111-111111111111",
            "--heartbeat", str(self.heartbeat), "--pending", str(self.pending),
            "--codex", str(self.fake), "--herdr", str(self.fake), "--coordinator", "coordinator"])
        self.checkout_code = 0
        real_run = watchdog.run

        def run(command, timeout):
            if len(command) > 1 and command[1] == str(watchdog.FLEET):
                return subprocess.CompletedProcess(command, self.checkout_code, "", "checkout fault")
            return real_run(command, timeout)

        self.runner = patch.object(watchdog, "run", side_effect=run)
        self.runner.start()
        self.addCleanup(self.runner.stop)
        self.sync()

    def sync(self):
        self.config_path.write_text(json.dumps(self.config))
        self.inventory_path.write_text(json.dumps({"result": {"agents": self.live}}))

    def polls(self, count=1, now=None, expected=0):
        output, error = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            for _ in range(count):
                self.assertEqual(watchdog.checkpoint(self.args, self.now if now is None else now), expected)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(error.getvalue(), "")

    def calls(self):
        return [json.loads(line) for line in self.queue_log.read_text().splitlines()] if self.queue_log.exists() else []

    def ledger(self):
        return json.loads((self.root / "watchdog.alerts.json").read_text())["alerts"]

    def handoff(self):
        event = {"kind": "review-ready", "eventId": "impl-1@7", "agent": "impl-1",
                 "at": self.now - 500, "closedAt": self.now - 490, "tip": "a" * 40}
        stream = {"ticket": "T1", "phase": "review-1", "events": [event], "agents": {
            "impl": {"name": "impl-1", "role": "impl", "dispatchState": "closed",
                     "capturedAt": event["at"], "captureEventId": event["eventId"]}}}
        self.config["streams"] = [stream]
        return stream

    def reviewer(self, stream, at=None, state="active", status="working"):
        stream["agents"]["review"] = {"name": "review-1", "role": "review", "dispatchState": state,
                                        "dispatchedAt": self.now - 400 if at is None else at}
        self.live.append({"name": "review-1", "workspace_id": "w8", "agent_status": status})

    def test_repeated_healthy_polls_have_zero_queue_calls(self):
        self.polls(5)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.ledger(), {})

    def test_long_working_worker_does_not_trigger_velocity_alarm(self):
        self.config["streams"] = [{"ticket": "T1", "phase": "implementing", "agents": {"impl": {
            "name": "impl", "dispatchState": "active", "dispatchedAt": self.now - 86400}}}]
        self.live.append({"name": "impl", "workspace_id": "w8", "agent_status": "working"})
        self.sync()
        self.polls(4)
        self.assertEqual(self.calls(), [])

    def test_heartbeat_once_then_recovery_rearms(self):
        self.heartbeat.unlink()
        self.polls(4)
        self.assertEqual(len(self.calls()), 1)
        self.heartbeat.write_text(str(self.now))
        self.polls()
        self.assertEqual(self.ledger(), {})
        self.heartbeat.write_text(str(self.now - 100))
        self.polls(3)
        self.assertEqual(len(self.calls()), 2)

    def test_failed_queue_backoff_survives_restart(self):
        self.heartbeat.unlink()
        self.queue_failure.touch()
        self.polls(expected=1)
        self.assertEqual(len(self.calls()), 1)
        self.polls(now=self.now + 59)
        self.assertEqual(len(self.calls()), 1)
        self.polls(now=self.now + 60, expected=1)
        self.assertEqual(len(self.calls()), 2)
        self.queue_failure.unlink()
        self.polls(now=self.now + 179)
        self.assertEqual(len(self.calls()), 2)
        self.polls(now=self.now + 180)
        self.polls(2, now=self.now + 2000)
        self.assertEqual(len(self.calls()), 3)

    def test_attempt_saved_before_queue_and_crash_is_backed_off(self):
        self.heartbeat.unlink()
        with patch.object(watchdog, "run", side_effect=KeyboardInterrupt):
            # Inventory is the first external read, so inject at queue only.
            with patch.object(watchdog, "collect", return_value=(dict([watchdog.incident("heartbeat", "x", "dead")]), {"heartbeat"})):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog.checkpoint(self.args, self.now)
        alert = next(iter(self.ledger().values()))
        self.assertEqual(alert["status"], "attempting")
        self.assertEqual(alert["nextAttemptAt"], self.now + 60)

    def test_malformed_ledger_fails_closed(self):
        path = self.root / "watchdog.alerts.json"
        path.write_text('{"version":1,"alerts":{"oops":{}}}')
        self.heartbeat.unlink()
        with self.assertRaises(ValueError):
            watchdog.checkpoint(self.args, self.now)
        self.assertEqual(self.calls(), [])
        self.assertEqual(path.read_text(), '{"version":1,"alerts":{"oops":{}}}')

    def test_config_and_inventory_failures_wake_once_each(self):
        self.config_path.write_text("{")
        self.polls(2)
        self.assertEqual(len(self.calls()), 1)
        self.sync()
        self.inventory_path.write_text("not JSON")
        self.polls(3)
        self.assertEqual(len(self.calls()), 2)

    def test_inventory_failure_does_not_clear_unresolved_lane_alert(self):
        stream = self.handoff()
        self.reviewer(stream)
        self.live.pop()
        self.sync()
        self.polls()
        before = {key for key, value in self.ledger().items() if value["scope"] in {"lane", "handoff"}}
        self.inventory_path.write_text("broken")
        self.polls()
        self.assertTrue(before.issubset(self.ledger()))
        self.sync()
        self.polls()
        self.assertEqual(len(self.calls()), 2)

    def test_current_handoff_missing_reviewer_is_actionable_once(self):
        self.handoff()
        self.sync()
        self.polls(4)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("REVIEW-HANDOFF", self.calls()[0][-1])

    def test_real_current_working_reviewer_satisfies_handoff(self):
        stream = self.handoff()
        self.reviewer(stream)
        self.sync()
        self.polls(3)
        self.assertEqual(self.calls(), [])

    def test_stale_review_slot_and_other_workspace_do_not_satisfy_handoff(self):
        stream = self.handoff()
        self.reviewer(stream, at=self.now - 600)
        self.sync()
        self.polls()
        self.assertIn("REVIEW-HANDOFF", self.calls()[0][-1])
        self.reviewer(stream)
        self.live[-1]["workspace_id"] = "w9"
        self.live[-2]["workspace_id"] = "w9"
        self.sync()
        self.polls()
        self.assertEqual(len(self.calls()), 2)

    def test_completed_and_bounced_history_never_reopens_handoff(self):
        stream = self.handoff()
        for phase in ["done", "complete", "landed", "approved", "bounce-1", "implementing"]:
            stream["phase"] = phase
            self.sync()
            self.polls()
        self.assertTrue(all("REVIEW-HANDOFF" not in call[-1] for call in self.calls()))

    def test_closed_reviewer_with_current_verdict_is_not_missing_handoff(self):
        stream = self.handoff()
        self.reviewer(stream, state="closed")
        stream["events"].append({"kind": "verdict", "eventId": "review-1@8", "agent": "review-1",
                                  "at": self.now - 200, "closedAt": self.now - 190})
        self.sync()
        self.polls()
        self.assertTrue(all("REVIEW-HANDOFF" not in call[-1] for call in self.calls()))

    def test_hold_with_reason_surfaces_once_and_reason_change_rearms(self):
        stream = self.handoff()
        stream.update(phase="hold", holdReason="waiting for operator ruling")
        self.sync()
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("HOLD T1", self.calls()[0][-1])
        self.assertNotIn("REVIEW-HANDOFF", self.calls()[0][-1])
        stream["holdReason"] = "different operator decision"
        self.sync()
        self.polls()
        self.assertEqual(len(self.calls()), 2)

    def test_starting_lane_gets_grace_then_alert(self):
        self.config["streams"] = [{"ticket": "T1", "phase": "implementing", "agents": {"impl": {
            "name": "impl", "dispatchState": "reserved", "reservedAt": self.now - 100}}}]
        self.sync()
        self.polls()
        self.assertEqual(self.calls(), [])
        self.heartbeat.write_text(str(self.now + 21))
        self.polls(now=self.now + 21)
        self.assertIn("STARTING-STUCK", self.calls()[0][-1])

    def test_pending_root_events_wake_without_stdout_monitor_delivery(self):
        for target in ("verdict", "vanished", "teardown", "action"):
            self.pending.write_text(f"lane@7\tlane\tidle\t0\t0\t{target}\n")
            self.polls(2)
        self.assertEqual(len(self.calls()), 4)

    def test_routine_pending_stays_monitor_owned_until_unacked_deadline(self):
        self.pending.write_text(f"lane@7\tlane\tidle\t{self.now - 30}\t1\tcoordinator\n")
        self.polls()
        self.assertEqual(self.calls(), [])
        self.heartbeat.write_text(str(self.now + 100))
        self.polls(now=self.now + 100)
        self.assertIn("PENDING-UNACKED", self.calls()[0][-1])

    def test_closed_pending_event_is_acknowledged_by_exact_capture(self):
        self.handoff()["phase"] = "approved"
        self.sync()
        self.pending.write_text("impl-1@7\timpl-1\tidle\t0\t0\tvanished\n")
        self.polls()
        self.assertEqual(self.calls(), [])

    def test_uncorrelated_closed_record_does_not_ack_pending(self):
        stream = self.handoff()
        stream["phase"] = "approved"
        stream["events"][0].pop("closedAt")
        stream["agents"]["impl"]["captureEventId"] = "impl-1@other"
        self.sync()
        self.pending.write_text("impl-1@7\timpl-1\tidle\t0\t0\tcoordinator\n")
        self.polls()
        self.assertIn("CAPTURE-TEARDOWN", self.calls()[0][-1])

    def test_verdict_pending_wakes_even_after_monitor_swept(self):
        stream = self.handoff()
        stream["phase"] = "verdict-pending"
        stream["events"].append({"kind": "verdict", "eventId": "review-1@8", "agent": "review-1",
                                  "at": self.now - 100, "closedAt": self.now - 90})
        self.sync()
        self.polls(2)
        self.assertIn("VERDICT-PENDING", self.calls()[0][-1])

    def test_checkout_drift_is_actionable_once(self):
        self.checkout_code = 2
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("CHECKOUT-DRIFT", self.calls()[0][-1])

    def test_default_session_clears_ambient_herdr_environment(self):
        with patch.dict(os.environ, {"HERDR_ENV": "1", "HERDR_SESSION": "wrong", "HERDR_WORKSPACE_ID": "w9"}):
            self.polls()
        call = json.loads((self.root / "inventory-calls.jsonl").read_text().splitlines()[0])
        self.assertEqual(call["env"], {})
        self.assertEqual(call["args"], ["agent", "list"])
        self.config["session"] = "shared"
        self.sync()
        self.polls()
        call = json.loads((self.root / "inventory-calls.jsonl").read_text().splitlines()[-1])
        self.assertEqual(call["args"], ["--session", "shared", "agent", "list"])

    def test_dry_run_no_queue_or_state_mutation(self):
        self.heartbeat.unlink()
        self.args.state_dir = self.root / "absent-state-directory"
        self.args.dry_run = True
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(watchdog.checkpoint(self.args, self.now), 0)
        self.assertIn("MONITOR-HEARTBEAT", output.getvalue())
        self.assertFalse(self.args.state_dir.exists())
        self.assertEqual(self.calls(), [])

    def test_pause_preserves_ledger_and_stops_all_reads_and_wakes(self):
        self.heartbeat.unlink()
        self.polls()
        ledger = (self.root / "watchdog.alerts.json").read_bytes()
        self.args.pause_file = self.root / "PAUSED.md"
        self.args.pause_file.write_text("operator restart")
        with patch.object(watchdog, "collect", side_effect=AssertionError("poll while paused")):
            self.polls(3)
        self.assertEqual((self.root / "watchdog.alerts.json").read_bytes(), ledger)
        self.assertEqual(len(self.calls()), 1)
        self.args.pause_file.unlink()
        self.polls()
        self.assertEqual(len(self.calls()), 1)

    def test_coordinator_missing_is_actionable(self):
        self.live = []
        self.sync()
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("COORDINATOR-MISSING", self.calls()[0][-1])

    def test_pending_corruption_surfaces_once(self):
        self.pending.write_text("broken")
        self.polls(2)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("MONITOR-PENDING", self.calls()[0][-1])

    def test_board_stale_relative_to_config(self):
        self.args.board = self.root / "board"
        self.args.board.write_text("projection")
        os.utime(self.args.board, (self.now - 1000, self.now - 1000))
        os.utime(self.config_path, (self.now - 500, self.now - 500))
        self.polls(2)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("BOARD-STALE", self.calls()[0][-1])


    def test_monitor_retries_cannot_rearm_unacked_incident(self):
        for elapsed, sent in [(30, 0), (120, 120), (270, 120), (360, 360),
                              (510, 360), (840, 840), (990, 840)]:
            self.pending.write_text(f"impl@9\timpl\tidle\t{self.now + sent}\t1\tcoordinator\n")
            self.heartbeat.write_text(str(self.now + elapsed))
            self.polls(now=self.now + elapsed)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("PENDING-UNACKED impl@9", self.calls()[0][-1])
        self.pending.write_text("")
        self.polls(now=self.now + 990)
        self.assertEqual(self.ledger(), {})

    def test_captured_lane_teardown_survives_missing_pending_row(self):
        stream = self.handoff()
        stream["events"][0].pop("closedAt")
        stream["agents"]["impl"]["dispatchState"] = "captured"
        self.live.append({"name": "impl-1", "workspace_id": "w8", "agent_status": "done"})
        self.sync()
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("CAPTURE-TEARDOWN", self.calls()[0][-1])

    def test_reconstructed_pending_row_does_not_duplicate_capture_teardown_wake(self):
        stream = self.handoff()
        stream["events"][0].pop("closedAt")
        stream["agents"]["impl"]["dispatchState"] = "captured"
        self.live.append({"name": "impl-1", "workspace_id": "w8", "agent_status": "done"})
        self.sync()
        self.polls()
        self.pending.write_text("impl-1@7\timpl-1\tdone\t0\t0\tcoordinator\n")
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)

    def test_legacy_capture_timestamp_uses_correlated_event_identity(self):
        stream = self.handoff()
        stream["events"][0].pop("closedAt")
        stream["agents"]["impl"]["dispatchState"] = "captured"
        stream["agents"]["impl"].pop("captureEventId")
        self.live.append({"name": "impl-1", "workspace_id": "w8", "agent_status": "done"})
        self.sync()
        self.polls()
        self.pending.write_text("impl-1@7\timpl-1\tdone\t0\t0\tcoordinator\n")
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("CAPTURE-TEARDOWN T1 impl-1@7", self.calls()[0][-1])

    def test_malformed_event_closure_cannot_acknowledge_pending(self):
        stream = self.handoff()
        stream["phase"] = "approved"
        stream["events"][0]["closedAt"] = "garbage"
        self.sync()
        self.pending.write_text("impl-1@7\timpl-1\tidle\t0\t0\tvanished\n")
        self.polls()
        self.assertIn("FLEET-CONFIG", self.calls()[0][-1])

    def test_reserved_working_and_unknown_reviewer_do_not_prove_handoff(self):
        stream = self.handoff()
        self.reviewer(stream, state="reserved")
        self.sync()
        self.polls()
        self.assertIn("REVIEW-HANDOFF", self.calls()[0][-1])
        self.assertEqual(len(self.calls()), 1)

    def test_current_settled_reviewer_requires_exact_pending_event(self):
        stream = self.handoff()
        self.reviewer(stream, status="done")
        self.live[-1]["state_change_seq"] = 5
        self.pending.write_text("review-1@5\treview-1\tdone\t0\t0\tverdict\n")
        self.sync()
        self.polls()
        self.assertNotIn("REVIEW-HANDOFF", self.calls()[0][-1])
        self.assertIn("PENDING-VERDICT", self.calls()[0][-1])
        self.pending.write_text("review-1@4\treview-1\tdone\t0\t0\tverdict\n")
        self.polls()
        self.assertIn("REVIEW-HANDOFF", self.calls()[-1][-1])

    def test_review_phase_aliases_have_handoff_checks(self):
        stream = self.handoff()
        for phase in ("review", "in-review"):
            stream["phase"] = phase
            self.sync()
            self.polls()
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("REVIEW-HANDOFF", self.calls()[0][-1])

    def test_blocked_coordinator_requires_two_polls_and_rearms_after_recovery(self):
        self.live[0]["agent_status"] = "blocked"
        self.sync()
        self.polls()
        self.assertEqual(self.calls(), [])
        self.polls(3)
        self.assertEqual(len(self.calls()), 1)
        self.live[0]["agent_status"] = "working"
        self.sync()
        self.polls()
        self.live[0]["agent_status"] = "blocked"
        self.sync()
        self.polls(2)
        self.assertEqual(len(self.calls()), 2)

    def test_transient_blocked_worker_is_silent(self):
        self.config["streams"] = [{"ticket": "T1", "phase": "implementing", "agents": {"impl": {
            "name": "impl", "dispatchState": "active", "dispatchedAt": self.now - 1000}}}]
        self.live.append({"name": "impl", "workspace_id": "w8", "agent_status": "blocked"})
        self.sync()
        self.polls()
        self.live[-1]["agent_status"] = "working"
        self.sync()
        self.polls(3)
        self.assertEqual(self.calls(), [])

    def test_fresh_config_updates_cannot_mask_old_board(self):
        self.args.board = self.root / "board"
        self.args.board.write_text("projection")
        os.utime(self.args.board, (self.now - 1000, self.now - 1000))
        for elapsed in (0, 30, 60):
            os.utime(self.config_path, (self.now + elapsed, self.now + elapsed))
            self.heartbeat.write_text(str(self.now + elapsed))
            self.polls(now=self.now + elapsed)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("BOARD-STALE", self.calls()[0][-1])

    def test_local_health_metrics_require_no_queue(self):
        self.polls(3)
        data = json.loads((self.root / "watchdog.alerts.json").read_text())
        self.assertEqual(data["checkCount"], 3)
        self.assertEqual(data["lastCheckAt"], self.now)
        self.assertEqual(data["lastHealthyAt"], self.now)
        self.assertEqual(data.get("queueAttemptCount", 0), 0)
        self.assertEqual(self.calls(), [])


    def test_empty_active_phase_uses_durable_grace_then_wakes_once(self):
        for phase in ("implementing", "bounce-1", "review-1"):
            self.config["streams"] = [{"ticket": phase, "phase": phase}]
            self.sync()
            self.polls()
        self.assertEqual(self.calls(), [])
        self.heartbeat.write_text(str(self.now + 121))
        self.polls(3, now=self.now + 121)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("PHASE-WITHOUT-LANE", self.calls()[0][-1])

    def test_ready_work_waits_for_dependencies_and_occupied_serial_lane(self):
        blocker = {"ticket": "T0", "phase": "implementing", "agents": {"impl": {
            "name": "impl", "dispatchState": "active", "dispatchedAt": self.now - 1000}}}
        ready = {"ticket": "T1", "phase": "ready", "blockedBy": ["T0"]}
        self.config["streams"] = [blocker, ready]
        self.live.append({"name": "impl", "workspace_id": "w8", "agent_status": "working"})
        self.sync()
        self.polls(3)
        self.assertEqual(self.calls(), [])
        blocker["phase"] = "landed"
        blocker["agents"]["impl"]["dispatchState"] = "closed"
        self.sync()
        self.polls()
        self.assertEqual(self.calls(), [])
        self.heartbeat.write_text(str(self.now + 121))
        self.polls(3, now=self.now + 121)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("READY-WITHOUT-WORKER", self.calls()[0][-1])

    def test_resolved_blocked_work_becomes_ready_but_hold_and_unknown_gates_do_not(self):
        self.config["streams"] = [
            {"ticket": "T0", "phase": "complete"},
            {"ticket": "T1", "phase": "blocked", "blockedBy": ["T0"]},
            {"ticket": "T2", "phase": "blocked", "blockedBy": ["operator approval"]}]
        self.sync()
        self.polls()
        self.heartbeat.write_text(str(self.now + 121))
        self.polls(now=self.now + 121)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("READY-WITHOUT-WORKER T1", self.calls()[0][-1])
        self.assertNotIn("READY-WITHOUT-WORKER T2", self.calls()[0][-1])


if __name__ == "__main__":
    unittest.main()
