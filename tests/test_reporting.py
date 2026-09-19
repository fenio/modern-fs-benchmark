import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FLAKE = ROOT / "flake.nix"
NIXOS_MODULE = ROOT / "nix" / "module.nix"
FIXTURE_RUNS = ROOT / "tests" / "fixtures" / "runs"
DASHBOARD = ROOT / "scripts" / "make-dashboard.py"
AUDIT = ROOT / "scripts" / "audit-results.py"
SCHEMA = ROOT / "scripts" / "result-schema.json"
VALIDATOR = ROOT / "scripts" / "validate-result.py"
RUN_BENCH = ROOT / "scripts" / "run-bench.sh"
SUMMARIZE = ROOT / "scripts" / "summarize.sh"
MANAGED_HARDWARE_RUNNER = ROOT / "scripts" / "managed-hardware-runner.sh"
XFS_BACKEND = ROOT / "scripts" / "fs" / "xfs.sh"
ZFS_BACKEND = ROOT / "scripts" / "fs" / "zfs.sh"
BCACHEFS_BACKEND = ROOT / "scripts" / "fs" / "bcachefs.sh"
BCACHEFS_DEBUG = ROOT / "scripts" / "lib" / "bcachefs-debug.sh"
BCACHEFS_REPRO = ROOT / "scripts" / "repro-bcachefs-ec-evacuate.sh"
BENCH_WORKFLOW = ROOT / ".github" / "workflows" / "bench.yml"
HARDWARE_BENCH_WORKFLOW = (
    ROOT / ".github" / "workflows" / "bench-real-hw.yml"
)
SAS_HDD_BENCH_WORKFLOW = (
    ROOT / ".github" / "workflows" / "bench-real-hw-sas-hdd.yml"
)
HYBRID_TIER_WORKFLOW = (
    ROOT / ".github" / "workflows" / "bench-real-hw-sas-hdd-hybrid-tier.yml"
)
PAGES_WORKFLOW = ROOT / ".github" / "workflows" / "publish-pages.yml"
BCACHEFS_REPRO_WORKFLOW = (
    ROOT / ".github" / "workflows" / "repro-bcachefs-ec.yml"
)

METRIC_CONTRACT = [
    ("seqwrite_mbps", "Sequential write", "MB/s", "higher"),
    ("randwrite_iops", "Random write, 4k + fsync", "IOPS", "higher"),
    ("randwrite4_iops", "Random write, 4 threads", "IOPS", "higher"),
    ("fsync_p99_ms", "fsync p99 latency", "ms", "lower"),
    ("fsync_p999_ms", "fsync p99.9 latency", "ms", "lower"),
    ("randread_iops", "Random read, 4k cold cache", "IOPS", "higher"),
    ("randread4_iops", "Random read, 4 threads", "IOPS", "higher"),
    ("seqread_mbps", "Sequential read", "MB/s", "higher"),
    ("lat_idle_p99_ms", "Trivial-op p99, idle", "ms", "lower"),
    ("lat_load_p99_ms", "Trivial-op p99 under streaming write", "ms", "lower"),
    ("lat_load_max_ms", "Trivial-op worst case under load", "ms", "lower"),
    ("lat_load_ops", "Trivial ops completed under load", "ops", "higher"),
    ("smalltree_create_ms", "Create 20k-file tree", "ms", "lower"),
    ("smalltree_create4_ms", "Create 20k-file tree, 4 workers", "ms", "lower"),
    ("smalltree_cp_ms", "cp -r 20k-file tree, cold", "ms", "lower"),
    ("smalltree_rm_ms", "rm -rf 20k-file tree", "ms", "lower"),
    ("sparse_create_ms", "ftruncate empty file to 1G", "ms", "lower"),
    ("sparse_create_bytes", "Bytes allocated for sparse 1G", "B", "lower"),
    ("sparse_grow_ms", "ftruncate 256M file to 512M", "ms", "lower"),
    ("largedir_create_ms", "Create 100k files in one directory", "ms", "lower"),
    ("largedir_readdir_cold_ms", "Enumerate 100k names, cold", "ms", "lower"),
    ("largedir_stat_cold_ms", "Stat 100k files, cold", "ms", "lower"),
    ("largedir_stat_warm_ms", "Stat 100k files, warm", "ms", "lower"),
    ("largedir_delete_ms", "Delete 100k-file directory", "ms", "lower"),
    ("snapshot_create_ms", "Snapshot create", "ms", "lower"),
    ("snapshot_delete_ms", "Snapshot delete (all)", "ms", "lower"),
    ("reclaim_s", "Space reclaim after delete", "s", "lower"),
    ("reclaim_write_mbps", "Write during reclaim", "MB/s", "higher"),
    ("compress_ratio", "zstd compression ratio", "x", "higher"),
    ("compress_write_mbps", "Compressible-data write", "MB/s", "higher"),
    ("reflink_ms", "Reflink copy of 2G", "ms", "lower"),
    ("divergence_plain_mbps", "Overwrite plain file", "MB/s", "higher"),
    ("divergence_clone_mbps", "Overwrite fresh reflink clone", "MB/s", "higher"),
    ("divergence_snap_mbps", "Overwrite freshly-snapshotted file", "MB/s", "higher"),
    ("degraded_randwrite_iops", "Degraded random write", "IOPS", "higher"),
    ("degraded_randread_iops", "Degraded random read", "IOPS", "higher"),
    ("rebuild_s", "Rebuild after device loss", "s", "lower"),
    ("scrub_s", "Scrub after corruption", "s", "lower"),
    ("nearfull95_write_mbps", "Write near full (95% target)", "MB/s", "higher"),
    ("nearfull99_write_mbps", "Write near full (99% target)", "MB/s", "higher"),
    ("snapscale_create_ms", "Snapshot create at 500 snaps", "ms", "lower"),
    ("snapscale_remount_ms", "Remount with 500 snaps", "ms", "lower"),
    ("snapscale_delete_ms", "Delete 500 snapshots", "ms", "lower"),
]

HARDWARE_METRIC_CONTRACT = [
    ("randwrite8_iops", "Random write, 8 workers", "IOPS", "higher"),
    ("randwrite16_iops", "Random write, 16 workers", "IOPS", "higher"),
    (
        "randwrite4_sharded_iops",
        "Random write, 4 shard-aware workers",
        "IOPS",
        "higher",
    ),
    (
        "randwrite8_sharded_iops",
        "Random write, 8 shard-aware workers",
        "IOPS",
        "higher",
    ),
    (
        "randwrite16_sharded_iops",
        "Random write, 16 shard-aware workers",
        "IOPS",
        "higher",
    ),
    ("randread8_iops", "Random read, 8 workers", "IOPS", "higher"),
    ("randread16_iops", "Random read, 16 workers", "IOPS", "higher"),
]


def run_script(script, *args):
    return subprocess.run(
        [sys.executable, str(script), *(str(arg) for arg in args)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def run_audit(runs):
    return run_script(AUDIT, "--allow-partial", runs)


def run_benchmark_shell(source, *args):
    return subprocess.run(
        ["bash", "-c", f'source "$1"\n{source}', "bash", str(RUN_BENCH), *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def dashboard_data(html):
    prefix = "const DATA = "
    suffix = ";\nconst SLOTS = "
    start = html.index(prefix) + len(prefix)
    end = html.index(suffix, start)
    return json.loads(html[start:end])


class DashboardRegressionTests(unittest.TestCase):
    def test_generated_dashboard_preserves_current_data_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "index.html"
            result = run_script(
                DASHBOARD,
                "--runs",
                FIXTURE_RUNS,
                "--out",
                output,
                "--repo",
                "https://example.test/fsbench",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("wrote", result.stdout)
            html = output.read_text()
            data = dashboard_data(html)

        self.assertEqual(data["latest"]["date"], "2026-07-16T10:02:00Z")
        self.assertEqual(data["latest"]["kernel"], "6.18.0-fixture")
        self.assertEqual(data["runCount"], 2)
        self.assertEqual(data["stale"], ["ext4/single", "zfs/mirror"])
        self.assertEqual(
            [entity["id"] for entity in data["entities"]],
            [
                "ext4/single",
                "xfs/zvol",
                "zfs/mirror",
                "btrfs/raid1",
                "bcachefs/replicas2",
            ],
        )
        self.assertEqual(
            data["metrics"],
            [
                {"key": key, "label": label, "unit": unit, "better": better}
                for key, label, unit, better in METRIC_CONTRACT
            ],
        )
        latest = data["latest"]["results"]
        self.assertEqual(latest["ext4/single"]["seqwrite_mbps"], 510.2)
        self.assertEqual(latest["btrfs/raid1"]["aging_mbps"], [42.0, 39.5, 37.0])
        self.assertIsNone(latest["zfs/mirror"]["reflink_ms"])
        self.assertIsNone(latest["bcachefs/replicas2"]["scrub_found"])
        self.assertEqual(
            latest["bcachefs/replicas2"]["calibration"],
            {"seqwrite_mbps": 404.0, "randwrite_iops": 14300.0},
        )
        self.assertEqual(
            latest["bcachefs/replicas2"]["version"],
            "tools 1.38.1 / module 1.38.1",
        )
        self.assertEqual(data["repo"], "https://example.test/fsbench")
        self.assertIsNone(data["hardwareProfile"])
        self.assertIsNone(data["benchmarkScenario"])
        self.assertEqual(data["setupDetails"], [])
        self.assertEqual(data["historyBranch"], "results-data")
        self.assertIn('href="https://github.com/nasty-project/nasty"', html)
        for legacy_section in (
            "Latest run",
            "Snapshot aging",
            "Trends across runs",
            "Table view",
        ):
            self.assertIn(legacy_section, html)
        self.assertIn("Summary indices", html)
        self.assertIn("content.appendChild(buildScoreSummary(view));", html)
        self.assertIn("select a score", html)
        self.assertIn("to expand its normalized contributions", html)
        self.assertIn('class: "index-sort"', html)
        self.assertIn("let indexSortCol = null", html)
        self.assertIn('class: "index-detail-row"', html)
        self.assertIn('"aria-expanded": "false"', html)
        self.assertIn(
            "all detailed dashboard views remain available below",
            html,
        )
        self.assertLess(
            html.index("content.appendChild(buildScoreSummary(view));"),
            html.index('content.appendChild(el("h2", {}, "Latest run"));'),
        )
        self.assertIn("Explore trends", html)
        self.assertIn("content.appendChild(buildExplorer(view));", html)
        self.assertIn(
            "https://cdn.jsdelivr.net/npm/echarts@6.0.0/dist/echarts.min.js",
            html,
        )
        self.assertNotIn(
            '<script src="https://cdn.jsdelivr.net/npm/echarts',
            html,
        )
        self.assertIn("rebuild();\nloadExplorerLibrary();", html)
        self.assertIn(
            "sha384-F07Cpw5v8spSU0H113F33m2NQQ/o6GqPTnTjf45ssG4Q6q58ZwhxBiQtIaqvnSpR",
            html,
        )
        self.assertIn(
            "the existing dashboard charts are unaffected",
            html,
        )
        self.assertEqual(
            [
                run["results"].get("ext4/single", {}).get("seqwrite_mbps")
                for run in data["runs"]
            ],
            [510.2, None],
        )
        self.assertEqual(
            [
                run["results"].get("btrfs/raid1", {}).get("seqwrite_mbps")
                for run in data["runs"]
            ],
            [None, 360.0],
        )

    def test_dashboard_distinguishes_runs_from_compacted_trend_points(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            runs = tmp / "runs"
            shutil.copytree(FIXTURE_RUNS / "100", runs / "100")
            shutil.copytree(FIXTURE_RUNS / "100", runs / "101")
            shutil.copytree(FIXTURE_RUNS / "101", runs / "102")
            output = tmp / "index.html"

            result = run_script(
                DASHBOARD,
                "--runs",
                runs,
                "--out",
                output,
                "--window",
                1,
            )
            data = dashboard_data(output.read_text())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["runCount"], 3)
        self.assertEqual(len(data["runs"]), 2)
        self.assertTrue(data["runs"][0]["agg"])

    def test_dashboard_only_exposes_hardware_metrics_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            runs = tmp / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_path = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_path.read_text())
            for index, (key, _label, _unit, _better) in enumerate(
                HARDWARE_METRIC_CONTRACT, start=1
            ):
                document["results"][key] = index * 1000
            result_path.write_text(json.dumps(document))
            output = tmp / "index.html"

            result = run_script(DASHBOARD, "--runs", runs, "--out", output)
            data = dashboard_data(output.read_text())

        self.assertEqual(result.returncode, 0, result.stderr)
        hardware_metrics = [
            (metric["key"], metric["label"], metric["unit"], metric["better"])
            for metric in data["metrics"]
            if metric["key"] in {item[0] for item in HARDWARE_METRIC_CONTRACT}
        ]
        self.assertEqual(hardware_metrics, HARDWARE_METRIC_CONTRACT)

    def test_dashboard_allows_missing_legacy_profile_but_rejects_conflicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            output = Path(tmp) / "index.html"
            shutil.copytree(FIXTURE_RUNS, runs)
            args = (
                "--runs",
                runs,
                "--out",
                output,
                "--hardware-profile",
                "farm3",
                "--expected-hardware-profile",
                "farm3",
                "--allow-missing-hardware-profile",
            )

            legacy = run_script(DASHBOARD, *args)
            legacy_data = dashboard_data(output.read_text())
            conflicting_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(conflicting_file.read_text())
            document["hardware_profile"] = "sas-hdd"
            conflicting_file.write_text(json.dumps(document))
            conflicting = run_script(DASHBOARD, *args)

        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertEqual(legacy_data["hardwareProfile"], "farm3")
        self.assertEqual(conflicting.returncode, 1)
        self.assertIn(
            "hardware_profile must be 'farm3', got 'sas-hdd'", conflicting.stderr
        )

    def test_dashboard_validates_and_displays_benchmark_scenario(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            output = Path(tmp) / "index.html"
            shutil.copytree(FIXTURE_RUNS, runs)
            for result_file in runs.glob("*/*.json"):
                document = json.loads(result_file.read_text())
                document["benchmark_scenario"] = "hybrid-isolated"
                result_file.write_text(json.dumps(document))

            accepted = run_script(
                DASHBOARD,
                "--runs",
                runs,
                "--out",
                output,
                "--expected-benchmark-scenario",
                "hybrid-isolated",
            )
            html = output.read_text()
            data = dashboard_data(html)
            conflicting_file = runs / "100" / "result-ext4-single.json"
            document = json.loads(conflicting_file.read_text())
            document["benchmark_scenario"] = "other"
            conflicting_file.write_text(json.dumps(document))
            rejected = run_script(
                DASHBOARD,
                "--runs",
                runs,
                "--out",
                output,
                "--expected-benchmark-scenario",
                "hybrid-isolated",
            )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(data["benchmarkScenario"], "hybrid-isolated")
        self.assertIn(
            '(DATA.benchmarkScenario ? ` · ${DATA.benchmarkScenario}` : "")',
            html,
        )
        self.assertIn("Benchmark scenario: ${DATA.benchmarkScenario}.", html)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn(
            "benchmark_scenario must be 'hybrid-isolated', got 'other'",
            rejected.stderr,
        )

    def test_dashboard_displays_explicit_test_setup(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "index.html"
            result = run_script(
                DASHBOARD,
                "--runs",
                FIXTURE_RUNS,
                "--out",
                output,
                "--setup-detail",
                "Physical media=Six SAS HDDs",
                "--setup-detail",
                "Topology=Four members plus one rebuild spare",
            )
            html = output.read_text()
            data = dashboard_data(html)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            data["setupDetails"],
            [
                {"label": "Physical media", "value": "Six SAS HDDs"},
                {
                    "label": "Topology",
                    "value": "Four members plus one rebuild spare",
                },
            ],
        )
        self.assertIn('setup.appendChild(el("h2", {}, "Test setup"));', html)
        self.assertIn("description.textContent = detail.value", html)


class AuditRegressionTests(unittest.TestCase):
    def test_representative_history_has_no_anomalies(self):
        result = run_audit(FIXTURE_RUNS)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("audited 2 runs, 3 entities in latest", result.stdout)
        self.assertIn("no anomalies found", result.stdout)

    def test_integrity_failure_is_a_hard_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["results"]["data_intact"] = False
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn("## HARD anomalies", result.stdout)
        self.assertIn(
            "btrfs/raid1: data NOT intact after scrub — self-healing failed",
            result.stdout,
        )

    def test_fiemap_null_is_expected_without_reflink_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            for name in ("result-ext4-single.json", "result-zfs-mirror.json"):
                shutil.copy2(runs / "100" / name, runs / "101" / name)

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("audited 2 runs, 5 entities in latest", result.stdout)
        self.assertIn("no anomalies found", result.stdout)

    def test_fiemap_null_is_rejected_with_reflink_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-xfs-zvol.json"
            document = json.loads(result_file.read_text())
            document["results"]["reflink_fiemap_shared"] = None
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "xfs/zvol.reflink_fiemap_shared: unexpectedly null",
            result.stdout,
        )

    def test_reflink_null_is_rejected_for_current_zfs_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-zfs-mirror.json"
            shutil.copy2(runs / "100" / result_file.name, result_file)
            document = json.loads(result_file.read_text())
            document["schema_version"] = 5
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn("zfs/mirror.reflink_ms: unexpectedly null", result.stdout)

    def test_missing_latest_metric_is_a_hard_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            del document["results"]["sparse_grow_bytes"]
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "btrfs/raid1: schema document.results: missing metrics: "
            "sparse_grow_bytes",
            result.stdout,
        )

    def test_wrong_latest_metric_type_is_a_hard_anomaly(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["results"]["seqwrite_mbps"] = "fast"
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "btrfs/raid1: schema document.results.seqwrite_mbps: "
            "expected number, got str",
            result.stdout,
        )

    def test_historical_documents_are_not_forced_through_current_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "100" / "result-ext4-single.json"
            document = json.loads(result_file.read_text())
            del document["results"]["sparse_grow_bytes"]
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no anomalies found", result.stdout)

    def test_incomplete_latest_matrix_is_a_hard_anomaly(self):
        result = run_script(AUDIT, FIXTURE_RUNS)

        self.assertEqual(result.returncode, 1)
        self.assertIn("latest run missing configurations:", result.stdout)

    def test_real_hardware_allows_skipped_enospc_and_degraded_phases(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["devices"] = "/dev/sdb /dev/sdc /dev/sdd /dev/sde"
            for key in (
                "degraded_randwrite_iops",
                "degraded_randread_iops",
                "rebuild_s",
                "nearfull95_write_mbps",
                "nearfull99_write_mbps",
                "nearfull95_pct",
                "nearfull99_pct",
                "enospc_delete_ok",
                "enospc_recover_ok",
            ):
                document["results"][key] = None
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no anomalies found", result.stdout)

    def test_reclaim_timeout_reports_restored_space(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["results"]["reclaim_s"] = None
            document["results"]["reclaim_free_pct"] = 82.4
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "btrfs/raid1: reclaim did not finish within 300s; "
            "82.4% restored, target 85%",
            result.stdout,
        )

    def test_schema_v3_reclaim_timeout_uses_80_percent_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            result_file = runs / "101" / "result-btrfs-raid1.json"
            document = json.loads(result_file.read_text())
            document["schema_version"] = 3
            document["results"]["reclaim_s"] = None
            document["results"]["reclaim_free_pct"] = 78.4
            result_file.write_text(json.dumps(document))

            result = run_audit(runs)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "btrfs/raid1: reclaim did not finish within 300s; "
            "78.4% restored, target 80%",
            result.stdout,
        )

    def test_expected_scenario_and_configuration_set_are_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = Path(tmp) / "runs"
            shutil.copytree(FIXTURE_RUNS, runs)
            for result_file in runs.glob("*/*.json"):
                document = json.loads(result_file.read_text())
                document["benchmark_scenario"] = "hybrid-isolated"
                result_file.write_text(json.dumps(document))
            entities = [
                "btrfs/raid1",
                "bcachefs/replicas2",
                "xfs/zvol",
            ]
            configuration_args = [
                item
                for entity in entities
                for item in ("--expected-configuration", entity)
            ]

            accepted = run_script(
                AUDIT,
                "--expected-benchmark-scenario",
                "hybrid-isolated",
                *configuration_args,
                runs,
            )
            missing = run_script(
                AUDIT,
                "--expected-benchmark-scenario",
                "hybrid-isolated",
                *configuration_args,
                "--expected-configuration",
                "ext4/single",
                runs,
            )
            conflicting_file = runs / "100" / "result-ext4-single.json"
            document = json.loads(conflicting_file.read_text())
            document["benchmark_scenario"] = "other"
            conflicting_file.write_text(json.dumps(document))
            rejected = run_script(
                AUDIT,
                "--allow-partial",
                "--expected-benchmark-scenario",
                "hybrid-isolated",
                runs,
            )

        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
        self.assertIn("no anomalies found", accepted.stdout)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("latest run missing configurations: ext4/single", missing.stdout)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn(
            "benchmark_scenario must be 'hybrid-isolated', got 'other'",
            rejected.stderr,
        )


class ResultSchemaTests(unittest.TestCase):
    def write_complete_result_set(self, directory):
        configurations = json.loads(SCHEMA.read_text())["configurations"]
        template = json.loads(
            (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
        )
        paths = []
        for entity in configurations:
            fs, layout = entity.split("/", 1)
            document = template.copy()
            document["fs"] = fs
            document["layout"] = layout
            path = Path(directory) / f"result-{fs}-{layout}.json"
            path.write_text(json.dumps(document))
            paths.append(path)
        return paths

    def test_manifest_preserves_dashboard_metric_contract(self):
        schema = json.loads(SCHEMA.read_text())
        metrics = schema["metrics"]

        self.assertEqual(schema["schema_version"], 5)
        self.assertEqual(
            [
                (metric["key"], metric["label"], metric["unit"], metric["better"])
                for metric in metrics
                if metric["display"] == "card"
            ],
            METRIC_CONTRACT[:3]
            + HARDWARE_METRIC_CONTRACT[:5]
            + METRIC_CONTRACT[3:7]
            + HARDWARE_METRIC_CONTRACT[5:]
            + METRIC_CONTRACT[7:],
        )
        self.assertEqual(len({metric["key"] for metric in metrics}), len(metrics))
        optional = {
            metric["key"]
            for metric in metrics
            if not metric.get("required", True)
        }
        self.assertEqual(optional, {metric[0] for metric in HARDWARE_METRIC_CONTRACT})
        dashboard = DASHBOARD.read_text()
        score_model = dashboard[
            dashboard.index("const SCORE_MODEL") : dashboard.index("const scoreMetric")
        ]
        for key, _label, _unit, _better in HARDWARE_METRIC_CONTRACT:
            self.assertNotIn(key, score_model)

    def test_scenario_and_topology_are_optional_nonempty_strings(self):
        schema = json.loads(SCHEMA.read_text())

        for key in ("benchmark_scenario", "topology"):
            self.assertEqual(
                schema["document"][key],
                {"type": "string", "nonempty": True, "required": False},
            )
        result = run_script(
            VALIDATOR,
            FIXTURE_RUNS / "101" / "result-btrfs-raid1.json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_configurations_match_benchmark_matrix(self):
        schema = json.loads(SCHEMA.read_text())
        matrix = re.findall(
            r"^\s+- fs: (\S+)\n\s+layout: (\S+)",
            BENCH_WORKFLOW.read_text(),
            re.MULTILINE,
        )

        self.assertEqual(
            list(schema["configurations"]),
            [f"{fs}/{layout}" for fs, layout in matrix],
        )

    def test_nullable_metrics_declare_capability_or_special_handling(self):
        schema = json.loads(SCHEMA.read_text())
        unscoped = [
            metric["key"]
            for metric in schema["metrics"]
            if metric.get("nullable") and "capability" not in metric
        ]

        self.assertEqual(unscoped, ["lat_load_p99_ms", "lat_load_max_ms"])

    def test_configuration_capabilities_are_known_and_unique(self):
        schema = json.loads(SCHEMA.read_text())
        metric_capabilities = {
            metric["capability"]
            for metric in schema["metrics"]
            if "capability" in metric
        }
        configured_capabilities = {
            capability
            for capabilities in schema["configurations"].values()
            for capability in capabilities
        }

        self.assertEqual(configured_capabilities, metric_capabilities)
        for capabilities in schema["configurations"].values():
            self.assertEqual(len(capabilities), len(set(capabilities)))

    def test_all_representative_results_validate(self):
        fixtures = sorted(FIXTURE_RUNS.glob("*/*.json"))
        result = run_script(VALIDATOR, *fixtures)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("validated 5 result file(s)", result.stdout)

    def test_complete_result_set_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.write_complete_result_set(tmp)

            result = run_script(VALIDATOR, "--complete-set", *paths)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"validated {len(paths)} result file(s) as a complete matrix",
            result.stdout,
        )

    def test_incomplete_result_set_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.write_complete_result_set(tmp)
            missing = paths.pop()
            missing_document = json.loads(missing.read_text())
            missing_entity = (
                f"{missing_document['fs']}/{missing_document['layout']}"
            )
            missing.unlink()

            result = run_script(VALIDATOR, "--complete-set", *paths)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"result set missing configurations: {missing_entity}",
            result.stderr,
        )

    def test_duplicate_result_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = self.write_complete_result_set(tmp)
            duplicate = Path(tmp) / "duplicate.json"
            shutil.copy2(paths[0], duplicate)

            result = run_script(VALIDATOR, "--complete-set", *paths, duplicate)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "result set has duplicate configurations: ext4/single",
            result.stderr,
        )

    def test_expected_hardware_profile_is_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            document["hardware_profile"] = "sas-hdd"
            result_file.write_text(json.dumps(document))

            accepted = run_script(
                VALIDATOR,
                "--expected-hardware-profile",
                "sas-hdd",
                result_file,
            )
            rejected = run_script(
                VALIDATOR,
                "--expected-hardware-profile",
                "farm3",
                result_file,
            )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn(
            "hardware_profile must be 'farm3', got 'sas-hdd'", rejected.stderr
        )

    def test_expected_benchmark_scenario_is_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            document["benchmark_scenario"] = "hybrid-isolated"
            result_file.write_text(json.dumps(document))

            accepted = run_script(
                VALIDATOR,
                "--expected-benchmark-scenario",
                "hybrid-isolated",
                result_file,
            )
            rejected = run_script(
                VALIDATOR,
                "--expected-benchmark-scenario",
                "other",
                result_file,
            )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(rejected.returncode, 1)
        self.assertIn(
            "benchmark_scenario must be 'other', got 'hybrid-isolated'",
            rejected.stderr,
        )

    def test_explicit_three_configuration_complete_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for fixture in sorted((FIXTURE_RUNS / "101").glob("*.json")):
                path = Path(tmp) / fixture.name
                shutil.copy2(fixture, path)
                paths.append(path)
            documents = [json.loads(path.read_text()) for path in paths]
            entities = [f"{doc['fs']}/{doc['layout']}" for doc in documents]
            configuration_args = [
                item
                for entity in entities
                for item in ("--expected-configuration", entity)
            ]

            accepted = run_script(
                VALIDATOR,
                "--complete-set",
                *configuration_args,
                *paths,
            )
            missing = run_script(
                VALIDATOR,
                "--complete-set",
                *configuration_args,
                *paths[:-1],
            )
            unexpected_path = Path(tmp) / "unexpected.json"
            unexpected_document = documents[0].copy()
            unexpected_document["fs"] = "ext4"
            unexpected_document["layout"] = "single"
            unexpected_path.write_text(json.dumps(unexpected_document))
            unexpected = run_script(
                VALIDATOR,
                "--complete-set",
                *configuration_args,
                *paths,
                unexpected_path,
            )
            duplicate_path = Path(tmp) / "duplicate.json"
            shutil.copy2(paths[0], duplicate_path)
            duplicate = run_script(
                VALIDATOR,
                "--complete-set",
                *configuration_args,
                *paths,
                duplicate_path,
            )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(missing.returncode, 1)
        self.assertIn(
            f"result set missing configurations: {entities[-1]}", missing.stderr
        )
        self.assertEqual(unexpected.returncode, 1)
        self.assertIn(
            "result set has unknown configurations: ext4/single",
            unexpected.stderr,
        )
        self.assertEqual(duplicate.returncode, 1)
        self.assertIn(
            f"result set has duplicate configurations: {entities[0]}",
            duplicate.stderr,
        )

    def test_history_publication_requires_complete_result_set(self):
        workflow = BENCH_WORKFLOW.read_text()

        validation = workflow.index("Validate complete result set")
        publication = workflow.index("Append results to history branch")

        self.assertLess(validation, publication)
        self.assertIn(
            "validate-result.py --complete-set incoming/result-*.json",
            workflow,
        )
        self.assertIn("name: Store hosted results", workflow)
        self.assertNotIn("actions/deploy-pages", workflow)

    def test_hardware_results_use_separate_history_and_dashboard(self):
        hosted = BENCH_WORKFLOW.read_text()
        hardware = HARDWARE_BENCH_WORKFLOW.read_text()
        sas_hdd = SAS_HDD_BENCH_WORKFLOW.read_text()
        pages = PAGES_WORKFLOW.read_text()

        self.assertIn("git -C data push origin results-data", hosted)
        self.assertIn("cp LICENSE-DATA data/LICENSE", hosted)
        self.assertNotIn("modern-fs-benchmark-run", hosted)
        self.assertNotIn("BENCH_DEVICES", hosted)
        self.assertIn("results-real-hw", hardware)
        self.assertIn(
            "git -C hardware-data push origin results-real-hw", hardware
        )
        self.assertIn("cp LICENSE-DATA hardware-data/LICENSE", hardware)
        self.assertIn('startswith("/dev/")', hardware)
        self.assertNotIn("actions/deploy-pages", hardware)
        self.assertIn("standard-data/runs", pages)
        self.assertIn("hardware-data/runs", pages)
        self.assertIn("site/real-hw/index.html", pages)
        self.assertIn("results-real-hw-sas-hdd", sas_hdd)
        self.assertNotIn("results-data", sas_hdd)
        self.assertIn(
            "git -C sas-hdd-data push origin results-real-hw-sas-hdd", sas_hdd
        )
        self.assertIn("hardware-profile:sas-hdd", sas_hdd)
        self.assertIn("--expected-hardware-profile sas-hdd", sas_hdd)
        self.assertIn("sas-hdd-data/runs", pages)
        self.assertIn("site/sas-hdd/index.html", pages)
        self.assertNotIn("site/real-hw/sas-hdd/index.html", pages)
        self.assertIn("id: sas-hdd-history", pages)
        self.assertIn(
            "if: steps.sas-hdd-history.outputs.present == 'true'", pages
        )
        self.assertNotIn("continue-on-error: true", pages)
        self.assertIn("--expected-hardware-profile farm3", pages)
        self.assertIn("--allow-missing-hardware-profile", pages)
        self.assertIn("--expected-hardware-profile sas-hdd", pages)
        self.assertIn("Devices=Four 16 GiB loop devices", pages)
        self.assertIn("they are not independent physical disks", pages)
        self.assertIn("Physical media=Six independent 6 TB", pages)
        self.assertIn("Physical media=Eleven drives", pages)
        self.assertIn("Role use=Btrfs uses the 4 GiB", pages)
        self.assertIn("Btrfs=Single-profile Btrfs on eight-HDD md RAID10", pages)
        self.assertIn("ZFS=Four HDD mirror vdevs", pages)
        self.assertIn("bcachefs=Replicated HDD background target", pages)
        self.assertLess(
            pages.index("actions/upload-pages-artifact"),
            pages.index("actions/deploy-pages"),
        )

    def test_unversioned_results_use_v1_contract(self):
        result = run_script(
            VALIDATOR,
            FIXTURE_RUNS / "100" / "result-ext4-single.json",
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_schema_v2_requires_reclaim_telemetry(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            del document["results"]["reclaim_free_pct"]
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results: missing metrics: reclaim_free_pct",
            result.stderr,
        )

    def test_schema_v4_requires_large_directory_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            schema = json.loads(SCHEMA.read_text())
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            document["schema_version"] = 4
            introduced = [
                metric["key"]
                for metric in schema["metrics"]
                if metric.get("introduced") == 4
            ]
            for key in introduced:
                document["results"][key] = 1
            del document["results"]["largedir_stat_warm_ms"]
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results: missing metrics: largedir_stat_warm_ms",
            result.stderr,
        )

    def test_wrong_metric_type_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            document["results"]["seqwrite_mbps"] = "fast"
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results.seqwrite_mbps: expected number, got str",
            result.stderr,
        )

    def test_optional_hardware_metrics_are_validated_when_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            for key, _label, _unit, _better in HARDWARE_METRIC_CONTRACT:
                document["results"][key] = 1234.5
            result_file.write_text(json.dumps(document))

            valid = run_script(VALIDATOR, result_file)
            document["results"]["randwrite8_iops"] = None
            result_file.write_text(json.dumps(document))
            invalid = run_script(VALIDATOR, result_file)

        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(invalid.returncode, 1)
        self.assertIn(
            "document.results.randwrite8_iops: null is not allowed",
            invalid.stderr,
        )

    def test_missing_metric_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(
                (FIXTURE_RUNS / "101" / "result-btrfs-raid1.json").read_text()
            )
            del document["results"]["sparse_grow_bytes"]
            result_file.write_text(json.dumps(document))

            result = run_script(VALIDATOR, result_file)

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "document.results: missing metrics: sparse_grow_bytes",
            result.stderr,
        )

    def test_benchmark_validates_result_before_reporting_success(self):
        source = RUN_BENCH.read_text()

        write_result = source.index('> "$RESULT_FILE"')
        validate_result = source.index(
            'python3 "$SCRIPT_DIR/validate-result.py" "$RESULT_FILE"'
        )
        report_success = source.index('log "done: $RESULT_FILE"')

        self.assertLess(write_result, validate_result)
        self.assertLess(validate_result, report_success)

    def test_benchmark_emits_current_schema_version(self):
        schema_version = json.loads(SCHEMA.read_text())["schema_version"]
        match = re.search(r"'\(\{schema_version: (\d+),", RUN_BENCH.read_text())

        self.assertIsNotNone(match)
        self.assertEqual(int(match.group(1)), schema_version)

    def test_benchmark_supports_optional_result_provenance_overrides(self):
        source = RUN_BENCH.read_text()
        write_result = source[source.index("write_result() {") :]

        self.assertIn("${BENCH_RESULT_DEVICES:-${BENCH_DEVICES:-loop}}", write_result)
        self.assertIn("${BENCH_RESULT_NDEV:-${#DEVICES[@]}}", write_result)
        self.assertIn(
            "${BENCH_RESULT_DEVICE_SIZE_BYTES:-$(blockdev --getsize64",
            write_result,
        )
        self.assertIn('${BENCH_SCENARIO:-}', write_result)
        self.assertIn('${BENCH_TOPOLOGY:-}', write_result)
        for variable in (
            "BENCH_RESULT_DEVICES",
            "BENCH_RESULT_NDEV",
            "BENCH_RESULT_DEVICE_SIZE_BYTES",
        ):
            self.assertNotIn(variable, source[: source.index("write_result() {")])

    def test_summary_heading_only_includes_scenario_when_present(self):
        fixture = FIXTURE_RUNS / "101" / "result-btrfs-raid1.json"
        default = subprocess.run(
            ["bash", str(SUMMARIZE), str(fixture)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        with tempfile.TemporaryDirectory() as tmp:
            result_file = Path(tmp) / "result.json"
            document = json.loads(fixture.read_text())
            document["benchmark_scenario"] = "hybrid-isolated"
            result_file.write_text(json.dumps(document))
            scenario = subprocess.run(
                ["bash", str(SUMMARIZE), str(result_file)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertEqual(default.stdout.splitlines()[0], "### Filesystem benchmark results")
        self.assertEqual(scenario.returncode, 0, scenario.stderr)
        self.assertEqual(
            scenario.stdout.splitlines()[0],
            "### Filesystem benchmark results — hybrid-isolated",
        )


class BenchmarkPhaseTests(unittest.TestCase):
    phases = [
        "phase_host_calibration",
        "setup_benchmark_filesystem",
        "phase_sequential_write",
        "phase_random_write",
        "phase_random_read",
        "phase_sequential_read",
        "phase_trivial_latency",
        "phase_source_tree",
        "phase_sparse_files",
        "phase_large_directory",
        "phase_aging",
        "phase_snapshot_reclaim",
        "phase_snapshot_scaling",
        "phase_compression",
        "phase_divergence",
        "phase_degraded_rebuild",
        "phase_corruption_scrub",
        "phase_enospc",
        "write_result",
    ]

    def test_phases_run_in_destructive_order(self):
        stubs = "\n".join(
            f"{phase}() {{ printf '%s\\n' {phase}; }}" for phase in self.phases
        )

        result = run_benchmark_shell(f"{stubs}\nrun_benchmark_phases")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), self.phases)

    def test_sequential_write_phase_can_run_with_stubs(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = r'''
DATA=$2
SEQ_SIZE=2G
log() { :; }
fio_json() {
  printf '%s\n' "$*" > "$DATA/fio-call"
  printf '%s\n' "$DATA/fio.json"
}
jq() { printf '321.5\n'; }
phase_sequential_write
printf '%s\n' "$SEQWRITE_MBPS"
'''
            result = run_benchmark_shell(source, tmp)
            fio_call = (Path(tmp) / "fio-call").read_text().strip()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "321.5")
        self.assertEqual(
            fio_call,
            f"seqwrite --directory={tmp} --rw=write --bs=1M "
            "--size=2G --end_fsync=1",
        )

    def test_hosted_random_write_does_not_run_hardware_scaling(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = r'''
DATA=$2
RUNTIME=30
BENCH_DEVICES=
log() { :; }
fio_json() {
  printf '%s\n' "$*" >> "$DATA/fio-calls"
  printf '%s\n' "$DATA/fio.json"
}
jq() { printf '123.5\n'; }
phase_random_write
printf '%s %s %s %s %s\n' \
  "$RANDWRITE8_IOPS" "$RANDWRITE16_IOPS" \
  "$RANDWRITE4_SHARDED_IOPS" "$RANDWRITE8_SHARDED_IOPS" \
  "$RANDWRITE16_SHARDED_IOPS"
'''
            result = run_benchmark_shell(source, tmp)
            calls = (Path(tmp) / "fio-calls").read_text().splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "null null null null null")
        self.assertEqual(len(calls), 2)
        self.assertFalse(any("--numjobs=8" in call for call in calls))
        self.assertFalse(any("--numjobs=16" in call for call in calls))

    def test_hardware_random_write_runs_8_and_16_workers(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = r'''
DATA=$2
RUNTIME=30
BENCH_DEVICES=/dev/fake
BENCH_HARDWARE_RANDOM_SCALING=1
log() { :; }
rm() { printf 'rm\n' >> "$DATA/events"; }
sync() { printf 'sync\n' >> "$DATA/events"; }
fio_json() {
  printf '%s\n' "$1" >> "$DATA/events"
  printf '%s\n' "$*" >> "$DATA/fio-calls"
  printf '%s\n' "$DATA/fio.json"
}
jq() { printf '123.5\n'; }
phase_random_write
printf '%s %s %s %s %s\n' \
  "$RANDWRITE8_IOPS" "$RANDWRITE16_IOPS" \
  "$RANDWRITE4_SHARDED_IOPS" "$RANDWRITE8_SHARDED_IOPS" \
  "$RANDWRITE16_SHARDED_IOPS"
'''
            result = run_benchmark_shell(source, tmp)
            calls = (Path(tmp) / "fio-calls").read_text().splitlines()
            events = (Path(tmp) / "events").read_text().splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "123.5 123.5 123.5 123.5 123.5")
        self.assertEqual(len(calls), 7)
        self.assertTrue(any("--size=128M" in call and "--numjobs=8" in call for call in calls))
        self.assertTrue(any("--size=64M" in call and "--numjobs=16" in call for call in calls))
        sharded = [call for call in calls if call.startswith("randwrite-sharded")]
        self.assertEqual(len(sharded), 3)
        expected = {
            "randwrite-sharded4": ("--size=256M", "--numjobs=4"),
            "randwrite-sharded8": ("--size=128M", "--numjobs=8"),
            "randwrite-sharded16": ("--size=64M", "--numjobs=16"),
        }
        for call in sharded:
            size, jobs = expected[call.split()[0]]
            self.assertIn(size, call)
            self.assertIn(jobs, call)
            self.assertIn("--nrfiles=1", call)
            self.assertIn("--thread=0", call)
            self.assertIn("--create_serialize=0", call)
            self.assertIn("--filename_format=$jobname.$jobnum.$filenum", call)
            self.assertIn("--group_reporting", call)
        self.assertEqual(
            events,
            [
                "randwrite", "rm", "randwrite-par", "rm",
                "randwrite-par8", "rm", "randwrite-par16", "rm", "sync",
                "randwrite-sharded4", "rm", "sync",
                "randwrite-sharded8", "rm", "sync",
                "randwrite-sharded16", "rm", "sync",
            ],
        )

    def test_hardware_random_read_runs_8_and_16_workers_cold(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = r'''
DATA=$2
READ_SIZE=2G
RUNTIME=30
BENCH_DEVICES=/dev/fake
BENCH_HARDWARE_RANDOM_SCALING=1
cache_drops=0
log() { :; }
fio() { :; }
fs_drop_caches() { cache_drops=$((cache_drops + 1)); }
fio_json() {
  printf '%s\n' "$*" >> "$DATA/fio-calls"
  printf '%s\n' "$DATA/fio.json"
}
jq() { printf '456.5\n'; }
phase_random_read
printf '%s %s %s\n' "$RANDREAD8_IOPS" "$RANDREAD16_IOPS" "$cache_drops"
'''
            result = run_benchmark_shell(source, tmp)
            calls = (Path(tmp) / "fio-calls").read_text().splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "456.5 456.5 4")
        self.assertEqual(len(calls), 4)
        self.assertTrue(any("--io_size=64M" in call and "--numjobs=8" in call for call in calls))
        self.assertTrue(any("--io_size=32M" in call and "--numjobs=16" in call for call in calls))

    def test_skipped_degraded_phase_resets_optional_metrics(self):
        source = r'''
FS=ext4
LAYOUT=single
SPARE_DEV=
DEG_WRITE_IOPS=1
DEG_READ_IOPS=2
REBUILD_S=3
log() { :; }
phase_degraded_rebuild
printf '%s %s %s\n' "$DEG_WRITE_IOPS" "$DEG_READ_IOPS" "$REBUILD_S"
'''

        result = run_benchmark_shell(source)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "null null null")

    def test_large_directory_phase_runs_with_tiny_file_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = r'''
DATA=$2
LARGEDIR_FILES=3
cache_drops=0
log() { :; }
sync() { :; }
now_ms() { printf '1\n'; }
fs_drop_caches() { cache_drops=$((cache_drops + 1)); }
jq() {
  python3 -c 'import sys; values=sorted(map(int, sys.stdin)); print(values[len(values)//2])'
}
phase_large_directory
directory_left=0
[ ! -e "$DATA/large-dir" ] || directory_left=1
printf '%s %s %s %s %s %s %s\n' \
  "$LARGEDIR_CREATE_MS" "$LARGEDIR_READDIR_COLD_MS" \
  "$LARGEDIR_STAT_COLD_MS" "$LARGEDIR_STAT_WARM_MS" \
  "$LARGEDIR_DELETE_MS" "$cache_drops" "$directory_left"
'''

            result = run_benchmark_shell(source, tmp)

        self.assertEqual(result.returncode, 0, result.stderr)
        values = [int(value) for value in result.stdout.split()]
        self.assertEqual(len(values), 7)
        self.assertTrue(all(value >= 0 for value in values[:5]))
        self.assertEqual(values[5:], [2, 0])


class BackendConfigurationTests(unittest.TestCase):
    def test_zfs_enables_block_cloning_for_new_pools(self):
        source = ZFS_BACKEND.read_text()

        self.assertIn("FS_REFLINK=1", source)

    def test_xfs_zvol_does_not_reserve_space_needed_by_snapshots(self):
        source = XFS_BACKEND.read_text()

        self.assertIn("-o refreservation=none", source)
        self.assertIn("zvol_resolve_device", source)
        self.assertIn('name=$(zvol_id "$candidate"', source)

    def test_bcachefs_ec_evacuation_is_bounded_and_diagnostic(self):
        backend = BCACHEFS_BACKEND.read_text()
        debug = BCACHEFS_DEBUG.read_text()

        self.assertIn("bcachefs_evacuate_with_diagnostics", backend)
        self.assertIn('die "bcachefs EC evacuation failed or timed out"', backend)
        for evidence in (
            "bcachefs reconcile status",
            "internal/moving_ctxts",
            "internal/new_stripes",
            "options/ec_stripe_buf_limit",
            "options/move_bytes_in_flight",
            "/proc/sysrq-trigger",
            "dmesg --color=never",
        ):
            self.assertIn(evidence, debug)

    def test_standalone_bcachefs_ec_reproducer_matches_failure_path(self):
        reproducer = BCACHEFS_REPRO.read_text()
        workflow = BCACHEFS_REPRO_WORKFLOW.read_text()

        for command in (
            "bcachefs format -f --erasure_code --replicas=3",
            "bcachefs device offline --force",
            "bcachefs device add",
            "bcachefs_evacuate_with_diagnostics",
        ):
            self.assertIn(command, reproducer)
        self.assertIn("workflow_dispatch", workflow)
        self.assertIn("if: always()", workflow)

    def test_hardware_workflow_requires_managed_runner(self):
        workflow = HARDWARE_BENCH_WORKFLOW.read_text()

        self.assertIn("runs-on: [self-hosted, linux, x64, fs-benchmark]", workflow)
        self.assertIn("modern-fs-benchmark-run", workflow)
        self.assertIn("managed benchmark wrapper is not installed", workflow)
        self.assertIn("--capabilities", workflow)
        self.assertIn("hardware-random-scaling-v2", workflow)
        self.assertIn("$GITHUB_RUN_ID", workflow)
        self.assertIn("/var/lib/modern-fs-benchmark/results/", workflow)
        self.assertNotIn("scripts/install-deps.sh", workflow)
        self.assertIn("ENABLE_HARDWARE_BENCHMARKS", workflow)
        self.assertIn("max-parallel: 1", workflow)
        for key, _label, _unit, _better in HARDWARE_METRIC_CONTRACT:
            self.assertIn(key, workflow)

    def test_sas_hdd_workflow_is_profile_isolated(self):
        workflow = SAS_HDD_BENCH_WORKFLOW.read_text()

        self.assertIn(
            "runs-on: [self-hosted, linux, x64, fs-benchmark-sas-hdd]",
            workflow,
        )
        self.assertNotIn(
            "runs-on: [self-hosted, linux, x64, fs-benchmark]", workflow
        )
        self.assertIn("ENABLE_SAS_HDD_BENCHMARKS", workflow)
        self.assertIn("hardware-profile:sas-hdd", workflow)
        self.assertIn('--revision "${{ github.sha }}"', workflow)
        self.assertIn('.benchmark_revision == $expected_revision', workflow)
        self.assertIn("results-real-hw-sas-hdd", workflow)
        self.assertIn('startswith("/dev/disk/by-id/")', workflow)

    def test_sas_hdd_provisioning_and_launcher_enforce_safety_boundary(self):
        provisioner = (ROOT / "contrib" / "sas-hdd" / "provision-storage.sh").read_text()
        launcher = (ROOT / "contrib" / "sas-hdd" / "modern-fs-benchmark-run").read_text()

        self.assertIn("FORBIDDEN_OS_DISK=/dev/sda", provisioner)
        self.assertIn("lsblk -snrpo NAME", provisioner)
        self.assertIn('/sys/class/block/$node/holders/*', provisioner)
        self.assertIn("swapon --show=NAME", provisioner)
        self.assertIn("zpool status -LP", provisioner)
        self.assertIn("partprobe", provisioner)
        self.assertIn("--check", provisioner)
        self.assertLess(
            provisioner.index("if (( check_only ))"),
            provisioner.index("wipefs --all"),
        )
        self.assertIn('wipefs --all --force "${device}-part1"', provisioner)
        self.assertIn("! -user root -o -perm /022", launcher)
        self.assertIn("-type l", launcher)
        self.assertIn("installed_revision", launcher)
        self.assertIn("MANAGED_DEVICE_SIZE_BYTES=17179869184", launcher)

        refused = subprocess.run(
            [str(ROOT / "contrib" / "sas-hdd" / "provision-storage.sh")],
            text=True,
            capture_output=True,
            env={**os.environ, "CONFIRM_DESTROY_SAS_HDD": "wrong"},
        )
        self.assertEqual(refused.returncode, 2)
        self.assertIn("refusing", refused.stderr)

    def test_hybrid_tier_workflow_is_scenario_isolated(self):
        workflow = HYBRID_TIER_WORKFLOW.read_text()
        baseline = SAS_HDD_BENCH_WORKFLOW.read_text()
        pages = PAGES_WORKFLOW.read_text()

        self.assertIn("group: fs-bench-sas-hdd-storage", workflow)
        self.assertIn("group: fs-bench-sas-hdd-storage", baseline)
        self.assertIn("benchmark-scenario:hybrid-tier-v1", workflow)
        self.assertIn("results-real-hw-sas-hdd-hybrid-tier-v1", workflow)
        self.assertIn("needs.bench.result == 'success'", workflow)
        self.assertIn("hybrid-cleanup-btrfs-complete", workflow)
        self.assertIn("hybrid-cleanup-zfs-complete", workflow)
        self.assertIn("hybrid-cleanup-bcachefs-complete", workflow)
        self.assertIn('.fs == "btrfs" and .ndev == 12', workflow)
        self.assertIn('.fs == "zfs" and .ndev == 11', workflow)
        self.assertIn('.fs == "bcachefs" and .ndev == 11', workflow)
        self.assertIn("expected_btrfs_devices", workflow)
        self.assertIn("expected_tier_devices", workflow)
        self.assertIn(".devices == $expected_btrfs_devices", workflow)
        self.assertIn(".devices == $expected_tier_devices", workflow)
        self.assertIn("site/sas-hdd/hybrid-tier/index.html", pages)
        self.assertIn("--expected-benchmark-scenario hybrid-tier-v1", pages)
        self.assertNotIn("results-data", workflow)

        configurations = re.findall(
            r"^\s+- fs: (\S+)\n\s+layout: (\S+)", workflow, re.MULTILINE
        )
        self.assertEqual(
            configurations,
            [
                ("btrfs", "hybrid-dmcache"),
                ("zfs", "hybrid-special-l2arc"),
                ("bcachefs", "hybrid-native"),
            ],
        )

    def test_hybrid_tier_runner_installs_cleanup_before_mutation(self):
        runner = (ROOT / "scripts" / "run-sas-hdd-hybrid-tier.sh").read_text()
        topology = (ROOT / "scripts" / "lib" / "sas-hdd-hybrid-tier.sh").read_text()
        managed = (
            ROOT / "scripts" / "managed-sas-hdd-hybrid-tier-runner.sh"
        ).read_text()
        launcher = (
            ROOT / "contrib" / "sas-hdd" / "modern-fs-benchmark-hybrid-tier-run"
        ).read_text()

        self.assertLess(runner.index("trap hybrid_on_exit"), runner.index("hybrid_prepare"))
        self.assertIn("HDD RAID10 + mirrored dm-cache writeback", topology)
        self.assertIn("special mirror", topology)
        self.assertIn("--foreground_target=hot", topology)
        self.assertIn("--background_target=hdd", topology)
        self.assertIn("--promote_target=readcache", topology)
        self.assertIn("--durability=0", topology)
        self.assertIn("hybrid_assert_zpool_owned", topology)
        self.assertIn("hybrid_assert_vg_owned", topology)
        self.assertIn("hybrid_assert_md_owned", topology)
        self.assertIn('findmnt -rn -o TARGET,SOURCE,FSTYPE', topology)
        self.assertIn('"$MNT" | "$MNT"/*', topology)
        self.assertIn("retains a block-device holder after cleanup", topology)
        self.assertIn('dmsetup remove --retry "$dm_name"', topology)
        self.assertIn('"$HYBRID_VG"-*', topology)
        self.assertIn("has non-scenario holder", topology)
        self.assertLess(
            topology.index("udevadm settle || failed=1"),
            topology.index('dmsetup remove --retry "$dm_name"'),
        )
        self.assertIn('mkfs.btrfs -f -d single -m single', topology)
        self.assertIn("BENCH_RESULT_NDEV=12", topology)
        self.assertIn("BENCH_RESULT_NDEV=11", topology)
        self.assertIn("cachefile=none", topology)
        self.assertIn("bcachefs show-super", topology)
        self.assertIn("BENCH_RESULT_DEVICE_SIZE_BYTES=omit", topology)
        self.assertIn("benchmark-scenario:$MANAGED_BENCHMARK_SCENARIO", managed)
        self.assertIn("/run/lock/modern-fs-benchmark.lock", managed)
        self.assertIn("/usr/bin/env -i", launcher)
        self.assertNotIn("$GITHUB", launcher)

    def test_hybrid_tier_provisioner_has_fixed_roles_and_confirmation(self):
        provisioner_path = (
            ROOT / "contrib" / "sas-hdd" / "provision-hybrid-tier-storage.sh"
        )
        provisioner = provisioner_path.read_text()

        self.assertIn("FORBIDDEN_OS_DISK=/dev/sda", provisioner)
        self.assertIn("HDD_SECTORS=268435456", provisioner)
        self.assertIn("HOT_SECTORS=134217728", provisioner)
        self.assertIn("META_SECTORS=8388608", provisioner)
        self.assertIn("Elements in grown defect list", provisioner)
        self.assertIn("fsbench-hybrid-readcache", provisioner)
        self.assertIn("/run/lock/modern-fs-benchmark.lock", provisioner)
        self.assertLess(
            provisioner.index("if (( check_only ))"),
            provisioner.index('wipefs --all --force "$device"'),
        )

        refused = subprocess.run(
            [str(provisioner_path)],
            text=True,
            capture_output=True,
            env={**os.environ, "CONFIRM_DESTROY_SAS_HDD_HYBRID": "wrong"},
        )
        self.assertEqual(refused.returncode, 2)
        self.assertIn("refusing", refused.stderr)

    def test_hybrid_cleanup_rejects_failed_unmount(self):
        topology = ROOT / "scripts" / "lib" / "sas-hdd-hybrid-tier.sh"
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'''
set -euo pipefail
MNT=/mnt/fsbench-test
source "{topology}"
HYBRID_ALL_DEVICES=()
sync() {{ :; }}
findmnt() {{ printf '/mnt/fsbench-test fsbench_hybrid zfs\n'; }}
umount() {{ return 1; }}
zpool() {{ return 1; }}
vgs() {{ return 1; }}
udevadm() {{ :; }}
if hybrid_cleanup; then
  exit 1
fi
''',
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hybrid_cleanup_rejects_foreign_descendant_mount(self):
        topology = ROOT / "scripts" / "lib" / "sas-hdd-hybrid-tier.sh"
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'''
set -euo pipefail
MNT=/mnt/fsbench-test
die() {{ printf 'ERROR: %s\n' "$*" >&2; exit 1; }}
source "{topology}"
findmnt() {{ printf '/mnt/fsbench-test/child /dev/foreign ext4\n'; }}
if (hybrid_assert_mounts_owned); then
  exit 1
fi
''',
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("foreign ext4 mount", result.stderr)

    def test_hybrid_scenario_capabilities_are_explicit(self):
        schema = json.loads(SCHEMA.read_text())
        self.assertEqual(
            schema["scenario_configurations"]["hybrid-tier-v1"],
            {
                "btrfs/hybrid-dmcache": [
                    "snapshots",
                    "compression",
                    "reflink",
                    "snapscale",
                ],
                "zfs/hybrid-special-l2arc": [
                    "snapshots",
                    "compression",
                    "reflink",
                    "snapscale",
                ],
                "bcachefs/hybrid-native": [
                    "snapshots",
                    "compression",
                    "reflink",
                    "snapscale",
                ],
            },
        )
        self.assertIn("include_device_size", RUN_BENCH.read_text())

    def test_hosted_and_hardware_workflows_use_same_matrix(self):
        def matrix_profile(path):
            workflow = path.read_text()
            matrix = workflow[
                workflow.index("      matrix:\n") : workflow.index("    env:\n")
            ]
            pattern = re.compile(
                r"^\s+- fs: (\S+)\n\s+layout: (\S+)(.*?)"
                r"(?=^\s+- fs:|\Z)",
                re.MULTILINE | re.DOTALL,
            )
            profile = []
            for fs, layout, options in pattern.findall(matrix):
                dev_size = re.search(r"^\s+dev_size: (\S+)", options, re.MULTILINE)
                aging = re.search(r"^\s+aging_iters: (\d+)", options, re.MULTILINE)
                profile.append(
                    (
                        fs,
                        layout,
                        dev_size.group(1) if dev_size else "16G",
                        int(aging.group(1)) if aging else 100,
                    )
                )
            return profile

        hosted = matrix_profile(BENCH_WORKFLOW)
        hardware = matrix_profile(HARDWARE_BENCH_WORKFLOW)
        sas_hdd = matrix_profile(SAS_HDD_BENCH_WORKFLOW)

        self.assertEqual(len(hosted), 26)
        self.assertEqual(hardware, hosted)
        self.assertEqual(sas_hdd, hosted)

    def test_nixos_module_keeps_machine_policy_in_cluster_configuration(self):
        flake = FLAKE.read_text()
        module = NIXOS_MODULE.read_text()
        managed = MANAGED_HARDWARE_RUNNER.read_text()

        self.assertIn("nixosModules.modern-fs-benchmark", flake)
        self.assertIn("config.boot.kernelPackages.bcachefs", module)
        self.assertNotIn("linuxPackages_", module)
        self.assertIn("devices must contain exactly four devices", module)
        self.assertIn("modern-fs-benchmark-run", module)
        self.assertIn('command = "${runBenchmark}/bin/', module)
        self.assertIn("config.boot.zfs.package", module)
        self.assertIn("config.boot.zfs.modulePackage", module)
        self.assertIn('[ "dm_raid" "dm_snapshot" "dm_integrity" ]', module)
        self.assertIn("another filesystem benchmark is already running", managed)
        self.assertIn("zfsSingleDevice", module)
        self.assertIn("34359738368", managed)
        self.assertIn("resolves to a duplicate block device", managed)
        self.assertIn("export BENCH_HARDWARE_RANDOM_SCALING=1", managed)
        self.assertIn("hardware-random-scaling-v2", managed)
        self.assertIn("BENCH_HARDWARE_PROFILE", managed)
        self.assertIn("hardwareProfile", module)
        self.assertIn('/run/wrappers/bin/sudo', module)
        self.assertIn('CapabilityBoundingSet = lib.mkForce [ "~" ]', module)
        self.assertNotIn("BENCH_HARDWARE_RANDOM_SCALING", BENCH_WORKFLOW.read_text())
        self.assertNotIn("boot.supportedFilesystems", module)
        self.assertNotIn("results directory must be inside", module)
        self.assertIn("packages =", flake)
        self.assertIn("apps =", flake)

    def test_real_device_validation_precedes_signature_wipe(self):
        common = (ROOT / "scripts" / "lib" / "common.sh").read_text()

        stale_cleanup = common.index("    remove_stale_benchmark_mappings")
        validation = common.index('[ -b "$dev" ]')
        mount_check = common.index('is mounted — refusing')
        wipe = common.index('wipefs --all --force "$dev"')
        self.assertLess(stale_cleanup, validation)
        self.assertLess(validation, wipe)
        self.assertLess(mount_check, wipe)

    def test_lvm_mapping_cleanup_retries_after_udev_settles(self):
        common = (ROOT / "scripts" / "lib" / "common.sh").read_text()
        layered = (ROOT / "scripts" / "lib" / "layered.sh").read_text()

        self.assertIn('dmsetup remove --retry "${d##*/}"', common)
        self.assertIn('/sys/class/block/$node/holders/$holder', common)
        self.assertLess(
            layered.index("udevadm settle"),
            layered.index('dmsetup remove --retry "${d##*/}"'),
        )


if __name__ == "__main__":
    unittest.main()
