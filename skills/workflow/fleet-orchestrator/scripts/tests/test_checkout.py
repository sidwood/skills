"""BC checkout creation and dispatch boundary tests with disposable repositories."""

from __future__ import annotations

import io
import json
import os
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import fleet


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.seed = self.root / "project"
        self.seed.mkdir()
        self.git(self.seed, "init", "-b", "main")
        self.git(self.seed, "config", "user.name", "Test")
        self.git(self.seed, "config", "user.email", "test@example.invalid")
        self.git(self.seed, "commit", "--allow-empty", "-m", "Initial")
        self.base = self.git(self.seed, "rev-parse", "HEAD")
        self.branch = "t1"
        self.checkout = self.root / "project.t1"
        self.config_path = self.root / "fleet.json"
        self.prompt = self.root / "prompt.txt"
        self.prompt.write_text("Implement T1\n")
        self.config = {"seed": str(self.seed), "workspace": "w1", "streams": [{
            "ticket": "T1", "phase": "ready", "branch": self.branch,
            "baseTip": self.base, "checkout": str(self.checkout),
            "implRecipe": "grok-xhigh", "agents": {},
        }]}
        fleet.sync_recipe_catalog(self.config)
        self.write()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tool = self.bin / "git-bc-add"
        self.tool.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
pathlib.Path(os.environ['BC_CALL_LOG']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('BC_FAIL'):
    sys.exit(7)
assert len(sys.argv) == 4 and sys.argv[1] == '--offline'
seed, branch = sys.argv[2:]
target = seed + '.' + branch.replace('/', '-')
subprocess.run(['git', 'clone', '--local', seed, target], check=True)
subprocess.run(['git', '-C', target, 'checkout', '-b', branch], check=True)
if not os.environ.get('BC_BAD_MARKER'):
    subprocess.run(['git', '-C', target, 'config', 'bc.source', seed], check=True)
if os.environ.get('BC_SETUP_WARNING'):
    print('BC setup output: prerequisite unavailable')
    print('BC warning: bc.postadd failed; setup remains required', file=sys.stderr)
''')
        self.tool.chmod(0o755)
        self.log = self.root / "bc-call.json"
        self.env = mock.patch.dict(os.environ, {"PATH": str(self.bin) + os.pathsep + os.environ['PATH'],
                                                "BC_CALL_LOG": str(self.log)})
        self.env.start()
        self.addCleanup(self.env.stop)

    @staticmethod
    def git(repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self):
        self.config_path.write_text(json.dumps(self.config))

    def args(self, *args):
        return fleet.build_parser().parse_args(["--config", str(self.config_path), *args])

    def clone(self, target=None, source=None, marker=True):
        target = target or self.checkout
        source = source or self.seed
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--local", str(source), str(target)], check=True, capture_output=True)
        self.git(target, "checkout", "-B", self.branch)
        self.git(target, "config", "user.name", "Test")
        self.git(target, "config", "user.email", "test@example.invalid")
        if marker:
            self.git(target, "config", "bc.source", str(source))
        return target

    def validate(self):
        return fleet.validate_checkout(self.config, self.config['streams'][0])

    def test_creation_uses_bc_default_offline_command_and_records_verified_identity(self):
        self.assertEqual(fleet.main(["--config", str(self.config_path), "checkout", "T1"]), 0)
        self.assertEqual(json.loads(self.log.read_text()), ['--offline', str(self.seed), self.branch])
        stream = json.loads(self.config_path.read_text())['streams'][0]
        receipt = stream['checkoutReceipt']
        self.assertEqual(receipt['command'], ['git', 'bc-add', '--offline', str(self.seed), self.branch])
        self.assertEqual(receipt['executable'], str(self.tool))
        self.assertEqual(receipt['baseTip'], self.base)
        self.assertEqual(self.git(self.seed, 'branch', '--show-current'), 'main')
        self.assertEqual(self.validate()['checkout'], str(self.checkout))

    def test_successful_bc_setup_warning_remains_visible_once(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {'BC_SETUP_WARNING': '1'}), redirect_stdout(stdout), redirect_stderr(stderr):
            self.assertEqual(fleet.cmd_checkout(self.args('checkout', 'T1')), 0)
        self.assertEqual(stdout.getvalue().count('BC setup output: prerequisite unavailable'), 1)
        self.assertEqual(stderr.getvalue().count('BC warning: bc.postadd failed; setup remains required'), 1)
        self.assertIn('CHECKOUT-OK: created', stdout.getvalue())
        stream = json.loads(self.config_path.read_text())['streams'][0]
        self.assertEqual(stream['checkoutReceipt']['baseTip'], self.base)

    def test_reuse_preserves_existing_work_and_does_not_invent_creation_receipt(self):
        self.clone()
        (self.checkout / 'work.txt').write_text('unfinished work')
        self.assertEqual(fleet.cmd_checkout(self.args('checkout', 'T1')), 0)
        stream = json.loads(self.config_path.read_text())['streams'][0]
        self.assertNotIn('checkoutReceipt', stream)
        self.assertIn('checkoutVerification', stream)
        self.assertFalse(self.log.exists())
        self.assertEqual((self.checkout / 'work.txt').read_text(), 'unfinished work')

    def test_bc_failure_leaves_no_false_receipt_or_state_mutation(self):
        before = self.config_path.read_bytes()
        with mock.patch.dict(os.environ, {'BC_FAIL': '1'}):
            with self.assertRaises(fleet.FleetError):
                fleet.cmd_checkout(self.args('checkout', 'T1'))
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertFalse(self.checkout.exists())

    def test_failed_post_creation_validation_preserves_clone_without_false_receipt(self):
        before = self.config_path.read_bytes()
        with mock.patch.dict(os.environ, {'BC_BAD_MARKER': '1'}):
            with self.assertRaisesRegex(fleet.FleetError, 'no local bc.source'):
                fleet.cmd_checkout(self.args('checkout', 'T1'))
        self.assertTrue(self.checkout.exists())
        self.assertEqual(self.config_path.read_bytes(), before)

    def test_recorded_missing_checkout_is_not_recreated(self):
        self.config['streams'][0]['checkoutVerification'] = {'verifiedAt': 'previously'}
        self.write()
        with self.assertRaisesRegex(fleet.FleetError, 'cannot recreate'):
            fleet.cmd_checkout(self.args('checkout', 'T1'))
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_checkouts(self.args('checkouts', 'check'))
        self.assertFalse(self.log.exists())

    def test_new_nested_path_rejected_before_bc(self):
        self.config['streams'][0]['checkout'] = str(self.seed / 'temp' / 'T1')
        self.write()
        with self.assertRaisesRegex(fleet.FleetError, 'BC default path'):
            fleet.cmd_checkout(self.args('checkout', 'T1'))
        self.assertFalse(self.log.exists())
        with self.assertRaisesRegex(fleet.FleetError, 'planned checkout'):
            fleet.cmd_checkouts(self.args('checkouts', 'check'))

    def test_new_checkout_dry_run_is_read_only(self):
        before = self.config_path.read_bytes()
        self.assertEqual(fleet.cmd_checkout(self.args('checkout', 'T1', '--dry-run')), 0)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.checkout.exists())
        self.assertEqual(self.config_path.read_bytes(), before)

    def test_seed_branch_with_different_tip_rejected_before_bc(self):
        self.git(self.seed, 'checkout', '-b', self.branch)
        self.git(self.seed, 'commit', '--allow-empty', '-m', 'Other work')
        self.git(self.seed, 'checkout', 'main')
        with self.assertRaisesRegex(fleet.FleetError, 'differs from'):
            fleet.cmd_checkout(self.args('checkout', 'T1'))
        self.assertFalse(self.log.exists())

    def test_separate_raw_clone_without_marker_rejected(self):
        self.clone(marker=False)
        with self.assertRaisesRegex(fleet.FleetError, 'no local bc.source'):
            self.validate()

    def test_seed_itself_rejected(self):
        self.config['streams'][0]['checkout'] = str(self.seed)
        with self.assertRaisesRegex(fleet.FleetError, 'seed checkout'):
            self.validate()

    def test_worktree_rejected(self):
        self.git(self.seed, 'worktree', 'add', '-b', self.branch, str(self.checkout))
        with self.assertRaisesRegex(fleet.FleetError, 'own .git directory'):
            self.validate()

    def test_wrong_branch_rejected(self):
        self.clone()
        self.git(self.checkout, 'checkout', 'main')
        with self.assertRaisesRegex(fleet.FleetError, 'configured branch'):
            self.validate()

    def test_source_chain_accepts_custom_bc_siblings(self):
        intermediate = self.clone(self.root / 'project.custom')
        self.clone(source=intermediate)
        self.assertEqual(self.validate()['sourceChain'], [str(intermediate), str(self.seed)])
        self.config['streams'][0]['checkout'] = str(intermediate)
        self.assertEqual(self.validate()['checkout'], str(intermediate))

    def test_existing_chained_checkout_accepts_unlanded_intermediate_source_base(self):
        intermediate = self.clone(self.root / 'project.batch-source')
        self.git(intermediate, 'commit', '--allow-empty', '-m', 'Approved batch base')
        unlanded_base = self.git(intermediate, 'rev-parse', 'HEAD')
        self.clone(source=intermediate)
        self.config['streams'][0]['baseTip'] = unlanded_base
        self.assertNotEqual(self.git(self.seed, 'rev-parse', 'HEAD'), unlanded_base)
        identity = self.validate()
        self.assertEqual(identity['baseTip'], unlanded_base)
        self.assertEqual(identity['sourceChain'], [str(intermediate), str(self.seed)])
        self.git(self.checkout, 'commit', '--allow-empty', '-m', 'Checkout-only commit')
        self.config['streams'][0]['baseTip'] = self.git(self.checkout, 'rev-parse', 'HEAD')
        with self.assertRaisesRegex(fleet.FleetError, 'not an ancestor of any BC source HEAD'):
            self.validate()

    def test_wrong_source_and_cycle_rejected(self):
        self.clone()
        other = self.clone(self.root / 'other', marker=False)
        self.git(self.checkout, 'config', 'bc.source', str(other))
        with self.assertRaisesRegex(fleet.FleetError, 'no local bc.source'):
            self.validate()
        self.git(other, 'config', 'bc.source', str(self.checkout))
        with self.assertRaisesRegex(fleet.FleetError, 'cyclic'):
            self.validate()

    def test_base_must_belong_to_source_chain_and_checkout(self):
        self.clone()
        self.git(self.checkout, 'commit', '--allow-empty', '-m', 'New')
        self.config['streams'][0]['baseTip'] = self.git(self.checkout, 'rev-parse', 'HEAD')
        with self.assertRaisesRegex(fleet.FleetError, 'not an ancestor'):
            self.validate()

    def test_explicit_legacy_layout_continues_only_pinned_existing_clone(self):
        legacy = self.clone(self.seed / 'temp' / 'T1')
        stream = self.config['streams'][0]
        stream['checkout'] = str(legacy)
        with self.assertRaisesRegex(fleet.FleetError, 'sibling'):
            self.validate()
        stream['checkoutLegacyLayout'] = {'checkout': str(legacy), 'branch': self.branch,
            'seed': str(self.seed), 'operatorAuthority': 'Sid: new checkouts from now on; preserve T1'}
        self.assertTrue(self.validate()['legacyLayout'])
        for field in ('checkout', 'branch', 'seed', 'operatorAuthority'):
            original = stream['checkoutLegacyLayout'][field]
            stream['checkoutLegacyLayout'][field] = ''
            with self.assertRaisesRegex(fleet.FleetError, 'sibling'):
                self.validate()
            stream['checkoutLegacyLayout'][field] = original
        missing = self.seed / 'temp' / 'missing'
        stream['checkout'] = str(missing)
        stream['checkoutLegacyLayout']['checkout'] = str(missing)
        self.write()
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_checkout(self.args('checkout', 'T1'))
        self.assertFalse(self.log.exists())
        self.assertFalse(missing.exists())

    def test_dispatch_guard_precedes_mutation_herdr_dry_run_and_fallback_selection(self):
        self.clone(marker=False)
        self.config['usagePools']['grok-native']['state'] = 'spent'
        self.write()
        before = self.config_path.read_bytes()
        for dry_run in ([], ['--dry-run']):
            with mock.patch('fleet.herdr_tab_create') as tab, mock.patch('fleet.save_config') as save:
                with self.assertRaisesRegex(fleet.FleetError, 'no local bc.source'):
                    fleet.cmd_dispatch(self.args('dispatch', 'T1', 'impl', '--prompt-file', str(self.prompt), *dry_run))
                tab.assert_not_called()
                save.assert_not_called()
        self.assertEqual(self.config_path.read_bytes(), before)

    def test_capacity_recovery_fails_closed_without_reserving_a_replacement(self):
        self.clone(marker=False)
        stream = self.config['streams'][0]
        event = {'eventId': 'old@1', 'resolutionClass': 'capacity', 'agent': 'old',
                 'role': 'impl', 'promptFile': str(self.prompt)}
        stream['events'] = [event]
        stream['agents'] = {'impl': {'name': 'old', 'dispatchState': 'closed'}}
        self.write()
        with mock.patch('fleet.herdr_tab_create') as tab:
            with self.assertRaisesRegex(fleet.FleetError, 'no local bc.source'):
                fleet.resume_capacity_recovery(self.config_path, self.config, stream, event)
            tab.assert_not_called()
        after = json.loads(self.config_path.read_text())['streams'][0]
        self.assertEqual(after['agents'], stream['agents'])
        self.assertNotIn('dispatchCounters', after)
        self.assertIn('CHECKOUT-DRIFT', after['events'][0]['recoveryError'])

    def test_missing_tool_stops_dispatch(self):
        self.clone()
        with mock.patch('fleet.shutil.which', return_value=None), mock.patch('fleet.herdr_tab_create') as tab:
            with self.assertRaisesRegex(fleet.FleetError, 'missing from PATH'):
                fleet.cmd_dispatch(self.args('dispatch', 'T1', 'impl', '--prompt-file', str(self.prompt)))
            tab.assert_not_called()

    def test_zero_dispatch_counters_allow_planned_scan_and_bc_creation(self):
        self.config['streams'][0]['dispatchCounters'] = {'impl': 0, 'review': 0}
        self.write()
        before = self.config_path.read_bytes()
        self.assertEqual(fleet.cmd_checkouts(self.args('checkouts', 'check')), 0)
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertFalse(self.checkout.exists())
        self.assertEqual(fleet.cmd_checkout(self.args('checkout', 'T1')), 0)
        self.assertEqual(json.loads(self.log.read_text()), ['--offline', str(self.seed), self.branch])

    def test_positive_dispatch_counter_prevents_missing_checkout_recreation(self):
        self.config['streams'][0]['dispatchCounters'] = {'impl': 1, 'review': 0}
        self.write()
        with self.assertRaisesRegex(fleet.FleetError, 'cannot recreate'):
            fleet.cmd_checkout(self.args('checkout', 'T1'))
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_checkouts(self.args('checkouts', 'check'))
        self.assertFalse(self.log.exists())

    def test_complete_ticket_history_is_skipped_without_live_lane(self):
        self.config['streams'][0].update(phase='complete', checkout='/gone/legacy/T1',
            dispatchCounters={'impl': 1, 'review': 1},
            agents={'impl': {'name': 'old-impl', 'dispatchState': 'closed'},
                    'review': {'name': 'old-review', 'dispatchState': 'resolved'}})
        self.write()
        self.assertEqual(fleet.cmd_checkouts(self.args('checkouts', 'check')), 0)
        self.config['streams'][0]['agents']['review']['dispatchState'] = 'active'
        self.write()
        with self.assertRaises(fleet.FleetError):
            fleet.cmd_checkouts(self.args('checkouts', 'check'))

    def test_scan_skips_terminal_history_and_accepts_uncreated_plan_without_writes(self):
        self.config['streams'].append({'ticket': 'L1', 'phase': 'done', 'checkout': '/gone/history'})
        self.write()
        before = self.config_path.read_bytes()
        self.assertEqual(fleet.cmd_checkouts(self.args('checkouts', 'check')), 0)
        self.assertEqual(self.config_path.read_bytes(), before)
        self.assertFalse(self.checkout.exists())


if __name__ == '__main__':
    unittest.main()
