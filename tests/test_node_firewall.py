"""Behavior tests with fake firewall commands. Never changes the host firewall."""
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'yiyi-node-firewall.py'
spec = importlib.util.spec_from_file_location('node_firewall', SCRIPT)
fw = importlib.util.module_from_spec(spec)
with patch('sys.dont_write_bytecode', True):
    spec.loader.exec_module(fw)


class Firewall:
    def __init__(self, backend):
        self.backend = backend
        self.ufw = []
        self.rich = set()
        self.commands = []
        self.fail_port = None

    def run(self, args, **kwargs):
        self.commands.append(args)
        code, out = 0, ''
        if args == ['ufw', 'status']:
            out = 'Status: active\n'
        elif args == ['ufw', 'status', 'numbered']:
            out = '\n'.join('[{}] {} ALLOW IN {} # {}'.format(i, str(p)+'/tcp' if p else 'Anywhere', ip, tag)
                            for i, (ip, p, tag) in enumerate(self.ufw, 1))
        elif args[:3] == ['ufw', 'insert', '1']:
            p = int(args[args.index('port') + 1]) if 'port' in args else 0
            if p == self.fail_port:
                code = 2
            else:
                self.ufw.insert(0, (args[args.index('from') + 1], p, args[-1]))
        elif args[:3] == ['ufw', '--force', 'delete']:
            self.ufw.pop(int(args[-1]) - 1)
        elif args == ['firewall-cmd', '--state']:
            out = 'running\n' if self.backend == 'firewalld' else 'not running\n'
            code = 0 if self.backend == 'firewalld' else 252
        elif '--get-zones' in args:
            out = 'public internal\n'
        elif args[0] == 'firewall-cmd':
            key = ('--permanent' in args, args[-2], args[-1].split('=', 1)[1])
            if args[-1].startswith('--query-'):
                code = 0 if key in self.rich else 1
            elif args[-1].startswith('--add-'):
                self.rich.add(key)
            elif args[-1].startswith('--remove-'):
                self.rich.remove(key)
        else:
            raise AssertionError(args)
        return subprocess.CompletedProcess(args, code, out, 'injected failure' if code == 2 else '')


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name) / 'state'
        self.enterContext(patch.object(fw, 'STATE_DIR', root))
        self.enterContext(patch.object(fw, 'STATE_FILE', root / 'state.json'))
        self.enterContext(patch.object(fw.sys, 'platform', 'linux'))
        self.enterContext(patch.object(fw.os, 'geteuid', return_value=0))
        self.enterContext(patch('sys.stdout', new_callable=io.StringIO))

    def use(self, backend):
        fake = Firewall(backend)
        # Expose inactive firewalld as well: must not block active UFW.
        self.enterContext(patch.object(fw.shutil, 'which', side_effect=lambda c: c if c == 'firewall-cmd' or backend == 'ufw' else None))
        self.enterContext(patch.object(fw.subprocess, 'run', side_effect=fake.run))
        return fake

    def test_plan_and_validation(self):
        a = fw.arguments(['--role', 'storage', '--control-ip', '192.0.2.1', '--play-ip', '192.0.2.2', '--play-ip', '192.0.2.2'])
        self.assertEqual([(r['ip'], r['port']) for r in fw.plan(a)], [('192.0.2.1', 18084), ('192.0.2.2', 18084)])
        self.assertEqual(fw.address('2001:db8::1'), '2001:db8::1')
        for bad in ['0.0.0.0', '127.0.0.1', '192.0.2.1/24', '256.1.1.1', 'example.com', '1.2.3.4;reboot']:
            with self.assertRaises(fw.argparse.ArgumentTypeError):
                fw.address(bad)
        with self.assertRaises(SystemExit), patch('sys.stderr', new_callable=io.StringIO):
            fw.arguments(['--role', 'play', '--control-ip', '192.0.2.1', '--node-ip', '192.0.2.2'])

    def test_default_preview_does_not_write_or_mutate(self):
        fake = self.use('ufw')
        fw.main(['--role', 'control', '--node-ip', '192.0.2.2'])
        self.assertFalse(fw.STATE_DIR.exists())
        self.assertEqual(fake.ufw, [])
        self.assertFalse(any('insert' in c or 'delete' in c for c in fake.commands))

    def test_all_ports_ufw_repeat_and_remove_preserves_narrow_rules(self):
        fake = self.use('ufw')
        fake.ufw.append(('192.0.2.1', 18084, 'administrator'))
        args = ['--role', 'storage', '--all-ports', '--peer-ip', '192.0.2.1', '--peer-ip', '192.0.2.2']
        fw.main(args + ['--apply'])
        fw.main(args + ['--apply'])
        self.assertEqual(len(fake.ufw), 3)
        fw.main(args + ['--remove'])
        self.assertEqual(fake.ufw, [('192.0.2.1', 18084, 'administrator')])

    def test_all_ports_firewalld_has_no_port_or_protocol_restriction(self):
        fake = self.use('firewalld')
        args = ['--role', 'play', '--all-ports', '--peer-ip', '192.0.2.1', '--zone', 'public']
        fw.main(args + ['--apply'])
        self.assertEqual(len(fake.rich), 2)
        self.assertTrue(all('port=' not in r[2] and 'protocol=' not in r[2] for r in fake.rich))
        fw.main(args + ['--remove'])
        self.assertFalse(fake.rich)

    def test_ufw_repeat_and_remove_preserve_preexisting_rule(self):
        fake = self.use('ufw')
        fake.ufw.append(('192.0.2.2', 18082, 'admin rule'))
        args = ['--role', 'control', '--node-ip', '192.0.2.2']
        fw.main(args + ['--apply'])
        fw.main(args + ['--apply'])
        self.assertEqual(len(fake.ufw), 3)
        self.assertEqual(len(fw.read_state()), 2)
        fw.main(args + ['--remove'])
        self.assertEqual(fake.ufw, [('192.0.2.2', 18082, 'admin rule')])
        self.assertEqual(fw.read_state(), [])

    def test_failed_apply_rolls_back_only_this_run(self):
        fake = self.use('ufw')
        args = ['--role', 'control', '--node-ip', '192.0.2.2']
        fake.fail_port = 18083
        with self.assertRaises(fw.Error):
            fw.main(args + ['--apply'])
        self.assertEqual(fake.ufw, [])
        self.assertEqual(fw.read_state(), [])

    def test_failed_new_node_preserves_prior_node(self):
        fake = self.use('ufw')
        fw.main(['--role', 'control', '--node-ip', '192.0.2.2', '--apply'])
        before = list(fake.ufw)
        state = fw.read_state()
        fake.fail_port = 18083
        with self.assertRaises(fw.Error):
            fw.main(['--role', 'control', '--node-ip', '192.0.2.3', '--apply'])
        self.assertEqual(fake.ufw, before)
        self.assertEqual(fw.read_state(), state)

    def test_removal_is_scoped_to_selected_node(self):
        fake = self.use('ufw')
        fw.main(['--role', 'storage', '--control-ip', '192.0.2.1', '--play-ip', '192.0.2.2', '--play-ip', '192.0.2.3', '--apply'])
        fw.main(['--role', 'storage', '--play-ip', '192.0.2.2', '--remove'])
        self.assertEqual({(ip, port) for ip, port, _ in fake.ufw}, {('192.0.2.1', 18084), ('192.0.2.3', 18084)})

    def test_ufw_accepts_ipv6_and_ipv4_host_masks(self):
        self.use('ufw')
        out = '[ 1] 19090/tcp ALLOW IN 192.0.2.1/32 # administrator\n[ 2] 19090/tcp (v6) ALLOW IN 2001:db8::1 # ' + fw.tag(dict(role='play', ip='2001:db8::1', port=19090))
        with patch.object(fw, 'run', return_value=subprocess.CompletedProcess([], 0, out, '')):
            self.assertEqual(fw.ufw_matches(dict(role='play', ip='192.0.2.1', port=19090)), [('1', False)])
            self.assertEqual(fw.ufw_matches(dict(role='play', ip='2001:db8::1', port=19090)), [('2', True)])

    def test_firewalld_preserves_existing_runtime_rule_on_remove(self):
        fake = self.use('firewalld')
        args = ['--role', 'play', '--control-ip', '192.0.2.1', '--play-port', '19091', '--zone', 'public']
        a = fw.arguments(args)
        preexisting = (False, '--zone=public', fw.rich_rule(fw.plan(a)[0]))
        fake.rich.add(preexisting)
        fw.main(args + ['--apply'])
        fw.main(args + ['--apply'])
        self.assertEqual(len(fake.rich), 2)
        self.assertEqual(len(fw.read_state()), 1)
        fw.main(args + ['--remove'])
        self.assertEqual(fake.rich, {preexisting})
        self.assertFalse(any('--reload' in c for c in fake.commands))

    def test_firewalld_requires_explicit_zone(self):
        fake = self.use('firewalld')
        with self.assertRaises(fw.Error):
            fw.main(['--role', 'play', '--control-ip', '192.0.2.1', '--apply'])
        self.assertFalse(fake.rich)
        self.assertFalse(fw.STATE_DIR.exists())

    def test_no_active_manager_never_enables_firewall(self):
        self.enterContext(patch.object(fw.shutil, 'which', return_value=None))
        with self.assertRaises(fw.Error):
            fw.main(['--role', 'play', '--control-ip', '192.0.2.1', '--apply'])
        self.assertFalse(fw.STATE_DIR.exists())


if __name__ == '__main__':
    unittest.main()
