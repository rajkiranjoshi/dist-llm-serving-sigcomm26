#!/usr/bin/env bash
# Tear down everything this example created. Leaves minikube itself running; pass
# --delete-cluster to remove the cluster too.
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-sim}"
RELEASE="${RELEASE:-llmd}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

echo "==> deleting driver jobs and configmap"
kubectl delete job -n "${NAMESPACE}" -l job-name --ignore-not-found >/dev/null 2>&1 || true
kubectl delete job sim-driver-baseline sim-driver-llmd -n "${NAMESPACE}" --ignore-not-found
kubectl delete configmap sim-driver -n "${NAMESPACE}" --ignore-not-found

echo "==> deleting model servers"
kubectl delete -n "${NAMESPACE}" -k "${ROOT}/modelserver/sim" --ignore-not-found

echo "==> uninstalling llm-d router"
helm uninstall "${RELEASE}" -n "${NAMESPACE}" --ignore-not-found || true

echo "==> deleting namespace"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

if [[ "${1:-}" == "--delete-cluster" ]]; then
  echo "==> deleting minikube cluster"
  minikube delete
else
  echo
  echo "minikube left running. To remove it too: minikube delete"
  echo "(The GAIE CRDs are cluster-scoped and were left in place.)"
fi
