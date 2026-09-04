#!/usr/bin/env python3
"""Hold the fleet-monitor process lock, then replace this process with Bash."""

from __future__ import annotations

import errno
import fcntl
import os
import sys


def fail(message: str) -> None:
    os.write(2, f"fleet-monitor: {message}\n".encode())
    raise SystemExit(2)


if len(sys.argv) < 3:
    fail("lock helper received invalid arguments")

lock_path, script, *args = sys.argv[1:]
try:
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
except OSError:
    fail("lock unavailable")

try:
    fcntl.lockf(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as exc:
    os.close(lock_fd)
    if exc.errno in (errno.EACCES, errno.EAGAIN):
        fail("already running")
    fail("lock unavailable")

try:
    # Diagnostic only. Kernel lock ownership, never this text, controls entry.
    os.ftruncate(lock_fd, 0)
    os.write(lock_fd, f"{os.getpid()}\n".encode())
    os.fsync(lock_fd)
    os.set_inheritable(lock_fd, True)
except OSError:
    os.close(lock_fd)
    fail("lock unavailable")

environment = os.environ.copy()
environment["_FLEET_MONITOR_LOCK_FD"] = str(lock_fd)
environment["_FLEET_MONITOR_LOCK_PATH"] = lock_path
try:
    os.execvpe(
        "bash",
        ["bash", script, "--_fleet-monitor-lock-held", *args],
        environment,
    )
except OSError:
    os.close(lock_fd)
    fail("exec failed")
