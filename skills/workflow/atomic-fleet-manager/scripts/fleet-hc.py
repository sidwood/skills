#!/usr/bin/env python3
"""Herdr Core (hc) reads for the fleet scripts.

  fleet-hc.py snapshot --space ID [--project NAME]
      One tab-separated row per live terminal of the fleet: address, name,
      role, app, state, fleet state, folder, where. A terminal belongs to the
      fleet when its herdr.space label is the space (on any machine: a
      remote terminal keeps the bare space id) or its fleet.project label is
      the project.
  fleet-hc.py wait --space ID [--project NAME] [--timeout S] [--exclude T]...
      Block until a fleet terminal other than the excluded ones appears,
      ends, or changes state (working, idle, done, blocked). Prints
      "EVENT <type> <address> <state>" and exits 0, or exits 1 at the
      timeout.
  fleet-hc.py tab ADDRESS
      The GUI tab holding the terminal (herdr-app ls), for tab.rename.
  fleet-hc.py space-name ID
      The GUI name of a space on this computer.

The name of a terminal is its fleet.name label, else the tab part of its
where label ("Project / TAB"), else its address. The GUI rewrites where, so
the scripts set fleet.name and treat where only as a fallback for terminals
opened by hand.
"""
import json
import signal
import subprocess
import sys


def labels(t):
    return t.get("labels") or {}


def status(t):
    s = t.get("status") or {}
    return (s.get("app") or "none"), (s.get("state") or "unknown")


def name(t):
    lab = labels(t)
    if lab.get("fleet.name"):
        return lab["fleet.name"]
    where = lab.get("where") or ""
    if " / " in where:
        return where.split(" / ", 1)[1]
    return t.get("address", "?")


def folder(t):
    fg = t.get("foreground") or {}
    return fg.get("cwd") or t.get("cwd") or ""


def belongs(t, space, project):
    lab = labels(t)
    return (space and lab.get("herdr.space") == space) or (project and lab.get("fleet.project") == project)


def events():
    return subprocess.Popen(["hc", "events", "--json"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def first_snapshot(proc):
    for line in proc.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "terminals" in msg:
            return msg["terminals"]
    sys.exit("fleet-hc: hc events ended before its snapshot")


def arg(flag, default=""):
    argv = sys.argv
    return argv[argv.index(flag) + 1] if flag in argv[:-1] else default


def args(flag):
    argv = sys.argv
    return [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == flag]


def snapshot():
    space, project = arg("--space"), arg("--project")
    proc = events()
    try:
        terminals = first_snapshot(proc)
    finally:
        proc.kill()
    for t in terminals:
        if t.get("state") != "live" or not belongs(t, space, project):
            continue
        lab = labels(t)
        app, state = status(t)
        row = [t["address"], name(t), lab.get("fleet.role", ""), app, state,
               lab.get("fleet.state", ""), folder(t), lab.get("where", "")]
        print("\t".join(v.replace("\t", " ").replace("\n", " ") for v in row))


# A status event also fires when only an agent's progress message changes;
# these are the changes worth waking for.
AT_REST = {"idle": "at-rest", "done": "at-rest"}


def wait():
    space, project = arg("--space"), arg("--project")
    timeout = int(arg("--timeout", "0") or 0)
    exclude = set(args("--exclude"))
    if timeout > 0:
        signal.signal(signal.SIGALRM, lambda *_: sys.exit(1))
        signal.alarm(timeout)
    proc = events()
    import atexit
    atexit.register(proc.kill)
    watched = {}
    for t in first_snapshot(proc):
        if t.get("state") == "live" and belongs(t, space, project) and t["address"] not in exclude:
            watched[t["address"]] = status(t)[1]
    for line in proc.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("method") != "event":
            continue
        p = msg.get("params") or {}
        kind, address, data = p.get("type"), p.get("terminal"), p.get("data") or {}
        if address in exclude:
            continue
        if kind == "created":
            if belongs(data, space, project):
                watched[address] = status(data)[1]
                print("EVENT created", address, status(data)[1])
                return 0
            continue
        if kind == "labels" and address not in watched:
            # A terminal labelled into the fleet after it started.
            if belongs({"labels": data.get("labels")}, space, project):
                watched[address] = "unknown"
                print("EVENT labelled", address, "unknown")
                return 0
            continue
        if address not in watched:
            continue
        if kind == "status":
            state = (data.get("status") or {}).get("state") or "unknown"
            if AT_REST.get(state, state) != AT_REST.get(watched[address], watched[address]):
                print("EVENT status", address, state)
                return 0
            watched[address] = state
        elif kind in ("finished", "removed", "exited", "deleted"):
            print("EVENT", kind, address, "gone")
            return 0
    return 1


def herdr_app_ls():
    out = subprocess.run(["herdr-app", "ls"], capture_output=True, text=True, timeout=20)
    return json.loads(out.stdout)


def tab():
    address = sys.argv[2]
    for space in herdr_app_ls().get("spaces", []):
        for t in space.get("tabs", []):
            if any(x.get("terminal") == address for x in t.get("terminals", [])):
                print(t["id"])
                return 0
    return 1


def space_name():
    wanted = sys.argv[2]
    for space in herdr_app_ls().get("spaces", []):
        if space.get("id") == wanted:
            print(space.get("name") or "")
            return 0
    return 1


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    handlers = {"snapshot": snapshot, "wait": wait, "tab": tab, "space-name": space_name}
    if command not in handlers:
        sys.exit(__doc__)
    try:
        sys.exit(handlers[command]() or 0)
    except BrokenPipeError:
        sys.exit(0)
