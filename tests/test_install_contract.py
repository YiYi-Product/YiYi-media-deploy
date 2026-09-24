from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


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
            line.strip()
            for line in script.splitlines()
            if line.strip().startswith("compose up") and "--force-recreate" in line
        ]

        self.assertEqual(2, len(commands))
        for command in commands:
            self.assertIn("--no-deps", command)
            self.assertTrue(command.endswith(" yiyi-media"))
            self.assertNotIn(" postgres", command)
            self.assertNotIn(" redis", command)


if __name__ == "__main__":
    unittest.main()
