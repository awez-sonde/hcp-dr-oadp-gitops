# GitOps for HyperShift control-plane backup with OADP

This repository is a lab-oriented GitOps layout for **Hosted Control Plane (HyperShift)** disaster-recovery practice. You run the management plane on an **Advanced Cluster Management (ACM)** OpenShift cluster, install **OpenShift API for Data Protection (OADP)** and **Velero** through **OpenShift GitOps (Argo CD)**, send backups to **S3-compatible object storage** that both management clusters can reach, and mirror the same GitOps footprint on a **second management cluster** used as the recovery site.

In the reference lab, that second cluster is named **Dubai OCP**; you can treat that name as a stand-in for any **backup or secondary management cluster** where you intend to run restore drills. The hosted workload in this example is a **single** `HostedControlPlane`; the manifests assume **one bucket** and a single hosted cluster for simplicity.

The goal is not to replace upstream HyperShift or OADP documentation, but to show how GitOps can keep **operators, RBAC, and the `DataProtectionApplication`** aligned with Git while you follow the official backup and restore procedures for hosted clusters.

---

## Why this layout exists

On ACM, HyperShift hosts the API servers, etcd, and controllers for your hosted clusters. If you need to prove you can rebuild the management plane elsewhere, you need durable backups of the hosted control plane and a repeatable way to deploy **OADP, Velero, and storage credentials** on another management cluster.

The story has three parts:

1. **Shared object storage** — Any **S3-compatible** endpoint reachable from **both** management clusters (same region or well-connected network, with credentials scoped for Velero). In an enterprise that is often cloud object storage; in this lab the authors used **MinIO** as a stand-in. This README does not prescribe how you provision that storage.
2. **Primary management cluster (ACM)** — GitOps applies OADP, namespaces, cloud credentials, and a `DataProtectionApplication` that points Velero at your S3 URL and bucket.
3. **Backup management cluster** — The same manifest paths are applied on the secondary cluster so it has matching operators and `BackupStorageLocation` configuration when you run a restore drill. In this repo the example path is `gitops/applications/dubai/` to match the lab cluster name **Dubai OCP**; rename or fork paths to match your environment.

OADP for hosted-cluster backup runs on the **management** cluster where MCE or HyperShift runs, not on the hosted cluster’s worker nodes.

---

## What is in this repository

| Path | Role |
|------|------|
| `kcli-plans/minio-dr-vm.yml` | Optional lab asset: example VM plan used in the reference environment for S3-compatible storage. |
| `scripts/bootstrap-minio-vm.sh` | Optional lab asset: helper used with the plan above. |
| `scripts/install-minio-on-guest.sh` | Optional lab asset: guest-side install script for the same lab. |
| `scripts/mimic-acm-disaster.sh` | Optional lab helper to simulate loss of the management plane; non-production only. |
| `scripts/apply-bootstrap-gitops.sh` | Applies the OpenShift GitOps operator bundle once per cluster (cluster-admin). |
| `bootstrap/openshift-gitops/` | OperatorGroup, Subscription, and namespace for OpenShift GitOps. |
| `gitops/rbac/` | ClusterRole and binding so the Argo CD **application-controller** service account can manage HyperShift, OADP, and Velero APIs. |
| `manifests/oadp/operator/` | Namespace, OperatorGroup, Subscription, cleartext MinIO `Secret` (POC only). Synced first by Argo CD. |
| `manifests/oadp/config/` | `DataProtectionApplication` only. Synced by a **second** Argo `Application` after the OADP CSV installs CRDs (see below). |
| `manifests/oadp/kustomization.yaml` | Aggregates `operator` + `config` for local `kubectl kustomize`; prefer two-step `oc apply` or two Argo apps. |
| `manifests/hcp-backup/` | Velero `Schedule` for recurring **hosted control plane** backups (GitOps). Optional `backup-once.example.yaml` for a manual one-off (not in kustomize). |
| `gitops/applications/acm/` | Argo CD `Application` resources aimed at the primary (ACM) cluster. |
| `gitops/applications/dubai/` | Same pattern for the **backup** cluster (example name Dubai OCP), including optional manifests for restore-oriented GitOps. |
| `manifests/restore/` | Example Velero restore manifest; edit before restore drills. |

---

## End-to-end picture

1. Provide **S3-compatible storage** and a bucket; ensure **both** management clusters have network reachability and correct credentials.
2. On **each** management cluster, install OpenShift GitOps from `bootstrap/openshift-gitops/`, wait until Argo CD is ready, then apply `gitops/rbac/` so Applications can reconcile cluster-scoped resources.
3. Point every Argo CD `Application` at **your** Git remote (`spec.source.repoURL` and `targetRevision`). For this POC, `manifests/oadp/operator` and `manifests/oadp/config` pin the reference MinIO URL and credentials in Git; fork and edit if your lab differs.
4. Apply `gitops/applications/acm/` on the primary cluster (RBAC, OADP operator app, DPA app, then the **HCP backup** app — see [Argo CD applications for ACM](#argocd-applications-for-acm)), then `gitops/applications/dubai/` when you want a symmetric install on the backup cluster.
5. Hosted control plane backups are driven by a **Velero `Schedule`** in Git ([OADP 1.5+ HyperShift DR](https://hypershift.pages.dev/how-to/disaster-recovery/backup-and-restore-oadp-1-5/)). Tune namespaces, cron, and CSI vs FS backup in `manifests/hcp-backup/` for your platform; see [Verifying backup status on ACM](#verifying-backup-status-on-acm).
6. For a drill, follow your runbook on the backup cluster: coordinate **Velero restore**, **HyperShift restore**, and DNS or load balancing so API and application hostnames for the hosted cluster resolve to the endpoints on the recovery management cluster.

If management and storage share a flat network, keep object-store addresses **outside** overlapping **MetalLB** pools. After a restore, stable DNS names for the API often sit in front of **new** VIPs on the recovery cluster, so plan DNS or proxy updates with that in mind.

---

## Prerequisites

- Two OpenShift clusters with cluster-admin access: a **primary** management cluster (this lab uses ACM) and a **backup** management cluster (this lab uses Dubai OCP).
- S3-compatible storage reachable from **both** clusters.
- `oc` configured per cluster.
- For cross-management restore, hosted clusters should use **stable hostnames** in `servicePublishingStrategy` as required by your HyperShift version.

---

## Getting started

```bash
# On each management cluster (primary, then backup)
export KUBECONFIG=/path/to/cluster-admin-kubeconfig
./scripts/apply-bootstrap-gitops.sh
# Wait for OpenShift GitOps to finish installing, then:
oc apply -f gitops/rbac/

# Set spec.source.repoURL (and branch) on every Application to your clone, then:
oc apply -f gitops/applications/acm/
# ACM order: 01 rbac → 02 operator → 03 dpa (wait for CSV) → 04 hcp backup schedule
oc apply -f gitops/applications/dubai/   # or your fork’s path for the backup cluster
```

If your MinIO endpoint, bucket, or keys differ from the committed POC values, edit `manifests/oadp/config/dpa-minio.yaml` and `manifests/oadp/operator/secret-cloud-credentials.yaml`. The file `manifests/oadp/secret-cloud-credentials.env.example` documents the Velero `cloud` secret shape for other tooling.

## Argo CD applications for ACM

Applications live under `gitops/applications/acm/`. Apply the directory after GitOps is installed and RBAC is applied. Recommended order: **`01` → `02` → `03` (wait for OADP CSV) → `04`**.

### Two Applications for OADP (operator + DPA)

Argo CD validates **all** resources in an `Application` before it applies any of them. The `DataProtectionApplication` CRD does not exist until the OADP operator CSV is installed, so a **single** Application that includes both the `Subscription` and the `DataProtectionApplication` fails validation and leaves everything **Missing**.

This repo therefore uses two Applications on ACM (and the same pair on Dubai):

| Application | Path | Purpose |
|-------------|------|--------|
| `hcp-dr-oadp-operator` | `manifests/oadp/operator` | Namespace, OperatorGroup, Subscription, Velero cloud `Secret`. |
| `hcp-dr-oadp-dpa` | `manifests/oadp/config` | `DataProtectionApplication` only; retries until the CRD exists. |
| `hcp-dr-hcp-backup` | `manifests/hcp-backup` | Velero **`Schedule`** for recurring HCP backups. Apply after `hcp-dr-oadp-dpa` is healthy. |

If you still have the old single Application **`hcp-dr-oadp-minio`**, delete it once, then push and re-apply ACM apps:

```bash
oc delete application.argoproj.io hcp-dr-oadp-minio -n openshift-gitops --ignore-not-found
oc apply -f gitops/applications/acm/
```

If `hcp-dr-oadp-dpa` stays **OutOfSync** with a diff only on **`metadata.annotations.argocd.argoproj.io/tracking-id`**, add that path under `ignoreDifferences` on the Application (this repo does). That annotation is added by Argo on the live object and is not stored in Git.

If the diff includes **spec** (for example plugins or `nodeAgent`), Git and the cluster still differ: push your branch, **Sync** (or enable **`Replace=true`** on the Application, as in `03-argocd-oadp-dpa.application.yaml`), and confirm `oc get dpa -n openshift-adp -o yaml` matches Git.

For a manual check: `kubectl diff -f <(kubectl kustomize manifests/oadp/config) -n openshift-adp` should print nothing when Git matches the live DPA.

The separate [oadp-virtualization-recovery-iac](https://github.com/awez-sonde/oadp-virtualization-recovery-iac) PoC uses **phased Argo apps** (setup vs workload vs manual backup/recovery); the same idea applies here: operator manifests first, DPA second, and keep Git aligned with what the operator reconciles so Argo reports **Synced**.

Use a **public** Git remote with plain **HTTPS** if you want Argo CD to clone without repository credentials. Point `repoURL` at the same remote you push to. If the server cannot clone the revision in `targetRevision`, Applications will stay out of sync until the remote is reachable and the path exists at that revision.

---

## Hosted control plane backup: what GitOps does

On ACM, this repository aims for:

- **OADP + Velero + DPA** with plugins and settings aligned to [HyperShift OADP 1.5+ DR](https://hypershift.pages.dev/how-to/disaster-recovery/backup-and-restore-oadp-1-5/) (including `hypershift` and `csi` Velero plugins, snapshot location, and **node agent** for data mover–style backups).
- A **Velero `Schedule`** (`manifests/hcp-backup/`) applied by Argo (`hcp-dr-hcp-backup`) so **recurring** hosted control plane backups run on a cron after the stack is healthy.

You must still **edit** `manifests/hcp-backup/scheduled-backup-hosted-control-plane.yaml` for the correct **`spec.template.includedNamespaces`** (Velero’s `template` is a flat `BackupSpec`, not `template.spec`) and cron. The sample uses **`hcp1-hcp1`**. **`spec.template.storageLocation`** must be the **`BackupStorageLocation` object name** (for this DPA it is usually `dpa-minio-1`; confirm with `oc get backupstoragelocation -n openshift-adp`). It is **not** the word `default` unless a BSL is literally named `default`. For a one-off backup, copy `manifests/hcp-backup/backup-once.example.yaml`, set a **unique** `metadata.name`, and `oc apply` it (that file is not in the kustomize bundle).

If CSI snapshot upload or the data mover does not match your storage, switch to the **non-CSI** backup pattern in the same HyperShift doc (for example `defaultVolumesToFsBackup: true` and no `snapshotMoveData`) and adjust the DPA accordingly.

---

## Verifying backup status on ACM

Point `KUBECONFIG` at the **ACM** cluster (where OADP runs) and use the steps below. Velero custom resources usually live in **`openshift-adp`** when the DPA is installed there.

### 1. Confirm backup infrastructure (not yet a backup)

```bash
oc get dataprotectionapplication -n openshift-adp
oc get backupstoragelocation -n openshift-adp
oc get pods -n openshift-adp -l app.kubernetes.io/name=velero
```

**Expect:** DPA reports reconciled / healthy for your operator version; default BSL **`phase=Available`**; Velero pod **`Running`**; with the HyperShift-oriented DPA, **node-agent** pods should run for the CSI data mover path.

If the BSL is not `Available`, fix storage, credentials, and networking before any backup will succeed.

### 2. Velero schedules and backups

```bash
oc get schedule.velero.io -n openshift-adp
oc get backup.velero.io -n openshift-adp
```

`backup.velero.io` and `schedule.velero.io` are spelled out on purpose; short names can collide with other APIs.

- When the **`Schedule`** is active (not paused), Velero creates new **`Backup`** objects on each cron tick (names are usually derived from the schedule name and timestamp).
- If **both** `Schedule` is absent or paused and **`Backup`** is empty, nothing is backing up yet—apply the `hcp-dr-hcp-backup` Application and/or fix the schedule spec.
- Widen backup search if needed: `oc get backup.velero.io -A`.

### 3. Inspect a specific backup

Replace `<name>` with a name from the `backup.velero.io` list in step 2:

```bash
oc get backup.velero.io <name> -n openshift-adp -o jsonpath='{.status.phase}{"\n"}'
oc describe backup.velero.io <name> -n openshift-adp
```

**Typical outcomes:** `Completed` means the backup run finished successfully. `Failed` or `PartiallyFailed` means you should read `status` / events and fix configuration or scope before relying on that backup.

### 4. Confirm objects landed in object storage

Velero writes under your bucket (and optional prefix from the DPA, for example `hcp-dr`). With MinIO Client:

```bash
mc alias set lab http://<minio-endpoint>:9000 <access-key> '<secret-key>'
mc ls --recursive lab/velero/
```

After at least one successful backup you should see **new keys** under the bucket (exact paths depend on the Velero AWS plugin version). If the bucket or prefix only contains metadata you created by hand and nothing grows after a backup attempt, the backup did not complete successfully.

### 5. HyperShift-specific checks

Some flows also create or update resources tied to **`HostedControlPlane`** / etcd backup steps in management or hosted namespaces. Always reconcile these checks with the **exact** runbook for your version (CLI steps, inclusion labels, and timing differ from generic application backups).

---

## Restore and GitOps on the backup cluster

**Operators, RBAC, `BackupStorageLocation`, and `DataProtectionApplication`** are good candidates for continuous automated sync.

**Restore** is still a **gated** operation: you decide *when* the backup cluster should reconcile restore manifests. A practical lab pattern is to keep Velero `Restore` (and related) YAML in Git on a branch or path the backup cluster’s Argo CD **does not** sync until you enable it—then use **manual sync** or temporarily wire an `Application` so GitOps applies the restore exactly when your runbook says to. Validate each step against upstream HyperShift and OADP restore guidance; this repo only supplies examples under `gitops/applications/dubai/` and `manifests/restore/`.

---

## Scope of this example

- **One** hosted control plane and **one** object-store bucket in the sample `DataProtectionApplication` layout.
- Paths and names match a single lab; fork and rename to fit your clusters and Git hosting.

---

## Disclaimer

This repository is a **lab / POC scaffold**. Cleartext object-store credentials are committed on purpose for frictionless GitOps; replace with sealed secrets, external secrets, or private overlays before any real environment. Harden RBAC, pin operator channels, and validate against your support matrix for production.
