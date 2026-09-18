package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	// NOTE: keep these in sync with newrelic/scripts/common.sh
	// (OTEL_DEMO_CHART_VERSION / NR_K8S_CHART_VERSION / NRI_BUNDLE_CHART_VERSION). Tracked for de-duplication.
	OtelDemoChartVersion  = "0.41.2"
	NrK8sChartVersion     = "0.14.2"
	NriBundleChartVersion = "8.0.26"
	OtelDemoNamespace     = "opentelemetry-demo"
	// nri-bundle runs in its own namespace so it shares no Kubernetes objects
	// with the demo or NRDOT. Secrets are namespaced, so handleK8s creates a
	// copy of the license secret there from the same license key input.
	NriBundleNamespace = "newrelic"
)

var (
	isOpenShift = false

	// Global capture of shell environment for restoration after uninstall
	InitialLicenseKey string
	InitialAccountId  string

	Paths = map[string]string{
		"otel-values":         filepath.Join("..", "k8s", "helm", "opentelemetry-demo.yaml"),
		"otel-browser-values": filepath.Join("..", "k8s", "helm", "nr-browser.yaml"),
		"otel-nri-values":     filepath.Join("..", "k8s", "helm", "opentelemetry-demo-nri-collector.yaml"),
		"nr-k8s-values":       filepath.Join("..", "k8s", "helm", "nr-k8s-otel-collector.yaml"),
		"nri-bundle-values":   filepath.Join("..", "k8s", "helm", "nri-bundle.yaml"),
		"docker-compose":      filepath.Join("..", "docker", "docker-compose.yml"),
		"docker-patch":        filepath.Join("..", "docker", "config", "monkey-patch.js"),
		"tf-account":          filepath.Join("..", "terraform", "nr_account"),
		"tf-resources":        filepath.Join("..", "terraform", "nr_resources"),
		"tf-browser":          filepath.Join("..", "terraform", "nr_browser"),
	}

	Charts = map[string]struct{ Name, Repo, Version, NS string }{
		"nr-k8s":     {"nr-k8s-otel-collector", "newrelic/nr-k8s-otel-collector", NrK8sChartVersion, OtelDemoNamespace},
		"nri-bundle": {"nri-bundle", "newrelic/nri-bundle", NriBundleChartVersion, NriBundleNamespace},
		"otel-demo":  {"otel-demo", "open-telemetry/opentelemetry-demo", OtelDemoChartVersion, OtelDemoNamespace},
	}
)

type Config struct {
	LicenseKey, ApiKey, AccountId, Region, Target, Action                              string
	EnableBrowser                                                                      *bool
	EnableNrdot                                                                        *bool
	EnableNriBundle                                                                    *bool
	EnableDemoOtelCollector                                                            *bool
	OtlpEndpoint                                                                       string
	SubAccountId                                                                       string
	ParentAccountId                                                                    string
	SubaccountName, AdminGroupName                                                     string
	ReadonlyUserEmail, ReadonlyUserName                                                string
	BrowserLicenseKey, BrowserAppID, BrowserAccountID, BrowserTrustKey, BrowserAgentID string
}

// CaptureInitialEnv stores the shell's variables before .env loads
func CaptureInitialEnv() {
	InitialLicenseKey = os.Getenv("NEW_RELIC_LICENSE_KEY")
	InitialAccountId = os.Getenv("NEW_RELIC_ACCOUNT_ID")
}

func loadConfig(cfg *Config) {
	// 1. Load .env file preserving original case for Terraform compatibility
	if envData, err := os.ReadFile(".env"); err == nil {
		lines := strings.Split(string(envData), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			pair := strings.SplitN(line, "=", 2)
			if len(pair) == 2 {
				key := strings.TrimSpace(pair[0])
				val := strings.TrimSpace(pair[1])
				os.Setenv(key, val)
			}
		}
	}

	if cfg.Region == "" {
		cfg.Region = strings.ToUpper(getEnvOrDefault("NEW_RELIC_REGION", "US"))
	}

	// Helper to check both uppercase and lowercase suffixes for TF_VARs
	getTFVar := func(suffix string) string {
		val := os.Getenv("TF_VAR_" + suffix)
		if val == "" {
			val = os.Getenv("TF_VAR_" + strings.ToUpper(suffix))
		}
		return val
	}

	// 2. Populate fields from Environment (Standardizing to match Config struct)
	if cfg.LicenseKey == "" {
		cfg.LicenseKey = os.Getenv("NEW_RELIC_LICENSE_KEY")
	}
	if cfg.ApiKey == "" {
		cfg.ApiKey = os.Getenv("NEW_RELIC_API_KEY")
	}
	if cfg.AccountId == "" {
		cfg.AccountId = os.Getenv("NEW_RELIC_ACCOUNT_ID")
	}

	// Meta and Terraform Vars (Lowercase suffixes for variables.tf alignment)
	// NOTE: SubAccountId is intentionally NOT restored from TF_VAR_newrelic_account_id
	// here. It's only meant to hold a sub-account ID freshly created by this run's
	// "account" provisioning step (see terraform.go), which also sets AccountId to the
	// same value. Restoring it from a leftover env var let a stale sub-account ID from
	// a previous run silently override an explicit --NEW_RELIC_ACCOUNT_ID flag later
	// (buildEnvMap checked SubAccountId before AccountId). AccountId's own restoration
	// from NEW_RELIC_ACCOUNT_ID below already covers the "reuse across invocations" case.
	if cfg.ParentAccountId == "" {
		cfg.ParentAccountId = getTFVar("newrelic_parent_account_id")
	}
	if cfg.SubaccountName == "" {
		cfg.SubaccountName = getTFVar("subaccount_name")
	}
	if cfg.AdminGroupName == "" {
		cfg.AdminGroupName = getTFVar("admin_group_name")
	}
	if cfg.ReadonlyUserEmail == "" {
		cfg.ReadonlyUserEmail = getTFVar("readonly_user_email")
	}
	if cfg.ReadonlyUserName == "" {
		cfg.ReadonlyUserName = getTFVar("readonly_user_name")
	}

	// Browser fields from OS/Env
	if cfg.BrowserLicenseKey == "" {
		cfg.BrowserLicenseKey = os.Getenv("BROWSER_LICENSE_KEY")
	}
	if cfg.BrowserAppID == "" {
		cfg.BrowserAppID = os.Getenv("BROWSER_APPLICATION_ID")
	}
	if cfg.BrowserAccountID == "" {
		cfg.BrowserAccountID = os.Getenv("BROWSER_ACCOUNT_ID")
	}
	if cfg.BrowserTrustKey == "" {
		cfg.BrowserTrustKey = os.Getenv("BROWSER_TRUST_KEY")
	}
	if cfg.BrowserAgentID == "" {
		cfg.BrowserAgentID = os.Getenv("BROWSER_AGENT_ID")
	}

	// 3. Populate EnableBrowser from Flag/Env
	if cfg.EnableBrowser == nil {
		if envVal := os.Getenv("NEW_RELIC_ENABLE_BROWSER"); envVal != "" {
			b := strings.ToLower(envVal) == "true"
			cfg.EnableBrowser = &b
		}
	}

	// 4. Populate K8s component flags from Env
	if cfg.EnableNrdot == nil {
		if envVal := os.Getenv("ENABLE_NRDOT"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableNrdot = &b
		}
	}
	if cfg.EnableNriBundle == nil {
		if envVal := os.Getenv("ENABLE_NRI_BUNDLE"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableNriBundle = &b
		}
	}
	if cfg.EnableDemoOtelCollector == nil {
		// ENABLE_NRI_BUNDLE_OTEL_COLLECTOR is the former name of this switch.
		envVal := os.Getenv("ENABLE_DEMO_OTEL_COLLECTOR")
		if envVal == "" {
			envVal = os.Getenv("ENABLE_NRI_BUNDLE_OTEL_COLLECTOR")
		}
		if envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableDemoOtelCollector = &b
		}
	}

	if cfg.OtlpEndpoint == "" {
		cfg.OtlpEndpoint = os.Getenv("NEW_RELIC_OTLP_ENDPOINT")
	}

	if cfg.Action == "uninstall" {
		return
	}

	// 5. Consolidated Browser Prompt (Asked once here if still unknown)
	if cfg.EnableBrowser == nil && (cfg.Target == "k8s" || cfg.Target == "docker") {
		fmt.Println("\n>>> Browser Monitoring configuration missing.")
		enable := promptBool("Do you want to enable Digital Experience Monitoring (Browser)?")
		cfg.EnableBrowser = &enable
	}

	// 6. Prompts for K8s monitoring components if target is k8s and not yet set
	if cfg.Target == "k8s" {
		if cfg.EnableNrdot == nil {
			enable := promptBoolWithDefault("Enable New Relic OTel Collector (NRDOT)?", true)
			cfg.EnableNrdot = &enable
		}
		if cfg.EnableNriBundle == nil {
			enable := promptBoolWithDefault("Enable New Relic Infrastructure Bundle (nri-bundle)?", false)
			cfg.EnableNriBundle = &enable
		}
		if cfg.EnableDemoOtelCollector == nil {
			if !*cfg.EnableNrdot {
				enable := promptBoolWithDefault("NRDOT is disabled. Enable the demo's own OpenTelemetry Collector to export app telemetry to New Relic?", true)
				cfg.EnableDemoOtelCollector = &enable
			} else {
				f := false
				cfg.EnableDemoOtelCollector = &f
			}
		}
		if !*cfg.EnableNrdot && !*cfg.EnableDemoOtelCollector {
			fmt.Println(ColorYellow + "Warning: no collector enabled. The demo's services will export telemetry to an endpoint that does not exist and no application data will reach New Relic." + ColorReset)
		}
	}

	// Standard prompts for K8s/Docker
	if cfg.Target == "k8s" || cfg.Target == "docker" {
		if cfg.LicenseKey == "" {
			cfg.LicenseKey = promptUser("Enter your License Key (ends in -NRAL)", validateLicenseKey)
		}

		// If Browser is enabled, we MUST have API Key and Account ID for the Terraform step
		if cfg.EnableBrowser != nil && *cfg.EnableBrowser {
			if cfg.ApiKey == "" {
				cfg.ApiKey = promptUser("Enter your User API Key (begins with NRAK-)", validateUserApiKey)
			}
			if cfg.AccountId == "" {
				cfg.AccountId = promptUser("Enter your New Relic Account ID", validateNotEmpty)
			}
		}
	}

	if cfg.Target == "account" || cfg.Target == "resources" || cfg.Target == "browser" {
		if cfg.ApiKey == "" {
			cfg.ApiKey = promptUser("User API Key (NRAK)", validateUserApiKey)
		}
		if cfg.AccountId == "" {
			cfg.AccountId = promptUser("Parent Account ID", validateNotEmpty)
		}
	}

	if cfg.Target == "account" {
		if cfg.SubaccountName == "" {
			cfg.SubaccountName = promptUser("New Subaccount Name", validateNotEmpty)
		}
		if cfg.AdminGroupName == "" {
			cfg.AdminGroupName = promptUser("Existing Admin Group Name", validateNotEmpty)
		}
		if cfg.ReadonlyUserEmail == "" {
			cfg.ReadonlyUserEmail = promptUser("New Read-Only User Email", validateNotEmpty)
		}
		if cfg.ReadonlyUserName == "" {
			cfg.ReadonlyUserName = promptUser("New Read-Only User Name", validateNotEmpty)
		}
	}
}
