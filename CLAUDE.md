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
  - `context: metric` / `context: datapoint` (in `filter/Metrics`)
  - **There is NO `context: transaction` in PCG.**
- **Pre-enrichment limitations**: Cloud-enriched attributes such as `appName`, `appId`, `entity.guid`, and `transactionType` **do not exist at the gateway level** (they are attached later by New Relic cloud ingestion). Filter expressions at the gateway must use raw attributes (`name`, `http.route`, `attributes["uri"]`, etc.).

### 3. Why Health Items Still Appear in New Relic `Transaction` or APM UI
1. **`Span` vs `Transaction` Event**:
   - PCG's `filter/Traces` drops spans (`FROM Span`). It does not drop APM transaction events (`analytic_event_data` / `FROM Transaction`), which are forwarded to `event_api_endpoint`.
   - Dropping `Transaction` events from NRDB requires **Pipeline Control Cloud Rules** (e.g. `DELETE FROM Transaction WHERE name LIKE '%healthz%'`).
2. **Pre-Aggregated Timeslice Metrics**:
   - APM UI summary charts (RPM throughput, response time, Apdex) are backed by Timeslice Metrics (`HttpDispatcher`, `WebTransaction`, `Apdex`).
   - The agent pre-aggregates these rollups in-memory before transmission. PCG cannot recalculate or deduct durations from aggregated parent rollups even if leaf metrics are dropped.
3. **Transaction Naming Discrepancies**:
   - Built-in framework handlers or raw HTTP servers (e.g., standard Java `HttpServer`) may generate default transaction names (e.g., `OtherTransaction/Java/...`) that do not match route-based patterns like `(?i).*healthz.*`.

---

## Git & Workflow Invariants

- **Never execute `git add` or `git commit`**: The user manages git staging and commits directly.
- **Preserve AI disclosure guidelines**: Use `Assisted-by:` trailers in commit messages when appropriate, never `Co-authored-by:` (per `AGENTS.md`).
- **Never post AI-generated text directly to PRs or GitHub issues** without explicit user confirmation (per `AGENTS.md`).
