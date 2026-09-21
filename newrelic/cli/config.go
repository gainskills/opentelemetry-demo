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
	OtelDemoChartVersion     = "0.42.0"
	NrK8sChartVersion        = "0.14.2"
	NriBundleChartVersion    = "8.0.28"
	PcgChartVersion          = "2.5.0"
	AgentControlChartVersion = "1.7.20"
	OtelDemoNamespace        = "opentelemetry-demo"
	// nri-bundle and PCG run in their own namespace (newrelic) so they share no
	// Kubernetes objects with the demo or NRDOT.
	NriBundleNamespace = "newrelic"
	PcgNamespace       = "newrelic"
)

var (
	isOpenShift = false

	// Global capture of shell environment for restoration after uninstall
	InitialLicenseKey string
	InitialAccountId  string

	Paths = map[string]string{
		"otel-values":          filepath.Join("..", "k8s", "helm", "opentelemetry-demo-base.yaml"),
		"otel-browser-values":  filepath.Join("..", "k8s", "helm", "nr-browser.yaml"),
		"otel-nri-values":      filepath.Join("..", "k8s", "helm", "opentelemetry-demo-pure.yaml"),
		"otel-pcg-values":      filepath.Join("..", "k8s", "helm", "opentelemetry-demo-pcg.yaml"),
		"nr-k8s-values":        filepath.Join("..", "k8s", "helm", "nr-k8s-otel-collector.yaml"),
		"nri-bundle-values":    filepath.Join("..", "k8s", "helm", "nri-bundle.yaml"),
		"pcg-values":           filepath.Join("..", "k8s", "helm", "nr-pipeline-control-gateway.yaml"),
		"agent-control-values": filepath.Join("..", "k8s", "helm", "nr-agent-control-deployment.yaml"),
		"apm-test-apps":        filepath.Join("..", "k8s", "apm-test-apps.yaml"),
		"docker-compose":       filepath.Join("..", "docker", "docker-compose.yml"),
		"docker-patch":         filepath.Join("..", "docker", "config", "monkey-patch.js"),
		"tf-account":           filepath.Join("..", "terraform", "nr_account"),
		"tf-resources":         filepath.Join("..", "terraform", "nr_resources"),
		"tf-browser":           filepath.Join("..", "terraform", "nr_browser"),
	}

	Charts = map[string]struct{ Name, Repo, Version, NS string }{
		"nr-k8s":        {"nr-k8s-otel-collector", "newrelic/nr-k8s-otel-collector", NrK8sChartVersion, OtelDemoNamespace},
		"nri-bundle":    {"nri-bundle", "newrelic/nri-bundle", NriBundleChartVersion, NriBundleNamespace},
		"otel-demo":     {"otel-demo", "open-telemetry/opentelemetry-demo", OtelDemoChartVersion, OtelDemoNamespace},
		"pcg":           {"newrelic-pcg", "newrelic/pipeline-control-gateway", PcgChartVersion, PcgNamespace},
		"agent-control": {"agent-control-deployment", "newrelic/agent-control-deployment", AgentControlChartVersion, PcgNamespace},
	}
)

type Config struct {
	LicenseKey, ApiKey, AccountId, Region, Target, Action                              string
	ClientId, ClientSecret, OrganizationId                                             string
	EnableBrowser                                                                      *bool
	EnableNrdot                                                                        *bool
	EnableNriBundle                                                                    *bool
	EnableDemoOtelCollector                                                            *bool
	EnablePcg                                                                          *bool
	PcgFleetName                                                                       string
	EnableApmTestApps                                                                  *bool
	EnableOtelDemoApps                                                                 *bool
	EnableApmHybridApps                                                                *bool
	EnableApmNativeApps                                                                *bool
	OtelDemoDest                                                                       string
	ApmHybridDest                                                                      string
	ApmNativeDest                                                                      string
	RouteDemoToPcg                                                                     *bool
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
	if cfg.ClientId == "" {
		cfg.ClientId = os.Getenv("NEW_RELIC_CLIENT_ID")
	}
	if cfg.ClientSecret == "" {
		cfg.ClientSecret = os.Getenv("NEW_RELIC_CLIENT_SECRET")
	}
	if cfg.OrganizationId == "" {
		cfg.OrganizationId = os.Getenv("NEW_RELIC_ORGANIZATION_ID")
		if cfg.OrganizationId == "" && cfg.AccountId != "" {
			cfg.OrganizationId = cfg.AccountId
		}
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
		if envVal := os.Getenv("ENABLE_DEMO_OTEL_COLLECTOR"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableDemoOtelCollector = &b
		}
	}
	if cfg.EnablePcg == nil {
		if envVal := os.Getenv("ENABLE_PCG"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnablePcg = &b
		}
	}
	if cfg.PcgFleetName == "" {
		cfg.PcgFleetName = os.Getenv("NEW_RELIC_GATEWAY_FLEET")
		if cfg.PcgFleetName == "" {
			cfg.PcgFleetName = "otel-demo-fleet"
		}
	}
	if cfg.EnableApmTestApps == nil {
		if envVal := os.Getenv("ENABLE_APM_TEST_APPS"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableApmTestApps = &b
		}
	}
	if cfg.RouteDemoToPcg == nil {
		if envVal := os.Getenv("ROUTE_DEMO_TO_PCG"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.RouteDemoToPcg = &b
		}
	}
	if cfg.EnableOtelDemoApps == nil {
		if envVal := os.Getenv("ENABLE_OTEL_DEMO_APPS"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableOtelDemoApps = &b
		}
	}
	if cfg.EnableApmHybridApps == nil {
		if envVal := os.Getenv("ENABLE_APM_HYBRID_APPS"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableApmHybridApps = &b
		}
	}
	if cfg.EnableApmNativeApps == nil {
		if envVal := os.Getenv("ENABLE_APM_NATIVE_APPS"); envVal != "" {
			b := strings.ToLower(envVal) == "y" || strings.ToLower(envVal) == "true"
			cfg.EnableApmNativeApps = &b
		}
	}
	if cfg.OtelDemoDest == "" {
		cfg.OtelDemoDest = strings.ToLower(os.Getenv("OTEL_DEMO_DEST"))
	}
	if cfg.ApmHybridDest == "" {
		cfg.ApmHybridDest = strings.ToLower(os.Getenv("APM_HYBRID_DEST"))
	}
	if cfg.ApmNativeDest == "" {
		cfg.ApmNativeDest = strings.ToLower(os.Getenv("APM_NATIVE_DEST"))
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
		if cfg.EnablePcg == nil {
			enable := promptBoolWithDefault("Enable Pipeline Control Gateway (PCG)?", false)
			cfg.EnablePcg = &enable
		}
		if *cfg.EnablePcg {
			if cfg.PcgFleetName == "" {
				cfg.PcgFleetName = promptUserWithDefault("Enter New Relic Gateway Fleet Name", "otel-demo-fleet")
			}
			if cfg.ClientId == "" {
				cfg.ClientId = promptUserOptional("Enter New Relic Client ID for Fleet Control (optional, press Enter for in-cluster rules)")
			}
			if cfg.ClientId != "" {
				if cfg.ClientSecret == "" {
					cfg.ClientSecret = promptUser("Enter New Relic Client Secret", validateNotEmpty)
				}
				if cfg.OrganizationId == "" {
					if cfg.AccountId != "" {
						cfg.OrganizationId = promptUserWithDefault("Enter New Relic Organization ID", cfg.AccountId)
					} else {
						cfg.OrganizationId = promptUser("Enter New Relic Organization ID", validateNotEmpty)
					}
				}
			}
		}

		if *cfg.EnableNrdot {
			if cfg.EnableDemoOtelCollector != nil && *cfg.EnableDemoOtelCollector {
				fmt.Println(ColorYellow + "Note: ENABLE_NRDOT=true is active. Disabling ENABLE_DEMO_OTEL_COLLECTOR (only one collector can be deployed at a time)." + ColorReset)
			}
			f := false
			cfg.EnableDemoOtelCollector = &f
		} else if cfg.EnableDemoOtelCollector == nil {
			enable := promptBoolWithDefault("NRDOT is disabled. Deploy pure OpenTelemetry Collector architecture?", true)
			cfg.EnableDemoOtelCollector = &enable
		}

		if err := validateProfile(cfg); err != nil {
			fmt.Println(ColorRed + "Warning: " + err.Error() + ColorReset)
		}

		promptApplicationSuites(cfg)
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

func validateProfile(cfg *Config) error {
	if cfg.Target != "k8s" || cfg.Action == "uninstall" {
		return nil
	}

	nrdot := cfg.EnableNrdot != nil && *cfg.EnableNrdot
	nri := cfg.EnableNriBundle != nil && *cfg.EnableNriBundle
	demoOtel := cfg.EnableDemoOtelCollector != nil && *cfg.EnableDemoOtelCollector
	pcg := cfg.EnablePcg != nil && *cfg.EnablePcg

	valid := false
	switch {
	case nrdot && !nri && !demoOtel && !pcg: // 1. NRDOT standard
		valid = true
	case !nrdot && nri && !demoOtel && !pcg: // 2. NRI-Bundle only
		valid = true
	case !nrdot && nri && demoOtel && !pcg: // 3. NRI-Bundle + Pure OTel hybrid
		valid = true
	case !nrdot && !nri && demoOtel && !pcg: // 4. Pure OTel agentless
		valid = true
	case !nrdot && !nri && !demoOtel && pcg: // 5. PCG only
		valid = true
	case nrdot && !nri && !demoOtel && pcg: // 6. PCG + NRDOT
		valid = true
	case !nrdot && nri && !demoOtel && pcg: // 7. PCG + NRI-Bundle
		valid = true
	case !nrdot && !nri && demoOtel && pcg: // 8. PCG + Pure OTel
		valid = true
	}

	if !valid {
		return fmt.Errorf("selected configuration (NRDOT=%v, NRI=%v, PureOTel=%v, PCG=%v) does not match any of the 8 supported profiles:\n"+
			"  1. NRDOT (standard): ENABLE_NRDOT=true\n"+
			"  2. NRI-Bundle only: ENABLE_NRI_BUNDLE=true\n"+
			"  3. NRI-Bundle + Pure OTel (hybrid): ENABLE_NRI_BUNDLE=true, ENABLE_DEMO_OTEL_COLLECTOR=true\n"+
			"  4. Pure OTel Collector (agentless): ENABLE_DEMO_OTEL_COLLECTOR=true\n"+
			"  5. PCG only: ENABLE_PCG=true\n"+
			"  6. PCG + NRDOT: ENABLE_PCG=true, ENABLE_NRDOT=true\n"+
			"  7. PCG + NRI-Bundle: ENABLE_PCG=true, ENABLE_NRI_BUNDLE=true\n"+
			"  8. PCG + Pure OTel Collector: ENABLE_PCG=true, ENABLE_DEMO_OTEL_COLLECTOR=true",
			nrdot, nri, demoOtel, pcg)
	}
	return nil
}

// Prompt user for application suites to deploy and their telemetry destinations
func promptApplicationSuites(cfg *Config) {
	fmt.Println("\n--- Application Suites Selection & Telemetry Routing ---")

	// 1. OpenTelemetry Demo Apps (15+ upstream services)
	if cfg.EnableOtelDemoApps == nil {
		enable := promptBoolWithDefault("Deploy OpenTelemetry Demo microservices (15+ upstream services)?", true)
		cfg.EnableOtelDemoApps = &enable
	}

	if *cfg.EnableOtelDemoApps {
		if cfg.OtelDemoDest == "" {
			var otelOpts []ChoiceOption
			if cfg.EnablePcg != nil && *cfg.EnablePcg {
				otelOpts = append(otelOpts, ChoiceOption{"pcg", "Pipeline Control Gateway (pipeline-control-gateway:4317)"})
			}
			if cfg.EnableNrdot == nil || *cfg.EnableNrdot {
				otelOpts = append(otelOpts, ChoiceOption{"nrdot", "NRDOT Collector (nr-k8s-otel-collector-gateway:4317)"})
			}
			if cfg.EnableDemoOtelCollector != nil && *cfg.EnableDemoOtelCollector {
				otelOpts = append(otelOpts, ChoiceOption{"otel-collector", "Pure OpenTelemetry Collector (otel-collector:4317)"})
			}
			otelOpts = append(otelOpts, ChoiceOption{"saas", "Direct to New Relic SaaS (https://otlp.nr-data.net:4318)"})

			cfg.OtelDemoDest = promptChoice("Choose destination for OpenTelemetry Demo services:", 1, otelOpts)
		}
		routePcg := (cfg.OtelDemoDest == "pcg")
		cfg.RouteDemoToPcg = &routePcg
	} else {
		f := false
		cfg.RouteDemoToPcg = &f
	}

	// If APM test apps were explicitly disabled, skip child prompts
	if cfg.EnableApmTestApps != nil && !*cfg.EnableApmTestApps {
		f := false
		cfg.EnableApmHybridApps = &f
		cfg.EnableApmNativeApps = &f
		return
	}

	// 2. New Relic APM Hybrid Apps (Python, Node, Java, .NET with OTel API)
	if cfg.EnableApmHybridApps == nil {
		enable := promptBoolWithDefault("Deploy New Relic APM Hybrid test workloads (OTel API Mode)?", true)
		cfg.EnableApmHybridApps = &enable
	}

	if *cfg.EnableApmHybridApps {
		if cfg.ApmHybridDest == "" {
			if cfg.EnablePcg != nil && *cfg.EnablePcg {
				hybridOpts := []ChoiceOption{
					{"pcg", "Pipeline Control Gateway (SaaS entity registration + PCG port 4318 OTLP)"},
					{"saas", "Direct to New Relic SaaS (collector.newrelic.com:443 / otlp.nr-data.net:4318)"},
				}
				cfg.ApmHybridDest = promptChoice("Choose destination for APM Hybrid workloads:", 1, hybridOpts)
			} else {
				cfg.ApmHybridDest = "saas"
				fmt.Println("Note: In-cluster OTel collectors cannot ingest New Relic APM agent traffic. APM Hybrid workloads will send directly to New Relic SaaS.")
			}
		}
	}

	// 3. New Relic APM Native Apps (Python, Node, Java, .NET with Proprietary Protocol)
	if cfg.EnableApmNativeApps == nil {
		enable := promptBoolWithDefault("Deploy New Relic APM Native test workloads (Proprietary Protocol)?", true)
		cfg.EnableApmNativeApps = &enable
	}

	if *cfg.EnableApmNativeApps {
		if cfg.ApmNativeDest == "" {
			if cfg.EnablePcg != nil && *cfg.EnablePcg {
				nativeOpts := []ChoiceOption{
					{"saas", "Direct to New Relic SaaS (https://collector.newrelic.com:443 for baseline testing)"},
					{"pcg", "Pipeline Control Gateway (port 80 nrproprietaryreceiver - requires plaintext support or TLS proxy)"},
				}
				cfg.ApmNativeDest = promptChoice("Choose destination for APM Native workloads:", 1, nativeOpts)
			} else {
				cfg.ApmNativeDest = "saas"
				fmt.Println("Note: PCG is not deployed. Native APM workloads will report directly to New Relic SaaS (collector.newrelic.com:443) for baseline comparison.")
			}
		}
	}

	// Maintain EnableApmTestApps compatibility flag for scripts/cleanup
	nativeOn := cfg.EnableApmNativeApps != nil && *cfg.EnableApmNativeApps
	hybridOn := cfg.EnableApmHybridApps != nil && *cfg.EnableApmHybridApps
	hasApm := nativeOn || hybridOn
	cfg.EnableApmTestApps = &hasApm
}
