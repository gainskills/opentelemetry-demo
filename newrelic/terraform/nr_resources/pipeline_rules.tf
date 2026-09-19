# --------------------------------------------------------------------------------------------------
# New Relic Pipeline Control Rules & Metric Pruning Rules
#
# PURPOSE:
# This file defines backend data-dropping and cardinality-reduction rules to control New Relic
# ingestion volume and storage costs.
#
# CRITICAL ARCHITECTURAL & BILLING CONTEXT:
# 1. End-of-Life (EOL) Successor:
#    These resources replace the legacy NRQL Drop Rules API (`nrqlDropRulesCreate` mutation and
#    `newrelic_nrql_drop_rule` Terraform resource), which has reached EOL.
# 2. Advanced Compute SKU Billing:
#    Unlike legacy drop rules (which were free at ingest), Pipeline Cloud Rules fall under the
#    Advanced Compute SKU. Charges are incurred based on Billable Scanned Events (BSE) and
#    dropped GBs. For high-volume streams, prioritize dropping data at the Edge (OTel Collector
#    or Pipeline Control Gateway) to eliminate both cloud egress and backend compute charges.
# 3. Entity Synthesis Guardrails:
#    DO NOT drop or prune `k8s.pod.uid`, `k8s.container.id`, `k8s.cluster.name`, `k8s.namespace.name`,
#    or `entity.guid`. New Relic's Kubernetes Cluster Explorer and APM-to-Infrastructure correlation
#    depend strictly on these attributes.
# --------------------------------------------------------------------------------------------------

# --------------------------------------------------------------------------------------------------
# 1. Pipeline Cloud Rule: Drop Noisy Debug Logs Across All Services
#
# PURPOSE:
# DEBUG-level logs often constitute 40-70% of total log volume in non-production or chatty
# microservices without providing operational alert value. This rule discards all DEBUG logs
# before they are written to the New Relic Database (NRDB).
# --------------------------------------------------------------------------------------------------
resource "newrelic_pipeline_cloud_rule" "drop_debug_logs" {
  count       = var.enable_pipeline_cloud_rules ? 1 : 0
  account_id  = var.newrelic_account_id
  name        = "Drop All Debug Level Logs"
  description = "Discards all DEBUG level logs across all services to control log ingest volume."
  nrql        = "DELETE FROM Log WHERE logLevel = 'DEBUG' OR level = 'DEBUG' OR severity = 'DEBUG'"
}

# --------------------------------------------------------------------------------------------------
# 2. Pipeline Cloud Rule: Drop Health Check and Liveness/Readiness Probe Logs
#
# PURPOSE:
# Frequent synthetic health check probes (e.g. /healthz, /readyz, kube-probe) generate continuous
# log noise from ingress controllers and services. This rule drops logs matching standard probe
# patterns if they were not already filtered at the edge.
# --------------------------------------------------------------------------------------------------
resource "newrelic_pipeline_cloud_rule" "drop_health_probe_logs" {
  count       = var.enable_pipeline_cloud_rules ? 1 : 0
  account_id  = var.newrelic_account_id
  name        = "Drop Probe and Healthcheck Logs"
  description = "Discards Kubernetes probe logs (/healthz, /readyz, kube-probe) that escaped edge filtering."
  nrql        = "DELETE FROM Log WHERE message LIKE '%/healthz%' OR message LIKE '%/readyz%' OR message LIKE '%kube-probe%'"
}

# --------------------------------------------------------------------------------------------------
# 3. Pipeline Cloud Rule: Strip Sensitive / PII Attributes from Logs
#
# PURPOSE:
# Instead of dropping the entire log record, this rule strips specific sensitive or high-cardinality
# ephemeral attributes (e.g. client IP, session tokens) while preserving the rest of the log event
# for troubleshooting and search.
# --------------------------------------------------------------------------------------------------
resource "newrelic_pipeline_cloud_rule" "strip_sensitive_log_attributes" {
  count       = var.enable_pipeline_cloud_rules ? 1 : 0
  account_id  = var.newrelic_account_id
  name        = "Strip PII and Ephemeral Tokens from Logs"
  description = "Removes sensitive authorization tokens and client IP attributes while retaining log entries."
  nrql        = "DELETE client_ip, authorization_header, bearer_token FROM Log"
}

# --------------------------------------------------------------------------------------------------
# 4. Metric Pruning Rule: Cardinality Reduction on Custom Business Metrics
#
# PURPOSE:
# Replaces legacy `drop_attributes_from_metric_aggregates` action. Strips high-cardinality dynamic
# tags (e.g., individual transaction IDs, customer UUIDs, ephemeral session IDs) before metric
# timeslice data is written, preventing cardinality explosion and runaway metric storage costs.
# --------------------------------------------------------------------------------------------------
resource "newrelic_metric_pruning_rule" "prune_order_metric_cardinality" {
  count       = var.enable_pipeline_cloud_rules ? 1 : 0
  account_id  = var.newrelic_account_id
  name        = "Prune Ephemeral Order Metric Attributes"
  description = "Strips high-cardinality transaction IDs from custom order metrics to prevent cardinality explosion."
  metric_name = "app.order.duration"
  attribute_names = [
    "transaction_id",
    "order_session_uuid",
    "customer_ip"
  ]
}
