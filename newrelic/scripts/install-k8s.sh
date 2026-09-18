#!/bin/bash
# -----------------------------------------------------------------------------
# install-k8s.sh
#
# Purpose:
#   Installs the OpenTelemetry Demo and New Relic Kubernetes instrumentation
#   into a Kubernetes cluster using Helm charts.
#
# How to run:
#   ./install-k8s.sh
#   (Run from the newrelic/scripts directory)
#
# Dependencies:
#   - kubectl
#   - helm
#   - Access to the target Kubernetes cluster
#   - NEW_RELIC_LICENSE_KEY (will prompt if not set)
#   - NEW_RELIC_REGION (optional, defaults to us; set to eu or jp for other regions)
#   - NEW_RELIC_OTLP_ENDPOINT (optional, derived from the region; override to
#     route the demo's collector through a Pipeline Control gateway)
#   - ENABLE_NRDOT / ENABLE_NRI_BUNDLE / ENABLE_DEMO_OTEL_COLLECTOR (will prompt)
# -----------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/common.sh"

check_tool_installed helm
check_tool_installed kubectl

prompt_for_license_key
prompt_for_region
prompt_for_openshift
prompt_for_k8s_monitoring_components
resolve_otlp_endpoint

install_or_upgrade_chart() {
  local release_name=$1
  local chart=$2
  local version=$3
  local values_file=$4
  local namespace=$5
  local is_openshift=${6:-}
  local provider_value=""
  local helm_args=("$release_name" "$chart" --version "$version" -f "$values_file")

  if [ "$is_openshift" = "y" ] && [ "$release_name" = "otel-demo" ]; then
    helm_args+=(--set "serviceAccount.create=false" --set "serviceAccount.name=opentelemetry-demo")
  elif [ "$is_openshift" = "y" ] && [ "$release_name" = "nr-k8s-otel-collector" ]; then
    provider_value="OPEN_SHIFT"
    helm_args+=(--set "provider=$provider_value")
  fi

  # Add any additional --set commands passed as remaining arguments
  # Shift away the first 5 required arguments, then check if 6th exists before shifting it
  shift 5
  if [ $# -gt 0 ]; then
    shift  # Shift away the 6th argument (is_openshift) if it exists
  fi
  # Now process any remaining arguments as additional --set or -f commands
  while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then
      if [ $# -lt 2 ]; then
        echo "Error: -f flag provided without a values file." >&2
        exit 1
      fi
      helm_args+=("-f" "$2")
      shift 2
    elif [[ "$1" == -f* ]]; then
      helm_args+=("$1")
      shift
    else
      helm_args+=(--set "$1")
      shift
    fi
  done

  helm_args+=(-n "$namespace" --install)

  if ! helm upgrade "${helm_args[@]}"; then
    echo "Error: Failed to install or upgrade $release_name ($chart) to version $version."
    exit 1
  fi
}

# Set up the NR collector postgresql receiver's monitoring access, per
# https://docs.newrelic.com/docs/opentelemetry/database/postgresql/hosted/.
# The chart's init.sql already creates $POSTGRES_MONITOR_USER with pg_monitor
# and enables pg_stat_statements in both astronomy_db and postgres, but it
# doesn't grant access to the app's catalog/accounting schemas, which
# top_query's EXPLAIN needs to read. ALTER DEFAULT PRIVILEGES covers tables
# services create after this script runs.
# All statements are idempotent (no-op if already applied) and require no DB
# restart, since shared_preload_libraries is set via the chart's postgresql
# command override.
setup_pg_monitoring() {
  echo "Setting up postgresql receiver monitoring access for $POSTGRES_MONITOR_USER..."
  if ! kubectl rollout status deployment/astronomy-db -n "$OTEL_DEMO_NAMESPACE" --timeout=120s; then
    echo "Warning: astronomy-db deployment not ready; skipping monitoring setup. Run manually later."
    return
  fi
  local app_db_ddl="GRANT USAGE ON SCHEMA catalog TO $POSTGRES_MONITOR_USER; GRANT SELECT ON ALL TABLES IN SCHEMA catalog TO $POSTGRES_MONITOR_USER; ALTER DEFAULT PRIVILEGES IN SCHEMA catalog GRANT SELECT ON TABLES TO $POSTGRES_MONITOR_USER; GRANT USAGE ON SCHEMA accounting TO $POSTGRES_MONITOR_USER; GRANT SELECT ON ALL TABLES IN SCHEMA accounting TO $POSTGRES_MONITOR_USER; ALTER DEFAULT PRIVILEGES IN SCHEMA accounting GRANT SELECT ON TABLES TO $POSTGRES_MONITOR_USER;"
  if kubectl exec -n "$OTEL_DEMO_NAMESPACE" deployment/astronomy-db -- \
      sh -c "psql -v ON_ERROR_STOP=1 -U postgres -d astronomy_db -c '$app_db_ddl'"; then
    echo "postgresql monitoring configured for $POSTGRES_MONITOR_USER."
  else
    echo "Warning: failed to configure postgresql monitoring for $POSTGRES_MONITOR_USER. Run manually with:"
    echo "  kubectl exec -n $OTEL_DEMO_NAMESPACE deployment/astronomy-db -- sh -c 'psql -U postgres -d astronomy_db -c \"$app_db_ddl\"'"
  fi
}

ensure_namespace() {
  local namespace=$1
  if kubectl get ns "$namespace" &> /dev/null; then
    echo "Namespace '$namespace' already exists."
  else
    kubectl create ns "$namespace"
  fi
}

# Secrets are namespaced, so each namespace running New Relic components needs
# its own copy of the same license key.
apply_license_secret() {
  local namespace=$1
  kubectl create secret generic "$NR_LICENSE_SECRET" --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" -n "$namespace" --dry-run=client -o yaml | kubectl apply -f -
}

ensure_namespace "$OTEL_DEMO_NAMESPACE"
apply_license_secret "$OTEL_DEMO_NAMESPACE"

# Ensure Helm repositories are added and updated
ensure_helm_repo "newrelic" "https://helm-charts.newrelic.com"
ensure_helm_repo "open-telemetry" "https://open-telemetry.github.io/opentelemetry-helm-charts"

if [ "$ENABLE_NRDOT" = "y" ]; then
  echo "Installing New Relic K8s OpenTelemetry Collector (NRDOT)..."
  install_or_upgrade_chart "$NR_K8S_RELEASE_NAME" "newrelic/nr-k8s-otel-collector" "$NR_K8S_CHART_VERSION" "$NR_K8S_VALUES_PATH" "$OTEL_DEMO_NAMESPACE" "$IS_OPENSHIFT_CLUSTER" "global.region=$NEW_RELIC_REGION"
fi

if [ "$ENABLE_NRI_BUNDLE" = "y" ]; then
  echo "Installing New Relic Infrastructure Bundle (nri-bundle)..."
  ensure_namespace "$NRI_BUNDLE_NAMESPACE"
  apply_license_secret "$NRI_BUNDLE_NAMESPACE"
  install_or_upgrade_chart "$NRI_BUNDLE_RELEASE_NAME" "newrelic/nri-bundle" "$NRI_BUNDLE_CHART_VERSION" "$NRI_BUNDLE_VALUES_PATH" "$NRI_BUNDLE_NAMESPACE" "false" "global.region=$NEW_RELIC_REGION"
fi

echo "Installing OpenTelemetry Demo..."
if [ "$ENABLE_NRDOT" != "y" ] && [ "$ENABLE_DEMO_OTEL_COLLECTOR" = "y" ]; then
  install_or_upgrade_chart "$OTEL_DEMO_RELEASE_NAME" "open-telemetry/opentelemetry-demo" "$OTEL_DEMO_CHART_VERSION" "$OTEL_DEMO_VALUES_PATH" "$OTEL_DEMO_NAMESPACE" "$IS_OPENSHIFT_CLUSTER" -f "$OTEL_DEMO_NRI_VALUES_PATH" "opentelemetry-collector.config.exporters.otlphttp/newrelic.endpoint=$NEW_RELIC_OTLP_ENDPOINT"
else
  install_or_upgrade_chart "$OTEL_DEMO_RELEASE_NAME" "open-telemetry/opentelemetry-demo" "$OTEL_DEMO_CHART_VERSION" "$OTEL_DEMO_VALUES_PATH" "$OTEL_DEMO_NAMESPACE" "$IS_OPENSHIFT_CLUSTER"
fi

# Set up postgres db grants
if [ "$ENABLE_NRDOT" = "y" ]; then
  setup_pg_monitoring
fi

echo "OpenTelemetry Demo installation completed successfully!"
