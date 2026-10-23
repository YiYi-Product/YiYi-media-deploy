from pathlib import Path
import base64
import re
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CredentialMasterKeyTest(unittest.TestCase):
    def run_key_setup(self, directory: str, existing=False) -> subprocess.CompletedProcess:
        script = (ROOT / "install.sh").read_text(encoding="utf-8")
        functions = []
        for name in ("env_value", "set_env_value", "configure_credential_master_key"):
            match = re.search(rf"^{name}\(\) \{{.*?^\}}", script, re.M | re.S)
            self.assertIsNotNone(match)
            functions.append(match.group())
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + "\n".join(functions) + f"\npostgres_data_existing={str(existing).lower()}\nconfigure_credential_master_key"],
            cwd=directory, capture_output=True, text=True, check=False,
        )

    def test_missing_blank_and_placeholder_keys_are_initialized_once_without_logging(self) -> None:
        for initial in ("", "YIYI_CREDENTIAL_MASTER_KEY=\n", "YIYI_CREDENTIAL_MASTER_KEY=GENERATE_ON_INSTALL\n"):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                env_file.write_text(initial, encoding="utf-8")
                result = self.run_key_setup(directory)
                self.assertEqual(0, result.returncode, result.stderr)
                content = env_file.read_text(encoding="utf-8")
                value = content.strip().split("=", 1)[1]
                self.assertEqual(32, len(base64.b64decode(value, validate=True)))
                self.assertNotIn(value, result.stdout + result.stderr)
                self.assertEqual(0o600, stat.S_IMODE(env_file.stat().st_mode))
                again = self.run_key_setup(directory)
                self.assertEqual(0, again.returncode, again.stderr)
                self.assertTrue(env_file.read_text(encoding="utf-8") == content, "升级不得更换已生成的密钥")

    def test_existing_valid_key_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            original = "YIYI_CREDENTIAL_MASTER_KEY=" + base64.b64encode(bytes(range(32))).decode() + "\n"
            env_file.write_text(original, encoding="utf-8")
            result = self.run_key_setup(directory)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertTrue(env_file.read_text(encoding="utf-8") == original)
            self.assertEqual("", result.stdout + result.stderr)

    def test_invalid_keys_are_rejected_without_overwriting_or_logging_the_value(self) -> None:
        for value in ("invalid-test-only-key!", base64.b64encode(bytes(48)).decode()):
            with self.subTest(length=len(value)), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                original = "YIYI_CREDENTIAL_MASTER_KEY=" + value + "\n"
                env_file.write_text(original, encoding="utf-8")
                result = self.run_key_setup(directory)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("格式无效", result.stderr)
                self.assertNotIn(value, result.stdout + result.stderr)
                self.assertTrue(env_file.read_text(encoding="utf-8") == original)

    def test_missing_key_with_existing_database_is_deferred_without_generating(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text("", encoding="utf-8")
            result = self.run_key_setup(directory, existing=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("YIYI_CREDENTIAL_MASTER_KEY=GENERATE_ON_INSTALL\n", env_file.read_text())

    def test_install_initializes_key_before_compose_and_passes_it_to_application(self) -> None:
        script = (ROOT / "install.sh").read_text(encoding="utf-8")
        self.assertIn("\nconfigure_credential_master_key\n", script)
        self.assertLess(script.index("\nconfigure_credential_master_key\n"), script.index("\ncompose()"))
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertIn("YIYI_CREDENTIAL_MASTER_KEY: ${YIYI_CREDENTIAL_MASTER_KEY:?", compose)


class InstallContractTest(unittest.TestCase):
    def test_application_is_recreated_after_infrastructure(self) -> None:
        script = (ROOT / "install.sh").read_text(encoding="utf-8")
        infrastructure = "compose up -d postgres redis --wait --wait-timeout 300"
        recreate = (
            "compose up -d --no-deps --force-recreate --wait "
            "--wait-timeout 900 yiyi-media"
        )
        recreate_and_cleanup = (
            "compose up -d --no-deps --force-recreate --remove-orphans --wait "
            "--wait-timeout 900 yiyi-media"
        )

        self.assertIn(infrastructure, script)
        self.assertIn(recreate, script)
        self.assertIn(recreate_and_cleanup, script)
        self.assertLess(script.index(infrastructure), script.index(recreate))

    def test_recreate_is_limited_to_application_container(self) -> None:
        script = (ROOT / "install.sh").read_text(encoding="utf-8")
        commands = [
            command
            for command in re.findall(r"^\s*(?:if ! )?(compose up[^;\n]+)", script, re.M)
            if "--force-recreate" in command
        ]

        self.assertEqual(2, len(commands))
        for command in commands:
            self.assertIn("--no-deps", command)
            self.assertTrue(command.endswith(" yiyi-media"))
            self.assertNotIn(" postgres", command)
            self.assertNotIn(" redis", command)


class PostgresReadinessTest(unittest.TestCase):
    def run_helpers(self, mock: str, command: str):
        script = (ROOT / "install.sh").read_text()
        functions = []
        for name in ("postgres_query", "wait_for_postgres", "ensure_databases"):
            functions.append(re.search(rf"^{name}\(\) \{{.*?^\}}", script, re.M | re.S).group())
        return subprocess.run(["bash", "-euo", "pipefail", "-c",
            "\n".join(functions) + "\n" + mock + "\n" + command], capture_output=True, text=True)

    def test_wait_retries_tcp_query_before_accepting_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "attempts"
            result = self.run_helpers(r'''
compose() {
    [[ "$*" == *"-h 127.0.0.1"* ]] || return 99
    printf x >> "$COUNTER"
    [[ "$(wc -c < "$COUNTER")" -ge 3 ]] || return 1
    echo 1
}
sleep() { :; }
''', f"COUNTER='{counter}'\nwait_for_postgres")
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("xxx", counter.read_text())

    def test_wait_fails_if_tcp_never_becomes_ready(self):
        result = self.run_helpers("compose() { return 1; }\nsleep() { :; }", "wait_for_postgres")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("尚未就绪", result.stderr)

    def test_concurrent_database_creation_is_rechecked(self):
        with tempfile.TemporaryDirectory() as directory:
            flag = Path(directory) / "created"
            result = self.run_helpers(r'''
postgres_query() {
    if [[ "$*" == *"CREATE DATABASE"* ]]; then touch "$FLAG"; return 1; fi
    [[ ! -f "$FLAG" ]] || echo 1
}
YIYI_DATABASES=(yiyi_config)
''', f"FLAG='{flag}'\nensure_databases")
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("数据库已就绪", result.stdout)

    def test_genuine_database_creation_error_is_not_ignored(self):
        result = self.run_helpers(r'''
postgres_query() { [[ "$*" != *"CREATE DATABASE"* ]]; }
YIYI_DATABASES=(yiyi_config)
''', "ensure_databases")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("创建数据库失败", result.stderr)


class ComposePreflightTest(unittest.TestCase):
    def check_large_config(self, unsafe=False):
        script = (ROOT / "install.sh").read_text()
        functions = "\n".join(re.search(rf"^{name}\(\) \{{.*?^\}}", script, re.M | re.S).group()
                              for name in ("env_value", "preflight"))
        variables = ("YIYI_DB_USER YIYI_DB_PASSWORD YIYI_REDIS_PASSWORD YIYI_IMAGE_TAG "
                     "SPRING_DATASOURCE_URL SPRING_DATASOURCE_USERNAME SPRING_DATASOURCE_PASSWORD "
                     "REDIS_HOST REDIS_PORT YIYI_SERVICE_TOKEN YIYI_NODE_TOKEN YIYI_CREDENTIAL_MASTER_KEY "
                     "YIYI_LICENSE_SERVER_URL LOG_DIR").split()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            (root / "config/license-public.runtime.jwk").write_text("test-public-key")
            (root / ".env").write_text("YIYI_SERVER_HOST=localhost\n" +
                                      "".join(key + "=test-fixture\n" for key in variables))
            config = "services:\n  yiyi-media:\n"
            if unsafe:
                config += "    cap_add:\n      - SYS_ADMIN\n"
            config += "    environment:\n      YIYI_DEPLOYMENT_MODE: STANDALONE\n"
            config += "".join("      " + key + ": test-fixture\n" for key in variables)
            config += "      LARGE_TEST_VALUE: " + "x" * 1048576 + "\n"
            (root / "compose-fixture.yaml").write_text(config)
            mock = r'''
EXPECTED_SERVICES="postgres redis yiyi-media"
compose() {
    case "$*" in
        "config -q") return 0;;
        "config --services") printf 'yiyi-media\npostgres\nredis\n';;
        "config") cat compose-fixture.yaml;;
        *) return 1;;
    esac
}
preflight
'''
            return subprocess.run(["bash", "-euo", "pipefail", "-c", functions + "\n" + mock],
                                  cwd=root, capture_output=True, text=True)

    def test_large_valid_compose_does_not_fail_with_sigpipe(self):
        result = self.check_large_config()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout + result.stderr)

    def test_large_compose_still_rejects_capability(self):
        result = self.check_large_config(unsafe=True)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("不允许添加 capability", result.stderr)


if __name__ == "__main__":
    unittest.main()
