#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

NR_K8S_VALUES_PATH="${NR_K8S_VALUES_PATH}"
NR_K8S_RENDERED_PATH="${NR_K8S_RENDER_PATH}"

# Policy: these must always exist in the rendered config, regardless of what
# extraConfig currently declares. Unlike the generic extraConfig check below
# (which only catches drift between what's declared and what rendered), this
# is what stops someone from removing the entry in values.yaml itself.
# Keep this list intentionally short - only things whose disappearance
# should always fail CI, not routine additions. Update it when a listed
# item is deliberately renamed or retired, or when a new component becomes
# similarly load-bearing (e.g. it backs a shipped dashboard).
REQUIRED_CONNECTORS=("spanmetrics")
REQUIRED_RECEIVERS=("prometheus/ad" "postgresql" "kafka_metrics")
REQUIRED_PROCESSORS=()
REQUIRED_PIPELINES=("metrics/spanmetrics" "metrics/postgres" "logs/postgres")

echo "Validating NR K8s chart configuration..."

# Render chart
echo ""
echo "[1/2] Rendering nr-k8s-otel-collector ($NR_K8S_CHART_VERSION)..."

RENDERED=$(mktemp)
CONFIG=$(mktemp)
trap 'rm -f "$RENDERED" "$CONFIG"' EXIT

helm template nr-k8s-otel-collector newrelic/nr-k8s-otel-collector \
    --version "$NR_K8S_CHART_VERSION" \
    -n opentelemetry-demo \
    --create-namespace \
    -f "$NR_K8S_VALUES_PATH" > "$RENDERED"

# Extract collector config from the deployment ConfigMap (carries our custom
# extraConfig). The daemonset ConfigMap also matches "otel-collector" and has
# its own "*-config.yaml" key, so scope the name match to "deployment-config"
# to avoid concatenating two independent configs into one file.
yq -r 'select(.kind == "ConfigMap" and (.metadata.name | test("deployment-config"))) | .data | to_entries | .[] | select(.key | test("config")) | .value' "$RENDERED" > "$CONFIG"

if [ ! -s "$CONFIG" ]; then
    echo "ERROR: Could not extract collector config"
    exit 1
fi

echo "✓ Chart rendered"

# Validate with otelcol if available (optional)
if command -v otelcol-contrib &> /dev/null; then
    # The config references runtime-only values that otelcol's config
    # validation checks eagerly, unrelated to whether the config itself is
    # correct: ${env:POSTGRES_*} (only set on the real deployment) and the
    # in-cluster ServiceAccount token file (only present inside a pod).
    # Stub both so validation reflects the config, not the environment it's
    # run in.
    TOKEN_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
    TOKEN_FILE="$TOKEN_DIR/token"
    CREATED_TOKEN_DIR=false
    if [ ! -f "$TOKEN_FILE" ]; then
        if sudo mkdir -p "$TOKEN_DIR" 2>/dev/null && echo "dummy-token" | sudo tee "$TOKEN_FILE" > /dev/null 2>&1; then
            CREATED_TOKEN_DIR=true
        fi
    fi

    if ! POSTGRES_USERNAME="${POSTGRES_USERNAME:-dummy}" POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-dummy}" \
        otelcol-contrib validate --config "$CONFIG" > /tmp/otelcol-validate.log 2>&1; then
        echo "ERROR: Config validation failed"
        cat /tmp/otelcol-validate.log
        [ "$CREATED_TOKEN_DIR" = true ] && sudo rm -f "$TOKEN_FILE"
        exit 1
    fi
    [ "$CREATED_TOKEN_DIR" = true ] && sudo rm -f "$TOKEN_FILE"
    echo "✓ Config syntax valid"
fi

# Assert our custom extraConfig is present. This is independent of the
# rendered-vs-committed diff below: if a PR removes required custom config
# from values AND re-renders/commits the result, the diff would pass even
# though the config is now missing. otelcol validate wouldn't catch it
# either (removing a component and all its references isn't invalid,
# just wrong). So check structurally for what must be there.
#
# Rather than a hand-maintained list, derive what's "required" from
# extraConfig in the values file itself: every component key we declare
# there must exist in the rendered config's matching section. This stays
# correct automatically as extraConfig gains or loses entries - nothing
# here needs updating when it does.
echo ""
echo "[2/3] Checking required custom config is present..."

MISSING=()

for category in receivers processors connectors exporters; do
    keys=$(yq -r ".deployment.configMap.extraConfig.$category // {} | keys | .[]" "$NR_K8S_VALUES_PATH")
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        yq -e ".$category.\"$key\"" "$CONFIG" > /dev/null 2>&1 || MISSING+=("$category.$key")
    done <<< "$keys"
done

# extraConfig.pipelines entries land under service.pipelines in the
# rendered config, not top-level - the chart nests them under service:.
pipeline_keys=$(yq -r '.deployment.configMap.extraConfig.pipelines // {} | keys | .[]' "$NR_K8S_VALUES_PATH")
while IFS= read -r key; do
    [ -z "$key" ] && continue
    yq -e ".service.pipelines.\"$key\"" "$CONFIG" > /dev/null 2>&1 || MISSING+=("service.pipelines.$key")
done <<< "$pipeline_keys"

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: extraConfig components missing from rendered manifest:"
    for item in "${MISSING[@]}"; do
        echo "  ✗ $item"
    done
    exit 1
fi

echo "✓ All declared extraConfig components present"

# Policy check: the above only catches drift for what's still declared in
# extraConfig. Also enforce the fixed list at the top of this script, so
# deleting one of these from values.yaml (declaration and all) still fails.
for c in "${REQUIRED_CONNECTORS[@]:-}"; do
    [ -z "$c" ] && continue
    yq -e ".connectors.\"$c\"" "$CONFIG" > /dev/null 2>&1 || MISSING+=("connectors.$c (policy)")
done
for r in "${REQUIRED_RECEIVERS[@]:-}"; do
    [ -z "$r" ] && continue
    yq -e ".receivers.\"$r\"" "$CONFIG" > /dev/null 2>&1 || MISSING+=("receivers.$r (policy)")
done
for p in "${REQUIRED_PROCESSORS[@]:-}"; do
    [ -z "$p" ] && continue
    yq -e ".processors.\"$p\"" "$CONFIG" > /dev/null 2>&1 || MISSING+=("processors.$p (policy)")
done
for pl in "${REQUIRED_PIPELINES[@]:-}"; do
    [ -z "$pl" ] && continue
    yq -e ".service.pipelines.\"$pl\"" "$CONFIG" > /dev/null 2>&1 || MISSING+=("service.pipelines.$pl (policy)")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: policy-required components missing from rendered manifest:"
    for item in "${MISSING[@]}"; do
        echo "  ✗ $item"
    done
    echo ""
    echo "If this removal is intentional, update REQUIRED_* at the top of"
    echo "newrelic/scripts/validate-k8s-charts.sh."
    exit 1
fi

echo "✓ All policy-required components present"

# Compare rendered vs committed
echo ""
echo "[3/3] Checking for stale rendered manifest..."

DIFF=$(diff -u <(sed 's/[[:space:]]*$//' "$NR_K8S_RENDERED_PATH" | sed '/^$/d') \
               <(sed 's/[[:space:]]*$//' "$RENDERED" | sed '/^$/d') || true)

if [ -n "$DIFF" ]; then
    echo "ERROR: Rendered manifest differs from committed"
    echo "This means:"
    echo "  - Chart version changed"
    echo "  - Values changed (including custom extraConfig)"
    echo "  - Something is broken"
    echo ""
    echo "--- committed ($NR_K8S_RENDERED_PATH)"
    echo "+++ freshly rendered"
    echo "$DIFF"
    echo ""
    echo "Fix: Run newrelic/scripts/update-k8s.sh to re-render"
    exit 1
fi

echo "✓ Rendered manifest is current"

# Compare nri-bundle rendered vs committed
echo ""
echo "Checking for stale nri-bundle rendered manifest..."

NRI_RENDERED=$(mktemp)
BASE_RENDER=$(mktemp)
OVERLAY_RENDER=$(mktemp)
trap 'rm -f "$RENDERED" "$CONFIG" "$NRI_RENDERED" "$BASE_RENDER" "$OVERLAY_RENDER"' EXIT

helm template nri-bundle newrelic/nri-bundle \
    --version "$NRI_BUNDLE_CHART_VERSION" \
    -n "$NRI_BUNDLE_NAMESPACE" \
    --create-namespace \
    -f "$NRI_BUNDLE_VALUES_PATH" > "$NRI_RENDERED"

NRI_DIFF=$(diff -u <(sed 's/[[:space:]]*$//' "$NRI_BUNDLE_RENDER_PATH" | sed '/^$/d') \
                   <(sed 's/[[:space:]]*$//' "$NRI_RENDERED" | sed '/^$/d') || true)

if [ -n "$NRI_DIFF" ]; then
    echo "ERROR: Rendered nri-bundle manifest differs from committed"
    echo "This means:"
    echo "  - Chart version changed"
    echo "  - Values changed"
    echo "  - Something is broken"
    echo ""
    echo "--- committed ($NRI_BUNDLE_RENDER_PATH)"
    echo "+++ freshly rendered"
    echo "$NRI_DIFF"
    echo ""
    echo "Fix: Run newrelic/scripts/update-k8s.sh to re-render"
    exit 1
fi

echo "✓ Rendered nri-bundle manifest is current"

# Helm replaces lists instead of merging them, so any list re-declared in the
# NRI collector overlay silently drops entries it omits. Compare the base and
# overlay renders to catch that: the app services' environment variable names
# must be identical, and the collector Service name must match the overlay's
# OTEL_COLLECTOR_NAME.
echo ""
echo "Checking NRI collector overlay against the base values..."

OTEL_DEMO_VALUES_PATH="${OTEL_DEMO_VALUES_PATH:-newrelic/k8s/helm/opentelemetry-demo-base.yaml}"
OTEL_DEMO_NRI_VALUES_PATH="${OTEL_DEMO_NRI_VALUES_PATH:-newrelic/k8s/helm/opentelemetry-demo-pure.yaml}"

helm template otel-demo open-telemetry/opentelemetry-demo \
    --version "$OTEL_DEMO_CHART_VERSION" -n opentelemetry-demo \
    -f "$OTEL_DEMO_VALUES_PATH" > "$BASE_RENDER"
helm template otel-demo open-telemetry/opentelemetry-demo \
    --version "$OTEL_DEMO_CHART_VERSION" -n opentelemetry-demo \
    -f "$OTEL_DEMO_VALUES_PATH" -f "$OTEL_DEMO_NRI_VALUES_PATH" > "$OVERLAY_RENDER"

service_env_names() {
    yq -r 'select(.kind == "Deployment" and .metadata.name != "otel-collector") | .metadata.name as $n | .spec.template.spec.containers[].env[]?.name | "\($n) \(.)"' "$1" | grep -v '^[[:space:]]*$' | sort
}

ENV_DIFF=$(diff <(service_env_names "$BASE_RENDER") <(service_env_names "$OVERLAY_RENDER") || true)
if [ -n "$ENV_DIFF" ]; then
    echo "ERROR: the NRI collector overlay changes which environment variables are set"
    echo "$ENV_DIFF"
    echo ""
    echo "Fix: re-declare the full default.env list in $OTEL_DEMO_NRI_VALUES_PATH"
    exit 1
fi

OVERLAY_COLLECTOR_NAME=$(yq -r 'select(.kind == "Deployment" and .metadata.name == "frontend") | .spec.template.spec.containers[0].env[] | select(.name == "OTEL_COLLECTOR_NAME") | .value' "$OVERLAY_RENDER")
OVERLAY_SERVICES=$(yq -r 'select(.kind == "Service") | .metadata.name' "$OVERLAY_RENDER")
if ! grep -qx "$OVERLAY_COLLECTOR_NAME" <<< "$OVERLAY_SERVICES"; then
    echo "ERROR: OTEL_COLLECTOR_NAME '$OVERLAY_COLLECTOR_NAME' does not match any rendered Service"
    exit 1
fi

OVERLAY_COLLECTOR_CONFIG=$(yq -r 'select(.kind == "ConfigMap" and (.metadata.name == "otel-collector" or .metadata.name == "otel-collector-agent")) | .data | to_entries | .[0].value' "$OVERLAY_RENDER")
for pipeline in traces metrics logs; do
    EXPORTERS=$(yq -r ".service.pipelines.$pipeline.exporters[]" <<< "$OVERLAY_COLLECTOR_CONFIG")
    if ! grep -Eq "^(otlp_http/newrelic|otlphttp/newrelic|otlp/gateway)$" <<< "$EXPORTERS"; then
        echo "ERROR: overlay $pipeline pipeline does not export to otlphttp/newrelic or otlp/gateway"
        exit 1
    fi
done

echo "✓ NRI collector overlay preserves base environment and pipelines"

echo ""
echo "Checking PCG and Agent Control chart rendering..."

helm template "$PCG_RELEASE_NAME" newrelic/pipeline-control-gateway \
    --version "$PCG_CHART_VERSION" \
    -n "$PCG_NAMESPACE" \
    -f "$PCG_VALUES_PATH" \
    --set "global.region=${NEW_RELIC_REGION:-us}" > /dev/null
echo "✓ Pipeline Control Gateway (PCG) template valid"

helm template "$AGENT_CONTROL_RELEASE_NAME" newrelic/agent-control-deployment \
    --version "$AGENT_CONTROL_CHART_VERSION" \
    -n "$PCG_NAMESPACE" \
    -f "$AGENT_CONTROL_VALUES_PATH" \
    --set "global.region=${NEW_RELIC_REGION:-us}" \
    --set "systemIdentity.organizationId=12345" \
    --set "systemIdentity.parentIdentity.clientId=dummy-client-id" \
    --set "systemIdentity.parentIdentity.clientSecret=dummy-client-secret" > /dev/null
echo "✓ Agent Control Deployment template valid"

echo ""
echo "✓ All validations passed"
