#!/usr/bin/env bash
# Add libvirt dnsmasq static host for hosted cluster API (HyperShift hcp1 on Dubai).
# Requires: virsh, libvirt network "default" (or set VIRSH_NET).
# Run on the hypervisor that serves DNS for 192.168.122.0/24 (same host where "virsh net-dumpxml default" works).
#
# Usage:
#   sudo ./scripts/virsh-net-add-hcp1-api-dns.sh
# Optional env:
#   VIRSH_NET=default API_HOST=api.hcp1.awezlab.local API_IP=192.168.122.31

set -euo pipefail

NET="${VIRSH_NET:-default}"
API_HOST="${API_HOST:-api.hcp1.awezlab.local}"
API_IP="${API_IP:-192.168.122.31}"

# libvirt expects escaped quotes inside the XML fragment for net-update
XML="<host ip='${API_IP}'><hostname>${API_HOST}</hostname></host>"

if ! virsh net-info "${NET}" &>/dev/null; then
  echo "error: libvirt network '${NET}' not found" >&2
  exit 1
fi

echo "Adding DNS host to net '${NET}': ${API_HOST} -> ${API_IP}"
# add-first: insert near top of <dns>; use add-last if you prefer end of list
virsh net-update "${NET}" add-first dns-host "${XML}" --live --config

echo "Done. Flush DNS on clients (e.g. dscacheutil -flushcache on macOS) and test:"
echo "  ping -c1 ${API_HOST}"
echo "  curl -skI https://${API_HOST}:6443/readyz"
