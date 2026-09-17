from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "fleet-monitor.sh"


class FleetMonitorScriptTest(unittest.TestCase):
    def test_script_has_valid_shell_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_swept_vanished_event_is_ignored_before_requeue(self):
        source = SCRIPT.read_text()
        vanished = source.index("      VANISHED)\n")
        blocked = source.index("      BLOCKED)\n", vanished)
        branch = source[vanished:blocked]

        swept_guard = branch.index('swept_has_event "$rest"')
        pending_lookup = branch.index('pending_event_for_lane "$lane"')
        queue = branch.index('queue_event "$rest" "$lane" vanished vanished')

        self.assertLess(swept_guard, pending_lookup)
        self.assertLess(swept_guard, queue)


if __name__ == "__main__":
    unittest.main()
