import importlib.util
from pathlib import Path
import tempfile
import unittest
import subprocess


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("block_ready", ROOT / "scripts/wait-block-ready.py")
ready = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ready)


class BlockReadyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.sysfs = Path(self.temp.name)
        for name in ("sda1", "sdb1", "md0", "dm-0", "unrelated"):
            for relation in ("slaves", "holders"):
                (self.sysfs / name / relation).mkdir(parents=True)
        (self.sysfs / "sda1/holders/md0").touch()
        (self.sysfs / "sdb1/holders/md0").touch()
        (self.sysfs / "md0/slaves/sda1").touch()
        (self.sysfs / "md0/slaves/sdb1").touch()
        (self.sysfs / "md0/holders/dm-0").touch()
        (self.sysfs / "dm-0/slaves/md0").touch()
        (self.sysfs / "md0/md").mkdir()
        (self.sysfs / "dm-0/dm").mkdir()
        self.md_state()

    def md_state(self, action="idle", degraded="0", state="clean"):
        for key, value in (("sync_action", action), ("degraded", degraded), ("array_state", state)):
            (self.sysfs / "md0/md" / key).write_text(value)

    def inspect(self, status="0 100 linear"):
        return ready.pending_work(["/dev/sda1"], self.sysfs, lambda name: status)

    def test_bidirectional_walk_is_deduplicated_and_scoped(self):
        self.assertEqual(ready.stack_names(["/dev/sda1"], self.sysfs),
                         ["dm-0", "md0", "sda1", "sdb1"])

    def test_clean_md_passes(self):
        self.assertEqual(self.inspect(), [])

    def test_md_background_actions_wait(self):
        for action in ("resync", "recover", "check", "repair", "reshape", "frozen"):
            self.md_state(action=action)
            self.assertIn(f"action={action}", self.inspect()[0])

    def test_degraded_md_does_not_pass(self):
        self.md_state(degraded="1")
        self.assertIn("degraded=1", self.inspect()[0])

    def test_stale_inactive_array_fails_without_wait(self):
        self.md_state(state="inactive")
        with self.assertRaisesRegex(RuntimeError, "stale inactive"):
            self.inspect()

    def test_missing_device_and_unreadable_state_fail(self):
        with self.assertRaisesRegex(RuntimeError, "missing benchmark"):
            ready.stack_names(["/dev/missing"], self.sysfs)
        (self.sysfs / "md0/md/sync_action").unlink()
        with self.assertRaises(OSError):
            self.inspect()

    def test_dm_raid_health_progress_and_action(self):
        self.assertEqual(self.inspect("0 100 raid raid10 4 AAAA 100/100 idle 0 0"), [])
        for health, progress, action in (("AAAA", "1/100", "resync"),
                                          ("AADA", "100/100", "idle"),
                                          ("AAAA", "100/100", "check")):
            self.assertTrue(self.inspect(f"0 100 raid raid10 4 {health} {progress} {action} 0 0"))

    def test_dm_integrity_recalculation(self):
        self.assertEqual(self.inspect("0 100 integrity 0 100 -"), [])
        self.assertEqual(self.inspect("0 100 integrity 0 100 100"), [])
        self.assertIn("recalculation=1/100", self.inspect("0 100 integrity 0 100 1")[0])

    def test_unknown_raid_status_fails_closed(self):
        with self.assertRaises(RuntimeError):
            self.inspect("0 100 raid")

    def test_empty_status_and_integrity_mismatches_fail(self):
        for status in ("", "0 100 integrity 2 100 -"):
            with self.assertRaises(RuntimeError):
                self.inspect(status)

    def test_wait_returns_when_work_finishes(self):
        states = iter([["md0: resync"], []])
        sleeps = []
        ready.wait_ready([], 10, inspect=lambda _: next(states), clock=lambda: 0,
                         sleep=sleeps.append)
        self.assertEqual(sleeps, [2])

    def test_timeout_is_bounded_and_diagnostic(self):
        now = [0]
        def sleep(seconds):
            now[0] += seconds
        with self.assertRaisesRegex(RuntimeError, "within 3s: md0: check"):
            ready.wait_ready([], 3, inspect=lambda _: ["md0: check"],
                             clock=lambda: now[0], sleep=sleep)
        self.assertEqual(now[0], 3)

    def test_check_precedes_counter_snapshot_not_counter_end(self):
        script = (ROOT / "scripts/run-bench.sh").read_text()
        begin = script.split("block_io_begin() {", 1)[1].split("\n}", 1)[0]
        end = script.split("block_io_end() {", 1)[1].split("\n}", 1)[0]
        self.assertLess(begin.index("benchmark_wait_ready"), begin.index("snapshot"))
        self.assertNotIn("benchmark_wait_ready", end)

    def test_regular_md_cleanup_includes_replacement_spares(self):
        log = self.sysfs / "cleanup.log"
        command = f'''
set -eu
source "{ROOT}/scripts/lib/layered.sh"
LAYOUT=md-raid10 MNT=/fake SPARE_DEV=/dev/spare
DEVICES=(/dev/member0 /dev/member1)
SPARE_DEVICES=(/dev/spare /dev/spare2)
umount() {{ return 0; }}
mdadm() {{
  if [[ $1 == --examine ]]; then return 0; fi
  printf '%s\\n' "$*" >>"{log}"
}}
layered_teardown
'''
        result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = log.read_text().splitlines()
        for device in ("/dev/member0", "/dev/member1", "/dev/spare", "/dev/spare2"):
            self.assertIn(f"--zero-superblock {device}", lines)

    def test_failed_spare_superblock_cleanup_propagates_failure(self):
        command = f'''
source "{ROOT}/scripts/lib/layered.sh"
LAYOUT=md-raid10 MNT=/fake SPARE_DEV=/dev/spare
DEVICES=(/dev/member0) SPARE_DEVICES=()
umount() {{ return 0; }}
mdadm() {{
  [[ $1 == --examine ]] && return 0
  [[ $2 != /dev/spare ]]
}}
layered_teardown
'''
        result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
