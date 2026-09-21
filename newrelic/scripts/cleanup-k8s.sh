#!/bin/bash
# -----------------------------------------------------------------------------
# cleanup-k8s.sh
#
# Purpose:
#   Uninstalls the OpenTelemetry Demo and New Relic Kubernetes instrumentation
#   from a cluster by removing Helm releases and deleting the namespace.
#
# How to run:
#   ./cleanup-k8s.sh
#   (Run from the newrelic/scripts directory)
#
# Dependencies:
#   - kubectl
#   - helm
#   - Access to the target Kubernetes cluster
# -----------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/common.sh"

check_tool_installed helm
check_tool_installed kubectl

# --wait matters for nri-bundle: its cluster-scoped MutatingWebhookConfiguration
# is removed by the uninstall, but deleting the namespace first orphans the
# webhook pointing at a dead Service, which then stalls pod admission
# cluster-wide until its 28s timeout on every subsequent install.
cleanup_helm_release() {
    local release=$1
    local namespace=$2
    if helm status "$release" -n "$namespace" &> /dev/null; then
        echo "Helm release '$release' found. Uninstalling..."
        helm uninstall "$release" -n "$namespace" --wait
    fi
}

# Cluster-scoped objects survive namespace deletion, so sweep anything the
# release left behind (e.g. after a failed or partial uninstall).
cleanup_cluster_scoped_leftovers() {
    local release=$1
    local kinds="mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding"
    echo "Removing any cluster-scoped leftovers for '$release'..."
    kubectl delete "$kinds" -l "app.kubernetes.io/instance=$release" --ignore-not-found
}

cleanup_namespace() {
    local namespace=$1
    if kubectl get namespace "$namespace" &> /dev/null; then
        echo "Namespace '$namespace' found. Deleting..."
        kubectl delete namespace "$namespace"
    fi
}

cleanup_helm_release "$OTEL_DEMO_RELEASE_NAME" "$OTEL_DEMO_NAMESPACE"
cleanup_helm_release "$NR_K8S_RELEASE_NAME" "$OTEL_DEMO_NAMESPACE"
cleanup_helm_release "$NRI_BUNDLE_RELEASE_NAME" "$NRI_BUNDLE_NAMESPACE"
cleanup_cluster_scoped_leftovers "$NRI_BUNDLE_RELEASE_NAME"
cleanup_helm_release "$PCG_RELEASE_NAME" "$PCG_NAMESPACE"
cleanup_helm_release "$AGENT_CONTROL_RELEASE_NAME" "$PCG_NAMESPACE"
if [ -f "$APM_TEST_APPS_PATH" ]; then
    echo "Deleting New Relic APM test workloads..."
    kubectl delete -f "$APM_TEST_APPS_PATH" --ignore-not-found
fi
cleanup_namespace "$OTEL_DEMO_NAMESPACE"
if [ "$NRI_BUNDLE_NAMESPACE" != "$OTEL_DEMO_NAMESPACE" ]; then
    cleanup_namespace "$NRI_BUNDLE_NAMESPACE"
fi
if [ "$PCG_NAMESPACE" != "$OTEL_DEMO_NAMESPACE" ] && [ "$PCG_NAMESPACE" != "$NRI_BUNDLE_NAMESPACE" ]; then
    cleanup_namespace "$PCG_NAMESPACE"
fi

echo "Cleanup completed successfully."

exit 0
