#!/usr/bin/env bash
# Fix libvirt DNS: HCP Route hostnames must point at ACM ingress router (hostNetwork),
# NOT at api.acm VIP (.253) which only serves API on 6443 and returns 503 for ignition SNI on 443.
#
# ACM default router pods run on control-plane nodes (e.g. 192.168.122.9, .4) with hostNetwork.
#
# Usage:
#   sudo ./scripts/virsh-net-fix-hcp1-route-dns.sh
#   ROUTER_IP=192.168.122.9 ACM_API_IP=192.168.122.253 ./scripts/virsh-net-fix-hcp1-route-dns.sh

set -euo pipefail

NET="${VIRSH_NET:-default}"
ACM_API_IP="${ACM_API_IP:-192.168.122.253}"
ROUTER_IP="${ROUTER_IP:-192.168.122.9}"

HCP_ROUTE_HOSTS=(
  ignition.hcp1.awezlab.local
  oauth.hcp1.awezlab.local
  oidc.hcp1.awezlab.local
  konnectivity.hcp1.awezlab.local
)

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

echo "== ${NET}: remove HCP route names from api.acm block ${ACM_API_IP} =="
ACM_BLOCK="$(virsh net-dumpxml "${NET}" | sed -n "/<host ip='${ACM_API_IP}'>/,/<\\/host>/p")"
mapfile -t KEEP_HOSTNAMES < <(echo "${ACM_BLOCK}" | sed -n 's|.*<hostname>\(.*\)</hostname>.*|\1|p' | grep -v 'hcp1\.awezlab\.local' || true)

MODIFY_ACM="<host ip='${ACM_API_IP}'>"
for h in "${KEEP_HOSTNAMES[@]}"; do
  MODIFY_ACM+="<hostname>${h}</hostname>"
done
MODIFY_ACM+="</host>"

idx="$(parent_index_for_ip "${ACM_API_IP}")"
if [[ -z "${idx}" ]]; then
  echo "error: no host block for ${ACM_API_IP}" >&2
  exit 1
fi
virsh net-update "${NET}" modify dns-host "${MODIFY_ACM}" \
  --parent-index "${idx}" --live --config

echo "== ${NET}: add HCP route hostnames to router block ${ROUTER_IP} =="
ROUTER_BLOCK="$(virsh net-dumpxml "${NET}" | sed -n "/<host ip='${ROUTER_IP}'>/,/<\\/host>/p" || true)"
HOSTNAMES=()
if [[ -n "${ROUTER_BLOCK}" ]]; then
  mapfile -t HOSTNAMES < <(echo "${ROUTER_BLOCK}" | sed -n 's|.*<hostname>\(.*\)</hostname>.*|\1|p')
fi
for h in "${HCP_ROUTE_HOSTS[@]}"; do
  if ! printf '%s\n' "${HOSTNAMES[@]:-}" | grep -qxF "${h}"; then
    HOSTNAMES+=("${h}")
  fi
done

MODIFY_ROUTER="<host ip='${ROUTER_IP}'>"
for h in "${HOSTNAMES[@]}"; do
  MODIFY_ROUTER+="<hostname>${h}</hostname>"
done
MODIFY_ROUTER+="</host>"

if [[ -n "${ROUTER_BLOCK}" ]]; then
  idx="$(parent_index_for_ip "${ROUTER_IP}")"
  virsh net-update "${NET}" modify dns-host "${MODIFY_ROUTER}" \
    --parent-index "${idx}" --live --config
else
  virsh net-update "${NET}" add-first dns-host "${MODIFY_ROUTER}" --live --config
fi

echo ""
echo "Verify:"
for h in api.hcp1.awezlab.local ignition.hcp1.awezlab.local oauth.hcp1.awezlab.local; do
  echo -n "  ${h} -> "
  nslookup "${h}" 192.168.122.1 2>/dev/null | awk '/^Address: / {print $2}' | grep -v '122\.1$' | head -1
done
