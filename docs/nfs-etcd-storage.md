# NFS storage and hosted-cluster etcd permissions

HyperShift **managed etcd** on the management cluster uses **PersistentVolumeClaims** (e.g. `data-etcd-0` … `data-etcd-2` in the HostedControlPlane namespace). In this lab the StorageClass is often **NFS**. That is supported for a POC, but upstream prefers **local / high-performance** storage for etcd ([storage overview](https://hypershift.pages.dev/how-to/kubevirt/configuring-storage/)).

## What went wrong after DR restore (your lab)

After a **Velero restore** of namespace `hcp1-hcp1` onto Dubai, **etcd** containers failed with:

```text
failed to list data directory ... /var/lib/data: permission denied
```

**Cause:** etcd runs as a fixed non-root UID/GID from the pod security context (e.g. `runAsUser` / `fsGroup` **1000890000**). Restored volume data on NFS was owned by a **different** UID (e.g. **1000950000**) or **`root:root`** with mode **`0700`**, so the etcd process could not read `/var/lib/data`.

This is a **restore-specific** ownership mismatch, not necessarily a bug in the backup YAML. The fix used in the lab is a one-shot privileged Job: `manifests/hcp1-etcd-nfs-perm-fix/` (chown `data/` trees to the etcd UID).

## Before creating a new HostedCluster (fresh ACM)

You should **prevent** permission problems on **new** PVCs and reduce pain if you later restore.

### 1. StorageClass and NFS export

- Use a StorageClass backed by NFS that supports **ReadWriteOnce** and is reachable from **all management nodes** that can run etcd pods (control-plane nodes in this lab).
- On the **NFS server**, avoid export options that break OpenShift volume ownership unless you understand the tradeoffs:
  - **`root_squash`** maps root on the client to nobody on the server — init/chown as root in a pod may not behave as expected.
  - Many labs use **`no_root_squash`** only on isolated lab networks (not production).
- Prefer NFS export **`all_squash`** + **`anonuid`/`anongid`** aligned with your volume strategy, or exports that allow the cluster to set ownership via **`fsGroup`** (see below).

### 2. Let Kubernetes set ownership (new volumes)

For **new** etcd PVCs, the StatefulSet uses **`securityContext.fsGroup`** on the pod. The kubelet should set group ownership on mount when the StorageClass supports it.

**Check before first HostedCluster:**

```bash
# After SC exists — provision a test PVC/Pod with same fsGroup pattern or inspect SC mountOptions
oc get storageclass <your-nfs-sc> -o yaml
```

If your NFS provisioner supports **`mountOptions`** such as `uid=`, `gid=`, or fsGroup policy, document them in your fork. Red Hat OpenShift documents NFS volume ownership in [Configuring persistent storage](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/storage/configuring-persistent-storage).

### 3. Do not rely on “we’ll fix it at restore time” only

The repo includes **`manifests/hcp1-etcd-nfs-perm-fix/`** for **after** restore. For a **greenfield** cluster you should still:

- Use a **known-good** NFS SC tested with a small RWO PVC + pod running as non-root.
- Plan **UID stability**: restored data from another cluster may use different namespace UID ranges — another reason DR docs require **node reprovisioning** / greenfield restore in many flows.

### 4. Backup/restore and etcd data

Velero **CSI / data mover** paths copy volume content **as-is**. That is why post-restore **chown** was required. For DR drills:

- Expect to run the **etcd NFS perm fix Job** after restore **or** follow HyperShift/OADP runbook steps that reprovision etcd volumes.
- Keep **`manifests/hcp-backup/`** aligned with [OADP 1.5+ HCP DR](https://hypershift.pages.dev/how-to/disaster-recovery/backup-and-restore-oadp-1-5/) (includes `pvc`/`pv` in scope).

### 5. Verify etcd PVCs after HostedCluster create (healthy path)

```bash
export KUBECONFIG=<acm-kubeconfig>
HCP_NS=hcp1-hcp1   # example
oc get pvc -n $HCP_NS | grep etcd
oc get pods -n $HCP_NS -l app=etcd
oc logs -n $HCP_NS etcd-0 -c etcd --tail=20   # no permission denied
```

## Quick reference

| Phase | Action |
|-------|--------|
| **Before first HCP** | Valid NFS SC; test RWO mount + fsGroup; plan MetalLB + **API hostname** |
| **Day-2 healthy** | etcd pods 4/4 Running; no permission errors in logs |
| **After Velero restore** | If etcd CrashLoop `permission denied` → `manifests/hcp1-etcd-nfs-perm-fix/`, then restart etcd pods |
