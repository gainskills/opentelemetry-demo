#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate-pcg-apm.sh
#
# Purpose:
#   Verify that APM test workloads routed to the Pipeline Control Gateway
#   (PCG) reach it over TLS and that PCG receives and forwards their data.
#   Skips when no APM workload group is routed to PCG.
#   See "Pipeline Control Gateway TLS" in newrelic/README.md.
#
# How to run:
#   ./validate-pcg-apm.sh
#   (Run from the newrelic/scripts directory)
#
# Environment variables:
#   PCG_VALIDATE_TIMEOUT    Seconds to wait for each agent to connect
#                           (default: 180)
#
# Dependencies:
#   - kubectl
#   - Access to the target Kubernetes cluster
# -----------------------------------------------------------------------------
set -euo pipefail

source "$(dirname "$0")/common.sh"

check_tool_installed kubectl
check_tool_installed curl

TIMEOUT=${PCG_VALIDATE_TIMEOUT:-180}
TLS_ERROR_PATTERN='PKIX|EPROTO|UntrustedRoot|SSL connection could not|certificate verify failed|unable to get local issuer|FATAL: CA bundle'
FAILURES=0

fail() {
  echo "  ✗ $*"
  FAILURES=$((FAILURES + 1))
}

config_value() {
  kubectl get configmap apm-test-config -n "$OTEL_DEMO_NAMESPACE" -o jsonpath="{.data.$1}" 2>/dev/null || true
}

# Running pods of a deployment, excluding ones that are shutting down.
live_pods() {
  kubectl get pods -n "$OTEL_DEMO_NAMESPACE" -l "app.kubernetes.io/name=$1" \
    -o go-template='{{range .items}}{{if and (eq .status.phase "Running") (not .metadata.deletionTimestamp)}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
}

check_tls_handshake() {
  local host=$1
  echo "Checking TLS handshake to https://$host (trusting $PCG_CA_CONFIGMAP)..."
  if ! kubectl get configmap "$PCG_CA_CONFIGMAP" -n "$OTEL_DEMO_NAMESPACE" &>/dev/null; then
    fail "ConfigMap $PCG_CA_CONFIGMAP is missing in namespace $OTEL_DEMO_NAMESPACE; re-run the installer"
    return
  fi
  local overrides
  overrides=$(cat <<EOF
{"spec":{"containers":[{"name":"pcg-tls-check","image":"curlimages/curl:latest",
  "command":["curl","-sS","-o","/dev/null","-w","%{ssl_verify_result}","--cacert","/pcg-ca/ca.crt","https://$host/"],
  "volumeMounts":[{"name":"pcg-ca","mountPath":"/pcg-ca","readOnly":true}]}],
  "volumes":[{"name":"pcg-ca","configMap":{"name":"$PCG_CA_CONFIGMAP"}}]}}
EOF
)
  local result
  result=$(kubectl run "pcg-tls-check-$$" -n "$OTEL_DEMO_NAMESPACE" --rm -i --quiet --restart=Never \
    --image=curlimages/curl:latest --overrides="$overrides" 2>&1 || true)
  if [ "$result" = "0" ]; then
    echo "  ✓ certificate verified against the demo CA"
  else
    fail "TLS handshake failed: $result"
  fi
}

check_agent() {
  local deployment=$1 host=$2
  local pods
  pods=$(live_pods "$deployment")
  if [ -z "$pods" ]; then
    echo "  - $deployment: not deployed, skipping"
    return
  fi

  local pod logs waited
  for pod in $pods; do
    waited=0
    while true; do
      logs=$(kubectl logs "$pod" -n "$OTEL_DEMO_NAMESPACE" 2>/dev/null || true)
      if grep -qE "$TLS_ERROR_PATTERN" <<< "$logs"; then
        fail "$pod: $(grep -m1 -E "$TLS_ERROR_PATTERN" <<< "$logs" | cut -c1-160)"
        break
      fi
      # Java/.NET/Node log "connected to <host>"; Python logs "Reporting to:" once connected.
      if grep -qE "[Cc]onnected to $host|Reporting to:" <<< "$logs"; then
        echo "  ✓ $pod: connected to PCG"
        break
      fi
      if [ "$waited" -ge "$TIMEOUT" ]; then
        fail "$pod: no connection to PCG after ${TIMEOUT}s"
        break
      fi
      sleep 10
      waited=$((waited + 10))
    done
  done
}

pcg_metric() {
  awk -v name="$2" -v attr="$3" \
    'index($0, name "{") == 1 && index($0, attr) { sum += $NF } END { printf "%d", sum }' <<< "$1"
}

# PCG serves its own metrics on localhost:8888 only and its image has no
# shell, so read them through a port-forward on a random local port.
fetch_pcg_metrics() {
  local pod=$1 pf_log port="" i
  pf_log=$(mktemp)
  kubectl port-forward -n "$PCG_NAMESPACE" "pod/$pod" :8888 > "$pf_log" 2>&1 &
  local pf_pid=$!
  # shellcheck disable=SC2064
  trap "kill $pf_pid 2>/dev/null; rm -f '$pf_log'" RETURN
  for i in $(seq 1 20); do
    # Extract the local port from "Forwarding from 127.0.0.1:<port> -> 8888".
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+).*/\1/p' "$pf_log" | head -1)
    [ -n "$port" ] && break
    sleep 0.5
  done
  if [ -z "$port" ]; then
    cat "$pf_log" >&2
    return 1
  fi
  curl -sSf "http://127.0.0.1:$port/metrics"
}

check_pcg_counters() {
  echo "Checking PCG receiver and exporter counters..."
  local pod metrics
  pod=$(kubectl get pods -n "$PCG_NAMESPACE" -l app.kubernetes.io/name=pipeline-control-gateway \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | head -1)
  if [ -z "$pod" ]; then
    fail "no running PCG pod in namespace $PCG_NAMESPACE"
    return
  fi
  if ! metrics=$(fetch_pcg_metrics "$pod" 2>&1); then
    fail "could not read PCG metrics: $metrics"
    return
  fi

  local accepted_spans accepted_logs sent_spans sent_logs
  accepted_spans=$(pcg_metric "$metrics" otelcol_receiver_accepted_spans 'receiver="nrproprietaryreceiver"')
  accepted_logs=$(pcg_metric "$metrics" otelcol_receiver_accepted_log_records 'receiver="nrproprietaryreceiver"')
  sent_spans=$(pcg_metric "$metrics" otelcol_exporter_sent_spans 'exporter="nrcollectorexporter"')
  sent_logs=$(pcg_metric "$metrics" otelcol_exporter_sent_log_records 'exporter="nrcollectorexporter"')
  echo "  accepted: spans=$accepted_spans logs=$accepted_logs | forwarded: spans=$sent_spans logs=$sent_logs"

  if [ "$accepted_spans" -gt 0 ] && [ "$sent_spans" -gt 0 ]; then
    echo "  ✓ PCG receives and forwards APM agent data"
  else
    fail "PCG has not received and forwarded any APM spans"
  fi
}

native_ca=$(config_value NATIVE_NEW_RELIC_CA_BUNDLE)
hybrid_ca=$(config_value HYBRID_NEW_RELIC_CA_BUNDLE)
if [ -z "$native_ca" ] && [ -z "$hybrid_ca" ]; then
  echo "No APM workload group is routed to PCG; skipping PCG APM validation."
  exit 0
fi

pcg_host=$(config_value NATIVE_NEW_RELIC_HOST)
[ -n "$native_ca" ] || pcg_host=$(config_value HYBRID_NEW_RELIC_HOST)
check_tls_handshake "$pcg_host"

for group in native hybrid; do
  ca=$native_ca host=$(config_value NATIVE_NEW_RELIC_HOST)
  if [ "$group" = "hybrid" ]; then
    ca=$hybrid_ca host=$(config_value HYBRID_NEW_RELIC_HOST)
  fi
  if [ -z "$ca" ]; then
    echo "APM $group workloads report to $host; skipping."
    continue
  fi
  echo "Checking APM $group agents connect to PCG..."
  for lang in python node java dotnet; do
    check_agent "apm-$lang-$group" "$host"
  done
done

check_pcg_counters

if [ "$FAILURES" -gt 0 ]; then
  echo "PCG APM validation failed with $FAILURES problem(s)."
  exit 1
fi
echo "PCG APM validation succeeded!"
