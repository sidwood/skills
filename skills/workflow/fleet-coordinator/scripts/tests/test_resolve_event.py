"""Tests for durable resolution of unrecoverable monitor events."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class ResolveEventTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config_path = Path(self.tmp.name) / "fleet.json"
        config = json.loads((FIXTURES / "fleet.json").read_text())
        config["streams"][0]["agents"]["impl"] = {
            "name": "ticket-impl",
            "role": "impl",
            "dispatchState": "active",
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    def args(
        self,
        event_id: str = "ticket-impl@missing",
        capture_file: Path | None = None,
    ):
        arguments = [
                "--config",
                str(self.config_path),
                "resolve-event",
                "ticket-impl",
                "--event-id",
                event_id,
                "--reason",
                "agent and pane are both gone",
        ]
        if capture_file is not None:
            arguments.extend(["--capture-file", str(capture_file)])
        return fleet.build_parser().parse_args(arguments)

    def test_resolution_is_a_durable_monitor_ack(self) -> None:
        self.assertEqual(fleet.cmd_resolve_event(self.args()), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        event = stream["events"][-1]
        self.assertEqual(event["eventId"], "ticket-impl@missing")
        self.assertEqual(event["agent"], "ticket-impl")
        self.assertEqual(event["kind"], "resolved-lost-output")
        self.assertEqual(event["reason"], "agent and pane are both gone")
        self.assertEqual(stream["agents"]["impl"]["dispatchState"], "resolved")
        self.assertEqual(stream["phase"], "hold")
        self.assertEqual(stream["resumePhase"], "implementing")
        self.assertIn("ticket-impl@missing", stream["holdReason"])

    def test_resolution_retry_is_idempotent(self) -> None:
        args = self.args()
        self.assertEqual(fleet.cmd_resolve_event(args), 0)
        self.assertEqual(fleet.cmd_resolve_event(args), 0)

        events = json.loads(self.config_path.read_text())["streams"][0]["events"]
        matches = [event for event in events if event.get("eventId") == args.event_id]
        self.assertEqual(len(matches), 1)

    def test_resolution_can_audit_an_irrecoverable_open_teardown(self) -> None:
        event_id = "ticket-impl@7"
        captured_at = "2026-09-04T00:00:00+00:00"
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["phase"] = "review-1"
        stream["events"] = [
            {
                "at": captured_at,
                "eventId": event_id,
                "agent": "ticket-impl",
                "kind": "review-ready",
            }
        ]
        stream["agents"]["impl"].update(
            {
                "dispatchState": "captured",
                "capturedAt": captured_at,
                "captureEventId": event_id,
            }
        )
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        args = self.args(event_id)
        self.assertEqual(fleet.cmd_resolve_event(args), 0)
        self.assertEqual(fleet.cmd_resolve_event(args), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        event = stream["events"][0]
        self.assertIn("teardownResolvedAt", event)
        self.assertEqual(
            event["teardownResolutionReason"], "agent and pane are both gone"
        )
        self.assertEqual(stream["agents"]["impl"]["dispatchState"], "resolved")
        self.assertEqual(stream["phase"], "review-1")
        self.assertNotIn("holdReason", stream)

    def test_resolution_can_close_proof_after_role_slot_was_replaced(self) -> None:
        event_id = "old-impl@7"
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["events"] = [
            {
                "at": "2026-09-04T00:00:00+00:00",
                "eventId": event_id,
                "agent": "old-impl",
                "kind": "review-ready",
            }
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "resolve-event",
                "old-impl",
                "--event-id",
                event_id,
                "--reason",
                "old tab identity cannot be recovered",
            ]
        )

        self.assertEqual(fleet.cmd_resolve_event(args), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertIn("teardownResolvedAt", stream["events"][0])
        self.assertEqual(stream["agents"]["impl"]["name"], "ticket-impl")
        self.assertEqual(stream["agents"]["impl"]["dispatchState"], "active")

    def test_resolution_treats_event_id_as_opaque(self) -> None:
        args = self.args("opaque-event-id")
        self.assertEqual(fleet.cmd_resolve_event(args), 0)

        event = json.loads(self.config_path.read_text())["streams"][0]["events"][-1]
        self.assertEqual(event["eventId"], "opaque-event-id")
        self.assertEqual(event["agent"], "ticket-impl")

    def test_resolution_migrates_a_legacy_record_role_from_its_slot(self) -> None:
        config = json.loads(self.config_path.read_text())
        del config["streams"][0]["agents"]["impl"]["role"]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        self.assertEqual(fleet.cmd_resolve_event(self.args()), 0)

        record = json.loads(self.config_path.read_text())["streams"][0]["agents"][
            "impl"
        ]
        self.assertEqual(record["role"], "impl")
        self.assertEqual(record["dispatchState"], "resolved")

    def test_resolution_rejects_mismatched_event_identity(self) -> None:
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["events"] = [
            {
                "eventId": "opaque-event-id",
                "agent": "other-agent",
                "kind": "resolved-lost-output",
            }
        ]
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "already belongs"):
            fleet.cmd_resolve_event(self.args("opaque-event-id"))

    def test_resolution_rejects_a_saved_malformed_capture(self) -> None:
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["agents"]["impl"]["lastCaptureFailure"] = {
            "at": "2026-09-04T00:00:00+00:00",
            "eventId": "ticket-impl@missing",
            "capturePath": "/tmp/captures/ticket-impl.txt",
            "error": "missing REVIEW-READY",
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "saved capture exists"):
            fleet.cmd_resolve_event(self.args())

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["agents"]["impl"]["dispatchState"], "active")
        self.assertEqual(stream.get("events"), None)

    def test_resolution_can_explicitly_retire_exact_malformed_capture(self) -> None:
        capture_path = Path(self.tmp.name) / "ticket-impl.txt"
        capture_path.write_text("Login expired; no REVIEW-READY verdict\n")
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["agents"]["impl"]["lastCaptureFailure"] = {
            "at": "2026-09-04T00:00:00+00:00",
            "eventId": "ticket-impl@missing",
            "capturePath": str(capture_path),
            "error": "missing REVIEW-READY",
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        args = self.args(capture_file=capture_path)
        self.assertEqual(fleet.cmd_resolve_event(args), 0)
        self.assertEqual(fleet.cmd_resolve_event(args), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        matches = [
            event
            for event in stream["events"]
            if event.get("eventId") == "ticket-impl@missing"
        ]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["kind"], "resolved-invalid-output")
        self.assertEqual(matches[0]["capturePath"], str(capture_path.resolve()))
        self.assertEqual(matches[0]["captureError"], "missing REVIEW-READY")
        self.assertEqual(stream["agents"]["impl"]["dispatchState"], "resolved")
        self.assertEqual(stream["phase"], "hold")
        self.assertEqual(stream["resumePhase"], "implementing")

    def test_resolution_rejects_the_wrong_malformed_capture_path(self) -> None:
        capture_path = Path(self.tmp.name) / "ticket-impl.txt"
        capture_path.write_text("invalid\n")
        other_path = Path(self.tmp.name) / "other.txt"
        other_path.write_text("different evidence\n")
        config = json.loads(self.config_path.read_text())
        config["streams"][0]["agents"]["impl"]["lastCaptureFailure"] = {
            "at": "2026-09-04T00:00:00+00:00",
            "eventId": "ticket-impl@missing",
            "capturePath": str(capture_path),
            "error": "missing REVIEW-READY",
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

        with self.assertRaisesRegex(fleet.FleetError, "exact saved malformed"):
            fleet.cmd_resolve_event(self.args(capture_file=other_path))

    def test_second_resolution_preserves_original_resume_phase(self) -> None:
        self.assertEqual(fleet.cmd_resolve_event(self.args("ticket-impl@1")), 0)
        config = json.loads(self.config_path.read_text())
        stream = config["streams"][0]
        stream["agents"]["review"] = {
            "name": "ticket-review",
            "role": "review",
            "dispatchState": "active",
        }
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")
        args = fleet.build_parser().parse_args(
            [
                "--config",
                str(self.config_path),
                "resolve-event",
                "ticket-review",
                "--event-id",
                "ticket-review@2",
                "--reason",
                "second lane disappeared",
            ]
        )

        self.assertEqual(fleet.cmd_resolve_event(args), 0)

        stream = json.loads(self.config_path.read_text())["streams"][0]
        self.assertEqual(stream["phase"], "hold")
        self.assertEqual(stream["resumePhase"], "implementing")


if __name__ == "__main__":
    unittest.main()
