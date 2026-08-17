#!/usr/bin/env bash
# One-shot deploy of the whole example. This is a thin wrapper around exactly the
# commands the runbook walks through step by step -- use the runbook to learn what
# is happening, use this when you cannot afford to type (e.g. a live demo).
#
# Assumes minikube is already started. See the runbook for the platform-specific
# `minikube start` invocation (Linux: --driver=docker, macOS: --driver=vfkit).
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-sim}"
RELEASE="${RELEASE:-llmd}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
ROUTER_CHART="${ROUTER_CHART:-oci://ghcr.io/llm-d/charts/llm-d-router-standalone}"
ROUTER_CHART_VERSION="${ROUTER_CHART_VERSION:-v0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

echo "==> checking cluster reachability"
kubectl cluster-info >/dev/null

echo "==> installing Gateway API Inference Extension CRDs (${GAIE_VERSION})"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"

echo "==> creating namespace ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> installing llm-d router (standalone mode)"
# If you have stale ghcr.io credentials in ~/.docker/config.json, helm will try to
# use them and get a 403 instead of falling back to anonymous. These charts are
# public, so point helm at an empty docker config for this pull.
ANON_DOCKER="$(mktemp -d)"
echo '{}' > "${ANON_DOCKER}/config.json"
DOCKER_CONFIG="${ANON_DOCKER}" helm upgrade --install "${RELEASE}" \
  "${ROUTER_CHART}" \
  -f "${ROOT}/router/minikube.values.yaml" \
  -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}"
rm -rf "${ANON_DOCKER}"

echo "==> deploying llm-d-inference-sim model servers + baseline Service"
kubectl apply -n "${NAMESPACE}" -k "${ROOT}/modelserver/sim"

echo "==> waiting for rollouts"
kubectl rollout status "deployment/${RELEASE}-epp" -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/sim-decode -n "${NAMESPACE}" --timeout=300s

echo
kubectl get pods,svc -n "${NAMESPACE}"
echo
echo "Ready. Endpoints:"
echo "  llm-d (L7, Envoy+EPP) : http://$(kubectl get svc "${RELEASE}-epp" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}'):80"
echo "  baseline (L4, kube-proxy) : http://$(kubectl get svc sim-plain -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}'):8000"
echo
echo "Next: ./scripts/drive.sh"
