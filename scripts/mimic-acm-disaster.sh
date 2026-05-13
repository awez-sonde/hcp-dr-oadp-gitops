#!/usr/bin/env bash
#
# Lab helper: simulate loss of the ACM *management* cluster (or heavy impairment).
# Default: stop all VMs whose kcli cluster name is "acm" (non-destructive to disk).
#
# NOT for production. Review before use.
#
# Usage:
#   ./scripts/mimic-acm-disaster.sh              # DRILL=stop_vms (default)
#   DRILL=cordon_only ./scripts/mimic-acm-disaster.sh   # needs KUBECONFIG=ACM
#   DRILL=network_note ./scripts/mimic-acm-disaster.sh # prints iptables example only
#
# Env:
#   DRILL=stop_vms|cordon_only|network_note
#   KCLI_CLUSTER=acm
#   KUBECONFIG  (for cordon_only — path to ACM admin kubeconfig)
#
set -euo pipefail

DRILL="${DRILL:-stop_vms}"
KCLI_CLUSTER="${KCLI_CLUSTER:-acm}"

case "${DRILL}" in
  stop_vms)
    if ! command -v kcli >/dev/null 2>&1; then
      echo "error: kcli not found" >&2
      exit 1
    fi
    echo "Stopping VMs for kcli cluster '${KCLI_CLUSTER}'..."
    kcli stop cluster "${KCLI_CLUSTER}" || {
      echo "warn: kcli stop cluster failed (wrong cluster name or not kcli-managed?)." >&2
      echo "      List: kcli list vm" >&2
      exit 1
    }
    echo "Done. To recover: kcli start cluster ${KCLI_CLUSTER}"
    ;;
  cordon_only)
    if [[ -z "${KUBECONFIG:-}" ]]; then
      echo "error: set KUBECONFIG to ACM admin kubeconfig" >&2
      exit 1
    fi
    if ! command -v oc >/dev/null 2>&1; then
      echo "error: oc not found" >&2
      exit 1
    fi
    echo "Cordoning all nodes on current cluster (ACM)..."
    for n in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
      oc adm cordon "$n"
    done
    echo "Done. Uncordon when finished: oc adm uncordon <node>"
    ;;
  network_note)
    cat <<EOF
DRILL=network_note (manual)

Example on hypervisor to block libvirt default traffic TO ACM API VIP only
(replace 192.168.122.253 with your ACM VIP; test in screen session):

  sudo iptables -I FORWARD 1 -d 192.168.122.253 -j DROP
  # revert:
  sudo iptables -D FORWARD -d 192.168.122.253 -j DROP

Prefer lab VLAN isolation or kcli 'stop cluster' over permanent iptables rules.
EOF
    ;;
  *)
    echo "error: unknown DRILL=${DRILL}" >&2
    exit 1
    ;;
esac
