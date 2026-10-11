#!/usr/bin/env python3
"""Read an `agent --output-format stream-json` event file (Cursor).

  cursor-stream.py summary FILE   one line: what the agent is doing now
  cursor-stream.py text FILE      every assistant message, in order
  cursor-stream.py usage FILE...  token totals across the files

The composer-grok harness streams each writer and reviewer turn to a file,
so a run can be watched while it works instead of only when it ends.
"""
import json
import os
import sys
import time

SILENT_AFTER_SECONDS = 600


def events(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def describe(tool_call):
    """A short label for one tool call: its kind and its main argument."""
    for key, value in tool_call.items():
        if not key.endswith("ToolCall") or not isinstance(value, dict):
            continue
        kind = key[: -len("ToolCall")]
        args = value.get("args") or {}
        if args.get("command"):
            return " ".join(str(args["command"]).split())[:70]
        if args.get("path"):
            return f"{kind} {os.path.basename(str(args['path']))}"
        for name in ("pattern", "query", "globPattern"):
            if args.get(name):
                return f"{kind} {str(args[name])[:50]}"
        return kind
    return "tool"


def minutes(seconds):
    return f"{int(seconds // 60)}m"


def summary(path):
    running = {}
    last = None
    calls = 0
    finished = False
    for event in events(path):
        kind = event.get("type")
        if kind == "tool_call":
            call_id = event.get("call_id")
            label = describe(event.get("tool_call") or {})
            if event.get("subtype") == "started":
                calls += 1
                running[call_id] = (label, event.get("timestamp_ms"))
            else:
                running.pop(call_id, None)
            last = label
        elif kind == "result":
            finished = True
    now = time.time()
    try:
        quiet = now - os.path.getmtime(path)
    except OSError:
        return "starting"
    if finished:
        return f"finished · {calls} tool calls"
    if running:
        label, started = max(running.values(), key=lambda item: item[1] or 0)
        age = now - started / 1000 if started else quiet
        return f"running: {label} ({minutes(age)}) · {calls} tool calls"
    # No command in flight and nothing from the model for a long time: the
    # turn has stalled, which a busy turn never looks like.
    if quiet >= SILENT_AFTER_SECONDS:
        return f"silent {minutes(quiet)}, no command running · {calls} tool calls"
    if last is None:
        return "thinking"
    return f"last: {last} · {calls} tool calls"


def text(path):
    parts = []
    result = None
    for event in events(path):
        if event.get("type") == "assistant":
            for block in (event.get("message") or {}).get("content") or []:
                if block.get("type") == "text" and block.get("text", "").strip():
                    parts.append(block["text"].strip())
        elif event.get("type") == "result":
            result = (event.get("result") or "").strip()
    if result and (not parts or parts[-1] != result):
        parts.append(result)
    return "\n\n".join(parts)


def usage(paths):
    totals = {}
    for path in paths:
        for event in events(path):
            if event.get("type") != "result":
                continue
            for key, value in (event.get("usage") or {}).items():
                if isinstance(value, (int, float)):
                    totals[key] = totals.get(key, 0) + value
    if not totals:
        return "not recorded"
    return ", ".join(f"{key} {int(value):,}" for key, value in sorted(totals.items()))


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("summary", "text", "usage"):
        sys.stderr.write(__doc__)
        return 2
    if sys.argv[1] == "summary":
        print(summary(sys.argv[2]))
    elif sys.argv[1] == "text":
        print(text(sys.argv[2]))
    else:
        print(usage(sys.argv[2:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
