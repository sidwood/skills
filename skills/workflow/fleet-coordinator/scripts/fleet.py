#!/usr/bin/env python3
"""Fleet coordinator CLI — prompt assembly, capture, verdict, dispatch, land, gate."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
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


def save_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=".capture-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def persist_capture_text(
    config_path: Path, agent_name: str, event_id: str | None, text: str
) -> Path:
    configured = os.environ.get("FLEET_CAPTURES_DIR")
    captures_dir = (
        Path(configured).expanduser().resolve()
        if configured
        else config_path.parent / "captures"
    )
    identity = event_id or f"manual-{time.time_ns()}"
    safe_identity = re.sub(r"[^a-zA-Z0-9_.@-]", "-", identity)
    safe_agent = re.sub(r"[^a-zA-Z0-9_.-]", "-", agent_name)
    path = captures_dir / f"{safe_agent}-{safe_identity}-{time.time_ns()}.txt"
    save_text_atomic(path, text)
    return path


def config_path_from_args(args: argparse.Namespace) -> Path:
    raw = args.config or os.environ.get("FLEET_CONFIG")
    if raw:
        return Path(raw).expanduser().resolve()

    state_dir = os.environ.get("FLEET_STATE_DIR")
    if state_dir:
        return (Path(state_dir).expanduser() / "fleet.json").resolve()

    seed = os.environ.get("FLEET_SEED")
    if seed:
        return (Path(seed).expanduser() / "temp" / "fleet" / "fleet.json").resolve()

    raise FleetError(
        "config path required: --config, FLEET_CONFIG, or FLEET_SEED for "
        "<seed>/temp/fleet/fleet.json"
    )


@contextmanager
def config_lock(path: Path):
    lock_path = path.with_name(f"{path.name}.lock")
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_file = lock_path.open("a+")
    except OSError as exc:
        raise FleetError(f"cannot open fleet lock at {lock_path}: {exc}") from exc
    with lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        except OSError as exc:
            raise FleetError(f"cannot lock fleet config at {lock_path}: {exc}") from exc
        yield


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
    for candidate in (stream.get("phase", ""), stream.get("resumePhase", "")):
        match = re.fullmatch(r"review-(\d+)", candidate)
        if match:
            return int(match.group(1))
    verdicts = stream.get("verdicts", [])
    if verdicts:
        return int(verdicts[-1].get("pass", len(verdicts)))
    return 1


def next_review_pass(stream: dict[str, Any]) -> int:
    verdicts = stream.get("verdicts", [])
    if not verdicts:
        return 1
    latest = int(verdicts[-1].get("pass", len(verdicts)))
    return max(latest, len(verdicts)) + 1


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
    pre_fix = stream.get("preFixTip") or (verdict.get("tip") if verdict else "") or base_tip
    review_range = f"{base_tip}..{branch_tip}"
    if role == "review" and review_n > 1:
        configured_pre_fix = stream.get("preFixTip")
        if not configured_pre_fix:
            raise FleetError(f"review-{review_n} missing preFixTip")
        pre_fix = verify_pre_fix_tip(checkout, configured_pre_fix, branch_tip)
        review_range = f"{pre_fix}..{branch_tip}"

    values: dict[str, str] = {
        "TICKET": ticket,
        "SEED_PATH": str(seed),
        "SEED_TIP": base_tip if role == "review" else seed_tip,
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
APPROVE_RE = re.compile(
    r"^[ \t]*(?:[-*•][ \t]*)?APPROVE:\s*(yes|no)\s*$",
    re.IGNORECASE | re.MULTILINE,
)
REVIEW_READY_RE = re.compile(r"REVIEW-READY", re.IGNORECASE)
REVIEW_READY_TIP_RE = re.compile(
    r"(?:^|[\n\r])[ \t]*(?:(?:•[ \t]*)?REVIEW-READY\s+)?"
    r"[ \t]*(?:[-*]\s+)?"
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
    r"End with exactly one of:\s*\n"
    r"[ \t]*(?:[-*•][ \t]*)?APPROVE:\s*yes\s*\n"
    r"[ \t]*(?:[-*•][ \t]*)?APPROVE:\s*no\s*\n",
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
        return git_output(checkout, "rev-parse", "--verify", f"{tip}^{{commit}}")
    except FleetError as exc:
        raise FleetError(f"REVIEW-READY tip {tip[:7]} not in checkout") from exc


def verify_pre_fix_tip(checkout: Path, pre_fix_tip: str, tip: str) -> str:
    resolved = verify_tip_in_checkout(checkout, pre_fix_tip)
    resolved_tip = verify_tip_in_checkout(checkout, tip)
    if resolved == resolved_tip:
        raise FleetError(f"pre-fix tip {resolved[:7]} produces an empty review range")
    result = run_cmd(
        [
            "git",
            "-C",
            str(checkout),
            "merge-base",
            "--is-ancestor",
            resolved,
            resolved_tip,
        ],
        check=False,
    )
    if result.returncode != 0:
        raise FleetError(
            f"pre-fix tip {resolved[:7]} is not an ancestor of {resolved_tip[:7]}"
        )
    return resolved


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
    if role not in {"impl", "review"}:
        raise FleetError(f"unknown capture role: {role or '(missing)'}")

    if role == "impl":
        if not REVIEW_READY_RE.search(text):
            raise FleetError("implementer capture missing REVIEW-READY")
        idx = text.upper().rfind("REVIEW-READY")
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
        raise FleetError("reviewer capture missing APPROVE line")
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
    result = run_cmd(cmd, dry_run=dry_run, check=False)
    if dry_run or result.returncode == 0:
        return
    # A retry after close-succeeded/config-save-crashed is complete, not an
    # error. Herdr exposes that state as tab_not_found.
    if herdr_error_code(result) == "tab_not_found":
        return
    detail = (result.stderr or result.stdout or "tab close failed").strip()
    raise FleetError(detail)


def agent_record(stream: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [
        (slot, record)
        for slot, record in stream.get("agents", {}).items()
        if record.get("name") == name
    ]
    if not matches:
        raise FleetError(f"agent {name} not recorded on stream")
    if len(matches) != 1:
        raise FleetError(f"agent {name} is recorded in multiple role slots")
    slot, record = matches[0]
    if not record.get("role"):
        record["role"] = slot
    if record.get("role") != slot:
        raise FleetError(
            f"agent {name} role {record.get('role')!r} does not match slot {slot!r}"
        )
    return record


def find_agent_record(
    config: dict[str, Any], name: str
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    matches: list[tuple[dict[str, Any], str, dict[str, Any]]] = []
    for stream in config.get("streams", []):
        for slot, record in stream.get("agents", {}).items():
            if record.get("name") == name:
                matches.append((stream, slot, record))
    if not matches:
        return None
    if len(matches) != 1:
        raise FleetError(f"agent {name} is recorded on multiple streams or role slots")
    stream, slot, record = matches[0]
    if not record.get("role"):
        record["role"] = slot
    if record.get("role") != slot:
        raise FleetError(
            f"agent {name} role {record.get('role')!r} does not match slot {slot!r}"
        )
    return stream, record


def captured_event_binding(
    config: dict[str, Any], event_id: str
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    matches: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for stream in config.get("streams", []):
        for event in stream.get("events", []):
            if event.get("eventId") == event_id:
                matches.append((stream, event))
    if len(matches) > 1:
        raise FleetError(
            f"event ID {event_id!r} is recorded more than once; "
            "reconcile the duplicate before continuing"
        )
    return matches[0] if matches else None


def captured_event(config: dict[str, Any], event_id: str) -> dict[str, Any] | None:
    binding = captured_event_binding(config, event_id)
    return binding[1] if binding else None


CAPTURE_EVENT_KINDS = frozenset({"review-ready", "verdict"})
RESOLUTION_EVENT_KINDS = frozenset(
    {"resolved-lost-output", "resolved-invalid-output"}
)


def captured_event_for_record(
    stream: dict[str, Any], record: dict[str, Any], agent_name: str
) -> dict[str, Any] | None:
    if record.get("dispatchState") not in {"captured", "closed"}:
        return None
    capture_event_id = record.get("captureEventId")
    matches = [
        event
        for event in stream.get("events", [])
        if event.get("agent") == agent_name
        and event.get("kind") in CAPTURE_EVENT_KINDS
    ]
    if capture_event_id:
        matches = [event for event in matches if event.get("eventId") == capture_event_id]
    else:
        captured_at = record.get("capturedAt")
        if captured_at:
            matches = [event for event in matches if event.get("at") == captured_at]
    if len(matches) > 1:
        raise FleetError(
            f"agent {agent_name} has ambiguous legacy capture history; "
            "reconcile it before attaching an event ID"
        )
    return matches[0] if matches else None


def record_matches_capture_event(
    record: dict[str, Any], event_id: str, event: dict[str, Any]
) -> bool:
    """Return whether a current role record is the event's captured dispatch."""
    capture_event_id = record.get("captureEventId")
    if capture_event_id:
        return capture_event_id == event_id
    return bool(
        record.get("dispatchState") in {"captured", "closed"}
        and record.get("capturedAt")
        and record.get("capturedAt") == event.get("at")
    )


def validate_capture_context(
    stream: dict[str, Any], role: str, capture_kind: str
) -> int | None:
    phase = str(stream.get("phase", ""))
    if role == "impl":
        if capture_kind != "review-ready":
            raise FleetError("implementer capture must contain REVIEW-READY")
        if phase != "implementing":
            raise FleetError(
                f"implementer capture requires phase implementing, found {phase or '(missing)'}"
            )
        return None

    if role == "review":
        if capture_kind != "verdict":
            raise FleetError("reviewer capture must contain an APPROVE verdict")
        match = re.fullmatch(r"review-(\d+)", phase)
        if not match:
            raise FleetError(
                f"reviewer capture requires phase review-N, found {phase or '(missing)'}"
            )
        active_pass = int(match.group(1))
        expected_pass = next_review_pass(stream)
        if active_pass != expected_pass:
            raise FleetError(
                f"active review pass {active_pass} does not match next pass {expected_pass}"
            )
        return active_pass

    raise FleetError(f"unknown capture role: {role or '(missing)'}")


def record_capture(
    config: dict[str, Any],
    stream: dict[str, Any],
    name: str,
    captured: CaptureResult,
    config_path: Path,
    event_id: str | None = None,
    capture_path: Path | None = None,
    dry_run: bool = False,
) -> None:
    record = agent_record(stream, name)
    role = record.get("role", "")
    active_review_pass = validate_capture_context(stream, role, captured.kind)
    if captured.kind == "review-ready":
        new_tip = captured.tip or stream.get("tip", "")
        prior_verdicts = stream.get("verdicts", [])
        if prior_verdicts:
            if not captured.pre_fix_tip:
                raise FleetError("bounced REVIEW-READY missing pre-fix tip")
            pre_fix_tip = verify_pre_fix_tip(
                Path(stream["checkout"]), captured.pre_fix_tip, new_tip
            )
            stream["preFixTip"] = pre_fix_tip
            stream["reviewRange"] = f"{pre_fix_tip}..{new_tip}"
        else:
            stream["reviewRange"] = f"{stream.get('baseTip', '')}..{new_tip}"
        review_n = next_review_pass(stream)
        stream["tip"] = new_tip
        stream["phase"] = f"review-{review_n}"
        event = {
            "at": utc_now_iso(),
            "agent": name,
            "kind": "review-ready",
            "tip": captured.tip,
        }
    else:
        verdict = {
            "pass": active_review_pass,
            "tip": stream.get("tip", ""),
            "approve": captured.approve,
            "findings": [
                {"sev": f.sev, "tag": f.tag, "loc": f.loc, "title": f.title}
                for f in captured.findings
            ],
        }
        stream.setdefault("verdicts", []).append(verdict)
        stream["phase"] = "verdict-pending"
        event = {
            "at": utc_now_iso(),
            "agent": name,
            "kind": "verdict",
            "pass": active_review_pass,
            "approve": captured.approve,
        }
    if event_id is not None:
        event["eventId"] = event_id
    if capture_path is not None:
        event["capturePath"] = str(capture_path)
    record["dispatchState"] = "captured"
    record["capturedAt"] = event["at"]
    record["captureKind"] = captured.kind
    record.pop("lastCaptureFailure", None)
    if event_id is not None:
        record["captureEventId"] = event_id
    stream.setdefault("events", []).append(event)
    save_config(config_path, config, dry_run=dry_run)


def capture_kind_for_role(role: str) -> str:
    if role == "impl":
        return "review-ready"
    if role == "review":
        return "verdict"
    raise FleetError(f"unknown capture role: {role or '(missing)'}")


def close_captured_agent(
    config: dict[str, Any],
    record: dict[str, Any],
    capture_event: dict[str, Any] | None = None,
    dry_run: bool = False,
) -> bool:
    if record.get("dispatchState") == "closed":
        if (
            capture_event is not None
            and record.get("closedAt")
            and not capture_event.get("closedAt")
        ):
            capture_event["closedAt"] = record["closedAt"]
            return True
        return False
    tab_id = record.get("tabId")
    if not tab_id:
        raise FleetError("cannot close: no tabId recorded")
    herdr_tab_close(config, tab_id, dry_run=dry_run)
    closed_at = utc_now_iso()
    record["dispatchState"] = "closed"
    record["closedAt"] = closed_at
    if capture_event is not None:
        capture_event["closedAt"] = closed_at
    return True


def cmd_capture(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    event_id = getattr(args, "event_id", None)
    capture_file_arg = getattr(args, "capture_file", None)
    if capture_file_arg and event_id is None:
        raise FleetError("--capture-file requires --event-id")
    found = find_agent_record(config, args.agent_name)

    if event_id is not None:
        existing_binding = captured_event_binding(config, event_id)
        if existing_binding is not None:
            existing_stream, existing = existing_binding
            if existing.get("agent") != args.agent_name:
                raise FleetError(
                    f"event ID {event_id!r} already belongs to "
                    f"{existing.get('agent', 'an unknown agent')}"
                )
            if existing.get("kind") not in CAPTURE_EVENT_KINDS:
                raise FleetError(f"event ID {event_id!r} is not a capture event")
            if args.close and not existing.get("closedAt"):
                if found is None:
                    raise FleetError(
                        f"cannot close event {event_id!r}: its dispatch record is missing"
                    )
                found_stream, existing_record = found
                if found_stream is not existing_stream or not record_matches_capture_event(
                    existing_record, event_id, existing
                ):
                    raise FleetError(
                        f"cannot close event {event_id!r}: the current agent record "
                        "belongs to a different dispatch"
                    )
                if close_captured_agent(
                    config, existing_record, existing, args.dry_run
                ):
                    save_config(config_path, config, dry_run=args.dry_run)
            return 0

    prior_capture = None
    if found is not None:
        prior_stream, prior_record = found
        prior_capture = captured_event_for_record(
            prior_stream, prior_record, args.agent_name
        )
    if prior_capture is not None:
        prior_event_id = prior_capture.get("eventId")
        if event_id is not None and prior_event_id not in {None, event_id}:
            raise FleetError(
                f"agent {args.agent_name} was already captured as event "
                f"{prior_event_id!r}; refusing event {event_id!r}"
            )
        changed = False
        if event_id is not None and prior_event_id is None:
            prior_capture["eventId"] = event_id
            changed = True
            if found is not None:
                _stream, prior_record = found
                prior_record["captureEventId"] = event_id
        if args.close and found is not None:
            _stream, prior_record = found
            changed = (
                close_captured_agent(
                    config, prior_record, prior_capture, args.dry_run
                )
                or changed
            )
        if changed:
            save_config(config_path, config, dry_run=args.dry_run)
        return 0

    if found is None:
        raise FleetError(f"agent not on any stream: {args.agent_name}")
    stream, record = found
    role = record.get("role", "")
    validate_capture_context(stream, role, capture_kind_for_role(role))

    text = ""
    capture_path: Path | None = None
    if capture_file_arg:
        capture_path = Path(capture_file_arg).expanduser().resolve()
        if not capture_path.is_file():
            raise FleetError(f"capture file not found: {capture_path}")
        text = capture_path.read_text()
    else:
        try:
            text = herdr_agent_read(config, args.agent_name, dry_run=args.dry_run)
        except FleetError as agent_exc:
            pane_id = record.get("paneId")
            if not pane_id:
                raise FleetError(
                    f"agent read failed and no paneId is recorded: {agent_exc}"
                ) from agent_exc
            try:
                text = herdr_pane_read(config, pane_id, dry_run=args.dry_run)
            except FleetError as pane_exc:
                raise FleetError(
                    f"agent read failed ({agent_exc}); pane read failed ({pane_exc})"
                ) from pane_exc

    if args.dry_run:
        print(f"# dry-run: would parse capture for {args.agent_name}")
        if args.close:
            print(f"# dry-run: would close tab {record.get('tabId')}")
        return 0

    if capture_path is None:
        capture_path = persist_capture_text(
            config_path, args.agent_name, event_id, text
        )
    try:
        captured = parse_capture(text, role, Path(stream["checkout"]))
        record_capture(
            config,
            stream,
            args.agent_name,
            captured,
            config_path,
            event_id=event_id,
            capture_path=capture_path,
        )
    except FleetError as exc:
        failed_at = utc_now_iso()
        record["lastCaptureFailure"] = {
            "at": failed_at,
            "eventId": event_id,
            "capturePath": str(capture_path),
            "error": str(exc),
        }
        save_config(config_path, config)
        raise FleetError(f"{exc}; transcript saved at {capture_path}") from exc

    if args.close:
        current_event = (
            captured_event_binding(config, event_id)[1]
            if event_id is not None
            else captured_event_for_record(stream, record, args.agent_name)
        )
        if close_captured_agent(config, record, current_event):
            save_config(config_path, config)
    return 0


def cmd_resolve_event(args: argparse.Namespace) -> int:
    """Durably acknowledge an event whose output cannot be recovered."""
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    event_id = args.event_id
    reason = args.reason.strip()
    if not reason:
        raise FleetError("resolve-event requires a non-empty reason")

    existing_binding = captured_event_binding(config, event_id)
    if existing_binding is not None:
        existing_stream, existing = existing_binding
        if existing.get("agent") != args.agent_name:
            raise FleetError(
                f"event ID {event_id!r} already belongs to "
                f"{existing.get('agent', 'an unknown agent')}"
            )
        if existing.get("kind") in RESOLUTION_EVENT_KINDS:
            return 0
        if existing.get("kind") not in CAPTURE_EVENT_KINDS:
            raise FleetError(f"event ID {event_id!r} cannot be resolved")
        if existing.get("closedAt") or existing.get("teardownResolvedAt"):
            return 0

        resolved_at = utc_now_iso()
        existing["teardownResolvedAt"] = resolved_at
        existing["teardownResolutionReason"] = reason
        found = find_agent_record(config, args.agent_name)
        if found is not None:
            found_stream, record = found
            if found_stream is existing_stream and record_matches_capture_event(
                record, event_id, existing
            ):
                record["dispatchState"] = "resolved"
                record["resolvedAt"] = resolved_at
                record["resolutionReason"] = reason
        save_config(config_path, config, dry_run=args.dry_run)
        return 0

    found = find_agent_record(config, args.agent_name)
    if found is None:
        raise FleetError(f"agent not on any stream: {args.agent_name}")
    stream, record = found
    capture_failure = record.get("lastCaptureFailure")
    if isinstance(capture_failure, dict) and capture_failure.get("capturePath"):
        if not args.capture_file:
            raise FleetError(
                "cannot resolve lost output: a saved capture exists at "
                f"{capture_failure['capturePath']}; correct or reparse that evidence, "
                "or explicitly resolve it with --capture-file"
            )
        saved_path = Path(str(capture_failure["capturePath"])).expanduser().resolve()
        supplied_path = Path(args.capture_file).expanduser().resolve()
        if supplied_path != saved_path:
            raise FleetError(
                "--capture-file must name the exact saved malformed capture at "
                f"{saved_path}"
            )
        if capture_failure.get("eventId") != event_id:
            raise FleetError(
                "--event-id must match the saved malformed capture event ID "
                f"{capture_failure.get('eventId')!r}"
            )
        try:
            supplied_path.read_text()
        except OSError as exc:
            raise FleetError(
                f"cannot read saved malformed capture at {supplied_path}: {exc}"
            ) from exc
        resolved_at = utc_now_iso()
        stream.setdefault("events", []).append(
            {
                "at": resolved_at,
                "agent": args.agent_name,
                "eventId": event_id,
                "kind": "resolved-invalid-output",
                "reason": reason,
                "capturePath": str(supplied_path),
                "captureError": capture_failure.get("error", ""),
            }
        )
        record["dispatchState"] = "resolved"
        record["captureEventId"] = event_id
        record["resolvedAt"] = resolved_at
        record["resolutionReason"] = reason
        if stream.get("phase") != "hold":
            stream["resumePhase"] = stream.get("phase", "")
        stream["phase"] = "hold"
        stream["holdReason"] = f"invalid output for {event_id}: {reason}"
        save_config(config_path, config, dry_run=args.dry_run)
        return 0
    resolved_at = utc_now_iso()
    stream.setdefault("events", []).append(
        {
            "at": resolved_at,
            "agent": args.agent_name,
            "eventId": event_id,
            "kind": "resolved-lost-output",
            "reason": reason,
        }
    )
    record["dispatchState"] = "resolved"
    record["captureEventId"] = event_id
    record["resolvedAt"] = resolved_at
    record["resolutionReason"] = reason
    if stream.get("phase") != "hold":
        stream["resumePhase"] = stream.get("phase", "")
    stream["phase"] = "hold"
    stream["holdReason"] = f"lost output for {event_id}: {reason}"
    save_config(config_path, config, dry_run=args.dry_run)
    return 0


def next_action(config: dict[str, Any], stream: dict[str, Any]) -> str:
    phase = stream.get("phase", "")
    if phase == "landed":
        return "none"
    if phase == "approved":
        return f"fleet land {stream['ticket']}"
    if phase == "hold":
        return "escalate: ticket hold"
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
    startup_hints = {
        "reserved": "tab creation was not recorded; reconcile before retrying",
        "tab-created": "agent start was not recorded; inspect the tab before retrying",
        "started": "prompting was not recorded; inspect the agent before retrying",
        "prompting": "prompt completion is unknown; inspect or capture the agent before retrying",
    }
    for role, record in stream.get("agents", {}).items():
        name = record.get("name")
        dispatch_state = record.get("dispatchState")
        if dispatch_state in {"closed", "resolved"}:
            continue
        if dispatch_state in startup_hints:
            warnings.append(
                f"{stream['ticket']}: agent {name or '?'} ({role}) startup incomplete "
                f"at {dispatch_state}; {startup_hints[dispatch_state]}"
            )
            continue
        if dispatch_state == "active" and not name:
            warnings.append(
                f"{stream['ticket']}: active dispatch ({role}) has no agent name"
            )
            continue
        if name and name not in live_names:
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

    recorded_decision = verdict.get("decision")
    if isinstance(recorded_decision, dict) and recorded_decision.get("appliedAt"):
        action = recorded_decision.get("action")
        reason = recorded_decision.get("reason")
        if action not in {"BOUNCE", "LAND", "ESCALATE"} or not isinstance(
            reason, str
        ):
            raise FleetError("latest verdict has an invalid recorded decision")
        print(f"{action}: {reason}")
        return 0

    phase = stream.get("phase", "")
    if phase != "verdict-pending":
        raise FleetError(
            f"verdict requires phase verdict-pending, found {phase or '(missing)'}"
        )

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
            stream["approvedTip"] = verdict.get("tip")
            stream["phase"] = "approved"
        elif action == "ESCALATE":
            stream["phase"] = "hold"
        verdict["decision"] = {
            "action": action,
            "reason": reason,
            "appliedAt": utc_now_iso(),
        }
        save_config(config_path, config, dry_run=args.dry_run)
    return 0


def next_dispatch_number(stream: dict[str, Any], role: str) -> int:
    raw = stream.get("dispatchCounters", {}).get(role, 0)
    try:
        current = int(raw)
    except (TypeError, ValueError) as exc:
        raise FleetError(f"invalid {role} dispatch counter: {raw!r}") from exc
    if current < 0:
        raise FleetError(f"invalid {role} dispatch counter: {current}")
    return current + 1


def derive_agent_name(ticket: str, role: str, dispatch_number: int) -> str:
    if role not in ("impl", "review"):
        raise FleetError(f"unknown dispatch role: {role}")
    if dispatch_number < 1:
        raise FleetError(f"invalid dispatch number: {dispatch_number}")

    canonical_ticket = ticket.lower()
    slug = canonical_ticket.replace(".", "-")
    ticket_hash = hashlib.sha256(canonical_ticket.encode()).hexdigest()[:8]
    suffix = f"-{ticket_hash}-{role}-{dispatch_number}"
    slug = re.sub(r"[^a-z0-9_-]", "-", slug)
    slug = re.sub(r"-+", "-", slug).strip("-")
    if not slug or not slug[0].isalpha():
        slug = f"t{slug}"
    max_slug = 32 - len(suffix)
    if max_slug < 1:
        raise FleetError(
            f"dispatch number too long for a Herdr agent name: {dispatch_number}"
        )
    if len(slug) > max_slug:
        slug = slug[:max_slug].rstrip("-")
    return f"{slug}{suffix}"


def recipe_choice_for_stream(
    config: dict[str, Any], stream: dict[str, Any], role: str
) -> tuple[str, str, dict[str, Any]]:
    requested = stream.get("implRecipe") if role == "impl" else stream.get("reviewRecipe")
    if not isinstance(requested, str) or not requested:
        raise FleetError(f"no recipe for role {role}")
    recipes = config.get("recipes", {})
    if not isinstance(recipes, dict) or requested not in recipes:
        raise FleetError(f"unknown recipe: {requested}")
    primary = recipes[requested]
    if not isinstance(primary, dict):
        raise FleetError(f"invalid recipe: {requested}")
    fallbacks = primary.get("fallbacks", [])
    if not isinstance(fallbacks, list) or not all(
        isinstance(item, str) and item for item in fallbacks
    ):
        raise FleetError(f"invalid fallback list for recipe: {requested}")
    candidates = [requested, *fallbacks]
    if len(candidates) != len(set(candidates)):
        raise FleetError(f"duplicate or self fallback for recipe: {requested}")

    usage_pools = config.get("usagePools", {})
    if not isinstance(usage_pools, dict):
        raise FleetError("usagePools must be an object")
    skipped: list[str] = []
    for key in candidates:
        recipe = recipes.get(key)
        if not isinstance(recipe, dict):
            raise FleetError(f"unknown fallback recipe: {key}")
        enabled = recipe.get("enabled", True)
        if not isinstance(enabled, bool):
            raise FleetError(f"recipe enabled switch must be boolean: {key}")
        if not enabled:
            skipped.append(f"{key}=disabled")
            continue
        pool_key = recipe.get("usagePool")
        if pool_key is not None:
            if not isinstance(pool_key, str) or not pool_key:
                raise FleetError(f"invalid usage pool for recipe: {key}")
            pool = usage_pools.get(pool_key)
            if not isinstance(pool, dict):
                raise FleetError(f"unknown usage pool {pool_key!r} for recipe: {key}")
            state = pool.get("state", "available")
            if state not in {"available", "spent"}:
                raise FleetError(f"invalid state for usage pool {pool_key!r}: {state!r}")
            if state == "spent":
                skipped.append(f"{key}=spent:{pool_key}")
                continue
        return requested, key, recipe

    detail = ", ".join(skipped) or "no candidates"
    raise FleetError(
        f"operator alert: no available {role} recipe for {requested}; {detail}"
    )


def recipe_for_stream(
    config: dict[str, Any], stream: dict[str, Any], role: str
) -> dict[str, Any]:
    return recipe_choice_for_stream(config, stream, role)[2]


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


AGENT_START_ATTEMPTS = 3
AGENT_START_RETRY_SECONDS = 3.0
AGENT_READY_ATTEMPTS = 10
AGENT_READY_RETRY_SECONDS = 1.0
PROMPT_RECEIPT_ATTEMPTS = 4
PROMPT_RECEIPT_RETRY_SECONDS = 5.0
# Long enough to be distinctive, short enough to sit inside the first rendered
# transcript line, ahead of any pane wrapping or agent chrome.
PROMPT_SIGNATURE_LENGTH = 32
# A pane can echo a submitted prompt and still refuse it: an unauthenticated
# CLI answers with a login demand instead of working (the drawer-1 incident).
LOGIN_MARKERS = ("Not logged in", "Login expired", "Please run /login")
STARTUP_TRUST_DIALOGS = {
    "codex": (
        ("workspace trust", "do you trust the contents of this directory?"),
        ("1", "enter"),
    ),
    "claude": (
        (
            "quick safety check: is this a project you created or one you trust?",
            "yes, i trust this folder",
        ),
        ("enter",),
    ),
}
CODEX_RESTART_MARKERS = (
    "update ran successfully! please restart codex.",
    "codex was successfully upgraded",
)


def prompt_signature(text: str, length: int = PROMPT_SIGNATURE_LENGTH) -> str:
    return " ".join(text.split())[:length]


def herdr_agent_status(config: dict[str, Any], name: str) -> str:
    cmd = herdr_base(config) + ["agent", "get", name]
    result = run_cmd(cmd, check=False)
    try:
        payload = json.loads(result.stdout or "{}")
        return payload.get("result", {}).get("agent", {}).get("agent_status", "")
    except (json.JSONDecodeError, AttributeError):
        return ""


def normalized_transcript(text: str) -> str:
    return " ".join(text.casefold().split())


def startup_trust_keys(kind: str, transcript: str) -> tuple[str, ...] | None:
    dialog = STARTUP_TRUST_DIALOGS.get(kind)
    if dialog is None:
        return None
    markers, keys = dialog
    visible = normalized_transcript(transcript)
    return keys if any(marker in visible for marker in markers) else None


def codex_restart_required(
    config: dict[str, Any], name: str, pane_id: str
) -> bool:
    transcripts: list[str] = []
    for reader, target in (
        (herdr_agent_read, name),
        (herdr_pane_read, pane_id),
    ):
        try:
            transcripts.append(reader(config, target))
        except FleetError:
            continue
    combined = normalized_transcript("\n".join(transcripts))
    return any(marker in combined for marker in CODEX_RESTART_MARKERS)


def confirm_prompt_receipt(
    config: dict[str, Any],
    name: str,
    text: str,
    attempts: int = PROMPT_RECEIPT_ATTEMPTS,
    delay: float = PROMPT_RECEIPT_RETRY_SECONDS,
) -> bool:
    """A submitted prompt is received when the transcript echoes it OR the
    agent is measurably working on it.

    herdr's --wait --until working can match transient startup activity, and a
    CLI agent fresh from start may swallow the first submission entirely (the
    fix-1-review incident): the send's exit status alone is not receipt. But
    the echo alone is also not the whole story: some CLIs render a submitted
    prompt collapsed or late while already processing it (the auth-lane
    incident, where a blind re-send queued a duplicate brief). An agent whose
    status is working accepted SOMETHING; combined with the fact that we only
    prompt freshly started or idle seats, that something is our prompt.
    """
    signature = prompt_signature(text)
    if not signature:
        return True
    working_streak = 0
    for attempt in range(1, attempts + 1):
        try:
            transcript = herdr_agent_read(config, name)
        except FleetError:
            transcript = ""
        if any(marker in transcript for marker in LOGIN_MARKERS):
            return False
        if signature in " ".join(transcript.split()):
            return True
        # A boot flicker can report working for one poll and then swallow the
        # prompt (the auth-2-review incident); sustained working across two
        # spaced polls is genuine processing.
        if herdr_agent_status(config, name) == "working":
            working_streak += 1
            if working_streak >= 2:
                return True
        else:
            working_streak = 0
        if attempt < attempts:
            time.sleep(delay)
    return False


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
    if dry_run:
        run_cmd(cmd, dry_run=True)
        return
    # A pane fresh from tab create may not have an available shell yet;
    # herdr reports agent_pane_busy. Wait and retry rather than orphan the tab.
    # Codex can instead start successfully but pause before Herdr registration
    # on its numbered workspace-trust chooser. Accept that one known dialog and
    # wait briefly for the already-running process to become observable.
    for attempt in range(1, AGENT_START_ATTEMPTS + 1):
        result = run_cmd(cmd, check=False)
        if result.returncode == 0:
            return
        output = f"{result.stdout}\n{result.stderr}"
        if herdr_error_code(result) == "agent_not_ready":
            try:
                transcript = herdr_pane_read(config, pane_id)
            except FleetError:
                transcript = ""
            trust_keys = startup_trust_keys(recipe["kind"], transcript)
            if trust_keys is not None:
                run_cmd(
                    herdr_base(config)
                    + ["pane", "send-keys", pane_id, *trust_keys]
                )
                for ready_attempt in range(1, AGENT_READY_ATTEMPTS + 1):
                    if herdr_agent_status(config, name) in {"idle", "working", "done"}:
                        return
                    if ready_attempt < AGENT_READY_ATTEMPTS:
                        time.sleep(AGENT_READY_RETRY_SECONDS)
        if "agent_pane_busy" not in output or attempt == AGENT_START_ATTEMPTS:
            raise FleetError(
                f"command failed ({result.returncode}): {' '.join(cmd)}\n"
                f"{(result.stderr or result.stdout).strip()}"
            )
        time.sleep(AGENT_START_RETRY_SECONDS)


def herdr_recipe_pre_start(
    config: dict[str, Any],
    name: str,
    pane_id: str,
    recipe: dict[str, Any],
    dry_run: bool = False,
) -> bool:
    """Run a trusted recipe environment step in the fresh pane, when present."""
    step = recipe.get("envPreStep")
    if step is None:
        return False
    if not isinstance(step, str) or not step.strip():
        raise FleetError("recipe envPreStep must be a non-empty string")
    marker = f"__FLEET_PRE_START_{name}__"
    command = f"{{ {step}; }} && printf '\\n{marker}\\n'"
    commands = [
        herdr_base(config) + ["pane", "send-text", pane_id, command],
        herdr_base(config) + ["pane", "send-keys", pane_id, "enter"],
        herdr_base(config)
        + [
            "pane",
            "wait-output",
            "--match",
            marker,
            "--source",
            "recent-unwrapped",
            "--lines",
            "40",
            "--timeout",
            "30000",
            pane_id,
        ],
    ]
    for cmd in commands:
        result = run_cmd(cmd, check=False, dry_run=dry_run)
        if not dry_run and result.returncode != 0:
            raise FleetError(
                f"recipe environment pre-step failed for {name}: "
                f"{(result.stderr or result.stdout).strip() or 'no diagnostic'}"
            )
    return True


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
            "60000",
        ]
    )
    if dry_run:
        run_cmd(cmd, dry_run=True)
        return
    # Submission status signals (stalled, status-wait timeouts) are advisory:
    # a slow-booting seat can outlive them and still accept the prompt. The
    # transcript is the arbiter, so no send here is allowed to raise.
    result = run_cmd(cmd, check=False)
    if result.returncode != 0 and "agent_prompt_stalled" in (result.stderr or ""):
        visible_cmd = herdr_base(config) + ["agent", "read", name, "--source", "visible"]
        visible = run_cmd(visible_cmd, check=False)
        if "Workspace Trust" in (visible.stdout or ""):
            keys_cmd = herdr_base(config) + ["agent", "send-keys", name, "a"]
            run_cmd(keys_cmd)
        run_cmd(cmd, check=False)
    if confirm_prompt_receipt(config, name, text):
        return
    _raise_on_login_demand(config, name)
    # One re-send covers the swallowed-at-startup case; anything beyond that
    # is a seat problem the coordinator must see, not paper over.
    run_cmd(cmd, check=False)
    if confirm_prompt_receipt(config, name, text):
        return
    _raise_on_login_demand(config, name)
    raise FleetError(
        f"prompt not received by {name}: transcript never echoed "
        f"{prompt_signature(text)!r} after a re-send; read the pane"
    )


def _raise_on_login_demand(config: dict[str, Any], name: str) -> None:
    """An echoed prompt on an unauthenticated seat is delivery, not acceptance."""
    try:
        transcript = herdr_agent_read(config, name)
    except FleetError:
        return
    for marker in LOGIN_MARKERS:
        if marker in transcript:
            raise FleetError(
                f"seat {name} demands authentication ({marker!r}); a re-send "
                "cannot fix this - log the seat in, restart it fresh so the "
                "new credentials load, then dispatch again"
            )


def validate_dispatch_phase(stream: dict[str, Any], role: str) -> None:
    phase = str(stream.get("phase", ""))
    effective = phase
    if phase == "hold":
        effective = str(stream.get("resumePhase", ""))
        if not effective:
            raise FleetError("cannot dispatch from hold without a recoverable resumePhase")

    if role == "impl" and (
        effective in {"ready", "implementing"} or effective.startswith("bounce-")
    ):
        return
    if role == "review" and (
        effective in {"review", "in-review"}
        or re.fullmatch(r"review-\d+", effective)
    ):
        return
    raise FleetError(
        f"cannot dispatch {role} while phase is {phase or '(missing)'}"
        + (f" (resumePhase {effective or '(missing)'})" if phase == "hold" else "")
    )


def cmd_dispatch(args: argparse.Namespace) -> int:
    config_path = config_path_from_args(args)
    config = load_config(config_path)
    stream = find_stream(config, args.ticket)
    role = args.role
    dispatch_number = next_dispatch_number(stream, role)
    name = derive_agent_name(args.ticket, role, dispatch_number)
    requested_recipe, recipe_key, recipe = recipe_choice_for_stream(
        config, stream, role
    )
    label = f"{args.ticket} {role}"
    prompt_file = Path(args.prompt_file)
    if not prompt_file.is_file():
        raise FleetError(f"prompt file not found: {prompt_file}")

    if args.dry_run:
        validate_dispatch_phase(stream, role)
        ids = herdr_tab_create(config, stream["checkout"], label, dry_run=True)
        herdr_recipe_pre_start(
            config, name, ids["pane_id"], recipe, dry_run=True
        )
        herdr_agent_start(config, name, ids["pane_id"], recipe, dry_run=True)
        herdr_agent_prompt(config, name, prompt_file, dry_run=True)
        print(name)
        return 0

    for occupied_role, current in stream.get("agents", {}).items():
        if current and current.get("dispatchState") not in {"closed", "resolved"}:
            raise FleetError(
                f"live, uncaptured, or unclosed {occupied_role} dispatch "
                f"{current.get('name', '?')} is "
                f"{current.get('dispatchState') or 'legacy-active'}; reconcile "
                "it before starting another"
            )
    validate_dispatch_phase(stream, role)

    record = {
        "name": name,
        "role": role,
        "dispatchNumber": dispatch_number,
        "requestedRecipe": requested_recipe,
        "recipe": recipe_key,
        "promptFile": str(prompt_file),
        "reservedAt": utc_now_iso(),
        "dispatchState": "reserved",
    }
    stream.setdefault("dispatchCounters", {})[role] = dispatch_number
    stream.setdefault("agents", {})[role] = record
    save_config(config_path, config)

    ids = herdr_tab_create(config, stream["checkout"], label, dry_run=args.dry_run)
    record.update(
        {
            "tabId": ids["tab_id"],
            "paneId": ids["pane_id"],
            "dispatchState": "tab-created",
        }
    )
    save_config(config_path, config)
    if herdr_recipe_pre_start(config, name, ids["pane_id"], recipe):
        record["envPreparedAt"] = utc_now_iso()
        save_config(config_path, config)
    herdr_agent_start(config, name, ids["pane_id"], recipe, dry_run=args.dry_run)
    record["dispatchState"] = "started"
    save_config(config_path, config)

    # Persist the prompt attempt before crossing the external side-effect
    # boundary. If this process dies after Herdr accepts the prompt but before
    # the final save, the settle monitor must still regard the lane as owned
    # and capture its eventual result. A failed attempt may therefore surface
    # as a malformed capture, but it can no longer disappear silently.
    record["dispatchState"] = "prompting"
    record["promptAttemptedAt"] = utc_now_iso()
    if role == "impl":
        stream["phase"] = "implementing"
    else:
        stream["phase"] = f"review-{review_pass(stream)}"
    stream.pop("resumePhase", None)
    stream.pop("holdReason", None)
    save_config(config_path, config)
    try:
        herdr_agent_prompt(config, name, prompt_file, dry_run=args.dry_run)
    except FleetError:
        if recipe.get("kind") != "codex" or not codex_restart_required(
            config, name, record["paneId"]
        ):
            raise

        # Codex's self-updater exits the just-started TUI and requires a new
        # process. Replace the disposable tab once, retaining the same logical
        # dispatch record and agent name so ownership stays durable.
        record["codexRestartAttemptedAt"] = utc_now_iso()
        save_config(config_path, config)
        herdr_tab_close(config, record["tabId"])
        ids = herdr_tab_create(config, stream["checkout"], label)
        record.update(
            {
                "tabId": ids["tab_id"],
                "paneId": ids["pane_id"],
                "dispatchState": "prompting",
            }
        )
        save_config(config_path, config)
        if herdr_recipe_pre_start(config, name, ids["pane_id"], recipe):
            record["envPreparedAt"] = utc_now_iso()
            save_config(config_path, config)
        herdr_agent_start(config, name, ids["pane_id"], recipe)
        record["codexRestartedAt"] = utc_now_iso()
        save_config(config_path, config)
        herdr_agent_prompt(config, name, prompt_file)

    record["dispatchState"] = "active"
    record["dispatchedAt"] = utc_now_iso()
    save_config(config_path, config)
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
    parser.add_argument(
        "--config",
        help=(
            "Path to fleet.json (then FLEET_CONFIG, FLEET_STATE_DIR/fleet.json, "
            "or $FLEET_SEED/temp/fleet/fleet.json)"
        ),
    )
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
    p_capture.add_argument(
        "--event-id",
        help="Durable settle event ID; an already captured ID is a successful no-op",
    )
    p_capture.add_argument(
        "--capture-file",
        help="Retry this event from a previously saved transcript instead of Herdr",
    )
    p_capture.add_argument("--close", action="store_true")
    p_capture.set_defaults(func=cmd_capture)

    p_resolve = sub.add_parser(
        "resolve-event",
        help="Acknowledge irrecoverable output or teardown with a reason",
        parents=[common],
    )
    p_resolve.add_argument("agent_name")
    p_resolve.add_argument("--event-id", required=True)
    p_resolve.add_argument(
        "--capture-file",
        help="Explicitly resolve this exact saved malformed transcript as invalid output",
    )
    p_resolve.add_argument("--reason", required=True)
    p_resolve.set_defaults(func=cmd_resolve_event)

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


def mutates_config(args: argparse.Namespace) -> bool:
    if getattr(args, "dry_run", False):
        return False
    if args.command in {"capture", "resolve-event", "dispatch", "land"}:
        return True
    return args.command == "verdict" and bool(args.commit)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if mutates_config(args):
            with config_lock(config_path_from_args(args)):
                return args.func(args)
        return args.func(args)
    except FleetError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
