#!/usr/bin/env python3
"""Show an Atomic print-mode run (--mode json on stdin) as readable progress
lines in its FMA tab, and write the agent's last reply to the file named as
the first argument. Used by fma.sh."""
import json
import sys
import time

reply_path = sys.argv[1]
last_text = ""
last_beat = time.time()
streamed = 0


def short(value, limit=150):
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def assistant_text(message):
    parts = message.get("content") or []
    if isinstance(parts, str):
        return parts
    return "\n".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text").strip()


for line in sys.stdin:
    try:
        event = json.loads(line)
    except ValueError:
        continue
    kind = event.get("type")
    stamp = time.strftime("%H:%M:%S")
    if kind == "message_update":
        # A long answer or a long file arrives as many updates with no tool
        # call between them: say once a minute that the model is still writing.
        streamed += 1
        if time.time() - last_beat >= 60:
            last_beat = time.time()
            print(f"{stamp}  … still writing ({streamed} updates so far)", flush=True)
        continue
    last_beat = time.time()
    if kind == "tool_execution_start":
        args = event.get("args") or {}
        detail = args.get("path") or args.get("command") or args.get("pattern") or args.get("code") or args
        print(f"{stamp}  {event.get('toolName')}  {short(detail)}", flush=True)
    elif kind == "tool_execution_end" and event.get("isError"):
        print(f"{stamp}  {event.get('toolName')} failed: {short(event.get('result'), 200)}", flush=True)
    elif kind == "message_end":
        message = event.get("message") or {}
        if message.get("role") == "assistant":
            text = assistant_text(message)
            if text:
                last_text = text
                print(f"{stamp}  says: {short(text, 300)}", flush=True)
    elif kind == "agent_end":
        print(f"{stamp}  finished", flush=True)

with open(reply_path, "w") as handle:
    handle.write(last_text + "\n")
print("\n" + last_text, flush=True)
