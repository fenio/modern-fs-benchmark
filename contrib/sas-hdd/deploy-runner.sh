#!/usr/bin/env bash
# Deploy an immutable benchmark revision and its privileged launchers.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly TARGET=/opt/modern-fs-benchmark
readonly CANDIDATE=/opt/modern-fs-benchmark.new
readonly BACKUP=/opt/modern-fs-benchmark.previous
readonly RUNNER_SERVICE=/opt/actions-runner/svc.sh
readonly LAUNCHER_DIR=/usr/local/sbin
readonly LAUNCHERS=(
  modern-fs-benchmark-run
  modern-fs-benchmark-hybrid-tier-run
  modern-fs-benchmark-hybrid-tier-v2-run
)

if (( $# > 1 )); then
  echo "usage: $0 [git-ref]" >&2
  exit 2
fi

for command in git tar sudo mktemp grep; do
  command -v "$command" >/dev/null \
    || { echo "$command is required for deployment" >&2; exit 2; }
done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
git -C "$repo_root" fetch origin main
ref=${1:-origin/main}
revision=$(git -C "$repo_root" rev-parse --verify "$ref^{commit}")
[[ $revision =~ ^[0-9a-f]{40,64}$ ]] \
  || { echo "cannot resolve deployment revision: $ref" >&2; exit 2; }

staging=$(mktemp -d)
service_stopped=0
swap_started=0
old_moved=0
new_installed=0
deployment_complete=0

install_launchers() {
  local source_root=$1 launcher
  for launcher in "${LAUNCHERS[@]}"; do
    sudo install -o root -g root -m 0755 \
      "$source_root/contrib/sas-hdd/$launcher" "$LAUNCHER_DIR/$launcher"
  done
}

finish() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf "$staging"
  sudo rm -rf "$CANDIDATE"

  if (( status != 0 && swap_started && ! deployment_complete )); then
    echo "deployment failed; restoring the previous benchmark tree" >&2
    if (( new_installed )); then
      sudo rm -rf "$TARGET"
    fi
    if (( old_moved )); then
      sudo mv "$BACKUP" "$TARGET"
      install_launchers "$TARGET" || true
    fi
  fi
  if (( service_stopped )); then
    sudo "$RUNNER_SERVICE" start || true
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git -C "$repo_root" archive "$revision" | tar -x -C "$staging"
printf '%s\n' "$revision" >"$staging/REVISION"
for launcher in "${LAUNCHERS[@]}"; do
  bash -n "$staging/contrib/sas-hdd/$launcher"
done

# Build and validate the root-owned candidate before stopping the runner.
sudo rm -rf "$CANDIDATE"
sudo install -d -o root -g root -m 0755 "$CANDIDATE"
sudo cp -a "$staging/." "$CANDIDATE/"
sudo chown -R root:root "$CANDIDATE"
sudo chmod -R go-w "$CANDIDATE"
sudo chmod 0755 "$CANDIDATE"
unsafe_path=$(sudo find "$CANDIDATE" \
  \( -type l -o ! -user root -o -perm /022 \) -print -quit)
[[ -z $unsafe_path ]] \
  || { echo "unsafe path in deployment candidate: $unsafe_path" >&2; exit 1; }

if [[ -x $RUNNER_SERVICE ]]; then
  service_stopped=1
  sudo "$RUNNER_SERVICE" stop
fi

sudo rm -rf "$BACKUP"
swap_started=1
if sudo test -d "$TARGET"; then
  sudo mv "$TARGET" "$BACKUP"
  old_moved=1
fi
sudo mv "$CANDIDATE" "$TARGET"
new_installed=1
install_launchers "$TARGET"

baseline_capabilities=$(sudo "$LAUNCHER_DIR/modern-fs-benchmark-run" \
  --revision "$revision" --capabilities)
for capability in hardware-random-scaling-v2 md-integrity-parity-v1 \
  hardware-profile:sas-hdd; do
  grep -Fxq "$capability" <<<"$baseline_capabilities" \
    || { echo "deployed baseline launcher lacks $capability" >&2; exit 1; }
done

sudo "$LAUNCHER_DIR/modern-fs-benchmark-hybrid-tier-run" \
  --revision "$revision" --capabilities \
  | grep -Fxq benchmark-scenario:hybrid-tier-v1
sudo "$LAUNCHER_DIR/modern-fs-benchmark-hybrid-tier-v2-run" \
  --revision "$revision" --capabilities \
  | grep -Fxq benchmark-scenario:hybrid-tier-v2

if (( service_stopped )); then
  sudo "$RUNNER_SERVICE" start
  service_stopped=0
fi
deployment_complete=1
sudo rm -rf "$BACKUP"

echo "deployed SAS-HDD benchmark revision $revision"
