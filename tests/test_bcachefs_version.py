import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check-bcachefs-version.sh"


class BcachefsVersionTests(unittest.TestCase):
    def run_check(self, mode="--check", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory)
            commands = {
                "apt-get": 'echo "$*" >> "$CALLS"; exit "${APT_STATUS:-0}"',
                "apt-cache": 'printf "  Candidate: %s\\n" "${CANDIDATE:-1:1.39.7}"',
                "dpkg-query": 'printf "%s" "${INSTALLED:-1:1.39.7}"',
                "modinfo": 'echo "${DISK_VERSION:-1.39.7}"',
                "modprobe": 'echo "modprobe $*" >> "$CALLS"',
                "cat": 'echo "${LOADED_VERSION:-1.39.7}"',
                "flock": 'echo "flock $*" >> "$CALLS"; exit "${LOCK_STATUS:-0}"',
                "uname": 'echo "test-kernel"',
            }
            for name, body in commands.items():
                path = bin_dir / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            calls = bin_dir / "calls"
            # macOS has no /run/lock; keep the fixed production lock path and
            # redirect only this test copy to a disposable local file.
            script = bin_dir / "check.sh"
            script.write_text(SCRIPT.read_text().replace(
                "/run/lock/modern-fs-benchmark.lock", str(bin_dir / "storage.lock")))
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                       CALLS=str(calls), **overrides)
            result = subprocess.run(
                ["bash", str(script), mode], env=env,
                text=True, capture_output=True,
            )
            return result, calls.read_text()

    def test_current_packages_and_loaded_module_pass(self):
        result, calls = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("module 1.39.7", result.stdout)
        self.assertIn("APT::Update::Error-Mode=any", calls)
        self.assertNotIn("install", calls)

    def test_stale_packages_fail_before_loading_module(self):
        result, calls = self.run_check(INSTALLED="1:1.39.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("latest APT candidate is 1:1.39.7", result.stderr)
        self.assertNotIn("modprobe", calls)

    def test_old_loaded_module_fails_even_when_packages_are_current(self):
        result, _ = self.run_check(LOADED_VERSION="1.39.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("loaded bcachefs module is 1.39.6", result.stderr)
        self.assertIn("Reboot", result.stderr)

    def test_old_disk_module_fails_before_loading(self):
        result, calls = self.run_check(DISK_VERSION="1.39.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("module on disk is 1.39.6", result.stderr)
        self.assertNotIn("modprobe", calls)

    def test_repository_error_does_not_accept_cached_candidate(self):
        result, calls = self.run_check(APT_STATUS="100")
        self.assertEqual(result.returncode, 100)
        self.assertNotIn("modprobe", calls)

    def test_missing_candidate_fails(self):
        result, _ = self.run_check(CANDIDATE="(none)")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no APT candidate", result.stderr)

    def test_debian_package_revision_is_not_module_version(self):
        result, _ = self.run_check(CANDIDATE="1:1.39.7-1", INSTALLED="1:1.39.7-1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_upgrade_takes_lock_before_updating_packages(self):
        result, calls = self.run_check(mode="--upgrade")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(calls.index("flock"), calls.index("update"))
        self.assertIn("install -y bcachefs-tools bcachefs-kernel-dkms linux-headers-test-kernel", calls)

    def test_upgrade_refuses_busy_storage_without_touching_packages(self):
        result, calls = self.run_check(mode="--upgrade", LOCK_STATUS="1")
        self.assertEqual(result.returncode, 75)
        self.assertIn("storage is busy", result.stderr)
        self.assertNotIn("update", calls)
        self.assertNotIn("install", calls)

    def test_all_sas_runners_check_under_lock_before_device_setup(self):
        for name in ("managed-hardware-runner.sh",
                     "managed-sas-hdd-hybrid-tier-runner.sh",
                     "managed-sas-hdd-three-copy-runner.sh"):
            text = (ROOT / "scripts" / name).read_text()
            self.assertLess(text.index("flock -w"), text.index("check-bcachefs-version.sh"))
            self.assertLess(text.index("check-bcachefs-version.sh"), text.index("require_size()"))
        baseline = (ROOT / "scripts" / "managed-hardware-runner.sh").read_text()
        self.assertIn("$MANAGED_BENCHMARK_PROFILE == sas-hdd", baseline)


if __name__ == "__main__":
    unittest.main()
