#!/usr/bin/env bash
#
# Create MinIO VM on libvirt default network with 200 GiB disk (kcli plan).
# Run on the hypervisor as a user that can run kcli against libvirt.
#
# Usage:
#   ./scripts/bootstrap-minio-vm.sh
# Env:
#   PLAN_NAME=minio-dr  NETWORK=default  DISK_GB=200  REPO_ROOT=..  (auto-detected)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLAN_FILE="${REPO_ROOT}/kcli-plans/minio-dr-vm.yml"
NETWORK="${NETWORK:-default}"
DISK_GB="${DISK_GB:-200}"

if ! command -v kcli >/dev/null 2>&1; then
  echo "error: kcli not found in PATH" >&2
  exit 1
fi
if [[ ! -f "${PLAN_FILE}" ]]; then
  echo "error: missing plan ${PLAN_FILE}" >&2
  exit 1
fi

echo "Applying kcli plan from ${PLAN_FILE} (network=${NETWORK}, disk_gb=${DISK_GB})..."
kcli create plan -f "${PLAN_FILE}" -P "network=${NETWORK}" -P "disk_gb=${DISK_GB}"

echo
echo "Next steps:"
echo "  1. Wait for first boot:  kcli info vm minio-dr"
echo "  2. Install MinIO on the guest (from repo root on hypervisor):"
echo "       kcli ssh root@minio-dr -- bash -s < ${REPO_ROOT}/scripts/install-minio-on-guest.sh"
echo "  3. Change MINIO_ROOT_PASSWORD on the guest (edit /etc/systemd/system/minio.service, then systemctl daemon-reload && systemctl restart minio)."
echo "  4. mc alias set dr http://<VM_IP>:9000 minioadmin <password> && mc mb dr/velero"
echo "  5. For production, replace cleartext secrets with sealed secrets or ESO; POC uses Git as-is."
echo "  6. Ensure ACM and Dubai-OCP can reach <VM_IP>:9000 on virbr0."
