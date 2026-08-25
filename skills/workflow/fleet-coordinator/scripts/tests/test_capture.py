"""Tests for fleet capture subcommand — APPROVE parsing."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402

ECHOED_REVIEW_TAIL = """
End with exactly one of:
APPROVE: yes
APPROVE: no

[P1] (A) fleet.py:433: first match is echoed template
APPROVE: no
"""


class ParseCaptureTests(unittest.TestCase):
    def test_parse_approve_uses_last_line_not_echoed_template(self) -> None:
        approve = fleet.parse_approve_verdict(ECHOED_REVIEW_TAIL)
        self.assertIsNotNone(approve)
        self.assertFalse(approve)

    def test_parse_approve_yes_when_only_template_lines(self) -> None:
        text = "End with exactly one of:\nAPPROVE: yes\nAPPROVE: no\n"
        self.assertIsNone(fleet.parse_approve_verdict(text))


if __name__ == "__main__":
    unittest.main()
