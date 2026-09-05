#!/usr/bin/env python3
"""One bounded local checkpoint; enqueue AI work only for an actionable incident."""

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

DONE = {"done", "complete", "landed", "cancelled", "canceled", "killed", "superseded", "withdrawn"}
CLOSED = {"closed", "resolved"}
STARTING = {"reserved", "tab-created", "started", "prompting", "starting"}
FLEET = Path(__file__).resolve().parents[2] / "fleet-coordinator/scripts/fleet.py"


def stamp(value):
    if isinstance(value, bool):
        raise ValueError("invalid timestamp")
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str):
        try:
            result = float(value)
        except ValueError:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("timestamp must have a timezone")
            result = parsed.timestamp()
    else:
        raise ValueError("missing timestamp")
    if not math.isfinite(result):
        raise ValueError("invalid timestamp")
    return result


def clean_env():
    # Herdr pane/session variables must not override the canonical workspace.
    return {key: value for key, value in os.environ.items()
            if not key.startswith("HERDR_")}


def run(command, timeout):
    return subprocess.run(command, capture_output=True, text=True,
                          timeout=timeout, env=clean_env(), check=False)


def inventory(config, args):
    command = [args.herdr]
    if config.get("session"):
        command += ["--session", config["session"]]
    result = run(command + ["agent", "list"], args.command_timeout)
    if result.returncode:
        raise ValueError("Herdr inventory command failed")
    payload = json.loads(result.stdout)
    body = payload["result"]
    agents = body["agents"] if isinstance(body, dict) else body
    if not isinstance(agents, list):
        raise ValueError("inventory is not a list")
    selected = {}
    for agent in agents:
        if not isinstance(agent, dict):
            raise ValueError("invalid inventory row")
        workspaces = set()
        if "workspace_id" in agent:
            if not isinstance(agent["workspace_id"], str) or not agent["workspace_id"]:
                raise ValueError("invalid workspace")
            workspaces.add(agent["workspace_id"])
        for key in ("pane_id", "tab_id"):
            value = agent.get(key)
            if isinstance(value, str) and ":" in value:
                workspaces.add(value.split(":", 1)[0])
        if len(workspaces) > 1:
            raise ValueError("conflicting workspace identities")
        if not workspaces:
            raise ValueError("inventory row has no workspace identity")
        if config["workspace"] not in workspaces:
            continue
        name = agent.get("name")
        if not isinstance(name, str) or not name or name in selected:
            raise ValueError("invalid or duplicate agent name")
        if not isinstance(agent.get("agent_status"), str):
            raise ValueError("missing agent status")
        selected[name] = agent
    return selected


def read_config(path):
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise ValueError("config must be an object")
    for key in ("workspace", "seed"):
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError("missing config " + key)
    if not Path(config["seed"]).is_absolute():
        raise ValueError("seed must be absolute")
    if "session" in config and not isinstance(config["session"], str):
        raise ValueError("invalid session")
    streams = config.get("streams")
    if not isinstance(streams, list):
        raise ValueError("streams must be a list")
    tickets, names, ids = set(), set(), set()
    for stream in streams:
        if not isinstance(stream, dict):
            raise ValueError("invalid stream")
        ticket = stream.get("ticket")
        if not isinstance(ticket, str) or not ticket or ticket in tickets:
            raise ValueError("invalid or duplicate ticket")
        tickets.add(ticket)
        if not isinstance(stream.get("phase"), str):
            raise ValueError("invalid phase")
        agents, events = stream.get("agents", {}), stream.get("events", [])
        if not isinstance(agents, dict) or not isinstance(events, list):
            raise ValueError("invalid agents or events")
        for record in agents.values():
            if not isinstance(record, dict):
                raise ValueError("invalid agent record")
            name = record.get("name")
            if not isinstance(name, str) or not name or name in names:
                raise ValueError("invalid or duplicate lane identity")
            names.add(name)
            for key in ("reservedAt", "dispatchedAt", "capturedAt", "closedAt", "resolvedAt"):
                if record.get(key):
                    stamp(record[key])
        for event in events:
            if not isinstance(event, dict):
                raise ValueError("invalid event")
            for field in ("at", "closedAt", "teardownResolvedAt"):
                if event.get(field):
                    stamp(event[field])
            event_id = event.get("eventId")
            if event_id:
                if not isinstance(event_id, str) or event_id in ids:
                    raise ValueError("duplicate or invalid event identity")
                ids.add(event_id)
    return config


def correlated(record, event):
    if record.get("name") != event.get("agent"):
        return False
    if record.get("captureEventId"):
        return record["captureEventId"] == event.get("eventId")
    return bool(record.get("capturedAt") and record["capturedAt"] == event.get("at"))


def event_closed(stream, event):
    if (event.get("closedAt") or event.get("teardownResolvedAt")
            or event.get("kind") in {"resolved-lost-output", "resolved-invalid-output"}):
        return True
    return any(record.get("dispatchState") in CLOSED and correlated(record, event)
               for record in stream.get("agents", {}).values())


def incident(scope, identity, message):
    fingerprint = hashlib.sha256(json.dumps([scope, identity], sort_keys=True).encode()).hexdigest()
    return fingerprint, {"scope": scope, "message": message}


def pending_review(args, reviewer, agent):
    name = reviewer.get("name")
    seq = agent.get("state_change_seq")
    if seq is None:
        return False
    expected = f"{name}@{seq}"
    try:
        return any(len(parts) == 6 and parts[0] == expected and parts[1] == name
                   and parts[5] == "verdict"
                   for parts in (line.split("\t") for line in args.pending.read_text().splitlines()))
    except OSError:
        return False


def inspect_streams(config, live, now, args):
    issues = {}
    scopes = {"hold", "verdict", "teardown", "workflow", "ready"}
    if live is not None:
        scopes.update({"lane", "handoff"})

    def add(scope, identity, message):
        key, value = incident(scope, identity, message)
        issues[key] = value

    for stream in config["streams"]:
        ticket, phase = stream["ticket"], stream["phase"]
        records, events = stream.get("agents", {}), stream.get("events", [])
        open_records = [record for record in records.values() if record.get("dispatchState") not in CLOSED]
        review_phase = phase in {"review", "in-review"} or phase.startswith(("review-", "in-review-"))
        active_phase = phase == "implementing" or phase == "bounce" or phase.startswith("bounce-") or review_phase
        captures = [event for event in events if event.get("kind") in {"review-ready", "verdict"}]
        handoff_owned = (review_phase and captures and captures[-1].get("kind") == "review-ready"
                         and event_closed(stream, captures[-1]))
        if active_phase and not open_records and not handoff_owned:
            latest = events[-1] if events else {}
            identity = [ticket, phase, latest.get("eventId") or latest.get("at")]
            key, value = incident("workflow", identity, f"PHASE-WITHOUT-LANE {ticket} {phase}")
            anchor = stamp(latest["at"]) if latest.get("at") else now
            issues[key] = {**value, "readyAt": anchor + args.handoff_seconds + args.poll_grace}
        if phase == "hold":
            reason = stream.get("holdReason") or "missing hold reason"
            add("hold", [ticket, reason], f"HOLD {ticket}: {reason}")
        if phase == "verdict-pending":
            event = next((e for e in reversed(events) if e.get("kind") == "verdict"), {})
            add("verdict", [ticket, event.get("eventId") or event.get("at")],
                f"VERDICT-PENDING {ticket} {event.get('eventId', '')}".strip())
        for record in records.values():
            if record.get("dispatchState") != "captured":
                continue
            event = next((event for event in reversed(events) if correlated(record, event)), None)
            if event and event_closed(stream, event):
                continue
            captured_at = record.get("capturedAt") or (event or {}).get("at")
            if captured_at and now - stamp(captured_at) > args.teardown_seconds + args.poll_grace:
                capture_id = record.get("captureEventId") or (event or {}).get("eventId")
                add("teardown", [ticket, record["name"], capture_id or captured_at],
                    f"CAPTURE-TEARDOWN {ticket} {capture_id or record['name']}")
        if live is None:
            continue
        for role, record in records.items():
            state, name = record.get("dispatchState", "active"), record["name"]
            if state in CLOSED:
                continue
            started = record.get("reservedAt") or record.get("dispatchedAt")
            age = now - stamp(started) if started else float("inf")
            if state in STARTING:
                if age > args.handoff_seconds + args.poll_grace:
                    add("lane", [ticket, name, "starting"], f"STARTING-STUCK {ticket} {name}")
            elif name not in live:
                add("lane", [ticket, name, "missing"], f"LANE-MISSING {ticket} {name}")
            elif live[name]["agent_status"] == "starting" and age > args.handoff_seconds + args.poll_grace:
                add("lane", [ticket, name, "starting"], f"STARTING-STUCK {ticket} {name}")
        # A later phase or capture has already consumed a historical handoff.
        if phase in DONE or not review_phase:
            continue
        relevant = [e for e in events if e.get("kind") in {"review-ready", "verdict"}]
        if not relevant or relevant[-1].get("kind") != "review-ready":
            continue
        event = relevant[-1]
        if not event_closed(stream, event):
            continue
        at = stamp(event.get("at"))
        if now - at <= args.handoff_seconds + args.poll_grace:
            continue
        reviewer = records.get("review", {})
        reviewed_after = any(e.get("kind") == "verdict" and stamp(e.get("at")) >= at
                             for e in events)
        start = reviewer.get("dispatchedAt") or reviewer.get("reservedAt")
        agent = live.get(reviewer.get("name"), {})
        current = (start and stamp(start) >= at
                   and reviewer.get("dispatchState") == "active"
                   and (agent.get("agent_status") == "working"
                        or (agent.get("agent_status") in {"idle", "done", "blocked"}
                            and pending_review(args, reviewer, agent))))
        if not reviewed_after and not current:
            add("handoff", [ticket, event.get("eventId") or [event.get("agent"), event.get("at")]],
                f"REVIEW-HANDOFF {ticket} {event.get('eventId', event.get('agent', '?'))}")
    occupied = any(record.get("dispatchState") not in CLOSED
                   for stream in config["streams"] for record in stream.get("agents", {}).values())
    phases = {stream["ticket"]: stream["phase"] for stream in config["streams"]}
    if not occupied:
        for stream in config["streams"]:
            dependencies = (stream.get("blockedBy") or []) + (stream.get("dependsOn") or [])
            ready_phase = stream["phase"] in {"ready", "queued"} or (stream["phase"] == "blocked" and dependencies)
            if not ready_phase:
                continue
            resolved = True
            for dependency in dependencies:
                match = re.match(r"([A-Za-z0-9.\-]+)", str(dependency))
                if not match or phases.get(match.group(1)) not in DONE:
                    resolved = False
                    break
            if resolved:
                key, value = incident("ready", stream["ticket"], f"READY-WITHOUT-WORKER {stream['ticket']}")
                issues[key] = {**value, "readyAt": now + args.handoff_seconds + args.poll_grace}
    return issues, scopes


def inspect_pending(path, config, now, args):
    issues = {}
    if not path.exists():
        raise ValueError("pending event ledger is missing")
    events = {e["eventId"]: (s, e) for s in config["streams"]
              for e in s.get("events", []) if e.get("eventId")}
    seen = set()
    for line in path.read_text().splitlines():
        if not line:
            continue
        columns = line.split("\t")
        if len(columns) not in {5, 6}:
            raise ValueError("malformed pending event")
        event_id, lane, status, sent, attempts = columns[:5]
        if not event_id or not lane or event_id in seen or not sent.isdecimal() or not attempts.isdecimal():
            raise ValueError("invalid pending identity or counter")
        seen.add(event_id)
        target = columns[5] if len(columns) == 6 else ""
        if not target:
            target = "verdict" if any(r.get("name") == lane and role == "review"
                for s in config["streams"] for role, r in s.get("agents", {}).items()) else "coordinator"
        binding = events.get(event_id)
        if binding:
            stream, event = binding
            if event.get("agent") != lane:
                raise ValueError("pending event belongs to another lane")
            if event_closed(stream, event):
                continue
            if now - stamp(event.get("at")) <= args.teardown_seconds + args.poll_grace:
                continue
            key, value = incident("teardown", [stream["ticket"], lane, event_id],
                                  f"CAPTURE-TEARDOWN {stream['ticket']} {event_id}")
            issues[key] = value
            continue
        deferred = target == "coordinator"
        if deferred:
            target = "unacked"
        key, value = incident("pending", [event_id, target], f"PENDING-{target.upper()} {event_id}")
        if deferred:
            # Anchor this deadline once in the ledger; transport retries rewrite
            # TSV sent, but only a real acknowledgement resolves the incident.
            value["readyAt"] = (int(sent) or now) + args.handoff_seconds + args.poll_grace
        issues[key] = value
    return issues


def collect(args, now):
    issues, scopes = {}, {"heartbeat", "config"}

    def fault(scope, message):
        key, value = incident(scope, "unavailable", message)
        issues[key] = value

    try:
        heartbeat = stamp(args.heartbeat.read_text().strip())
        if heartbeat > now + args.poll_grace + 5:
            raise ValueError("heartbeat is in the future")
        if now - heartbeat > args.heartbeat_seconds + args.poll_grace:
            fault("heartbeat", "MONITOR-HEARTBEAT stale")
    except (OSError, ValueError):
        fault("heartbeat", "MONITOR-HEARTBEAT missing or unreadable")
    try:
        config = read_config(args.config)
    except (OSError, ValueError, TypeError, KeyError):
        fault("config", "FLEET-CONFIG unreadable or malformed")
        return issues, scopes
    scopes.update({"inventory", "checkouts", "pending-input"})
    try:
        live = inventory(config, args)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        live = None
        fault("inventory", "HERDR-INVENTORY unavailable or malformed")
    coordinator = args.coordinator or config.get("coordinator")
    if live is not None:
        scopes.add("blocked")
        owned = {record["name"] for stream in config["streams"]
                 for record in stream.get("agents", {}).values()
                 if record.get("dispatchState") not in CLOSED}
        if coordinator:
            owned.add(coordinator)
        for name in sorted(owned):
            if live.get(name, {}).get("agent_status") == "blocked":
                key, value = incident("blocked", name, "LANE-BLOCKED " + name)
                issues[key] = {**value, "confirmations": 2}
    if coordinator and live is not None:
        scopes.add("coordinator")
        if coordinator not in live:
            fault("coordinator", "COORDINATOR-MISSING " + coordinator)
    try:
        stream_issues, stream_scopes = inspect_streams(config, live, now, args)
        issues.update(stream_issues)
        scopes.update(stream_scopes)
    except (ValueError, TypeError, KeyError):
        fault("config", "FLEET-CONFIG invalid event timestamps or lane state")
    try:
        issues.update(inspect_pending(args.pending, config, now, args))
        scopes.add("pending")
    except (OSError, ValueError, TypeError, KeyError):
        fault("pending-input", "MONITOR-PENDING unreadable or malformed")
    try:
        result = run([sys.executable, str(FLEET), "--config", str(args.config), "checkouts", "check"],
                     args.command_timeout)
        if result.returncode:
            fault("checkouts", "CHECKOUT-DRIFT run fleet checkouts check")
    except (OSError, subprocess.SubprocessError):
        fault("checkouts", "CHECKOUT-CHECK unavailable")
    if args.board:
        scopes.add("board")
        try:
            board_at, config_at = args.board.stat().st_mtime, args.config.stat().st_mtime
            if config_at - board_at > args.handoff_seconds + args.poll_grace:
                fault("board", "BOARD-STALE relative to fleet config")
        except OSError:
            fault("board", "BOARD-MISSING or unreadable")
    return issues, scopes


def atomic_json(path, data):
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(data, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_ledger(path):
    if not path.exists():
        return {"version": 1, "alerts": {}}
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("alerts"), dict):
        raise ValueError("malformed watchdog ledger")
    for field in ("lastCheckAt", "lastHealthyAt"):
        if field in data:
            stamp(data[field])
    for field in ("checkCount", "queueAttemptCount"):
        if field in data and (type(data[field]) is not int or data[field] < 0):
            raise ValueError("invalid watchdog metric")
    for key, alert in data["alerts"].items():
        if not isinstance(key, str) or len(key) != 64 or not isinstance(alert, dict):
            raise ValueError("invalid alert")
        for field in ("scope", "message"):
            if not isinstance(alert.get(field), str) or not alert[field]:
                raise ValueError("invalid alert " + field)
        if alert.get("status") not in {"new", "attempting", "failed", "sent"}:
            raise ValueError("invalid alert status")
        if type(alert.get("attempts")) is not int or alert["attempts"] < 0:
            raise ValueError("invalid attempt counter")
        stamp(alert.get("nextAttemptAt"))
        stamp(alert.get("firstSeenAt"))
        if "readyAt" in alert:
            stamp(alert["readyAt"])
        for field in ("observations", "confirmations"):
            if field in alert and (type(alert[field]) is not int or alert[field] < 0):
                raise ValueError("invalid observation count")
    return data


def checkpoint(args, now=None):
    now = time.time() if now is None else now
    if args.pause_file and args.pause_file.exists():
        return 0
    if args.dry_run:
        issues, _ = collect(args, now)
        previous = read_ledger(args.state_dir / "watchdog.alerts.json")["alerts"]
        findings = []
        for key, issue in issues.items():
            stored = previous.get(key, {})
            ready = stored.get("readyAt", issue.get("readyAt", now)) <= now
            confirmed = stored.get("observations", 0) + 1 >= issue.get("confirmations", 1)
            if ready and confirmed:
                findings.append(issue["message"])
        for finding in sorted(findings):
            print(finding)
        return 0
    args.state_dir.mkdir(parents=True, exist_ok=True)
    with (args.state_dir / "watchdog.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        ledger_path = args.state_dir / "watchdog.alerts.json"
        # Never replace a corrupt ledger with an empty one: that would flood wakes.
        ledger = read_ledger(ledger_path)
        issues, observed = collect(args, now)
        ledger["lastCheckAt"] = now
        ledger["checkCount"] = ledger.get("checkCount", 0) + 1
        alerts = ledger["alerts"]
        for key in list(alerts):
            if key not in issues and alerts[key]["scope"] in observed:
                del alerts[key]
        for key, issue in issues.items():
            if key not in alerts:
                alerts[key] = {**issue, "status": "new", "attempts": 0,
                               "nextAttemptAt": now, "firstSeenAt": now, "observations": 0}
            alerts[key]["observations"] = alerts[key].get("observations", 0) + 1
        actionable = {key: alert for key, alert in alerts.items()
                      if alert.get("observations", 1) >= alert.get("confirmations", 1)
                      and alert.get("readyAt", now) <= now}
        if not actionable:
            ledger["lastHealthyAt"] = now
        due = {key: alert for key, alert in actionable.items()
               if alert["status"] != "sent" and alert["nextAttemptAt"] <= now}
        if not due:
            atomic_json(ledger_path, ledger)
            return 0
        for alert in due.values():
            alert["status"] = "attempting"
            alert["attempts"] += 1
            alert["lastAttemptAt"] = now
            delay = min(args.retry_seconds * 2 ** min(alert["attempts"] - 1, 10), args.max_retry_seconds)
            alert["nextAttemptAt"] = now + delay
        ledger["queueAttemptCount"] = ledger.get("queueAttemptCount", 0) + 1
        atomic_json(ledger_path, ledger)
        messages = sorted({alert["message"] for alert in due.values()})
        text = ("Fleet watchdog action required: " + "; ".join(messages))[:6000]
        text += f". Read {args.config}; inspect {ledger_path}. Resolve these incidents; healthy polls need no response."
        success, error = False, ""
        try:
            result = run([args.codex, "queue", "--thread", args.thread, "--message", text], args.command_timeout)
            success = result.returncode == 0
            error = (result.stderr or result.stdout)[-1000:] if not success else ""
        except (OSError, subprocess.SubprocessError) as exc:
            error = str(exc)[-1000:]
        for alert in due.values():
            alert["status"] = "sent" if success else "failed"
            if success:
                alert["sentAt"] = now
                alert.pop("error", None)
            else:
                alert["error"] = error
        atomic_json(ledger_path, ledger)
        with (args.state_dir / "watchdog.log").open("a") as log:
            log.write(json.dumps({"at": now, "queued": success, "incidents": list(due), "error": error}) + "\n")
        return 0 if success else 1


def absolute(value):
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("path must be absolute")
    return path


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a positive finite number")
    return number


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--config", type=absolute, required=True)
    cli.add_argument("--state-dir", type=absolute, required=True)
    cli.add_argument("--thread", type=lambda value: str(uuid.UUID(value)), required=True)
    cli.add_argument("--heartbeat", type=absolute, required=True)
    cli.add_argument("--pending", type=absolute, help="monitor TSV; defaults to state-dir/fleet-monitor.pending")
    cli.add_argument("--coordinator", help="expected coordinator Herdr agent name")
    cli.add_argument("--pause-file", type=absolute, help="existing operator marker suspends reads and wakes without changing ledger")
    cli.add_argument("--board", type=absolute)
    cli.add_argument("--handoff-seconds", type=positive, default=120)
    cli.add_argument("--heartbeat-seconds", type=positive, default=45)
    cli.add_argument("--teardown-seconds", type=positive, default=30)
    cli.add_argument("--poll-grace", type=float, default=0)
    cli.add_argument("--command-timeout", type=positive, default=8)
    cli.add_argument("--retry-seconds", type=positive, default=60)
    cli.add_argument("--max-retry-seconds", type=positive, default=900)
    cli.add_argument("--codex", default="codex")
    cli.add_argument("--herdr", default="herdr")
    cli.add_argument("--dry-run", action="store_true")
    return cli


def main(argv=None):
    cli = parser()
    args = cli.parse_args(argv)
    if not math.isfinite(args.poll_grace) or args.poll_grace < 0:
        cli.error("--poll-grace must be finite and nonnegative")
    args.pending = args.pending or args.state_dir / "fleet-monitor.pending"
    try:
        return checkpoint(args)
    except (OSError, ValueError, TypeError) as exc:
        print("fleet-watchdog: state failure; queue disabled: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
