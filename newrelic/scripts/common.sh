#!/bin/bash
set -euo pipefail

# General variables
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
SRC_DIR=${SRC_DIR:-"$SCRIPT_DIR/../../src"} #.env.override
COMMON_SCRIPT_PATH="$SCRIPT_DIR/common.sh"
TS=$(date +"%Y%m%d_%H%M%S")
TS_FULL=$(date +"%Y-%m-%d %H:%M:%S")

# Kubernetes variables
OTEL_DEMO_CHART_VERSION="0.41.2"
NR_K8S_CHART_VERSION="0.14.2"
NRI_BUNDLE_CHART_VERSION="8.0.26"
OTEL_DEMO_RELEASE_NAME=otel-demo
NR_K8S_RELEASE_NAME=nr-k8s-otel-collector
NRI_BUNDLE_RELEASE_NAME=nri-bundle
OTEL_DEMO_NAMESPACE=opentelemetry-demo
# nri-bundle runs in its own namespace so it shares no Kubernetes objects with
# the demo or NRDOT. Secrets are namespaced, so install-k8s.sh creates a copy
# of $NR_LICENSE_SECRET here from the same license key input.
NRI_BUNDLE_NAMESPACE=${NRI_BUNDLE_NAMESPACE:-newrelic}
NR_LICENSE_SECRET=newrelic-license-key
# Postgres user (created by the demo's init.sql) that the NR collector's
# postgresql receiver connects as; already has pg_monitor granted for
# query_sample/top_query.
POSTGRES_MONITOR_USER=monitoring_user
OTEL_DEMO_VALUES_PATH=${OTEL_DEMO_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/opentelemetry-demo.yaml"}
OTEL_DEMO_RENDER_PATH=${OTEL_DEMO_RENDER_PATH:-"$SCRIPT_DIR/../k8s/rendered/opentelemetry-demo.yaml"}
NR_K8S_VALUES_PATH=${NR_K8S_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/nr-k8s-otel-collector.yaml"}
NR_K8S_RENDER_PATH=${NR_K8S_RENDER_PATH:-"$SCRIPT_DIR/../k8s/rendered/nr-k8s-otel-collector.yaml"}
NRI_BUNDLE_VALUES_PATH=${NRI_BUNDLE_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/nri-bundle.yaml"}
NRI_BUNDLE_RENDER_PATH=${NRI_BUNDLE_RENDER_PATH:-"$SCRIPT_DIR/../k8s/rendered/nri-bundle.yaml"}
OTEL_DEMO_NRI_VALUES_PATH=${OTEL_DEMO_NRI_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/opentelemetry-demo-nri-collector.yaml"}
OTEL_DEMO_PCG_VALUES_PATH=${OTEL_DEMO_PCG_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/opentelemetry-demo-pcg.yaml"}
OTEL_GATEWAY_MANIFEST_PATH=${OTEL_GATEWAY_MANIFEST_PATH:-"$SCRIPT_DIR/../k8s/otel-collector-gateway.yaml"}
APM_TEST_APPS_PATH=${APM_TEST_APPS_PATH:-"$SCRIPT_DIR/../k8s/apm-test-apps.yaml"}
PCG_CHART_VERSION="2.5.0"
AGENT_CONTROL_CHART_VERSION="1.7.20"
PCG_RELEASE_NAME=newrelic-pcg
AGENT_CONTROL_RELEASE_NAME=agent-control-deployment
PCG_NAMESPACE=${PCG_NAMESPACE:-newrelic}
PCG_VALUES_PATH=${PCG_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/pipeline-control-gateway.yaml"}
AGENT_CONTROL_VALUES_PATH=${AGENT_CONTROL_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/agent-control-deployment.yaml"}
CONFIG_GO_PATH=${CONFIG_GO_PATH:-"$SCRIPT_DIR/../cli/config.go"}

# Docker variables
# Upstream v3.0.0 split the old monolithic docker-compose.yml into these layered
# files; NR's compose always runs the full stack, so update-docker.sh merges all three.
DOCKER_COMPOSE_SOURCE_PATHS=(
  "$SCRIPT_DIR/../../compose.yaml"
  "$SCRIPT_DIR/../../compose.full.yaml"
  "$SCRIPT_DIR/../../compose.observability.yaml"
  "$SCRIPT_DIR/../../compose.agent.yaml"
)
NR_DOCKER_COMPOSE_PATH=${NR_DOCKER_COMPOSE_PATH:-"$SCRIPT_DIR/../docker/docker-compose.yml"}
ENV_PATH=${ENV_PATH:-"$SCRIPT_DIR/../../.env"}

# Tracks the last upstream tag merge-upstream.sh successfully synced with.
# This repo only allows squash merges, which drop the second parent of a
# merge commit, so git ancestry (rev-list main..upstream) can't be trusted
# to detect "already synced" - a committed marker file survives squashing
# since it's just file content, not commit graph structure.
UPSTREAM_SYNC_TAG_PATH=${UPSTREAM_SYNC_TAG_PATH:-"$SCRIPT_DIR/.upstream-sync-tag"}

# Check if required tools are installed and error out if not
check_tool_installed() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is not installed or not in PATH."
        exit 1
    fi
}

# Check if a file exists and error out if not
check_file_exists() {
    if [ ! -f "$1" ]; then
        echo "Error: File $1 does not exist."
        exit 1
    fi
}

# Ensure Helm repository is added and updated
ensure_helm_repo() {
  local repo_name=$1
  local repo_url=$2
  if helm repo list | grep -q "$repo_name"; then
    echo "Helm repository '$repo_name' is already added."
  else
    helm repo add "$repo_name" "$repo_url"
  fi
  if ! helm repo update "$repo_name"; then
    echo "Error: Failed to update $repo_name Helm repository."
    exit 1
  fi
}

# Generic function to prompt for environment variables
# Usage: prompt_for_env_var VAR_NAME PROMPT_TEXT REQUIRED
prompt_for_env_var() {
  local var_name="$1"
  local prompt_text="$2"
  local required="${3:-false}"

  set +u
  local current_value="${!var_name}"

  if [ -z "$current_value" ]; then
    echo -n "$prompt_text: "
    read -r input_value || true
    if [ -n "$input_value" ]; then
      eval "export $var_name=\"$input_value\""
    fi
  else
    echo "Using $var_name from environment variable."
  fi

  # Check if required and empty
  current_value="${!var_name}"
  if [ "$required" = "true" ] && [ -z "$current_value" ]; then
    echo "Error: $var_name is required but empty."
    exit 1
  fi

  set -u
}

# Validate and normalize yes/no answers
# Usage: validate_yesno_answer VAR_NAME
validate_yesno_answer() {
  local var_name="$1"

  set +u
  local current_value="${!var_name}"

  # If already set to y or n, no validation needed
  if [ "$current_value" = "y" ] || [ "$current_value" = "n" ]; then
    set -u
    return
  fi

  # Normalize and validate the answer
  case "$current_value" in
    [yY]|[yY][eE][sS])
      eval "export $var_name=\"y\""
      ;;
    [nN]|[nN][oO])
      eval "export $var_name=\"n\""
      ;;
    *)
      echo "Error: Invalid value '$current_value' for $var_name. Must be 'y' or 'n'."
      exit 1
      ;;
  esac

  set -u
}

# Set NEW_RELIC_LICENSE_KEY variable from environment or prompt user
prompt_for_license_key() {
  prompt_for_env_var "NEW_RELIC_LICENSE_KEY" "Please enter your New Relic License Key" true
}

# Set NEW_RELIC_API_KEY variable from environment or prompt user
prompt_for_api_key() {
  prompt_for_env_var "NEW_RELIC_API_KEY" "Please enter your New Relic API Key" true
}

# Set NEW_RELIC_ACCOUNT_ID variable from environment or prompt user
prompt_for_account_id() {
  prompt_for_env_var "NEW_RELIC_ACCOUNT_ID" "Please enter your New Relic Account ID" true
}

# Set NEW_RELIC_REGION variable from environment or prompt user. Default to us.
prompt_for_region() {
  prompt_for_env_var "NEW_RELIC_REGION" "Please enter your New Relic Region (default: us)" false
  if [ -z "${NEW_RELIC_REGION:-}" ]; then
    export NEW_RELIC_REGION="us"
  else
    NEW_RELIC_REGION=$(echo "$NEW_RELIC_REGION" | tr '[:upper:]' '[:lower:]')
    export NEW_RELIC_REGION
  fi
}

# Prompt user to confirm if installation is for an OpenShift cluster
prompt_for_openshift() {
  prompt_for_env_var "IS_OPENSHIFT_CLUSTER" "Is this installation for an OpenShift cluster? (y/n, default: n)" false
  if [ -z "${IS_OPENSHIFT_CLUSTER:-}" ]; then
    export IS_OPENSHIFT_CLUSTER="n"
  fi
  validate_yesno_answer "IS_OPENSHIFT_CLUSTER"
}

# Set NEW_RELIC_OTLP_ENDPOINT from the region unless the caller overrode it.
# One knob for both region selection and routing through a Pipeline Control
# gateway; used by the demo collector's otlphttp/newrelic exporter.
resolve_otlp_endpoint() {
  if [ -n "${NEW_RELIC_OTLP_ENDPOINT:-}" ]; then
    return
  fi
  case "${NEW_RELIC_REGION:-us}" in
    eu) export NEW_RELIC_OTLP_ENDPOINT="https://otlp.eu01.nr-data.net:4318" ;;
    jp) export NEW_RELIC_OTLP_ENDPOINT="https://otlp.jp01.nr-data.net:4318" ;;
    *) export NEW_RELIC_OTLP_ENDPOINT="https://otlp.nr-data.net:4318" ;;
  esac
}

# Prompt user for Kubernetes monitoring components selection
prompt_for_k8s_monitoring_components() {
  prompt_for_env_var "ENABLE_NRDOT" "Enable New Relic OTel Collector (NRDOT)? (y/n, default: y)" false
  if [ -z "${ENABLE_NRDOT:-}" ]; then
    export ENABLE_NRDOT="y"
  fi
  validate_yesno_answer "ENABLE_NRDOT"

  prompt_for_env_var "ENABLE_NRI_BUNDLE" "Enable New Relic Infrastructure Bundle (nri-bundle)? (y/n, default: n)" false
  if [ -z "${ENABLE_NRI_BUNDLE:-}" ]; then
    export ENABLE_NRI_BUNDLE="n"
  fi
  validate_yesno_answer "ENABLE_NRI_BUNDLE"

  prompt_for_env_var "ENABLE_PCG" "Enable Pipeline Control Gateway (PCG without Flux)? (y/n, default: n)" false
  if [ -z "${ENABLE_PCG:-}" ]; then
    export ENABLE_PCG="n"
  fi
  validate_yesno_answer "ENABLE_PCG"

  if [ "$ENABLE_PCG" = "y" ]; then
    prompt_for_env_var "NEW_RELIC_GATEWAY_FLEET" "Enter New Relic Gateway Fleet Name (default: otel-demo-fleet)" false
    if [ -z "${NEW_RELIC_GATEWAY_FLEET:-}" ]; then
      export NEW_RELIC_GATEWAY_FLEET="otel-demo-fleet"
    fi

    prompt_for_env_var "ENABLE_APM_TEST_APPS" "Deploy dedicated New Relic APM test workloads (Python, Java, Node.js, C#)? (y/n, default: y)" false
    if [ -z "${ENABLE_APM_TEST_APPS:-}" ]; then
      export ENABLE_APM_TEST_APPS="y"
    fi
    validate_yesno_answer "ENABLE_APM_TEST_APPS"

    prompt_for_env_var "ROUTE_DEMO_TO_PCG" "Route OpenTelemetry Demo services through PCG? (y/n, default: y)" false
    if [ -z "${ROUTE_DEMO_TO_PCG:-}" ]; then
      export ROUTE_DEMO_TO_PCG="y"
    fi
    validate_yesno_answer "ROUTE_DEMO_TO_PCG"
  else
    export ENABLE_APM_TEST_APPS="${ENABLE_APM_TEST_APPS:-n}"
    export ROUTE_DEMO_TO_PCG="${ROUTE_DEMO_TO_PCG:-n}"
  fi

  # Renamed from ENABLE_NRI_BUNDLE_OTEL_COLLECTOR: this switch controls the
  # demo chart's own collector and is independent of nri-bundle.
  if [ -z "${ENABLE_DEMO_OTEL_COLLECTOR:-}" ] && [ -n "${ENABLE_NRI_BUNDLE_OTEL_COLLECTOR:-}" ]; then
    export ENABLE_DEMO_OTEL_COLLECTOR="$ENABLE_NRI_BUNDLE_OTEL_COLLECTOR"
  fi

  if [ "$ENABLE_NRDOT" = "n" ]; then
    prompt_for_env_var "ENABLE_DEMO_OTEL_COLLECTOR" "NRDOT is disabled. Deploy pure OpenTelemetry Collector architecture? (y/n, default: y)" false
    if [ -z "${ENABLE_DEMO_OTEL_COLLECTOR:-}" ]; then
      export ENABLE_DEMO_OTEL_COLLECTOR="y"
    fi
    validate_yesno_answer "ENABLE_DEMO_OTEL_COLLECTOR"

    export ENABLE_OTEL_GATEWAY="${ENABLE_OTEL_GATEWAY:-$ENABLE_DEMO_OTEL_COLLECTOR}"
  else
    export ENABLE_DEMO_OTEL_COLLECTOR="${ENABLE_DEMO_OTEL_COLLECTOR:-n}"
    export ENABLE_OTEL_GATEWAY="${ENABLE_OTEL_GATEWAY:-n}"
  fi

  if [ "$ENABLE_NRDOT" = "n" ] && [ "$ENABLE_DEMO_OTEL_COLLECTOR" = "n" ] && [ "$ENABLE_PCG" = "n" ]; then
    echo "Warning: no collector or gateway enabled. The demo's services will export telemetry to an endpoint that does not exist and no application data will reach New Relic." >&2
  fi
}

function sed_i() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS/BSD: needs the empty string argument
    sed -i '' "$@"
  else
    # Linux/GNU: standard -i
    sed -i "$@"
  fi
}

function parse_repo_owner() {
  local origin_repo_url
  origin_repo_url=$(git config --get remote.origin.url)
  # Matches SSH remote URLs: git@github.com:owner/repo(.git)
  local ssh_regex='^git@github.com:([^/]+)/([^.]+)(\.git)?$'
  # Matches HTTPS remote URLs with optional basic auth: https://[user:token@]github.com/owner/repo(.git)
  local https_regex='^https://([^@]+@)?github.com/([^/]+)/([^.]+)(\.git)?$'

  if [[ $origin_repo_url =~ $ssh_regex ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ $origin_repo_url =~ $https_regex ]]; then
    echo "${BASH_REMATCH[2]}"
  else
    echo "unable to parse repository owner from URL: $origin_repo_url" >&2
    exit 1
  fi
}
