#!/usr/bin/env bash
# Libvirt "default" network DNS for HyperShift hcp1 on the lab hypervisor.
# - api.hcp1.awezlab.local -> hosted kube-apiserver MetalLB VIP (ACM: .11, Dubai: .31)
# - ignition/oauth/oidc/konnectivity.hcp1.* -> ACM ingress router hostNetwork IP (.9), NOT api.acm VIP (.253)
#   If routes were pointed at .253, workers get 503 on :443 during install. Use virsh-net-fix-hcp1-route-dns.sh.
#
# Requires: virsh, libvirt network "default" (or VIRSH_NET).
# Run on the host where "virsh net-dumpxml default" shows 192.168.122.1.
#
# Usage:
#   sudo ./scripts/virsh-net-add-hcp1-api-dns.sh              # ACM defaults
#   API_IP=192.168.122.31 ./scripts/virsh-net-add-hcp1-api-dns.sh   # Dubai API VIP
#
# Optional env:
#   VIRSH_NET=default
#   API_HOST=api.hcp1.awezlab.local
#   API_IP=192.168.122.11
#   ACM_INGRESS_IP=192.168.122.9   # hostNetwork router node (NOT .253 API VIP)
#   REMOVE_STALE_API_IP=192.168.122.31

set -euo pipefail

NET="${VIRSH_NET:-default}"
API_HOST="${API_HOST:-api.hcp1.awezlab.local}"
API_IP="${API_IP:-192.168.122.11}"
ACM_INGRESS_IP="${ACM_INGRESS_IP:-192.168.122.253}"
REMOVE_STALE_API_IP="${REMOVE_STALE_API_IP:-192.168.122.31}"

HCP_ROUTE_HOSTS=(
  ignition.hcp1.awezlab.local
  oauth.hcp1.awezlab.local
  oidc.hcp1.awezlab.local
  konnectivity.hcp1.awezlab.local
)

if ! virsh net-info "${NET}" &>/dev/null; then
  echo "error: libvirt network '${NET}' not found" >&2
  exit 1
fi

parent_index_for_ip() {
  local ip="$1" idx=0 line
  while IFS= read -r line; do
    if [[ "${line}" == *"<host ip='${ip}'>"* ]]; then
      echo "${idx}"
      return 0
    fi
    ((idx++)) || true
  done < <(virsh net-dumpxml "${NET}" | grep '<host ip=')
  return 1
}

API_INT_HOST="${API_INT_HOST:-api-int.hcp1.awezlab.local}"

echo "== ${NET}: api ${API_HOST} + ${API_INT_HOST} -> ${API_IP} =="
API_BLOCK="$(virsh net-dumpxml "${NET}" | sed -n "/<host ip='${API_IP}'>/,/<\\/host>/p")"
mapfile -t API_HOSTNAMES < <(echo "${API_BLOCK}" | sed -n 's|.*<hostname>\(.*\)</hostname>.*|\1|p')
if printf '%s\n' "${API_HOSTNAMES[@]}" | grep -qxF "${API_HOST}" && \
   printf '%s\n' "${API_HOSTNAMES[@]}" | grep -qxF "${API_INT_HOST}"; then
  echo "skip: ${API_HOST} and ${API_INT_HOST} already on ${API_IP}"
else
  API_HOSTNAMES+=("${API_HOST}" "${API_INT_HOST}")
  # dedupe
  mapfile -t API_HOSTNAMES < <(printf '%s\n' "${API_HOSTNAMES[@]}" | awk '!seen[$0]++')
  MODIFY_API="<host ip='${API_IP}'>"
  for h in "${API_HOSTNAMES[@]}"; do MODIFY_API+="<hostname>${h}</hostname>"; done
  MODIFY_API+="</host>"
  if [[ -n "${API_BLOCK}" ]]; then
    idx="$(parent_index_for_ip "${API_IP}")"
    virsh net-update "${NET}" modify dns-host "${MODIFY_API}" \
      --parent-index "${idx}" --live --config
  else
    virsh net-update "${NET}" add-first dns-host "${MODIFY_API}" --live --config
  fi
fi

if [[ -n "${REMOVE_STALE_API_IP}" ]] && virsh net-dumpxml "${NET}" | grep -qF "<host ip='${REMOVE_STALE_API_IP}'>" && \
   virsh net-dumpxml "${NET}" | grep -A3 "<host ip='${REMOVE_STALE_API_IP}'>" | grep -qF "<hostname>${API_HOST}</hostname>"; then
  idx="$(parent_index_for_ip "${REMOVE_STALE_API_IP}")"
  echo "== remove stale ${API_HOST} on ${REMOVE_STALE_API_IP} (parent-index ${idx}) =="
  virsh net-update "${NET}" delete dns-host "<host ip='${REMOVE_STALE_API_IP}'/>" \
    --parent-index "${idx}" --live --config
fi

idx="$(parent_index_for_ip "${ACM_INGRESS_IP}")"
if [[ -z "${idx}" ]]; then
  echo "error: no <host ip='${ACM_INGRESS_IP}'> in ${NET}; add ACM ingress host block first" >&2
  exit 1
fi

echo "== ${NET}: HCP Route hostnames on ACM ingress ${ACM_INGRESS_IP} (parent-index ${idx}) =="
# Must use modify with full <host> (add-first on duplicate IP fails; bare <hostname> fails).
ACM_BLOCK="$(virsh net-dumpxml "${NET}" | sed -n "/<host ip='${ACM_INGRESS_IP}'>/,/<\\/host>/p")"
# Collect existing hostnames under ACM ingress IP
mapfile -t EXISTING < <(echo "${ACM_BLOCK}" | sed -n 's|.*<hostname>\(.*\)</hostname>.*|\1|p')
HOSTNAMES=("${EXISTING[@]}")
for h in "${HCP_ROUTE_HOSTS[@]}"; do
  if ! printf '%s\n' "${HOSTNAMES[@]}" | grep -qxF "${h}"; then
    HOSTNAMES+=("${h}")
  fi
done

MODIFY_XML="<host ip='${ACM_INGRESS_IP}'>"
for h in "${HOSTNAMES[@]}"; do
  MODIFY_XML+="<hostname>${h}</hostname>"
done
MODIFY_XML+="</host>"

virsh net-update "${NET}" modify dns-host "${MODIFY_XML}" \
  --parent-index "${idx}" --live --config

echo ""
echo "Verify:"
echo "  nslookup ${API_HOST} 192.168.122.1"
for h in "${HCP_ROUTE_HOSTS[@]}"; do
  echo "  nslookup ${h} 192.168.122.1"
done
