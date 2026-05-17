DNS for HyperShift hcp1 on Dubai (after restore / MetalLB)

1) Hosted API (kube-apiserver LoadBalancer in namespace hcp1-hcp1 on Dubai OCP)
   Name:  api.hcp1.awezlab.local
   Name:  api-int.hcp1.awezlab.local
   A:     192.168.122.31

2) HCP Routes on Dubai management ingress (not the API VIP)
   ignition.hcp1.awezlab.local, oauth.hcp1, oidc.hcp1, konnectivity.hcp1
   A:     192.168.122.252

3) Hosted data-plane apps (*.apps.hcp1.awezlab.local) — unchanged unless ingress moved
   Wildcard via dnsmasq: 192.168.122.21

Cutover script (hypervisor with libvirt "default" network)
----------------------------------------------------------
After Velero restore on Dubai, on the host where BM VMs get DNS from 192.168.122.1:

  sudo ./scripts/virsh-net-cutover-hcp1-dns.sh dubai

This moves:
  api / api-int     192.168.122.11  ->  192.168.122.31
  ignition/oauth/oidc/konnectivity  192.168.122.253 ->  192.168.122.252

Rollback to ACM:

  sudo ./scripts/virsh-net-cutover-hcp1-dns.sh acm

Dry-run:

  ./scripts/virsh-net-cutover-hcp1-dns.sh dubai --dry-run

Also update HAProxy api-hcp1-be to 192.168.122.31:6443 (infra/lab-haproxy/README.txt).

Alternative (ACM-only / first install)
--------------------------------------
  sudo ./scripts/virsh-net-add-hcp1-api-dns.sh

Manual /etc/hosts (workstation only)
------------------------------------
  dns/hosts-snippet.txt
