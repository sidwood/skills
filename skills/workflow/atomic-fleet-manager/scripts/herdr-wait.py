#!/usr/bin/env python3
"""Block until a Herdr agent changes state in one of the given panes.

  herdr-wait.py --timeout SECONDS PANE [PANE ...]

Subscribes to Herdr's `pane.agent_status_changed` event on its socket, so
the caller hears of a finished turn at once instead of at its next poll.

Prints `EVENT <pane> <status>` and exits 0 on the first change, prints
`TIMEOUT` and exits 0 when the time is up, and exits 2 when the socket or
the subscription fails, so the caller can fall back to sleeping.
"""
import json
import os
import socket
import sys
import time


def main():
    args = sys.argv[1:]
    timeout = 60.0
    if len(args) >= 2 and args[0] == "--timeout":
        timeout = float(args[1])
        args = args[2:]
    path = os.environ.get("HERDR_SOCKET_PATH")
    if not args or not path:
        sys.stderr.write(__doc__)
        return 2

    deadline = time.monotonic() + timeout
    request = {
        "id": "fleet-watch",
        "method": "events.subscribe",
        "params": {
            "subscriptions": [
                {"type": "pane.agent_status_changed", "pane_id": pane} for pane in args
            ]
        },
    }
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(path)
        sock.sendall((json.dumps(request) + "\n").encode())
    except OSError as error:
        sys.stderr.write(f"herdr-wait: {error}\n")
        return 2

    buffer = b""
    acknowledged = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print("TIMEOUT")
            return 0
        # Until Herdr accepts the subscription a silent socket is a failure,
        # not a quiet fleet.
        sock.settimeout(min(remaining, 5) if not acknowledged else remaining)
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            if acknowledged:
                print("TIMEOUT")
                return 0
            sys.stderr.write("herdr-wait: no reply to the subscription\n")
            return 2
        except OSError as error:
            sys.stderr.write(f"herdr-wait: {error}\n")
            return 2
        if not chunk:
            sys.stderr.write("herdr-wait: Herdr closed the socket\n")
            return 2
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("id") == "fleet-watch":
                if "error" in message:
                    sys.stderr.write(f"herdr-wait: {json.dumps(message['error'])}\n")
                    return 2
                acknowledged = True
            elif message.get("event") == "pane.agent_status_changed":
                data = message.get("data") or {}
                print("EVENT", data.get("pane_id"), data.get("agent_status"))
                return 0


if __name__ == "__main__":
    sys.exit(main())
