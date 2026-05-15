DNS for HyperShift hcp1 on Dubai (after restore / MetalLB)

1) Hosted API (kube-apiserver LoadBalancer in namespace hcp1-hcp1 on Dubai OCP)
   Name:  api.hcp1.awezlab.local
   A:     192.168.122.31

2) If your base domain is not awezlab.local, edit the hostname in the script before running.

3) Pick ONE approach:
   A) scripts/virsh-net-add-hcp1-api-dns.sh  — adds <dns><host> to libvirt "default" (needs virsh, network name "default")
   B) dns/hosts-snippet.txt                 — append to /etc/hosts on clients (Mac/Linux) for quick tests

Hosted OAuth/console routes already use apps.dubai-ocp.awezlab.local (management ingress); keep your
existing wildcard for that domain unless you changed ingress VIPs.
