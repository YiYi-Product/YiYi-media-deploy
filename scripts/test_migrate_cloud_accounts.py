import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("migrate-cloud-accounts.sh")
MOCK = r'''
DEPLOY_DIR="$TEST_DIR"
data_dir="$TEST_DIR/data"
db_user=yiyi
YIYI_DATABASES=(yiyi_config yiyi_user yiyi_media yiyi_storage)
mkdir -p "$data_dir"
printf 'fixture=true\n' >"$DEPLOY_DIR/.env"
docker() {
  case "$*" in
    *".Image"*) printf 'sha256:%064d\n' 0;;
    *"compose.project"*) echo yiyi;;
    *"compose.service"*) echo yiyi-media;;
  esac
}
compose() {
  printf '%s\n' "$*" >>"$TEST_TRACE"
  case "$*" in
    *"to_regclass('public.t_storage_provider')"*) echo "$TEST_EXISTS";;
    *"to_regclass('yiyi_account_upgrade.state')"*) echo f;;
    *"FROM t_storage_provider WHERE"*) echo 2;;
    *"to_regclass('public.flyway_schema_history')"*) echo t;;
    *"FROM flyway_schema_history"*) echo 539;;
    *"pg_dump"*) [[ "$TEST_FAILURE" != dump ]] || return 1; printf 'synthetic dump\n';;
    *"--entrypoint python3"*) [[ "$TEST_FAILURE" != migration ]] || return 1;;
    *"pg_restore --exit-on-error"*) [[ "$TEST_FAILURE" != restore ]] || return 1; command cat >/dev/null;;
    *"pg_restore --list"*) command cat >/dev/null;;
  esac
  return 0
}
source "$TEST_SCRIPT"
account_upgrade_prepare
if [[ "$TEST_HEALTH_FAILURE" == 1 ]]; then account_upgrade_rollback; exit 1; fi
account_upgrade_commit
'''


class InstallerMigrationTest(unittest.TestCase):
    def run_key_setup(self, key="", credentials="0"):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary, ".env")
            path.write_text("YIYI_CREDENTIAL_MASTER_KEY=" + key + "\n")
            mock = r'''
set -euo pipefail
DEPLOY_DIR="$TEST_DIR"; db_user=yiyi
env_value() { awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/, "");print;exit}' "$1"; }
set_env_value() { printf '%s=%s\n' "$2" "$3" >"$1"; chmod 0600 "$1"; }
docker() { return 1; }
compose() { case "$*" in *to_regclass*) echo t;; *"count(*)"*) echo "$TEST_CREDENTIALS";; *) return 1;; esac; }
source "$TEST_SCRIPT"
account_upgrade_ensure_key
'''
            result = subprocess.run(["bash", "-c", mock], env=dict(os.environ, TEST_DIR=temporary,
                TEST_SCRIPT=str(SCRIPT), TEST_CREDENTIALS=credentials), text=True, capture_output=True)
            return result, path.read_text()

    def test_first_install_generates_valid_key_without_printing_it(self):
        import base64
        result, content = self.run_key_setup()
        self.assertEqual(0, result.returncode)
        key = content.split("=", 1)[1].strip()
        self.assertEqual(32, len(base64.b64decode(key, validate=True)))
        self.assertNotIn(key, result.stdout + result.stderr)

    def test_upgrade_preserves_existing_master_key(self):
        import base64
        fixture = base64.b64encode(bytes(32)).decode()
        result, content = self.run_key_setup(fixture, credentials="1")
        self.assertEqual(0, result.returncode)
        self.assertEqual("YIYI_CREDENTIAL_MASTER_KEY=" + fixture + "\n", content)
        self.assertNotIn(fixture, result.stdout + result.stderr)

    def test_lost_master_key_never_overwrites_existing_encrypted_credentials(self):
        result, content = self.run_key_setup(credentials="1")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("YIYI_CREDENTIAL_MASTER_KEY=\n", content)

    def test_invalid_existing_master_key_is_not_rotated(self):
        result, content = self.run_key_setup("invalid-fixture")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual("YIYI_CREDENTIAL_MASTER_KEY=invalid-fixture\n", content)

    def run_install(self, failure="", exists="t", health=False):
        with tempfile.TemporaryDirectory() as temporary:
            trace = pathlib.Path(temporary, "trace")
            env = dict(os.environ, TEST_DIR=temporary, TEST_TRACE=str(trace), TEST_FAILURE=failure,
                       TEST_EXISTS=exists, TEST_HEALTH_FAILURE="1" if health else "0", TEST_SCRIPT=str(SCRIPT))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", MOCK], env=env, text=True, capture_output=True)
            calls = trace.read_text() if trace.exists() else ""
            pending = pathlib.Path(temporary, ".account-upgrade-backup").exists()
            backups = list(pathlib.Path(temporary, "data").glob("account-upgrade.*"))
            modes = [path.stat().st_mode & 0o777 for directory in backups for path in directory.glob("*.dump")]
            return result, calls, pending, modes

    def test_new_install_does_not_stop_or_dump(self):
        result, calls, pending, _ = self.run_install(exists="f")
        self.assertEqual(0, result.returncode)
        self.assertNotIn("stop yiyi-media", calls)
        self.assertNotIn("pg_dump", calls)
        self.assertFalse(pending)

    def test_success_is_backed_up_before_offline_migration(self):
        result, calls, pending, modes = self.run_install()
        self.assertEqual(0, result.returncode)
        self.assertLess(calls.index("stop yiyi-media"), calls.index("pg_dump"))
        self.assertLess(calls.rindex("pg_dump"), calls.index("--entrypoint python3"))
        self.assertEqual([0o600] * 4, modes)
        self.assertFalse(pending)

    def test_migration_failure_restores_all_databases_and_immutable_old_image(self):
        result, calls, pending, _ = self.run_install(failure="migration")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(4, calls.count("DROP DATABASE IF EXISTS yiyi_"))
        self.assertEqual(4, calls.count("pg_restore --exit-on-error"))
        self.assertIn("rollback.yaml up -d --no-deps --force-recreate --remove-orphans yiyi-media", calls)
        self.assertFalse(pending)

    def test_backup_failure_restarts_old_image_without_partial_restore(self):
        result, calls, _, _ = self.run_install(failure="dump")
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("--entrypoint python3", calls)
        self.assertNotIn("DROP DATABASE", calls)
        self.assertIn("rollback.yaml up", calls)

    def test_failed_restore_keeps_application_stopped_and_checkpoint(self):
        result, calls, pending, _ = self.run_install(failure="restore", health=True)
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("rollback.yaml up", calls)
        self.assertTrue(pending)

    def test_health_failure_also_rolls_back_databases_not_just_image(self):
        result, calls, pending, _ = self.run_install(health=True)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(4, calls.count("pg_restore --exit-on-error"))
        self.assertFalse(pending)


if __name__ == "__main__": unittest.main()
