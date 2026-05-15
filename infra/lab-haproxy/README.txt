Lab HAProxy reference (not applied by GitOps)

What changed for HyperShift hcp1 after restore on Dubai OCP
------------------------------------------------------------
- backend api-hcp1-be: server IP was 192.168.122.11 (old API path on ACM).
  It must target the MetalLB VIP for Service kube-apiserver in namespace
  hcp1-hcp1 on Dubai: 192.168.122.31:6443.

- Frontends api-server / SNI for api.hcp1.awezlab.local are unchanged; only
  the backend server IP was updated.

Hosted *.apps.hcp1.awezlab.local (443/80) still point to 192.168.122.21 in
this file. That is the data-plane ingress VIP in your lab. If ingress
moved after restore, update https-hcp1-be and http-hcp1-be accordingly.

Routes such as oauth-hcp1-hcp1.apps.dubai-ocp.awezlab.local use
*.apps.dubai-ocp.awezlab.local and already go to 192.168.122.252 — no
change required for those.

Deploy on the HAProxy host
--------------------------
1) Backup live config:  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d)
2) Merge or replace with infra/lab-haproxy/haproxy.cfg (adjust paths if your distro differs).
3) Validate:           haproxy -c -f /etc/haproxy/haproxy.cfg
4) Reload:             systemctl reload haproxy   # or: service haproxy reload

Quick one-line change (if only api-hcp1 backend differs)
--------------------------------------------------------
  sudo sed -i 's/server api-hcp1 192.168.122.11:6443/server api-hcp1 192.168.122.31:6443/' /etc/haproxy/haproxy.cfg
  sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
