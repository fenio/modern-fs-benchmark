# bcachefs EC evacuation stall reproducer

## Observed failure

The benchmark intermittently stalls while replacing one member of a four-device
bcachefs EC filesystem. The exact command is:

```sh
bcachefs device evacuate /dev/loop1
```

The command normally migrates about 3.48 GiB and finishes in roughly one minute.
On failing runs it reaches a small remainder, then reports the same value until
the 60-minute GitHub Actions job timeout:

- 332 KiB remaining for 2,802 samples
- 584 KiB remaining for 2,807 samples
- 900 KiB remaining for 2,775 samples

The host calibration is normal on these attempts. The filesystem uses bcachefs
tools and module 1.38.8 on kernel 7.0.0-1009-azure.

Examples:

- [run 29724829904, attempt 1](https://github.com/fenio/modern-fs-benchmark/actions/runs/29724829904/job/88295417320)
- [run 29724829904, attempt 2](https://github.com/fenio/modern-fs-benchmark/actions/runs/29724829904/job/88307306495)
- [run 29696521649, timed-out attempt](https://github.com/fenio/modern-fs-benchmark/actions/runs/29696521649/job/88220237414)
- [run 29716072546, successful control](https://github.com/fenio/modern-fs-benchmark/actions/runs/29716072546/job/88273318813)

The closest known report is
[koverstreet/bcachefs#1182](https://github.com/koverstreet/bcachefs/issues/1182),
where EC reconcile wedges after stripe-buffer memory exceeds its limit and
moving contexts stop making progress. Existing benchmark artifacts prove the
blocking command but do not contain enough kernel state to establish that both
failures have the same cause.

## Standalone reproducer

The script creates five disposable 16 GiB sparse loop devices, formats four as
a 2+2 EC filesystem with replicas=3, generates sequential and 4 KiB random
write churn, offlines one member, writes and reads while degraded, adds the
fifth loop as a spare, and evacuates the original member.

It never accepts or modifies real block devices.

```sh
sudo scripts/install-deps.sh bcachefs
sudo OUTPUT_DIR="$PWD/repro-output" \
  scripts/repro-bcachefs-ec-evacuate.sh
```

Expected success: evacuation completes in about one minute.

Observed failure signature: evacuation drops below 1 MiB remaining and makes
no further progress. The default command timeout is 12 minutes, with a live
diagnostic snapshot after three minutes.

Useful controls:

```sh
# Test whether completing pending EC work prevents the stall.
sudo RECONCILE_BEFORE_DEGRADE=1 \
  OUTPUT_DIR="$PWD/repro-with-reconcile" \
  scripts/repro-bcachefs-ec-evacuate.sh

# Override diagnostic and command timeouts.
sudo BCACHEFS_EVAC_DIAG_AFTER=60 BCACHEFS_EVAC_TIMEOUT=5m \
  OUTPUT_DIR="$PWD/repro-fast" \
  scripts/repro-bcachefs-ec-evacuate.sh
```

The manual `reproduce-bcachefs-ec-evacuation` workflow runs four independent
attempts and uploads each diagnostic bundle even when evacuation times out.

The full workload that originally exposed the failure remains available as a
control:

```sh
sudo DEV_SIZE=16G AGING_ITERS=100 AGING_IO=64M SNAPSCALE_COUNT=500 \
  RESULTS_DIR="$PWD/results" scripts/run-bench.sh bcachefs ec
```

## Captured evidence

Each attempt records:

- kernel, tools, and module versions
- fio seed, churn, and degraded-I/O JSON
- full evacuation progress
- `bcachefs fs usage -a -h`
- `bcachefs reconcile status`
- `reconcile_status`
- `internal/moving_ctxts`
- `internal/new_stripes`
- `internal/alloc_debug`, when available
- `ec_stripe_buf_limit` and `move_bytes_in_flight`
- IO and memory pressure
- bcachefs process stacks
- SysRq blocked-task report and `dmesg` on a stall

## Upstream report draft

> bcachefs 1.38.8 intermittently stops making progress during device
> evacuation on a four-device 2+2 EC filesystem. The test offlines one member,
> performs 30 seconds of 4 KiB random writes and reads while degraded, brings
> the member online, adds a fifth device, then evacuates the original member.
> Evacuation normally moves about 3.48 GiB in 57 seconds. In repeated failures,
> it reaches 332-900 KiB remaining and stays there for more than 45 minutes.
> Identical fresh-runner retries sometimes pass. This resembles issue #1182;
> the attached bundle includes reconcile status, new_stripes, moving contexts,
> blocked tasks, pressure, and the kernel log captured while stalled.
