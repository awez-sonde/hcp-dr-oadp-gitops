#!/usr/bin/env bash
# Apply OpenShift GitOps operator (run on each management cluster with cluster-admin).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
oc apply -k "${ROOT}/bootstrap/openshift-gitops/"
echo "Wait for openshift-gitops namespace and Argo CD route:"
echo "  oc get csv -n openshift-gitops-operator -w"
echo "  oc get pods -n openshift-gitops"
