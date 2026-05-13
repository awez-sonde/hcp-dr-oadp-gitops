# HyperShift management-plane DR lab — OADP + MinIO + OpenShift GitOps

This repository holds **lab-oriented** automation and GitOps manifests to practice **Hosted Control Plane (HyperShift) backup** from a **management cluster** (for example **ACM / MCE**) using **OADP (Velero)**, with backups stored on **S3-compatible MinIO** running on a **libvirt VM** on the `default` network. A second management cluster (**Dubai-OCP**) can run the **same** GitOps + OADP footprint so it can read the same bucket for **restore** drills.

## Corrections to the mental model (read this first)

1. **Where OADP runs**  
   OADP for **HostedCluster / control plane backup** is installed on the **management cluster** (where MCE / HyperShift runs), not on the bare-metal **data plane** workers of the hosted cluster. You typically install OADP on **ACM** for backups, and on **Dubai-OCP** if you want the **restore site** to have Velero/OADP tooling and the same `BackupStorageLocation` configuration.

2. **What GitOps should (and should not) continuously reconcile**  
   - **Safe to GitOps continuously:** OpenShift GitOps operator, OADP operator, namespaces, RBAC, `Secret` references (prefer SealedSecrets / External Secrets in real environments), `DataProtectionApplication`, `BackupStorageLocation`, `Schedule` (optional).  
   - **Dangerous to leave as an always-synced Application:** a **Velero `Restore`** or one-shot **HyperShift restore** — a controller can re-apply a completed restore or fight manual steps. Treat **restore** as a **documented procedure** plus **one-shot** manifests (apply once, then remove or set `syncPolicy: {}` / disable automation). This repo ships **examples** under `gitops/applications/dubai/` for prep manifests only; the actual HyperShift restore still follows [HyperShift DR documentation](https://hypershift.pages.dev/how-to/disaster-recovery/).

3. **“Destroy ACM”**  
   That is ambiguous. For an **HCP DR drill** you usually either:  
   - simulate loss of the **management plane** (stop ACM control-plane VMs / isolate network), or  
   - delete only the **HostedCluster** / namespaces after a backup (greenfield restore per upstream notes).  
   The included script **stops** kcli-managed ACM VMs by default; it does not delete etcd data unless you opt in. Adjust to match what you really want to test.

4. **MinIO IP vs MetalLB**  
   MinIO lives on a **VM with a stable IP** (DHCP reservation or static). It should **not** overlap **MetalLB pools** on any cluster on the same L2 network.

5. **API VIP after restore**  
   The **API DNS name** should stay stable; the **MetalLB IP** on Dubai **may differ** from ACM. Update DNS / HAProxy after restore (see prior discussion).

## Repository layout

| Path | Purpose |
|------|---------|
| `kcli-plans/minio-dr-vm.yml` | kcli plan: VM on `default`, **200 GiB** data disk |
| `scripts/bootstrap-minio-vm.sh` | Create VM via kcli (200 GiB disk); then run `install-minio-on-guest.sh` over `kcli ssh` |
| `scripts/install-minio-on-guest.sh` | Installs MinIO binary + systemd (run on guest or pipe via `kcli ssh`) |
| `scripts/mimic-acm-disaster.sh` | **Lab only:** stop ACM VMs or cordon nodes (configurable) |
| `bootstrap/openshift-gitops/` | OperatorGroup + Subscription for **OpenShift GitOps** (apply on **each** management cluster once) |
| `gitops/rbac/` | `ClusterRole` + `ClusterRoleBinding` so **Argo CD application-controller** can reconcile HyperShift + OADP + Velero APIs |
| `manifests/oadp/` | Namespace, OperatorGroup, Subscription, `Secret` template, `DataProtectionApplication` (kustomize-friendly) |
| `gitops/applications/acm/` | Argo CD `Application` CRs pointing at this repo (paths below) |
| `gitops/applications/dubai/` | Same for Dubai + optional one-shot restore **examples** |

## End-to-end flow (high level)

1. **Hypervisor:** run `scripts/bootstrap-minio-vm.sh` (or `kcli create plan -f kcli-plans/minio-dr-vm.yml`). Create MinIO bucket + user; record URL like `http://192.168.122.60:9000` reachable from **both** management clusters.
2. **ACM & Dubai:** ensure **non-overlapping MetalLB pools** on the shared L2 segment.
3. **ACM & Dubai:** `oc apply -k bootstrap/openshift-gitops/` and wait for `openshift-gitops` Argo CD to be ready.
4. **ACM & Dubai:** `oc apply -f gitops/rbac/` (binds Argo CD controller SA to the bundled `ClusterRole`).
5. **Fork / clone this repo** and set your Git URL; edit `manifests/oadp/kustomization.yaml` **configMapGenerator** or use **patches** for `s3Url`, bucket, and credentials (never commit real secrets).
6. **ACM & Dubai:** apply `gitops/applications/acm/` and `gitops/applications/dubai/` (after editing `spec.source.repoURL` in each file).
7. **Backup:** follow HyperShift OADP backup procedure (CLI or plugins) once Velero/OADP is healthy — see upstream [Backup and restore with OADP](https://hypershift.pages.dev/how-to/disaster-recovery/backup-and-restore-oadp/).
8. **DR drill:** run `scripts/mimic-acm-disaster.sh`; on Dubai, execute **restore** steps from upstream docs; update DNS for API/apps to Dubai MetalLB VIPs.

## Prerequisites

- kcli + libvirt on the hypervisor (for the MinIO VM script).
- Two OpenShift management clusters with routing to the Minio endpoint.
- `oc` / `kubectl` with **cluster-admin** for bootstrap applies.
- HostedCluster **fixed hostnames** in `servicePublishingStrategy` for cross-management restore (upstream prerequisite).

## Quick start commands

```bash
# 0) Make this directory its own git remote (optional)
cd hcp-dr-oadp-gitops && git init && git add . && git commit -m "Initial DR lab scaffold"

# 1) Hypervisor — MinIO VM
chmod +x scripts/*.sh
./scripts/bootstrap-minio-vm.sh
# Install MinIO on the guest from the hypervisor (note the `<` — without it, `bash -s` hangs):
#   kcli ssh root@minio-dr -- bash -s < ./scripts/install-minio-on-guest.sh
# Or if the script is already on the guest:  kcli ssh root@minio-dr -- bash /root/.../install-minio-on-guest.sh

# 2) Each management cluster (ACM, then Dubai)
export KUBECONFIG=/path/to/admin-kubeconfig
./scripts/apply-bootstrap-gitops.sh
# Wait for openshift-gitops pods Ready, then verify Argo CD’s application-controller SA name:
oc get sa -n openshift-gitops | grep application-controller
# If the name differs from openshift-gitops-argocd-application-controller, edit
# gitops/rbac/argocd-hcp-dr-clusterrole.yaml subjects before the next step.

oc apply -f gitops/rbac/

# 3) Fork repo, replace CHANGEME_ORG in gitops/applications/*/*.yaml, patch MinIO URL + Secret, commit.
#    Then apply Argo Applications:
oc apply -f gitops/applications/acm/    # or dubai/

# 4) Velero restore (one-shot, Dubai) — only after upstream backup exists
#    oc apply -f manifests/restore/velero-restore.example.yaml  # edit backupName first
```

## Disclaimer

This is a **lab scaffold**. Tighten RBAC, use sealed secrets, pin operator versions, and validate against your OpenShift / OADP / MCE versions before production use.
