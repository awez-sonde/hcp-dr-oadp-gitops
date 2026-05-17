# HyperShift + OADP lab prerequisites (ACM / MCE)

Use this checklist **before** creating a `HostedCluster` on a fresh ACM (management) cluster, and before enabling GitOps backup/restore. It aligns with [HyperShift DR prerequisites](https://hypershift.pages.dev/how-to/disaster-recovery/prerequisites/) and lessons from this lab (MetalLB VIP drift, missing API hostname, NFS etcd permissions after restore).

## 1. Management cluster (ACM) — platform

| Item | Doc / why | This repo |
|------|-----------|-----------|
| **MCE / HyperShift** installed and healthy | Required to host control planes | Out of scope here (install via ACM/MCE docs) |
| **StorageClass** for etcd PVCs | DR prereq: valid SC on management cluster | You choose SC (lab often **NFS**); see [NFS and etcd](nfs-etcd-storage.md) |
| **MetalLB** (or cloud LB) for `LoadBalancer` services | Hosted APIServer publishing type `LoadBalancer` needs an external IP | **ACM:** `manifests/metallb-acm/` + `gitops/applications/acm/00-*metallb*` |
| **Non-overlapping IP pools** | MinIO, ACM ingress VIPs, HCP API pool must not collide | Keep **object store** (e.g. `192.168.122.8`) **outside** MetalLB pools |
| **OpenShift GitOps + RBAC** | GitOps for OADP in this repo | `bootstrap/openshift-gitops/`, `gitops/rbac/`, `gitops/applications/acm/` |
| **OADP + Velero + DPA** | Backup/restore | `manifests/oadp/`, Argo apps `02`–`03` |
| **S3-compatible backup store** | Shared by ACM and recovery cluster | `manifests/oadp/config/dpa-minio.yaml` (edit URL/keys) |

## 2. HostedCluster — service publishing (critical for DR)

**Gap we hit last time:** `HostedControlPlane` had only:

```yaml
- service: APIServer
  servicePublishingStrategy:
    type: LoadBalancer
```

No `loadBalancer.hostname`. The API was exposed as a **raw MetalLB IP** (e.g. `192.168.122.11`). After restore on another management cluster, workers and kubeconfig still pointed at the **old IP**; DNS changes alone could not fix nodes that had a **literal IP** in kubeconfig.

**Doc minimum** ([prerequisites](https://hypershift.pages.dev/how-to/disaster-recovery/prerequisites/)):

```yaml
spec:
  services:
  - service: APIServer
    servicePublishingStrategy:
      type: LoadBalancer
      loadBalancer:
        hostname: api.hcp1.awezlab.local   # stable name YOU control
```

**Recommended:** fixed hostnames for OAuth, OIDC, Konnectivity, Ignition (`route.hostname`).

**Example in this repo:** `examples/hostedcluster-agent-dr-ready.yaml` (edit names, pull secret, agent namespace, release image).

**DNS / HAProxy (lab):**

1. Create **libvirt** `<dns><host>` or `/etc/hosts`: `api.hcp1.awezlab.local` → **current** MetalLB VIP for that cluster’s `kube-apiserver` Service.
2. Update **HAProxy** `api-hcp1-be` backend to that same IP:6443 (`infra/lab-haproxy/haproxy.cfg`).
3. On **DR cutover**, run **`scripts/virsh-net-cutover-hcp1-dns.sh dubai`** on the hypervisor (moves API `.11`→`.31`, HCP Routes `.253`→`.252`); update HAProxy; hostname in `HostedCluster` spec stays the same.

## 3. Bare metal / Agent provider

| Item | Doc | Lab note |
|------|-----|----------|
| **InfraEnv** in namespace **separate** from HostedControlPlane namespace | DR prereq | e.g. InfraEnv in `hcp1`, HCP namespace `hcp1-hcp1` |
| Do **not** delete InfraEnv during backup/restore | DR prereq | Back up agent/InfraEnv resources if your runbook includes them |

## 4. IP plan (this lab reference)

| Use | Example range / IP |
|-----|---------------------|
| ACM management API / apps (libvirt DNS) | `192.168.122.253` |
| Dubai management API / apps | `192.168.122.252` |
| **ACM MetalLB pool for hosted APIs** | `192.168.122.11`–`192.168.122.20` (`manifests/metallb-acm/`) |
| **Dubai MetalLB pool for hosted APIs** | `192.168.122.31`–`192.168.122.40` (`manifests/metallb/`) |
| MinIO | `192.168.122.8` (keep out of MetalLB pools) |
| Hosted **data-plane** ingress (`*.apps.hcp1...`) | Separate VIP (e.g. `.21`) via workers/ingress — not the API pool |

Assign **one** IP from the ACM pool to `kube-apiserver` LoadBalancer; point **`api.hcp1.awezlab.local`** at that IP **before** workers join.

## 5. Order of operations (fresh ACM)

1. Install **ACM / MCE / HyperShift** (product docs).
2. Install **MetalLB** on ACM from this repo; confirm pool is **Available**.
3. Install **GitOps** → **RBAC** → **OADP** (operator, then DPA) → optional **backup Schedule**.
4. Configure **DNS/HAProxy** for management and (planned) hosted API hostname.
5. Create **HostedCluster** using **`examples/hostedcluster-agent-dr-ready.yaml`** (with `loadBalancer.hostname`).
6. After HCP is up: confirm `oc get svc kube-apiserver -n <hcp-ns>` has `EXTERNAL-IP`, DNS matches, `admin-kubeconfig` uses **hostname** or correct IP.
7. Create **NodePool** / agents; verify workers **Ready**.

## 6. Restore-only assets (not for day-1 install)

| Path | When |
|------|------|
| `manifests/hcp1-etcd-nfs-perm-fix/` | After **Velero restore** if etcd pods fail with `permission denied` on `/var/lib/data` |
| `manifests/restore/dubai/` | Gated restore on recovery cluster |
| `gitops/applications/dubai/examples/07-argocd-velero-restore.application.yaml` | Manual Argo sync for restore |

See [NFS and etcd](nfs-etcd-storage.md) for **pre-install** vs **post-restore** permission guidance.

## 7. Repo coverage vs gaps (summary)

| Prerequisite | In repo today? |
|--------------|----------------|
| OADP / Velero / backup Schedule | Yes (`manifests/oadp/`, `manifests/hcp-backup/`, Argo ACM/Dubai) |
| MetalLB on **Dubai** | Yes |
| MetalLB on **ACM** | Yes (`manifests/metallb-acm/`, Argo `00-*`) |
| **HostedCluster with API hostname** | Yes (`examples/hostedcluster-agent-dr-ready.yaml`) |
| HAProxy / libvirt DNS notes | Yes (`infra/lab-haproxy/`, `dns/`, `scripts/virsh-net-add-hcp1-api-dns.sh`) |
| NFS etcd **pre-install** guidance | Yes (`docs/nfs-etcd-storage.md`) |
| NFS etcd **post-restore** fix Job | Yes (`manifests/hcp1-etcd-nfs-perm-fix/`) |
| MCE install manifests | No — use Red Hat ACM/MCE documentation |
