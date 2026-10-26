import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/configure-fuse.py"
spec = importlib.util.spec_from_file_location("configure_fuse", SCRIPT)
fuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fuse)


class FuseTest(unittest.TestCase):
    def test_default_has_no_extra_privileges(self):
        service = fuse.configuration(False, "/mnt/yiyi")["services"]["yiyi-media"]
        self.assertEqual({"environment": {"STORAGE_MOUNT_ENABLED": "false"}}, service)
        for value in ("", "false", '"FALSE"'):
            self.assertFalse(fuse.normalize_enabled(value))
        with self.assertRaises(ValueError):
            fuse.normalize_enabled("yes")

    def resolved(self):
        document = fuse.configuration(True, "/mnt/yiyi")
        document["services"]["yiyi-media"]["devices"] = [
            {"source": "/dev/fuse", "target": "/dev/fuse", "permissions": "rwm"}]
        document["services"]["postgres"] = {}
        document["services"]["redis"] = {}
        return document

    def test_enabled_accepts_only_fuse_permissions(self):
        document = self.resolved()
        fuse.validate(document)
        for field, value in (("privileged", True), ("cap_add", ["SYS_ADMIN", "NET_ADMIN"]),
                             ("devices", [{"source": "/dev/sda", "target": "/dev/sda", "permissions": "rwm"}])):
            bad = copy.deepcopy(document)
            bad["services"]["yiyi-media"][field] = value
            with self.assertRaises(ValueError):
                fuse.validate(bad)
        document["services"]["postgres"]["cap_add"] = ["SYS_ADMIN"]
        with self.assertRaises(ValueError):
            fuse.validate(document)

    def test_disabling_replaces_enabled_override(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "compose.fuse.yaml"
            output.write_text(json.dumps(fuse.configuration(True, "/mnt/yiyi")))
            subprocess.run([sys.executable, str(SCRIPT), str(output), "false", ""], check=True)
            self.assertEqual(fuse.configuration(False, "/mnt/yiyi"), json.loads(output.read_text()))

    @unittest.skipUnless(shutil.which("docker-compose"), "Docker Compose CLI unavailable")
    def test_real_compose_merge_enabled_and_disabled(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fuse.yaml"
            env = {**os.environ, **{key: "test-fixture" for key in (
                "YIYI_DB_PASSWORD", "YIYI_SERVICE_TOKEN", "YIYI_NODE_TOKEN",
                "YIYI_CREDENTIAL_MASTER_KEY", "YIYI_LICENSE_SERVER_URL")}}
            for enabled in (True, False):
                output.write_text(json.dumps(fuse.configuration(enabled, "/mnt/yiyi")))
                result = subprocess.run(["docker-compose", "--env-file", "/dev/null", "-f",
                                         str(ROOT / "compose.yaml"), "-f", str(output),
                                         "config", "--format", "json"], env=env,
                                        text=True, capture_output=True, check=True)
                resolved = json.loads(result.stdout)
                self.assertEqual({"yiyi-media", "postgres", "redis"}, set(resolved["services"]))
                service = resolved["services"]["yiyi-media"]
                self.assertFalse(service.get("privileged", False))
                self.assertIn("no-new-privileges:true", service["security_opt"])
                if enabled:
                    fuse.validate(resolved)
                    self.assertIn("apparmor:unconfined", service["security_opt"])
                else:
                    self.assertFalse(service.get("cap_add"))
                    self.assertFalse(service.get("devices"))
                    self.assertEqual("false", service["environment"]["STORAGE_MOUNT_ENABLED"])

    def test_missing_device_blocks_enable(self):
        with patch.object(fuse.sys, "platform", "linux"), patch.object(fuse.Path, "exists", return_value=False):
            with self.assertRaisesRegex(ValueError, "/dev/fuse"):
                fuse.check_host("/mnt/yiyi")

    def test_private_propagation_blocks_enable(self):
        with patch.object(fuse.sys, "platform", "linux"), \
             patch.object(fuse.Path, "exists", return_value=True), \
             patch.object(fuse.Path, "is_dir", return_value=True), \
             patch.object(fuse.os, "stat") as stat_mock, \
             patch.object(fuse.stat, "S_ISCHR", return_value=True), \
             patch.object(fuse.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "private\n")):
            with self.assertRaisesRegex(ValueError, "shared"):
                fuse.check_host("/mnt/yiyi")


if __name__ == "__main__":
    unittest.main()
