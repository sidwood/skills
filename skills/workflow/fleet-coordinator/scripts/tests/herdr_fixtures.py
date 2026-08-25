"""Herdr CLI fixture payloads and subprocess.run test helpers."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any
from unittest import mock

_REAL_SUBPROCESS_RUN = subprocess.run

FIXTURES = Path(__file__).resolve().parent / "fixtures"
ENVELOPES: dict[str, Any] = json.loads((FIXTURES / "herdr_envelopes.json").read_text())


def herdr_json(envelope: dict[str, Any]) -> str:
    return json.dumps(envelope)


def completed(
    cmd: list[str],
    *,
    returncode: int = 0,
    stdout: str = "",
    stderr: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(cmd, returncode, stdout, stderr)


def match_herdr(cmd: list[str], *parts: str) -> bool:
    return len(cmd) >= len(parts) + 1 and cmd[0] == "herdr" and all(p in cmd for p in parts)


def make_herdr_run_handler(
    *,
    agent_read: dict[str, str] | None = None,
    pane_read: dict[str, str] | None = None,
    agent_list: str | None = None,
    tab_create: str | None = None,
) -> mock.Mock:
    """Return a side_effect for subprocess.run that responds to herdr commands."""

    agent_read = agent_read or {}
    pane_read = pane_read or {}
    agent_list_out = agent_list or herdr_json(ENVELOPES["agent_list"])
    tab_create_out = tab_create or herdr_json(ENVELOPES["tab_create"])

    def handler(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        if cmd and cmd[0] == "git":
            return _REAL_SUBPROCESS_RUN(cmd, **kwargs)
        if not cmd or cmd[0] != "herdr":
            return completed(cmd, returncode=1, stderr="unexpected command")
        if match_herdr(cmd, "agent", "read"):
            name = cmd[3] if len(cmd) > 3 else ""
            if name in agent_read:
                body = agent_read[name]
                if body.startswith("{"):
                    return completed(cmd, returncode=1, stdout=body)
                return completed(cmd, stdout=body)
            return completed(
                cmd,
                returncode=1,
                stderr=herdr_json(ENVELOPES["agent_not_found"]),
            )
        if match_herdr(cmd, "pane", "read"):
            pane_id = cmd[3] if len(cmd) > 3 else ""
            text = pane_read.get(pane_id, "")
            if text:
                return completed(cmd, stdout=text)
            return completed(cmd, returncode=1, stderr="pane not found")
        if match_herdr(cmd, "agent", "list"):
            return completed(cmd, stdout=agent_list_out)
        if match_herdr(cmd, "tab", "create"):
            return completed(cmd, stdout=tab_create_out)
        if match_herdr(cmd, "tab", "close"):
            return completed(cmd)
        if match_herdr(cmd, "agent", "start"):
            return completed(cmd)
        if match_herdr(cmd, "agent", "prompt"):
            return completed(cmd)
        if match_herdr(cmd, "agent", "send-keys"):
            return completed(cmd)
        return completed(cmd, returncode=1, stderr=f"unhandled herdr: {cmd}")

    return mock.Mock(side_effect=handler)
