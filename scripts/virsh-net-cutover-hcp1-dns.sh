#!/usr/bin/env bash
# Cutover libvirt "default" network DNS for HyperShift hcp1 between ACM and Dubai (DR).
#
# Run on the lab hypervisor (where virsh net-dumpxml default shows 192.168.122.1)
# after Velero/HyperShift restore on the target management cluster.
#
# Usage:
#   sudo ./scripts/virsh-net-cutover-hcp1-dns.sh dubai    # ACM -> Dubai (API .11 -> .31)
#   sudo ./scripts/virsh-net-cutover-hcp1-dns.sh acm      # Dubai -> ACM (rollback)
#   ./scripts/virsh-net-cutover-hcp1-dns.sh dubai --dry-run
#
# What changes:
#   api.hcp1.awezlab.local, api-int.hcp1.awezlab.local
#     ACM: 192.168.122.11  |  Dubai: 192.168.122.31  (kube-apiserver MetalLB VIP)
#   ignition/oauth/oidc/konnectivity.hcp1.awezlab.local (HCP Routes on mgmt ingress)
#     ACM: 192.168.122.253 |  Dubai: 192.168.122.252
#
# Also update HAProxy api-hcp1-be (see infra/lab-haproxy/README.txt).

set -euo pipefail

NET="${VIRSH_NET:-default}"
DNS_SERVER="${DNS_SERVER:-192.168.122.1}"
DRY_RUN="${DRY_RUN:-0}"

API_HOST="${API_HOST:-api.hcp1.awezlab.local}"
API_INT_HOST="${API_INT_HOST:-api-int.hcp1.awezlab.local}"

HCP_ROUTE_HOSTS=(
  ignition.hcp1.awezlab.local
  oauth.hcp1.awezlab.local
  oidc.hcp1.awezlab.local
  konnectivity.hcp1.awezlab.local
)

MODE="${1:-}"
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

case "${MODE}" in
  dubai)
    API_IP_FROM=192.168.122.11
    API_IP_TO=192.168.122.31
    ROUTE_IP_FROM=192.168.122.253
    ROUTE_IP_TO=192.168.122.252
    ;;
  acm)
    API_IP_FROM=192.168.122.31
    API_IP_TO=192.168.122.11
    ROUTE_IP_FROM=192.168.122.252
    ROUTE_IP_TO=192.168.122.253
    ;;
  *)
    echo "usage: $0 {dubai|acm} [--dry-run]" >&2
    echo "  dubai  — point hcp1 DNS at Dubai after restore (API .31, Routes .252)" >&2
    echo "  acm    — point hcp1 DNS back at ACM (API .11, Routes .253)" >&2
    exit 1
    ;;
esac

API_HOSTS=("${API_HOST}" "${API_INT_HOST}")

run_virsh() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] virsh net-update ${NET} $*"
  else
    virsh net-update "${NET}" "$@"
  fi
}

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

hostnames_for_ip() {
  local ip="$1"
  virsh net-dumpxml "${NET}" | sed -n "/<host ip='${ip}'>/,/<\\/host>/p" \
    | sed -n 's|.*<hostname>\(.*\)</hostname>.*|\1|p'
}

host_block_exists() {
  virsh net-dumpxml "${NET}" | grep -qF "<host ip='${1}'>"
}

set_hostnames_on_ip() {
  local ip="$1"
  shift
  local -a names=("$@")
  local xml idx
  xml="<host ip='${ip}'>"
  for n in "${names[@]}"; do
    [[ -n "${n}" ]] && xml+="<hostname>${n}</hostname>"
  done
  xml+="</host>"

  if ! host_block_exists "${ip}"; then
    echo "== add host block ${ip} (${#names[@]} names) =="
    run_virsh add-first dns-host "${xml}" --live --config
    return
  fi

  idx="$(parent_index_for_ip "${ip}")"
  echo "== modify host block ${ip} parent-index ${idx} (${#names[@]} names) =="
  run_virsh modify dns-host "${xml}" --parent-index "${idx}" --live --config
}

remove_hostnames_from_ip() {
  local ip="$1"
  shift
  local -a remove=("$@")
  local -a keep=()

  if ! host_block_exists "${ip}"; then
    echo "skip: no block for ${ip}"
    return
  fi

  mapfile -t keep < <(hostnames_for_ip "${ip}")
  if [[ ${#keep[@]} -eq 0 ]]; then
    echo "skip: empty block ${ip}"
    return
  fi

  for h in "${remove[@]}"; do
    mapfile -t keep < <(printf '%s\n' "${keep[@]}" | grep -vxF "${h}" || true)
  done

  local idx
  idx="$(parent_index_for_ip "${ip}")"
  if [[ ${#keep[@]} -eq 0 ]]; then
    echo "== delete empty host block ${ip} (parent-index ${idx}) =="
    run_virsh delete dns-host "<host ip='${ip}'/>" --parent-index "${idx}" --live --config
  else
    echo "== remove names from ${ip}, keep: ${keep[*]} =="
    set_hostnames_on_ip "${ip}" "${keep[@]}"
  fi
}

move_hostnames() {
  local from_ip="$1" to_ip="$2"
  shift 2
  local -a names=("$@")
  local -a on_target=()

  if host_block_exists "${to_ip}"; then
    mapfile -t on_target < <(hostnames_for_ip "${to_ip}")
  fi

  local -a merged=("${on_target[@]}" "${names[@]}")
  mapfile -t merged < <(printf '%s\n' "${merged[@]}" | awk 'NF && !seen[$0]++')

  echo "== move $(IFS=,; echo "${names[*]}") : ${from_ip} -> ${to_ip} =="
  remove_hostnames_from_ip "${from_ip}" "${names[@]}"
  set_hostnames_on_ip "${to_ip}" "${merged[@]}"
}

verify_ns() {
  local q
  echo ""
  echo "Verify (dnsmasq ${DNS_SERVER}):"
  for q in "${API_HOST}" "${API_INT_HOST}" "${HCP_ROUTE_HOSTS[@]}"; do
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "  nslookup ${q} ${DNS_SERVER}"
    else
      echo -n "  ${q} -> "
      nslookup "${q}" "${DNS_SERVER}" 2>/dev/null \
        | awk '/^Address: / && $2 != "'"${DNS_SERVER}"'" { print $2; exit }' || echo "FAILED"
    fi
  done
}

if ! virsh net-info "${NET}" &>/dev/null; then
  echo "error: libvirt network '${NET}' not found" >&2
  exit 1
fi

echo "Cutover mode=${MODE} network=${NET} dry_run=${DRY_RUN}"
echo "  API:     ${API_IP_FROM} -> ${API_IP_TO}"
echo "  Routes:  ${ROUTE_IP_FROM} -> ${ROUTE_IP_TO}"
echo ""

move_hostnames "${API_IP_FROM}" "${API_IP_TO}" "${API_HOSTS[@]}"
move_hostnames "${ROUTE_IP_FROM}" "${ROUTE_IP_TO}" "${HCP_ROUTE_HOSTS[@]}"

verify_ns

echo ""
echo "Done. If HAProxy fronts api.hcp1, update api-hcp1-be to ${API_IP_TO}:6443 and reload haproxy."
echo "See: infra/lab-haproxy/README.txt"
