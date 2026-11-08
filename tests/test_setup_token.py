from pathlib import Path
import json
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'install.sh').read_text()


def functions(*names):
    return '\n'.join(re.search(rf'^{name}\(\) \{{.*?^\}}', SCRIPT, re.M | re.S).group() for name in names)


class SetupTokenTest(unittest.TestCase):
    def run_setup(self, directory, mode='generate'):
        return subprocess.run(['bash', '-euo', 'pipefail', '-c',
            functions('env_value', 'set_env_value', 'configure_setup_token') +
            '\nDEPLOY_DIR="$PWD"\nconfigure_setup_token "$1"', 'test', mode],
            cwd=directory, capture_output=True, text=True)

    def test_generation_upgrade_preservation_and_secret_permissions(self):
        for initial in ('', 'YIYI_SETUP_TOKEN=GENERATE_ON_INSTALL\n'):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as directory:
                env = Path(directory) / '.env'
                env.write_text(initial)
                result = self.run_setup(directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                token = (Path(directory) / '.setup-token').read_text().strip()
                self.assertRegex(token, r'^[a-f0-9]{64}$')
                self.assertNotIn(token, result.stdout + result.stderr)
                self.assertEqual(stat.S_IMODE(env.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE((Path(directory) / '.setup-token').stat().st_mode), 0o600)
                original = env.read_text()
                again = self.run_setup(directory)
                self.assertEqual(again.returncode, 0, again.stderr)
                self.assertTrue(env.read_text() == original, 'token changed during upgrade')
                self.assertTrue((Path(directory) / '.setup-token').read_text().strip() == token)

    def test_explicit_empty_closes_setup_without_regenerating(self):
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / '.env'
            env.write_text('YIYI_SETUP_TOKEN=\n')
            (Path(directory) / '.setup-token').write_text('old-test-token')
            result = self.run_setup(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(env.read_text(), 'YIYI_SETUP_TOKEN=\n')
            self.assertFalse((Path(directory) / '.setup-token').exists())

    def test_user_requires_control_configuration_and_never_generates(self):
        for initial in ('', 'YIYI_SETUP_TOKEN=GENERATE_ON_INSTALL\n'):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as directory:
                env = Path(directory) / '.env'
                env.write_text(initial)
                result = self.run_setup(directory, 'require')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(env.read_text(), initial)
                self.assertFalse((Path(directory) / '.setup-token').exists())

    def test_compose_injects_only_into_application_runtime(self):
        command = ['docker-compose'] if shutil.which('docker-compose') else ['docker', 'compose']
        if subprocess.run(command + ['version'], capture_output=True).returncode:
            self.skipTest('Docker Compose unavailable')
        result = subprocess.run(command + ['--env-file', str(ROOT / '.env.example'),
            '-f', str(ROOT / 'compose.yaml'), '--profile', '*', 'config', '--no-interpolate', '--format', 'json'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, 'compose validation failed')
        services = json.loads(result.stdout)['services']
        target = 'yiyi-media' if 'yiyi-media' in services else 'user'
        self.assertIn(target, services)
        for name, service in services.items():
            env = service.get('environment', {})
            if name == target:
                self.assertEqual(env.get('YIYI_SETUP_TOKEN'), '${YIYI_SETUP_TOKEN:-}')
            else:
                self.assertNotIn('YIYI_SETUP_TOKEN', env)

    def test_v3_join_scoping_conflicts_and_disabled_state(self):
        if 'setup_keys=(' not in SCRIPT:
            self.skipTest('multi-host only')
        start = SCRIPT.index('    # MFA 密钥只导入 user')
        block = SCRIPT[start:SCRIPT.index('    cp cluster-relay.crt', start)]
        for role, local, joined, succeeds in (
            ('user', None, 'test-token-one', True),
            ('user', 'GENERATE_ON_INSTALL', 'test-token-one', True),
            ('user', 'test-token-one', 'test-token-one', True),
            ('user', 'test-token-one', 'test-token-two', False),
            ('user', '', '', True),
            ('media', None, 'test-token-one', True),
            ('edge', None, 'test-token-one', True),
        ):
            with self.subTest(role=role, succeeds=succeeds), tempfile.TemporaryDirectory() as directory:
                env = Path(directory) / '.env'
                original = '' if local is None else f'YIYI_SETUP_TOKEN={local}\n'
                env.write_text(original)
                (Path(directory) / 'join.env').write_text(f'YIYI_SETUP_TOKEN={joined}\n')
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c',
                    functions('env_value', 'set_env_value') + '\nrole="$1"\nmfa_keys=(YIYI_MFA_SECRET_KEY YIYI_MFA_SECRET_KEY_PREVIOUS)\n' + block,
                    'test', role], cwd=directory, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds)
                self.assertNotIn(joined or 'never-a-token', result.stdout + result.stderr)
                expected = f'YIYI_SETUP_TOKEN={joined}\n' if role == 'user' and succeeds else original
                self.assertTrue(env.read_text() == expected, 'unexpected token import')
        self.assertIn('"${setup_keys[@]}"', SCRIPT[SCRIPT.index('export_join() {'):])
        self.assertIn('configure_setup_token require', SCRIPT)


if __name__ == '__main__':
    unittest.main()
