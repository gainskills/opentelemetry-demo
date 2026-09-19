terraform {
  required_version = ">= 1.0"

  required_providers {
    newrelic = {
      source = "newrelic/newrelic"
      # newrelic_pipeline_cloud_rule was introduced in 3.68.0
      version = ">= 3.68.0, < 4.0.0"
    }
  }
}
