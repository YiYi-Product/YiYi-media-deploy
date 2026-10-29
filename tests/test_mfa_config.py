from pathlib import Path
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MfaDeploymentTest(unittest.TestCase):
    def setup_key(self, directory, mode="generate"):
        script = (ROOT / "install.sh").read_text()
        functions = []
        for name in ("env_value", "set_env_value", "configure_mfa_secret_key"):
            match = re.search(rf"^{name}\(\) \{{.*?^\}}", script, re.M | re.S)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        return subprocess.run(["bash", "-euo", "pipefail", "-c",
            "\n".join(functions) + '\nconfigure_mfa_secret_key "$1"', "test", mode],
            cwd=directory, capture_output=True, text=True)

    def test_generate_preserve_validate_and_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text("YIYI_MFA_SECRET_KEY=GENERATE_ON_INSTALL\n")
            result = self.setup_key(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            original = env_file.read_text()
            value = original.split("=", 1)[1].strip()
            self.assertEqual(len(base64.b64decode(value, validate=True)), 32)
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            self.assertEqual(result.stdout, "")
            self.assertNotIn(value, result.stderr)
            result = self.setup_key(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(env_file.read_text() == original, "existing key was replaced")

    def test_invalid_current_or_previous_key_rejected_without_disclosure(self):
        valid = base64.b64encode(os.urandom(32)).decode()
        for current, previous in (("invalid-format", ""), (valid, "invalid-previous")):
            with self.subTest(previous=bool(previous)), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                original = f"YIYI_MFA_SECRET_KEY={current}\nYIYI_MFA_SECRET_KEY_PREVIOUS={previous}\n"
                env_file.write_text(original)
                result = self.setup_key(directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("格式无效", result.stderr)
                self.assertNotIn(current, result.stdout + result.stderr)
                if previous:
                    self.assertNotIn(previous, result.stdout + result.stderr)
                self.assertTrue(env_file.read_text() == original, "invalid key was silently replaced")

    def test_user_mode_never_generates_a_key(self):
        for initial in ("", "YIYI_MFA_SECRET_KEY=GENERATE_ON_INSTALL\n"):
            with tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                env_file.write_text(initial)
                result = self.setup_key(directory, "require")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("user 角色缺少 MFA 密钥", result.stderr)
                self.assertTrue(env_file.read_text() == initial)

    def test_compose_explicitly_injects_keys_only_into_user_runtime(self):
        if shutil.which("docker-compose"):
            command = ["docker-compose"]
        elif shutil.which("docker") and subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0:
            command = ["docker", "compose"]
        else:
            self.skipTest("docker compose is unavailable")
        result = subprocess.run(command + ["--env-file", str(ROOT / ".env.example"),
            "-f", str(ROOT / "compose.yaml"), "config", "--no-interpolate", "--format", "json"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, "compose config failed")
        services = json.loads(result.stdout)["services"]
        target = "yiyi-media" if "yiyi-media" in services else "user"
        for name, service in services.items():
            environment = service.get("environment", {})
            for key in ("YIYI_MFA_SECRET_KEY", "YIYI_MFA_SECRET_KEY_PREVIOUS"):
                if name == target:
                    self.assertEqual(environment.get(key), "${" + key + ":-}")
                else:
                    self.assertNotIn(key, environment, name)

    def test_multihost_join_import_is_scoped_and_preserves_existing_keys(self):
        script = (ROOT / "install.sh").read_text()
        if 'mfa_keys=(' not in script:
            self.skipTest("only applicable to multi-host deployment")
        functions = "\n".join(re.search(rf"^{name}\(\) \{{.*?^\}}", script, re.M | re.S).group()
            for name in ("env_value", "set_env_value"))
        start = script.index('    # MFA 密钥只导入 user')
        end = script.index('    cp cluster-relay.crt', start)
        block = script[start:end]
        key1 = base64.b64encode(os.urandom(32)).decode()
        key2 = base64.b64encode(os.urandom(32)).decode()
        for role, local, joined, succeeds in (
            ("user", "GENERATE_ON_INSTALL", key1, True),
            ("user", key1, key1, True),
            ("user", key1, key2, False),
            ("media", "GENERATE_ON_INSTALL", key1, True),
            ("edge", "GENERATE_ON_INSTALL", key1, True),
        ):
            with self.subTest(role=role, succeeds=succeeds), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                original = f"YIYI_MFA_SECRET_KEY={local}\n"
                env_file.write_text(original)
                (Path(directory) / "join.env").write_text(f"YIYI_MFA_SECRET_KEY={joined}\nYIYI_MFA_SECRET_KEY_PREVIOUS=\n")
                result = subprocess.run(["bash", "-euo", "pipefail", "-c", functions +
                    '\nrole="$1"\nmfa_keys=(YIYI_MFA_SECRET_KEY YIYI_MFA_SECRET_KEY_PREVIOUS)\n' + block,
                    "test", role], cwd=directory, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds)
                self.assertNotIn(key1, result.stdout + result.stderr)
                self.assertNotIn(key2, result.stdout + result.stderr)
                if role != "user" or not succeeds:
                    self.assertTrue(env_file.read_text() == original)
                else:
                    self.assertTrue(f"YIYI_MFA_SECRET_KEY={joined}\n" in env_file.read_text())
        self.assertIn('"${mfa_keys[@]}"; do', script[script.index("export_join() {"):])
        self.assertIn('configure_mfa_secret_key require', script)


if __name__ == "__main__":
    unittest.main()
