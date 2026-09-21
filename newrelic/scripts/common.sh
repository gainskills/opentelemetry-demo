#!/bin/bash
set -euo pipefail

# General variables
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
SRC_DIR=${SRC_DIR:-"$SCRIPT_DIR/../../src"} #.env.override
COMMON_SCRIPT_PATH="$SCRIPT_DIR/common.sh"
TS=$(date +"%Y%m%d_%H%M%S")
TS_FULL=$(date +"%Y-%m-%d %H:%M:%S")

# Kubernetes variables
OTEL_DEMO_CHART_VERSION="0.42.0"
NR_K8S_CHART_VERSION="0.14.2"
NRI_BUNDLE_CHART_VERSION="8.0.28"
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
OTEL_DEMO_VALUES_PATH=${OTEL_DEMO_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/opentelemetry-demo-base.yaml"}
OTEL_DEMO_RENDER_PATH=${OTEL_DEMO_RENDER_PATH:-"$SCRIPT_DIR/../k8s/rendered/opentelemetry-demo.yaml"}
NR_K8S_VALUES_PATH=${NR_K8S_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/nr-k8s-otel-collector.yaml"}
NR_K8S_RENDER_PATH=${NR_K8S_RENDER_PATH:-"$SCRIPT_DIR/../k8s/rendered/nr-k8s-otel-collector.yaml"}
NRI_BUNDLE_VALUES_PATH=${NRI_BUNDLE_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/nri-bundle.yaml"}
NRI_BUNDLE_RENDER_PATH=${NRI_BUNDLE_RENDER_PATH:-"$SCRIPT_DIR/../k8s/rendered/nri-bundle.yaml"}
OTEL_DEMO_NRI_VALUES_PATH=${OTEL_DEMO_NRI_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/opentelemetry-demo-pure.yaml"}
OTEL_DEMO_PCG_VALUES_PATH=${OTEL_DEMO_PCG_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/opentelemetry-demo-pcg.yaml"}
APM_TEST_APPS_PATH=${APM_TEST_APPS_PATH:-"$SCRIPT_DIR/../k8s/apm-test-apps.yaml"}
PCG_CHART_VERSION="2.5.0"
AGENT_CONTROL_CHART_VERSION="1.7.20"
PCG_RELEASE_NAME=newrelic-pcg
AGENT_CONTROL_RELEASE_NAME=agent-control-deployment
PCG_NAMESPACE=${PCG_NAMESPACE:-newrelic}
PCG_VALUES_PATH=${PCG_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/nr-pipeline-control-gateway.yaml"}
AGENT_CONTROL_VALUES_PATH=${AGENT_CONTROL_VALUES_PATH:-"$SCRIPT_DIR/../k8s/helm/nr-agent-control-deployment.yaml"}
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
    [yY]|[yY][eE][sS]|[tT][rR][uU][eE]|1)
      eval "export $var_name=\"y\""
      ;;
    [nN]|[nN][oO]|[fF][aA][lL][sS][eE]|0)
      eval "export $var_name=\"n\""
      ;;
    *)
      echo "Error: Invalid value '$current_value' for $var_name. Must be 'y' or 'n' (or true/false)."
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

# Helper to prompt user from a list of options
# Usage: prompt_for_choice VAR_NAME PROMPT_TITLE DEFAULT_INDEX OPTION_VALUES...
# Example: prompt_for_choice "APM_NATIVE_DEST" "Choose destination" 1 "pcg:PCG" "saas:SaaS"
prompt_for_choice() {
  local var_name="$1"
  local prompt_title="$2"
  local default_idx="$3"
  shift 3
  local options=("$@")

  set +u
  local current_value="${!var_name}"
  if [ -n "$current_value" ]; then
    echo "Using $var_name=$current_value from environment."
    set -u
    return
  fi

  echo "$prompt_title"
  local idx=1
  for opt in "${options[@]}"; do
    local desc="${opt#*:}"
    if [ "$idx" -eq "$default_idx" ]; then
      echo "  [$idx] $desc (default)"
    else
      echo "  [$idx] $desc"
    fi
    ((idx++))
  done

  echo -n "Enter choice [1-$#] (default: $default_idx): "
  read -r input_value || true
  input_value="${input_value:-$default_idx}"

  local selected_key=""
  if [[ "$input_value" =~ ^[0-9]+$ ]] && [ "$input_value" -ge 1 ] && [ "$input_value" -le "$#" ]; then
    local chosen="${options[$((input_value - 1))]}"
    selected_key="${chosen%%:*}"
  else
    for opt in "${options[@]}"; do
      local key="${opt%%:*}"
      if [ "$input_value" = "$key" ]; then
        selected_key="$key"
        break
      fi
    done
  fi

  if [ -z "$selected_key" ]; then
    echo "Error: Invalid selection '$input_value'." >&2
    exit 1
  fi

  eval "export $var_name=\"$selected_key\""
  echo "Selected $var_name=$selected_key"
  set -u
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

    prompt_for_env_var "NEW_RELIC_CLIENT_ID" "Enter New Relic Client ID for Fleet Control (optional, press Enter for in-cluster rules)" false
    if [ -n "${NEW_RELIC_CLIENT_ID:-}" ]; then
      prompt_for_env_var "NEW_RELIC_CLIENT_SECRET" "Enter New Relic Client Secret" true
      local default_org="${NEW_RELIC_ACCOUNT_ID:-}"
      if [ -n "$default_org" ]; then
        prompt_for_env_var "NEW_RELIC_ORGANIZATION_ID" "Enter New Relic Organization ID (default: $default_org)" false
        if [ -z "${NEW_RELIC_ORGANIZATION_ID:-}" ]; then
          export NEW_RELIC_ORGANIZATION_ID="$default_org"
        fi
      else
        prompt_for_env_var "NEW_RELIC_ORGANIZATION_ID" "Enter New Relic Organization ID" true
      fi
    fi
  fi

  if [ "$ENABLE_NRDOT" = "n" ]; then
    prompt_for_env_var "ENABLE_DEMO_OTEL_COLLECTOR" "NRDOT is disabled. Deploy pure OpenTelemetry Collector architecture? (y/n, default: y)" false
    if [ -z "${ENABLE_DEMO_OTEL_COLLECTOR:-}" ]; then
      export ENABLE_DEMO_OTEL_COLLECTOR="y"
    fi
    validate_yesno_answer "ENABLE_DEMO_OTEL_COLLECTOR"
  else
    if [ "${ENABLE_DEMO_OTEL_COLLECTOR:-n}" = "y" ]; then
      echo "Note: ENABLE_NRDOT=y is active. Disabling ENABLE_DEMO_OTEL_COLLECTOR (only one collector can be deployed at a time)." >&2
    fi
    export ENABLE_DEMO_OTEL_COLLECTOR="n"
  fi

  validate_k8s_profile
}

# Prompt user for application suites to deploy and their telemetry destinations
prompt_for_application_suites() {
  echo ""
  echo "--- Application Suites Selection & Telemetry Routing ---"

  # 1. OpenTelemetry Demo Apps (15+ upstream services)
  prompt_for_env_var "ENABLE_OTEL_DEMO_APPS" "Deploy OpenTelemetry Demo microservices (15+ upstream services)? (y/n, default: y)" false
  if [ -z "${ENABLE_OTEL_DEMO_APPS:-}" ]; then
    export ENABLE_OTEL_DEMO_APPS="y"
  fi
  validate_yesno_answer "ENABLE_OTEL_DEMO_APPS"

  if [ "$ENABLE_OTEL_DEMO_APPS" = "y" ]; then
    local otel_opts=()
    if [ "${ENABLE_PCG:-n}" = "y" ]; then
      otel_opts+=("pcg:Pipeline Control Gateway (pipeline-control-gateway:4317)")
    fi
    if [ "${ENABLE_NRDOT:-n}" = "y" ]; then
      otel_opts+=("nrdot:NRDOT Collector (nr-k8s-otel-collector-gateway:4317)")
    fi
    if [ "${ENABLE_DEMO_OTEL_COLLECTOR:-n}" = "y" ]; then
      otel_opts+=("otel-collector:Pure OpenTelemetry Collector (otel-collector:4317)")
    fi
    otel_opts+=("saas:Direct to New Relic SaaS (https://otlp.nr-data.net:4318)")

    prompt_for_choice "OTEL_DEMO_DEST" "Choose destination for OpenTelemetry Demo services:" 1 "${otel_opts[@]}"
    if [ "$OTEL_DEMO_DEST" = "pcg" ]; then
      export ROUTE_DEMO_TO_PCG="y"
    else
      export ROUTE_DEMO_TO_PCG="n"
    fi
  else
    export ROUTE_DEMO_TO_PCG="n"
  fi

  # If APM test apps were explicitly disabled, skip child prompts
  case "${ENABLE_APM_TEST_APPS:-}" in
    [nN]|[nN][oO]|[fF][aA][lL][sS][eE]|0)
      export ENABLE_APM_TEST_APPS="n"
      export ENABLE_APM_HYBRID_APPS="n"
      export ENABLE_APM_NATIVE_APPS="n"
      return
      ;;
  esac

  # 2. New Relic APM Hybrid Apps (Python, Node, Java, .NET with OTel API)
  prompt_for_env_var "ENABLE_APM_HYBRID_APPS" "Deploy New Relic APM Hybrid test workloads (OTel API Mode)? (y/n, default: y)" false
  if [ -z "${ENABLE_APM_HYBRID_APPS:-}" ]; then
    export ENABLE_APM_HYBRID_APPS="y"
  fi
  validate_yesno_answer "ENABLE_APM_HYBRID_APPS"

  if [ "$ENABLE_APM_HYBRID_APPS" = "y" ]; then
    if [ "${ENABLE_PCG:-n}" = "y" ]; then
      local hybrid_opts=(
        "pcg:Pipeline Control Gateway (SaaS entity registration + PCG port 4318 OTLP)"
        "saas:Direct to New Relic SaaS (collector.newrelic.com:443 / otlp.nr-data.net:4318)"
      )
      prompt_for_choice "APM_HYBRID_DEST" "Choose destination for APM Hybrid workloads:" 1 "${hybrid_opts[@]}"
    else
      export APM_HYBRID_DEST="saas"
      echo "Note: In-cluster OTel collectors cannot ingest New Relic APM agent traffic. APM Hybrid workloads will send directly to New Relic SaaS."
    fi
  fi

  # 3. New Relic APM Native Apps (Python, Node, Java, .NET with Proprietary Protocol)
  prompt_for_env_var "ENABLE_APM_NATIVE_APPS" "Deploy New Relic APM Native test workloads (Proprietary Protocol)? (y/n, default: y)" false
  if [ -z "${ENABLE_APM_NATIVE_APPS:-}" ]; then
    export ENABLE_APM_NATIVE_APPS="y"
  fi
  validate_yesno_answer "ENABLE_APM_NATIVE_APPS"

  if [ "$ENABLE_APM_NATIVE_APPS" = "y" ]; then
    if [ "${ENABLE_PCG:-n}" = "y" ]; then
      local native_opts=(
        "pcg:Pipeline Control Gateway (port 80 nrproprietaryreceiver)"
        "saas:Direct to New Relic SaaS (https://collector.newrelic.com:443 for baseline testing)"
      )
      prompt_for_choice "APM_NATIVE_DEST" "Choose destination for APM Native workloads:" 1 "${native_opts[@]}"
    else
      export APM_NATIVE_DEST="saas"
      echo "Note: PCG is not deployed. Native APM workloads will report directly to New Relic SaaS (collector.newrelic.com:443) for baseline comparison."
    fi
  fi

  # Maintain ENABLE_APM_TEST_APPS compatibility flag for scripts/cleanup
  if [ "${ENABLE_APM_NATIVE_APPS:-n}" = "y" ] || [ "${ENABLE_APM_HYBRID_APPS:-n}" = "y" ]; then
    export ENABLE_APM_TEST_APPS="y"
  else
    export ENABLE_APM_TEST_APPS="n"
  fi
}

# Validate that the selected monitoring flags match one of the 8 supported profiles
validate_k8s_profile() {
  local nrdot="${ENABLE_NRDOT:-y}"
  local nri="${ENABLE_NRI_BUNDLE:-n}"
  local pcg="${ENABLE_PCG:-n}"
  local demo_otel="${ENABLE_DEMO_OTEL_COLLECTOR:-n}"

  local matched_profile=""

  if [ "$nrdot" = "y" ] && [ "$nri" = "n" ] && [ "$demo_otel" = "n" ] && [ "$pcg" = "n" ]; then
    matched_profile="1. NRDOT (standard)"
  elif [ "$nrdot" = "n" ] && [ "$nri" = "y" ] && [ "$demo_otel" = "n" ] && [ "$pcg" = "n" ]; then
    matched_profile="2. NRI-Bundle only"
  elif [ "$nrdot" = "n" ] && [ "$nri" = "y" ] && [ "$demo_otel" = "y" ] && [ "$pcg" = "n" ]; then
    matched_profile="3. NRI-Bundle + Pure OTel (hybrid)"
  elif [ "$nrdot" = "n" ] && [ "$nri" = "n" ] && [ "$demo_otel" = "y" ] && [ "$pcg" = "n" ]; then
    matched_profile="4. Pure OTel Collector (agentless)"
  elif [ "$nrdot" = "n" ] && [ "$nri" = "n" ] && [ "$demo_otel" = "n" ] && [ "$pcg" = "y" ]; then
    matched_profile="5. PCG only"
  elif [ "$nrdot" = "y" ] && [ "$nri" = "n" ] && [ "$demo_otel" = "n" ] && [ "$pcg" = "y" ]; then
    matched_profile="6. PCG + NRDOT"
  elif [ "$nrdot" = "n" ] && [ "$nri" = "y" ] && [ "$demo_otel" = "n" ] && [ "$pcg" = "y" ]; then
    matched_profile="7. PCG + NRI-Bundle"
  elif [ "$nrdot" = "n" ] && [ "$nri" = "n" ] && [ "$demo_otel" = "y" ] && [ "$pcg" = "y" ]; then
    matched_profile="8. PCG + Pure OTel Collector"
  fi

  if [ -z "$matched_profile" ]; then
    echo "Error: Invalid component configuration (ENABLE_NRDOT=$nrdot, ENABLE_NRI_BUNDLE=$nri, ENABLE_DEMO_OTEL_COLLECTOR=$demo_otel, ENABLE_PCG=$pcg)." >&2
    echo "Configuration must match one of the 8 supported deployment profiles:" >&2
    echo "  1. NRDOT (standard): ENABLE_NRDOT=y" >&2
    echo "  2. NRI-Bundle only: ENABLE_NRI_BUNDLE=y" >&2
    echo "  3. NRI-Bundle + Pure OTel (hybrid): ENABLE_NRI_BUNDLE=y, ENABLE_DEMO_OTEL_COLLECTOR=y" >&2
    echo "  4. Pure OTel Collector (agentless): ENABLE_DEMO_OTEL_COLLECTOR=y" >&2
    echo "  5. PCG only: ENABLE_PCG=y" >&2
    echo "  6. PCG + NRDOT: ENABLE_PCG=y, ENABLE_NRDOT=y" >&2
    echo "  7. PCG + NRI-Bundle: ENABLE_PCG=y, ENABLE_NRI_BUNDLE=y" >&2
    echo "  8. PCG + Pure OTel Collector: ENABLE_PCG=y, ENABLE_DEMO_OTEL_COLLECTOR=y" >&2
    exit 1
  fi
  echo "Validated deployment profile: $matched_profile"
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
