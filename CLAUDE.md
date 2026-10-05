# CLAUDE.md

@AGENTS.md

## Repository & Architectural Context

This repository (`opentelemetry-demo_nr`) is a New Relic fork of the OpenTelemetry Astronomy Shop Demo.
It contains two distinct application workload suites:
1. **Upstream OpenTelemetry Demo Services**: ~15 microservices instrumented with pure OpenTelemetry SDKs, exporting telemetry via OTLP (gRPC/HTTP ports 4317/4318).
2. **New Relic APM Test Microservices** (`newrelic/k8s/apm-test-apps.yaml`): 8 dedicated services across 4 runtimes (Python, Node.js, Java, .NET) running the official New Relic APM agent (4 Native + 4 Hybrid).

---

## Strict Rule: New Relic Native APM vs. Hybrid APM Mode

### 1. Definitions
- **Native APM Agent**:
  - Runs the official New Relic APM agent with `NEW_RELIC_OPENTELEMETRY_ENABLED=false`.
  - Emits proprietary agent protocol over TLS to port 443 (`NEW_RELIC_HOST`).
- **Hybrid APM Agent (OpenTelemetry API Support)**:
  - Runs the **official New Relic APM agent** with `NEW_RELIC_OPENTELEMETRY_ENABLED=true` (or `opentelemetry.enabled: true` in agent config).
  - Emits proprietary agent protocol over TLS to port 443 (`NEW_RELIC_HOST`).
  - Enables the New Relic APM agent to bridge OpenTelemetry API calls (e.g. `opentelemetry.trace` / `TracerProvider`) into New Relic spans ([New Relic OTel API Support Docs](https://docs.newrelic.com/docs/apm/agents/manage-apm-agents/opentelemetry-api-support/)).

### 2. Critical Invariants (Never Confuse or Assume)
- **Hybrid APM is NOT pure OpenTelemetry**:
  - It does **NOT** use pure OpenTelemetry SDKs, OpenTelemetry Collector agents, or OTLP trace exporters.
  - It runs the official New Relic APM agent binary/package.
- **`instrumentation.provider` is `'newrelic'` for BOTH**:
  - In New Relic (NRDB / Distributed Tracing / UI), `instrumentation.provider` is **`'newrelic'` for both Native and Hybrid APM workloads**.
  - `instrumentation.provider = 'opentelemetry'` is ONLY emitted by pure OpenTelemetry SDKs reporting via OTLP.
  - **NEVER claim that Hybrid APM agents emit `instrumentation.provider = 'opentelemetry'`.**
- **How to Distinguish Native vs. Hybrid in New Relic**:
  - **In New Relic UI**: Navigate to **APM & Services → [Service Name] → Settings → Environment** (Agent Initialization / Configuration Settings). Look for `opentelemetry.enabled`:
    - `true` = Hybrid APM.
    - `false` (or omitted) = Native APM.
  - **In Tracing**: If the application code invokes OpenTelemetry APIs (`tracer.start_as_current_span`), those custom spans appear inside the New Relic distributed trace bridged by the agent.

---

## Pipeline Control Gateway (PCG) & Telemetry Routing

### 1. Protocols and Ports
- **New Relic APM Workloads (Native & Hybrid)**:
  - Connect to PCG over HTTPS/TLS on **port 443** via `nrproprietaryreceiver` (`NEW_RELIC_HOST=pipeline-control-gateway.newrelic.svc.cluster.local`, `NEW_RELIC_PORT=443`).
  - Do **NOT** send proprietary APM traffic to OTLP ports (4317/4318).
  - Require valid TLS certificates. Workloads mount the demo CA (`pcg-ca` ConfigMap) and set language-specific trust options (`NEW_RELIC_CA_BUNDLE_PATH`, `NODE_EXTRA_CA_CERTS`, `-Dnewrelic.config.ca_bundle_path`, or system CA store).
- **Pure OpenTelemetry Demo Services**:
  - Connect via OTLP (gRPC: 4317, HTTP: 4318) to NRDOT or the demo's OTel collector.
  - **NEVER route pure OTel demo services to PCG**: New Relic meters incoming data through PCG, which incurs throughput costs. Pure OTel demo services generate high synthetic telemetry volumes that must not be routed through PCG. PCG is reserved for New Relic APM agent workloads (Native & Hybrid) connecting on port 443.

### 2. Unified Pipeline Control Architecture & Critical Deprecations
- **DEPRECATION WARNING: Legacy NRQL Drop Filter Rules API is EOL (End-of-Life as of August 31, 2026)**:
  - The legacy NRQL Drop Filter Rules API (`dropRulesCreate` NerdGraph GraphQL mutation) and Terraform resource `newrelic_nrql_drop_rule` are **fully deprecated and reached End-of-Life on August 31, 2026**.
  - **NEVER** recommend `dropRulesCreate` or `newrelic_nrql_drop_rule`.
  - All cloud-side drop, discard, and attribute-stripping rules must strictly use **Pipeline Control Cloud Rules** (`newrelic_pipeline_cloud_rule` in Terraform, the Pipeline Control UI, or the Pipeline Cloud Rules API).
- **Unified Pipeline Control Topology**:
  - **Gateway Rules (PCG)**: Executed in-cluster/on-premises inside `pipeline-control-gateway` via OTTL `filter` and `transform` processors on decoded signals (`traces/nr`, `logs/nr`, OTLP). Saves outbound network bandwidth and egress costs.
  - **Cloud Rules**: Executed in New Relic's cloud ingestion infrastructure for signals that egress to New Relic Cloud.

---

## Telemetry Streams & PCG Processing Matrix

When New Relic APM agents (Native or Hybrid) report to PCG, their telemetry is split across 5 distinct proprietary harvest endpoints. PCG's `nrproprietaryreceiver` treats them differently:

| Telemetry Element | Agent Harvest Endpoint | PCG Internal Handling (`nrproprietaryreceiver`) | PCG Gateway Filter Support | Cloud Handling Mechanism |
| :--- | :--- | :--- | :--- | :--- |
| **Distributed Spans** | `span_event_data` | Decoded via `spanEventDataTransformer` into OTel spans (`traces/nr`) | **YES** (`filter/Traces` with `attributes["http.route"] == "/healthz"`) | Standard trace ingestion |
| **Transaction Traces** | `transaction_sample_data` | Decoded via `transactionTraceDataTransformer` into synthetic OTel spans (`traces/nr`) | **YES** (`filter/Traces` with `IsMatch(attributes["transaction_name"], "(?i).*healthz.*")`) | Standard trace ingestion |
| **Application Logs** | `log_event_data` | Decoded via `TransformAPMLogToPLog` into OTel logs (`logs/nr`) | **YES** (`filter/Logs`) | Standard log ingestion |
| **Timeslice Metrics** (`WebTransaction/...`, `HttpDispatcher`, throughput, response time) | `metric_data` | **No parser exists** (`ConsumeMetrics` is not implemented). Proxied raw via `proxyRequest` to `collector.newrelic.com` | **NO** (Bypasses PCG filters; payloads are opaque JSON batches) | **Metric Normalization Rules** (`IGNORE` or `REPLACE`) in APM Settings. (Cannot use cloud drop rules). |
| **Transaction Events** (`FROM Transaction`) | `analytic_event_data` | Proxied raw via `proxyRequest` to `https://insights-collector.newrelic.com` | **NO** (PCG has no `context: transaction` processor) | **Pipeline Control Cloud Rules** (`DELETE FROM Transaction WHERE ...`) |

---

## Healthcheck Filtering Guardrails: PCG vs. Agent

### 1. Absolute Rule on Scope
- **When asked about healthcheck filtering on PCG, ONLY focus on PCG (Pipeline Control Gateway).**
- **STOP suggesting changes to the application code or agent configuration** (e.g. never suggest `ignore_transaction`, app route modifications, or agent config edits when the inquiry is about gateway filtering).

### 2. PCG Architecture & OTTL Schema Capabilities
- PCG operates on pre-enrichment OpenTelemetry Collector pipelines.
- Supported filter contexts in PCG OTTL processors:
  - `context: span` / `context: span_event` (in `filter/Traces`)
  - `context: log` (in `filter/Logs`)
  - `context: metric` / `context: datapoint` (in `filter/Metrics` - applies to OTLP/Prometheus metrics, NOT agent timeslices)
  - **There is NO `context: transaction` in PCG.**
- **Pre-enrichment limitations**: Cloud-enriched attributes such as `appName`, `appId`, `entity.guid`, and `transactionType` **do not exist at the gateway level** (they are attached later by New Relic cloud ingestion). Filter expressions at the gateway must use raw attributes (`name`, `http.route`, `attributes["uri"]`, `attributes["transaction_name"]`, etc.).

### 3. Metric Normalization Rules for APM Timeslices
- **Why Cloud Drop Rules Fail on Timeslices**: Standard cloud drop rules evaluate against dimensional metric and event pipelines. New Relic explicitly documents:
  > *"APM metric timeslice data **cannot be dropped** using standard drop rules. To manage or filter metric timeslice data, you can instead use **metric normalization rules**."*
- **How Metric Normalization Operates**:
  - Evaluated pre-storage in New Relic's cloud ingestion engine on incoming metric names.
  - **Action: `IGNORE`**: Drops matching timeslices (`^WebTransaction/.*/healthz$`). Prevents the transaction from appearing in the APM Transactions list and suppresses synthetic metrics (`apm.service.transaction.overview`, `apm.service.transaction.duration`).
  - **Action: `REPLACE`**: Uses regex capture groups to rewrite dynamic paths, preventing Metric Grouping Issues (MGIs).

---

## PII, Sensitive Data & Compliance Boundaries

### 1. Perimeter Egress Risk for Proprietary APM Harvest
- Because PCG proxies `metric_data` and `analytic_event_data` raw without decoding or OTTL processing:
  - Any PII in metric names (e.g., unparameterized paths like `WebTransaction/Uri/users/john.doe@example.com`) or Transaction event attributes (`request.uri` query parameters, custom attributes, client IP) **leaves the VPC / Kubernetes cluster uninspected and unredacted**.
  - If regulatory policies (PCI-DSS, HIPAA, GDPR, Data Sovereignty) require that unmasked PII **must never exit the private network perimeter**, relying solely on PCG's `nrproprietaryreceiver` does not enforce that boundary for timeslices or Transaction events.

### 2. Mitigation Across Architectural Tiers
- **Tier 1: Gateway Egress Termination (Pre-Egress)**:
  - If Transaction events must never leave the cluster, null-route `event_api_endpoint` in PCG configuration (`event_api_endpoint: "http://127.0.0.1:9999/blackhole"`).
- **Tier 2: Cloud Sanitization (Post-Egress)**:
  - **For Timeslice Metrics**: Configure **Metric Normalization Rules** (`REPLACE`) to regex-mask sensitive identifiers before persistence.
  - **For Transaction Events**: Configure **Pipeline Control Cloud Rules** to drop sensitive attributes (`DROP_ATTRIBUTES`) or discard matching transactions (`DROP_DATA`).
- **Tier 3: Architectural Migration to Native OpenTelemetry (OTLP)**:
  - Pure OTLP workloads reporting to PCG's `otlp` receiver are fully decoded into OpenTelemetry data models.
  - Allows in-cluster redaction, hashing (`SHA256`), and attribute deletion using PCG's OpenTelemetry `transform` processor (OTTL) **before data leaves the corporate perimeter**.

---

## Git & Workflow Invariants

- **Never execute `git add` or `git commit`**: The user manages git staging and commits directly.
- **Preserve AI disclosure guidelines**: Use `Assisted-by:` trailers in commit messages when appropriate, never `Co-authored-by:` (per `AGENTS.md`).
- **Never post AI-generated text directly to PRs or GitHub issues** without explicit user confirmation (per `AGENTS.md`).
