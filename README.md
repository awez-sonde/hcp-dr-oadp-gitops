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
| `manifests/oadp/` | Namespace, OperatorGroup, Subscription, cleartext MinIO `Secret` (POC only), and `DataProtectionApplication` for S3. |
| `gitops/applications/acm/` | Argo CD `Application` resources aimed at the primary (ACM) cluster. |
| `gitops/applications/dubai/` | Same pattern for the **backup** cluster (example name Dubai OCP), including optional manifests for restore-oriented GitOps. |
| `manifests/restore/` | Example Velero restore manifest; edit names and timing before use. |

---

## End-to-end picture

1. Provide **S3-compatible storage** and a bucket; ensure **both** management clusters have network reachability and correct credentials.
2. On **each** management cluster, install OpenShift GitOps from `bootstrap/openshift-gitops/`, wait until Argo CD is ready, then apply `gitops/rbac/` so Applications can reconcile cluster-scoped resources.
3. Point every Argo CD `Application` at **your** Git remote (`spec.source.repoURL` and `targetRevision`). For this POC, `manifests/oadp` already pins the reference MinIO URL and credentials in Git; fork and edit if your lab differs.
4. Apply `gitops/applications/acm/` on the primary cluster, then `gitops/applications/dubai/` (or your renamed equivalent) on the backup cluster when you want a symmetric install.
5. Take **hosted control plane backups** using the flow that matches your OpenShift and HyperShift versions ([HyperShift disaster recovery](https://hypershift.pages.dev/how-to/disaster-recovery/) and Red Hat OADP documentation).
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
oc apply -f gitops/applications/dubai/   # or your fork’s path for the backup cluster
```

If your MinIO endpoint, bucket, or keys differ from the committed POC values, edit `manifests/oadp/dpa-minio.yaml` and `manifests/oadp/secret-cloud-credentials.yaml`. The file `manifests/oadp/secret-cloud-credentials.env.example` documents the Velero `cloud` secret shape for other tooling.

Use a **public** Git remote with plain **HTTPS** if you want Argo CD to clone without repository credentials. Point `repoURL` at the same remote you push to. If the server cannot clone the revision in `targetRevision`, Applications will stay out of sync until the remote is reachable and the path exists at that revision.

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
