"""Tests for deterministic board refreshes after fleet mutations."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))
import fleet  # noqa: E402


class BoardRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.seed = Path(self.tmp.name) / "seed"
        self.seed.mkdir()
        self.config_path = Path(self.tmp.name) / "fleet.json"

    def write_config(self, command: object | None = None) -> None:
        config: dict[str, object] = {"seed": str(self.seed), "streams": []}
        if command is not None:
            config["boardRefreshCommand"] = command
        self.config_path.write_text(json.dumps(config, indent=2) + "\n")

    @mock.patch("fleet.run_cmd")
    def test_refresh_runs_configured_argv_from_seed(self, run_cmd: mock.Mock) -> None:
        command = ["python3", "temp/fleet/build_state.py", "--board-only"]
        self.write_config(command)

        fleet.refresh_board(self.config_path)

        run_cmd.assert_called_once_with(command, cwd=self.seed)

    @mock.patch("fleet.run_cmd")
    def test_refresh_is_noop_when_not_configured(self, run_cmd: mock.Mock) -> None:
        self.write_config()

        fleet.refresh_board(self.config_path)

        run_cmd.assert_not_called()

    def test_mutating_main_refreshes_after_unlock(self) -> None:
        self.write_config(["python3", "build.py"])
        order: list[str] = []

        @contextmanager
        def lock(_path: Path):
            order.append("lock-enter")
            try:
                yield
            finally:
                order.append("lock-exit")

        args = fleet.argparse.Namespace(
            command="capture",
            dry_run=False,
            func=lambda _args: order.append("mutation") or 0,
        )
        parser = mock.Mock()
        parser.parse_args.return_value = args

        with (
            mock.patch("fleet.build_parser", return_value=parser),
            mock.patch("fleet.config_path_from_args", return_value=self.config_path),
            mock.patch("fleet.config_lock", side_effect=lock),
            mock.patch("fleet.refresh_board", side_effect=lambda _path: order.append("refresh")),
        ):
            result = fleet.main([])

        self.assertEqual(result, 0)
        self.assertEqual(order, ["lock-enter", "mutation", "lock-exit", "refresh"])


if __name__ == "__main__":
    unittest.main()
