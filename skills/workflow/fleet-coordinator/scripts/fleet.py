#!/usr/bin/env python3
"""Fleet coordinator CLI — prompt assembly, capture, verdict, dispatch, land, gate."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SKILL_DIR = Path(__file__).resolve().parent.parent
TEMPLATES_PATH = SKILL_DIR / "references" / "prompt-templates.md"
IN_SCOPE_TAG = "(A)"
DEFERRED_TAG_DEFAULT = "(B)"
STYLE_TAG = "(D)"
SEVERITIES = ("P0", "P1", "P2", "P3")
BLOCKING_SEVERITIES = ("P0", "P1", "P2")
REQUIRED_CONFIG_KEYS = ("user", "deploymentContext")


@dataclass(frozen=True)
class Finding:
    sev: str
    tag: str
    loc: str
    title: str


@dataclass(frozen=True)
class CaptureResult:
    kind: str
    tip: str | None = None
    pre_fix_tip: str | None = None
    approve: bool | None = None
    findings: tuple[Finding, ...] = ()
    gate_table: str | None = None
    deferral_notes: str | None = None
    raw_tail: str = ""


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_config(path: Path) -> dict[str, Any]:
    with path.open() as fh:
        return json.load(fh)


def save_config(path: Path, config: dict[str, Any], dry_run: bool = False) -> None:
    payload = json.dumps(config, indent=2) + "\n"
    if dry_run:
        print(f"# dry-run: would write {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=".fleet-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def config_path_from_args(args: argparse.Namespace) -> Path:
    raw = args.config or os.environ.get("FLEET_CONFIG")
    if not raw:
        raise FleetError("config path required: --config or FLEET_CONFIG")
    return Path(raw).expanduser().resolve()


def find_stream(config: dict[str, Any], ticket: str) -> dict[str, Any]:
    for stream in config.get("streams", []):
        if stream.get("ticket") == ticket:
            return stream
    raise FleetError(f"unknown ticket: {ticket}")


def run_cmd(
    cmd: list[str],
    *,
    dry_run: bool = False,
    cwd: str | Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    display = " ".join(cmd)
    if cwd:
        display = f"(cd {cwd}) {display}"
    if dry_run:
        print(display)
        return subprocess.CompletedProcess(cmd, 0, "", "")
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, check=False)
    if check and result.returncode != 0:
        raise FleetError(
            f"command failed ({result.returncode}): {display}\n{result.stderr.strip()}"
        )
    return result


def git_output(seed: str | Path, *git_args: str) -> str:
    result = run_cmd(["git", "-C", str(seed), *git_args])
    return result.stdout.strip()


def git_tip(repo: str | Path, rev: str = "HEAD") -> str:
    return git_output(repo, "rev-parse", rev)


def git_oneline(repo: str | Path, rev: str = "HEAD") -> str:
    return git_output(repo, "log", "--oneline", "-1", rev)


def git_default_branch(seed: Path, config: dict[str, Any]) -> str:
    configured = config.get("seedDefaultBranch")
    if configured:
        return configured
    try:
        return git_output(seed, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").split("/")[-1]
    except FleetError as exc:
        raise FleetError(
            "seedDefaultBranch not configured and origin/HEAD unavailable"
        ) from exc


def git_is_clean(repo: Path) -> bool:
    return git_output(repo, "status", "--porcelain") == ""


def parse_templates(markdown: str) -> dict[str, str]:
    names = {
        "Implementer handover": "implementer",
        "Scoped review (first pass and re-review)": "review",
        "Bounce (fix-only)": "bounce",
    }
    templates: dict[str, str] = {}
    blocks = re.findall(r"## ([^\n]+)\n\n```text\n(.*?)```", markdown, re.DOTALL)
    for heading, body in blocks:
        key = names.get(heading.strip())
        if key:
            templates[key] = body.rstrip("\n") + "\n"
    missing = set(names.values()) - set(templates)
    if missing:
        raise FleetError(f"missing prompt templates: {', '.join(sorted(missing))}")
    return templates


def load_templates() -> dict[str, str]:
    return parse_templates(TEMPLATES_PATH.read_text())


def deferred_tag(config: dict[str, Any], stream: dict[str, Any]) -> str:
    return stream.get("deferredTag") or config.get("deferredTag") or DEFERRED_TAG_DEFAULT


def format_rulings(stream: dict[str, Any]) -> str:
    lines = [item.get("text", "") for item in stream.get("rulings", []) if item.get("text")]
    return "\n".join(lines) if lines else "(none)"


def format_scope_out(stream: dict[str, Any]) -> str:
    rows = []
    for item in stream.get("scopeOut", []):
        tag = item.get("tag", "")
        target = item.get("target", "")
        desc = item.get("description", "")
        rows.append(f"- {tag} → {target}: {desc}")
    return "\n".join(rows) if rows else "(none)"


def format_acceptance(stream: dict[str, Any]) -> str:
    items = stream.get("acceptanceCriteria", [])
    return "\n".join(f"- [ ] {item}" for item in items) if items else "(none)"


def format_do_not_hunt(stream: dict[str, Any]) -> str:
    items = stream.get("doNotHunt", [])
    return "\n".join(f"- {item}" for item in items) if items else "(none)"


def format_deferrals(stream: dict[str, Any]) -> str:
    rows = []
    for item in stream.get("deferrals", []):
        rows.append(
            f"- [{item.get('sev', 'P3')}] {item.get('tag', '')} "
            f"{item.get('loc', '')}: {item.get('title', '')}"
        )
    return "\n".join(rows) if rows else "(none)"


def gate_commands_for_files(config: dict[str, Any], files: list[str]) -> list[str]:
    suites = config.get("gate", {}).get("suites", [])
    ordered = sorted(suites, key=lambda s: len(s.get("prefix", "")), reverse=True)
    commands: list[str] = []
    seen: set[str] = set()
    for path in files:
        matched = False
        for suite in ordered:
            prefix = suite.get("prefix", "")
            if prefix and not path.startswith(prefix):
                continue
            if not prefix and path == "":
                continue
            if not prefix or path.startswith(prefix):
                matched = True
                for cmd in suite.get("commands", []):
                    if cmd not in seen:
                        seen.add(cmd)
                        commands.append(cmd)
                break
        if not matched:
            for suite in ordered:
                if suite.get("prefix", "") == "":
                    for cmd in suite.get("commands", []):
                        if cmd not in seen:
                            seen.add(cmd)
                            commands.append(cmd)
                    break
    if not commands:
        for suite in ordered:
            if suite.get("prefix", "") == "":
                for cmd in suite.get("commands", []):
                    if cmd not in seen:
                        seen.add(cmd)
                        commands.append(cmd)
    return commands


def diff_files(checkout: Path, base: str, tip: str) -> list[str]:
    out = git_output(checkout, "diff", "--name-only", f"{base}..{tip}")
    return [line for line in out.splitlines() if line.strip()]


def gate_command_block(config: dict[str, Any], files: list[str]) -> str:
    lines: list[str] = []
    for cmd in config.get("gate", {}).get("bootstrap", []):
        lines.append(cmd)
    if lines and gate_commands_for_files(config, files):
        lines.append("")
    lines.extend(gate_commands_for_files(config, files))
    return "\n".join(lines)


def skipped_suites_text(stream: dict[str, Any]) -> str:
    rows = stream.get("skippedSuites", [])
    if not rows:
        return "(none)"
    return "; ".join(f"{item.get('suite', '?')}: {item.get('claim', '')}" for item in rows)


def review_pass(stream: dict[str, Any]) -> int:
    match = re.match(r"review-(\d+)", stream.get("phase", ""))
    if match:
        return int(match.group(1))
    verdicts = stream.get("verdicts", [])
    if verdicts:
        return int(verdicts[-1].get("pass", len(verdicts)))
    return 1


def scope_out_targets(stream: dict[str, Any]) -> str:
    targets = [item.get("target", "") for item in stream.get("scopeOut", []) if item.get("target")]
    return ", ".join(targets) if targets else "deferred work"


def latest_verdict(stream: dict[str, Any]) -> dict[str, Any] | None:
    verdicts = stream.get("verdicts", [])
    return verdicts[-1] if verdicts else None


def findings_from_verdict(verdict: dict[str, Any]) -> list[Finding]:
    out: list[Finding] = []
    for item in verdict.get("findings", []):
        out.append(
            Finding(
                sev=item.get("sev", "P3"),
                tag=item.get("tag", ""),
                loc=item.get("loc", ""),
                title=item.get("title", ""),
            )
        )
    return out


def findings_verbatim(findings: list[Finding]) -> str:
    rows = []
    for f in findings:
        rows.append(f"[{f.sev}] {f.tag} {f.loc}: {f.title}")
    return "\n".join(rows) if rows else "(none)"


def seed_moved_note(config: dict[str, Any], stream: dict[str, Any]) -> str:
    seed = Path(config["seed"])
    current = git_tip(seed)
    base = stream.get("baseTip", "")
    if base and current != base:
        checkout = stream["checkout"]
        branch = stream["branch"]
        return (
            f"Seed moved since branch base ({base[:7]} → {current[:7]}). "
            f"Rebase before fixing:\n"
            f"  git -C {checkout} fetch {seed}\n"
            f"  git -C {checkout} rebase {current}"
        )
    return ""


def validate_required_config(config: dict[str, Any]) -> None:
    missing = [key for key in REQUIRED_CONFIG_KEYS if not config.get(key)]
    if missing:
        raise FleetError(f"missing required config: {', '.join(missing)}")


def build_placeholder_map(
    config: dict[str, Any],
    stream: dict[str, Any],
    role: str,
) -> dict[str, str]:
    validate_required_config(config)
    seed = Path(config["seed"])
    checkout = Path(stream["checkout"])
    branch = stream["branch"]
    seed_tip = git_tip(seed)
    branch_tip = stream.get("tip") or git_tip(checkout, branch)
    user = config["user"]
    dep = config["deploymentContext"]
    ticket = stream["ticket"]
    cap = str(config.get("bounceCap", 0))
    count = str(stream.get("bounceCount", 0))
    defer_tag = deferred_tag(config, stream)
    base_tip = stream.get("baseTip") or seed_tip
    files = diff_files(checkout, base_tip, branch_tip)
    gate_cmds = gate_command_block(config, files)
    review_n = review_pass(stream)
    verdict = latest_verdict(stream)
    pre_fix = stream.get("preFixTip") or (verdict.get("tip") if verdict else "") or seed_tip
    review_range = stream.get("reviewRange") or f"{seed_tip}..{branch_tip}"

    values: dict[str, str] = {
        "TICKET": ticket,
        "SEED_PATH": str(seed),
        "SEED_TIP": seed_tip,
        "CLONE_PATH": str(checkout),
        "BRANCH": branch,
        "USER": user,
        "DEPLOYMENT_CONTEXT": dep,
        "ACCEPTANCE_CRITERIA_AS_CHECKLIST": format_acceptance(stream),
        "SCOPE_OUT_TAGS_WITH_TARGET_TICKETS": format_scope_out(stream),
        "RULINGS": format_rulings(stream),
        "GATE_COMMANDS_FOR_DIFF_REACH": gate_cmds,
        "RANGE": review_range,
        "BRANCH_TIP": branch_tip,
        "PRE_FIX_TIP": pre_fix,
        "DEFERRED_TAG": defer_tag,
        "TARGET_TICKET": scope_out_targets(stream),
        "DO_NOT_HUNT_LIST": format_do_not_hunt(stream),
        "GATE_COMMANDS": gate_cmds,
        "SKIPPED_SUITES_WITH_CLAIMS": skipped_suites_text(stream),
        "N": str(review_n),
        "REVIEWED_TIP": verdict.get("tip", branch_tip) if verdict else branch_tip,
        "COUNT": count,
        "CAP": cap,
        "FINDINGS_VERBATIM_WITH_SEVERITY_TAG_AND_LOCATION": findings_verbatim(
            findings_from_verdict(verdict) if verdict else []
        ),
        "DEFERRALS_AND_RULINGS": "\n\n".join(
            part for part in [format_deferrals(stream), format_rulings(stream)] if part != "(none)"
        )
        or "(none)",
        "SEED_MOVED_NOTE_IF_ANY": seed_moved_note(config, stream),
    }
    if "title" in stream:
        values["TITLE"] = stream.get("title", "")
    if "problem" in stream:
        values["PROBLEM_FROM_CARD"] = stream.get("problem", "")
    if "inScopeSummary" in stream:
        values["IN_SCOPE_SUMMARY"] = stream.get("inScopeSummary", "")
    if role == "review":
        if stream.get("bounceCount", 0) > 0 or stream.get("phase", "").startswith("bounce"):
            values["RANGE"] = f"{pre_fix}..{branch_tip}"
    return values


def render_template(template: str, values: dict[str, str]) -> str:
    rendered = template
    for key, value in values.items():
        rendered = rendered.replace(f"{{{{{key}}}}}", value or "")
    return rendered


def unresolved_slots(text: str) -> list[str]:
    slots = re.findall(r"\{\{([A-Z0-9_]+)\}\}", text)
    if "<" in text:
        slots.append("<")
    return sorted(set(slots))


class FleetError(Exception):
    pass


def cmd_prompt(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = find_stream(config, args.ticket)
    templates = load_templates()
    role = args.role
    if role not in templates:
        raise FleetError(f"unknown role: {role}")
    values = build_placeholder_map(config, stream, role)
    rendered = render_template(templates[role], values)
    missing = unresolved_slots(rendered)
    if missing:
        raise FleetError(f"unfilled placeholders: {', '.join(missing)}")
    out = Path(args.out)
    if args.dry_run:
        print(f"# dry-run: would write {out}")
        print(rendered, end="")
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(rendered)
    return 0


FINDING_RE = re.compile(
    r"\[(P[0-3])\]\s*(\([A-Z]\)|\([A-Z]\))\s*([^\s:]+:\d+)\s*:?\s*(.+)",
    re.IGNORECASE,
)
FINDING_RE_ALT = re.compile(
    r"\[(P[0-3])\]\s*(\([A-Z]\))\s+(\S+:\d+)\s+(.+)",
    re.IGNORECASE,
)
APPROVE_RE = re.compile(r"^APPROVE:\s*(yes|no)\s*$", re.IGNORECASE | re.MULTILINE)
REVIEW_READY_RE = re.compile(r"REVIEW-READY", re.IGNORECASE)
REVIEW_READY_TIP_RE = re.compile(
    r"(?:^|[\n\r])(?:REVIEW-READY\s+)?(?:[-*]\s+)?"
    r"(?:(?:\*\*)?(?:new\s+)?tip(?:\s+SHA)?(?:\*\*)?(?:\s+is)?\s*:?\s*(?:\*\*)?\s*([0-9a-f]{7,40})\b"
    r"|The\s+new\s+tip\s+SHA\s+is\s+([0-9a-f]{7,40})\b)",
    re.IGNORECASE,
)
PRE_FIX_RE = re.compile(r"pre-fix tip[:\s]+([0-9a-f]{7,40})", re.IGNORECASE)
LABEL_TIP_LINE_RE = re.compile(
    r"(?:pre-fix|base|seed)\s+tip\s*:?\s*[0-9a-f]{7,40}",
    re.IGNORECASE,
)


def strip_label_tip_lines(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not LABEL_TIP_LINE_RE.search(line)
    )


def review_ready_tip_sha(match: re.Match[str]) -> str:
    return match.group(1) or match.group(2)


def parse_herdr_payload(text: str) -> dict[str, Any] | None:
    text = text.strip()
    if not text.startswith("{"):
        return None
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def herdr_error_code(result: subprocess.CompletedProcess[str]) -> str | None:
    for chunk in (result.stdout, result.stderr):
        payload = parse_herdr_payload(chunk or "")
        if not payload:
            continue
        error = payload.get("error")
        if isinstance(error, dict):
            code = error.get("code")
            if isinstance(code, str):
                return code
    return None


ECHOED_APPROVE_BLOCK_RE = re.compile(
    r"End with exactly one of:\s*\nAPPROVE:\s*yes\s*\nAPPROVE:\s*no\s*\n",
    re.IGNORECASE,
)


def strip_echoed_review_prompt(text: str) -> str:
    return ECHOED_APPROVE_BLOCK_RE.sub("", text)


def parse_approve_verdict(text: str) -> bool | None:
    cleaned = strip_echoed_review_prompt(text)
    matches = list(APPROVE_RE.finditer(cleaned))
    if not matches:
        return None
    return matches[-1].group(1).lower() == "yes"


def verify_tip_in_checkout(checkout: Path, tip: str) -> str:
    try:
        return git_output(checkout, "rev-parse", "--verify", tip)
    except FleetError as exc:
        raise FleetError(f"REVIEW-READY tip {tip[:7]} not in checkout") from exc


def parse_findings(text: str) -> list[Finding]:
    findings: list[Finding] = []
    for line in text.splitlines():
        match = FINDING_RE.search(line) or FINDING_RE_ALT.search(line)
        if not match:
            continue
        findings.append(
            Finding(
                sev=match.group(1).upper(),
                tag=match.group(2),
                loc=match.group(3),
                title=match.group(4).strip(),
            )
        )
    return findings


def parse_capture(text: str, role: str, checkout: Path | None = None) -> CaptureResult:
    if REVIEW_READY_RE.search(text):
        idx = text.upper().find("REVIEW-READY")
        tail = text[idx:] if idx >= 0 else text
        pre_fix_match = PRE_FIX_RE.search(text)
        pre_fix_tip = pre_fix_match.group(1) if pre_fix_match else None
        tip_match = REVIEW_READY_TIP_RE.search(strip_label_tip_lines(tail))
        if not tip_match:
            raise FleetError("REVIEW-READY missing tip SHA")
        tip = review_ready_tip_sha(tip_match)
        if pre_fix_tip and tip == pre_fix_tip:
            raise FleetError("REVIEW-READY missing tip SHA")
        if checkout is not None:
            tip = verify_tip_in_checkout(checkout, tip)
        return CaptureResult(
            kind="review-ready",
            tip=tip,
            pre_fix_tip=pre_fix_tip,
            raw_tail=text[-500:],
        )
    approve = parse_approve_verdict(text)
    if approve is None:
        raise FleetError("no REVIEW-READY or APPROVE line")
    findings = tuple(parse_findings(text))
    return CaptureResult(
        kind="verdict",
        approve=approve,
        findings=findings,
        raw_tail=text[-500:],
    )


def herdr_base(config: dict[str, Any]) -> list[str]:
    cmd = ["herdr"]
    if os.environ.get("HERDR_ENV") != "1":
        cmd.extend(["--session", config["session"]])
    return cmd


def herdr_agent_read(config: dict[str, Any], name: str, dry_run: bool = False) -> str:
    cmd = herdr_base(config) + [
        "agent",
        "read",
        name,
        "--source",
        "recent-unwrapped",
        "--lines",
        "200",
    ]
    if dry_run:
        run_cmd(cmd, dry_run=True)
        return ""
    result = run_cmd(cmd, check=False)
    if result.returncode == 0:
        return result.stdout
    if herdr_error_code(result) == "agent_not_found":
        raise FleetError("agent_not_found")
    detail = (result.stderr or result.stdout or "agent read failed").strip()
    raise FleetError(detail)


def herdr_pane_read(config: dict[str, Any], pane_id: str, dry_run: bool = False) -> str:
    cmd = herdr_base(config) + ["pane", "read", pane_id, "--lines", "400"]
    result = run_cmd(cmd, dry_run=dry_run, check=not dry_run)
    if dry_run:
        return ""
    if result.returncode != 0:
        raise FleetError(result.stderr.strip() or "pane read failed")
    return result.stdout


def herdr_tab_close(config: dict[str, Any], tab_id: str, dry_run: bool = False) -> None:
    cmd = herdr_base(config) + ["tab", "close", tab_id]
    run_cmd(cmd, dry_run=dry_run)


def agent_record(stream: dict[str, Any], name: str) -> dict[str, Any]:
    agents = stream.get("agents", {})
    for role, record in agents.items():
        if record.get("name") == name:
            return record
    raise FleetError(f"agent {name} not recorded on stream")


def record_capture(
    config: dict[str, Any],
    stream: dict[str, Any],
    name: str,
    captured: CaptureResult,
    config_path: Path,
    dry_run: bool = False,
) -> None:
    record = agent_record(stream, name)
    role = record.get("role", "")
    if captured.kind == "review-ready":
        stream["tip"] = captured.tip or stream.get("tip", "")
        if captured.pre_fix_tip:
            stream["preFixTip"] = captured.pre_fix_tip
        review_n = review_pass(stream)
        stream["phase"] = f"review-{review_n}"
        stream["reviewRange"] = f"{stream.get('baseTip', '')}..{stream['tip']}"
        stream.setdefault("events", []).append(
            {
                "at": utc_now_iso(),
                "agent": name,
                "kind": "review-ready",
                "tip": captured.tip,
            }
        )
    else:
        verdict = {
            "pass": len(stream.get("verdicts", [])) + 1,
            "tip": stream.get("tip", ""),
            "approve": captured.approve,
            "findings": [
                {"sev": f.sev, "tag": f.tag, "loc": f.loc, "title": f.title}
                for f in captured.findings
            ],
        }
        stream.setdefault("verdicts", []).append(verdict)
        stream["phase"] = "verdict-pending"
        stream.setdefault("events", []).append(
            {
                "at": utc_now_iso(),
                "agent": name,
                "kind": "verdict",
                "approve": captured.approve,
            }
        )
    save_config(config_path, config, dry_run=dry_run)


def cmd_capture(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = None
    record = None
    for candidate in config.get("streams", []):
        for item in candidate.get("agents", {}).values():
            if item.get("name") == args.agent_name:
                stream = candidate
                record = item
                break
        if stream:
            break
    if not stream or not record:
        raise FleetError(f"agent not on any stream: {args.agent_name}")

    text = ""
    try:
        text = herdr_agent_read(config, args.agent_name, dry_run=args.dry_run)
    except FleetError as exc:
        if str(exc) != "agent_not_found":
            raise
        pane_id = record.get("paneId")
        if not pane_id:
            raise FleetError("agent_not_found and no paneId recorded") from exc
        text = herdr_pane_read(config, pane_id, dry_run=args.dry_run)

    if args.dry_run:
        print(f"# dry-run: would parse capture for {args.agent_name}")
        if args.close:
            print(f"# dry-run: would close tab {record.get('tabId')}")
        return 0

    captured = parse_capture(text, record.get("role", ""), Path(stream["checkout"]))
    record_capture(config, stream, args.agent_name, captured, config_path)

    if args.close:
        tab_id = record.get("tabId")
        if not tab_id:
            raise FleetError("cannot close: no tabId recorded")
        herdr_tab_close(config, tab_id)
    return 0


def next_action(config: dict[str, Any], stream: dict[str, Any]) -> str:
    phase = stream.get("phase", "")
    if phase == "landed":
        return "none"
    if phase == "approved":
        return f"fleet land {stream['ticket']}"
    if phase == "hold":
        return "escalate: verdict hold"
    if phase == "verdict-pending":
        return f"fleet verdict {stream['ticket']}"
    if phase == "implementing" or phase.startswith("review-"):
        return "await settle"
    if phase.startswith("bounce-"):
        return f"fleet prompt {stream['ticket']} bounce --out <file>"
    return "escalate: unknown phase"


def drift_warnings(config: dict[str, Any], stream: dict[str, Any], agents: list[dict[str, Any]]) -> list[str]:
    warnings: list[str] = []
    seed = Path(config["seed"])
    try:
        live_tip = git_tip(seed)
        if stream.get("baseTip") and stream["baseTip"] != live_tip:
            warnings.append(
                f"{stream['ticket']}: baseTip {stream['baseTip'][:7]} != seed {live_tip[:7]}"
            )
    except FleetError as exc:
        warnings.append(f"{stream['ticket']}: seed tip unreadable: {exc}")

    live_names = {a.get("name") for a in agents}
    for role, record in stream.get("agents", {}).items():
        name = record.get("name")
        if name and name not in live_names and stream.get("phase") not in ("landed", "verdict-pending"):
            warnings.append(f"{stream['ticket']}: agent {name} ({role}) not in herdr list")
    return warnings


def herdr_agent_list(config: dict[str, Any], dry_run: bool = False) -> list[dict[str, Any]]:
    cmd = herdr_base(config) + ["agent", "list"]
    if dry_run:
        run_cmd(cmd, dry_run=True)
        return []
    result = run_cmd(cmd, check=False)
    if result.returncode != 0:
        raise FleetError((result.stderr or result.stdout or "agent list failed").strip())
    payload = parse_herdr_payload(result.stdout)
    if not payload:
        raise FleetError("agent list returned non-JSON output")
    result_body = payload.get("result")
    if isinstance(result_body, dict):
        agents = result_body.get("agents", [])
        return agents if isinstance(agents, list) else []
    if isinstance(result_body, list):
        return result_body
    return []


def cmd_state(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    agents = herdr_agent_list(config, dry_run=args.dry_run)
    cap = config.get("bounceCap", 0)
    for stream in config.get("streams", []):
        ticket = stream.get("ticket", "?")
        phase = stream.get("phase", "?")
        bounce = stream.get("bounceCount", 0)
        base = (stream.get("baseTip") or "")[:7]
        tip = (stream.get("tip") or "")[:7]
        action = next_action(config, stream)
        print(
            f"{ticket}\tphase={phase}\tbounce={bounce}/{cap}\tbase={base}\ttip={tip}\tnext={action}"
        )
        for warning in drift_warnings(config, stream, agents):
            print(f"  warning: {warning}", file=sys.stderr)
    return 0


def is_in_scope_finding(finding: Finding, defer_tag: str) -> bool:
    return finding.tag == IN_SCOPE_TAG


def is_deferred_finding(finding: Finding, defer_tag: str) -> bool:
    return finding.tag == defer_tag


def verdict_decision(
    verdict: dict[str, Any],
    bounce_count: int,
    cap: int,
    defer_tag: str,
) -> tuple[str, str]:
    if "approve" not in verdict or verdict.get("approve") is None:
        return "ESCALATE", "no APPROVE line"

    findings = findings_from_verdict(verdict)
    blocking = [f for f in findings if f.sev in BLOCKING_SEVERITIES]
    in_scope_blocking = [f for f in blocking if is_in_scope_finding(f, defer_tag)]
    deferred_blocking = [f for f in blocking if is_deferred_finding(f, defer_tag)]

    if verdict.get("approve") is True:
        if in_scope_blocking:
            return "ESCALATE", "APPROVE yes with in-scope P0-P2 findings"
        return "LAND", "APPROVE yes with no in-scope P0-P2 findings"

    if not in_scope_blocking:
        if blocking and len(deferred_blocking) == len(blocking):
            return "ESCALATE", "prompt violation: APPROVE no with only deferred-tag P0-P2"
        return "ESCALATE", "APPROVE no without in-scope P0-P2 findings"

    if bounce_count >= cap:
        return "ESCALATE", f"bounce cap reached ({bounce_count}/{cap})"

    return "BOUNCE", f"in-scope P0-P2 findings; bounce {bounce_count + 1} of {cap}"


def cmd_verdict(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = find_stream(config, args.ticket)
    verdict = latest_verdict(stream)
    if not verdict:
        raise FleetError("no verdict recorded")
    defer_tag = deferred_tag(config, stream)
    action, reason = verdict_decision(
        verdict,
        int(stream.get("bounceCount", 0)),
        int(config.get("bounceCap", 0)),
        defer_tag,
    )
    print(f"{action}: {reason}")

    if action == "BOUNCE" and int(stream.get("bounceCount", 0)) >= int(config.get("bounceCap", 0)):
        raise FleetError("refusing bounce beyond cap")

    if args.commit:
        if action == "BOUNCE":
            stream["bounceCount"] = int(stream.get("bounceCount", 0)) + 1
            stream["phase"] = f"bounce-{stream['bounceCount']}"
        elif action == "LAND":
            stream["approvedTip"] = stream.get("tip")
            stream["phase"] = "approved"
        elif action == "ESCALATE":
            stream["phase"] = "hold"
        save_config(config_path, config, dry_run=args.dry_run)
    return 0


def derive_agent_name(ticket: str, role: str) -> str:
    slug = ticket.lower().replace(".", "-")
    suffix = "-impl" if role == "impl" else "-review"
    slug = re.sub(r"[^a-z0-9_-]", "-", slug)
    slug = re.sub(r"-+", "-", slug).strip("-")
    if not slug or not slug[0].isalpha():
        slug = f"t{slug}"
    max_slug = 32 - len(suffix)
    if len(slug) > max_slug:
        slug = slug[:max_slug].rstrip("-")
    name = f"{slug}{suffix}"
    return name


def recipe_for_stream(config: dict[str, Any], stream: dict[str, Any], role: str) -> dict[str, Any]:
    key = stream.get("implRecipe") if role == "impl" else stream.get("reviewRecipe")
    if not key:
        raise FleetError(f"no recipe for role {role}")
    recipes = config.get("recipes", {})
    if key not in recipes:
        raise FleetError(f"unknown recipe: {key}")
    return recipes[key]


def herdr_tab_create(
    config: dict[str, Any],
    cwd: str,
    label: str,
    dry_run: bool = False,
) -> dict[str, str]:
    cmd = herdr_base(config) + [
        "tab",
        "create",
        "--cwd",
        cwd,
        "--label",
        label,
        "--no-focus",
    ]
    if dry_run:
        run_cmd(cmd, dry_run=True)
        return {"tab_id": "tab-dry", "pane_id": "pane-dry"}
    result = run_cmd(cmd, check=False)
    if result.returncode != 0:
        raise FleetError((result.stderr or result.stdout or "tab create failed").strip())
    payload = parse_herdr_payload(result.stdout)
    if not payload:
        raise FleetError("tab create returned non-JSON output")
    root = payload.get("result", {}).get("root_pane", {})
    tab = payload.get("result", {}).get("tab", {})
    tab_id = tab.get("tab_id") or root.get("tab_id")
    pane_id = root.get("pane_id")
    if not tab_id or not pane_id:
        raise FleetError("tab create missing tab_id or pane_id")
    return {"tab_id": tab_id, "pane_id": pane_id}


def herdr_agent_start(
    config: dict[str, Any],
    name: str,
    pane_id: str,
    recipe: dict[str, Any],
    dry_run: bool = False,
) -> None:
    cmd = (
        herdr_base(config)
        + [
            "agent",
            "start",
            name,
            "--kind",
            recipe["kind"],
            "--pane",
            pane_id,
            "--timeout",
            "120000",
            "--",
        ]
        + list(recipe.get("args", []))
    )
    run_cmd(cmd, dry_run=dry_run)


def herdr_agent_prompt(
    config: dict[str, Any],
    name: str,
    prompt_file: Path,
    dry_run: bool = False,
) -> None:
    text = prompt_file.read_text()
    cmd = (
        herdr_base(config)
        + [
            "agent",
            "prompt",
            name,
            text,
            "--wait",
            "--until",
            "working",
            "--timeout",
            "20000",
        ]
    )
    if dry_run:
        run_cmd(cmd, dry_run=True)
        return
    result = run_cmd(cmd, check=False)
    if result.returncode != 0 and "agent_prompt_stalled" in (result.stderr or ""):
        visible_cmd = herdr_base(config) + ["agent", "read", name, "--source", "visible"]
        visible = run_cmd(visible_cmd, check=False)
        if "Workspace Trust" in (visible.stdout or ""):
            keys_cmd = herdr_base(config) + ["agent", "send-keys", name, "a"]
            run_cmd(keys_cmd)
        run_cmd(cmd)


def cmd_dispatch(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = find_stream(config, args.ticket)
    role = args.role
    name = derive_agent_name(args.ticket, role)
    recipe = recipe_for_stream(config, stream, role)
    label = f"{args.ticket} {role}"
    prompt_file = Path(args.prompt_file)
    if not prompt_file.is_file():
        raise FleetError(f"prompt file not found: {prompt_file}")

    ids = herdr_tab_create(config, stream["checkout"], label, dry_run=args.dry_run)
    herdr_agent_start(config, name, ids["pane_id"], recipe, dry_run=args.dry_run)
    herdr_agent_prompt(config, name, prompt_file, dry_run=args.dry_run)

    stream.setdefault("agents", {})[role] = {
        "name": name,
        "role": role,
        "tabId": ids["tab_id"],
        "paneId": ids["pane_id"],
        "promptFile": str(prompt_file),
        "dispatchedAt": utc_now_iso(),
    }
    if role == "impl":
        stream["phase"] = "implementing"
    else:
        stream["phase"] = f"review-{review_pass(stream)}"
    save_config(config_path, config, dry_run=args.dry_run)
    print(name)
    return 0


def cmd_land(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = find_stream(config, args.ticket)
    seed = Path(config["seed"])
    checkout = Path(stream["checkout"])
    branch = stream["branch"]
    default_branch = git_default_branch(seed, config)

    if not git_is_clean(seed):
        raise FleetError("seed working copy is dirty")
    current_branch = git_output(seed, "branch", "--show-current")
    if current_branch != default_branch:
        raise FleetError(f"seed not on default branch {default_branch} (on {current_branch})")

    approved = stream.get("approvedTip")
    if not approved:
        raise FleetError("no approved tip recorded")

    live_base = git_tip(seed)
    recorded_base = stream.get("baseTip")
    if recorded_base and recorded_base != live_base:
        print(
            f"Seed moved ({recorded_base[:7]} → {live_base[:7]}). Rebase the clone, then retry:\n"
            f"  git -C {checkout} fetch {seed}\n"
            f"  git -C {checkout} rebase {live_base}",
            file=sys.stderr,
        )
        return 1

    fetch_cmd = ["git", "-C", str(seed), "fetch", str(checkout), branch]
    merge_cmd = ["git", "-C", str(seed), "merge", "--ff-only", "FETCH_HEAD"]
    run_cmd(fetch_cmd, dry_run=args.dry_run)
    if args.dry_run:
        run_cmd(merge_cmd, dry_run=True)
        for check_cmd in config.get("postLandChecks", []):
            run_cmd(shlex.split(check_cmd), dry_run=True, cwd=seed)
        return 0

    fetch_head = git_output(seed, "rev-parse", "FETCH_HEAD")
    if fetch_head != approved:
        raise FleetError(
            f"FETCH_HEAD {fetch_head[:7]} != approved tip {approved[:7]}; "
            "clone moved after approval"
        )
    run_cmd(merge_cmd)
    land_tip = git_tip(seed)
    stream["phase"] = "landed"
    stream["landedAt"] = utc_now_iso()
    stream["landRange"] = f"{recorded_base}..{land_tip}"
    save_config(config_path, config)

    for check_cmd in config.get("postLandChecks", []):
        try:
            run_cmd(shlex.split(check_cmd), cwd=seed)
        except FleetError as exc:
            raise FleetError(f"landed but post-land check failed: {exc}") from exc
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = find_stream(config, args.ticket)
    checkout = Path(stream["checkout"])
    base = stream.get("baseTip") or git_tip(Path(config["seed"]))
    tip = stream.get("tip") or git_tip(checkout, stream["branch"])
    files = diff_files(checkout, base, tip)
    print(gate_command_block(config, files))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fleet")
    parser.add_argument("--config", help="Path to fleet.json (or set FLEET_CONFIG)")
    parser.add_argument("--dry-run", action="store_true", help="Print commands, change nothing")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--dry-run",
        action="store_true",
        default=argparse.SUPPRESS,
        help="Print commands, change nothing",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_prompt = sub.add_parser("prompt", help="Render a dispatch prompt", parents=[common])
    p_prompt.add_argument("ticket")
    p_prompt.add_argument("role", choices=["implementer", "review", "bounce"])
    p_prompt.add_argument("--out", required=True)
    p_prompt.set_defaults(func=cmd_prompt)

    p_capture = sub.add_parser("capture", help="Capture agent output into stream state", parents=[common])
    p_capture.add_argument("agent_name")
    p_capture.add_argument("--close", action="store_true")
    p_capture.set_defaults(func=cmd_capture)

    p_state = sub.add_parser("state", help="Show stream state and next actions", parents=[common])
    p_state.set_defaults(func=cmd_state)

    p_verdict = sub.add_parser("verdict", help="Apply verdict table to newest verdict", parents=[common])
    p_verdict.add_argument("ticket")
    p_verdict.add_argument("--commit", action="store_true")
    p_verdict.set_defaults(func=cmd_verdict)

    p_dispatch = sub.add_parser("dispatch", help="Open tab, start agent, send prompt", parents=[common])
    p_dispatch.add_argument("ticket")
    p_dispatch.add_argument("role", choices=["impl", "review"])
    p_dispatch.add_argument("--prompt-file", required=True)
    p_dispatch.set_defaults(func=cmd_dispatch)

    p_land = sub.add_parser("land", help="Fast-forward seed from approved clone", parents=[common])
    p_land.add_argument("ticket")
    p_land.set_defaults(func=cmd_land)

    p_gate = sub.add_parser("gate", help="Emit gate commands for stream diff", parents=[common])
    p_gate.add_argument("ticket")
    p_gate.set_defaults(func=cmd_gate)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "dry_run", False) and argv and "--dry-run" in argv:
        args.dry_run = True
    elif not hasattr(args, "dry_run"):
        args.dry_run = False
    try:
        return args.func(args)
    except FleetError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
