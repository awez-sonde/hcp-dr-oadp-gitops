#!/usr/bin/env bash
# Run *inside* the minio-dr guest (root), or pipe from hypervisor.
#
# Wrong (hangs forever):  kcli ssh root@minio-dr -- bash -s /path/to/this/script.sh
#   With -s, bash reads the program from STDIN; the path is only $1, not a file to execute.
#
# From hypervisor (script file on hypervisor — use stdin redirect):
#   kcli ssh root@minio-dr -- bash -s < /path/to/install-minio-on-guest.sh
#
# If the script is already on the guest at /root/.../install-minio-on-guest.sh:
#   kcli ssh root@minio-dr -- bash /root/.../install-minio-on-guest.sh
#
# Installs MinIO to /data/minio, systemd unit, default creds (CHANGE PASSWORD).
#
set -euo pipefail
export MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
export MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-redhat}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root on the guest" >&2
  exit 1
fi

if command -v dnf >/dev/null 2>&1; then
  dnf install -y curl ca-certificates
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates
fi

curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio
chmod +x /usr/local/bin/minio
id minio-user >/dev/null 2>&1 || useradd -r minio-user -s /sbin/nologin
mkdir -p /data/minio
chown -R minio-user:minio-user /data/minio

cat >/etc/systemd/system/minio.service <<UNIT
[Unit]
Description=MinIO Object Storage
After=network-online.target
Wants=network-online.target

[Service]
User=minio-user
Group=minio-user
Environment=MINIO_ROOT_USER=${MINIO_ROOT_USER}
Environment=MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
ExecStart=/usr/local/bin/minio server /data/minio --console-address ":9001"
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now minio.service
systemctl --no-pager -l status minio.service || true
echo "MinIO API :9000  console :9001 — set MINIO_ROOT_PASSWORD then re-run this script or edit unit file."
