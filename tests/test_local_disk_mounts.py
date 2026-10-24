import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/configure-local-disks.py"
spec = importlib.util.spec_from_file_location("local_disks", SCRIPT)
local_disks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local_disks)


class LocalDiskMountsTest(unittest.TestCase):
    def test_space_separated_and_quoted_lists_keep_same_paths(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            a, b = Path(directory) / "电影", Path(directory) / "TV"
            a.mkdir(); b.mkdir()
            for raw in (f"{a}  {b}", f'"{a} {b}"', f"'{a} {b}'"):
                with self.subTest(raw=raw):
                    mounts = local_disks.parse_mounts(raw)
                    self.assertEqual([str(a), str(b)], [m["source"] for m in mounts])
                    self.assertEqual([str(a), str(b)], [m["target"] for m in mounts])
                    self.assertTrue(all(not m["read_only"] for m in mounts))
                    self.assertTrue(all(not m["bind"]["create_host_path"] for m in mounts))

    def test_custom_targets_and_read_only_mounts(self):
        with tempfile.TemporaryDirectory() as directory:
            mounts = local_disks.parse_mounts(f"{directory}:/media/movies:ro {directory}:/media/tv:rw")
            self.assertEqual(["/media/movies", "/media/tv"], [m["target"] for m in mounts])
            self.assertEqual([True, False], [m["read_only"] for m in mounts])

    def test_invalid_missing_reserved_and_conflicting_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "not-created"
            for raw in ("/", "relative/path", str(missing), f"{directory}:relative",
                        f"{directory}:/", f"{directory}:/data/storage", f"{directory}://etc/yiyi",
                        f"{directory}:/media:invalid", f"{directory}:/media:ro:rshared",
                        f"{directory}::ro", f"{directory}:/media {directory}:/media",
                        f"{directory}:/media {directory}:/media/child"):
                with self.subTest(raw=raw), self.assertRaises(ValueError):
                    local_disks.parse_mounts(raw)
            self.assertFalse(missing.exists())

    def test_wildcards_and_shell_syntax_are_never_executed_or_expanded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "exists").mkdir()
            marker = root / "must-not-exist"
            for raw in (str(root / "*"), f"$(touch {marker})"):
                result = subprocess.run(["python3", str(SCRIPT), str(root / "override.yaml"), raw],
                                        text=True, capture_output=True)
                self.assertNotEqual(0, result.returncode)
            self.assertFalse(marker.exists())

    def test_generated_file_is_replaced_and_cleared_without_stale_mounts(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "override.yaml"
            for raw, expected in ((f"{directory}:/media", 1), ("", 0)):
                result = subprocess.run(["python3", str(SCRIPT), str(target), raw],
                                        capture_output=True, text=True)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(expected, len(json.loads(target.read_text())["services"]["yiyi-media"]["volumes"]))
            before = target.read_bytes()
            result = subprocess.run(["python3", str(SCRIPT), str(target), "/missing/yiyi-path"],
                                    capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(before, target.read_bytes())

    def test_dollar_characters_are_escaped_for_compose(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "$literal"
            source.mkdir()
            target = Path(directory) / "override.yaml"
            local_disks.write_override(target, local_disks.parse_mounts(f"{source}:/media/$literal"))
            mount = json.loads(target.read_text())["services"]["yiyi-media"]["volumes"][0]
            self.assertIn("$$literal", mount["source"])
            self.assertEqual("/media/$$literal", mount["target"])


if __name__ == "__main__":
    unittest.main()
