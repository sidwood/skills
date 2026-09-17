#!/usr/bin/env python3
"""Clear known Herdr agent startup dialogs and prove prompt readiness."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from typing import Any

TRUST_DIALOGS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "claude": (
        (
            "quick safety check: is this a project you created or one you trust?",
            "yes, i trust this folder",
        ),
        ("down", "enter"),
    ),
    "codex": (
        ("workspace trust", "do you trust the contents of this directory?"),
        ("1", "enter"),
    ),
    "cursor": (("workspace trust",), ("a",)),
}


def normalized(text: str) -> str:
    return " ".join(text.casefold().split())


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )


def herdr_base(session: str | None) -> list[str]:
    command = ["herdr"]
    if session:
        command.extend(["--session", session])
    return command


def agent_info(base: list[str], name: str) -> dict[str, Any] | None:
    result = run(base + ["agent", "get", name])
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)["result"]["agent"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None


def pane_text(base: list[str], pane: str) -> str:
    result = run(base + ["pane", "read", pane, "--source", "visible", "--lines", "80"])
    return result.stdout if result.returncode == 0 else ""


def prompt_visible(text: str) -> bool:
    return any(line.strip() == "❯" for line in text.splitlines())


def ensure_ready(
    name: str,
    pane: str,
    kind: str,
    session: str | None = None,
    timeout: float = 60.0,
    poll: float = 1.0,
) -> tuple[bool, str]:
    base = herdr_base(session)
    deadline = time.monotonic() + timeout
    trust_sent = False
    last_status = "missing"
    while time.monotonic() < deadline:
        info = agent_info(base, name)
        visible = pane_text(base, pane)
        dialog = TRUST_DIALOGS.get(kind)
        shown = normalized(visible)
        dialog_visible = (
            any(marker in shown for marker in dialog[0]) if dialog is not None else False
        )
        if dialog_visible:
            if not trust_sent:
                result = run(base + ["pane", "send-keys", pane, *dialog[1]])
                if result.returncode != 0:
                    return False, "trust-dialog acceptance failed"
                trust_sent = True
            time.sleep(poll)
            continue
        if info:
            last_status = str(info.get("agent_status") or "unknown")
            if last_status in {"idle", "working"} and info.get("interactive_ready"):
                return True, f"agent-status={last_status}"
            # Herdr can lag behind an already-ready TUI after the trust dialog.
            # A visible input prompt is sufficient to submit the real brief.
            if prompt_visible(visible):
                return True, f"pane-prompt agent-status={last_status}"
        time.sleep(poll)
    return False, f"not prompt-ready after {timeout:.0f}s (last-status={last_status})"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", required=True)
    parser.add_argument("--pane", required=True)
    parser.add_argument("--kind", choices=sorted(TRUST_DIALOGS), required=True)
    parser.add_argument("--session")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()
    ready, detail = ensure_ready(
        args.agent,
        args.pane,
        args.kind,
        session=args.session,
        timeout=args.timeout,
    )
    prefix = "READY" if ready else "BLOCKED"
    print(f"{prefix} {args.agent} — {detail}")
    return 0 if ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
