package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"text/template"
	"time"
)

// fetchBrowserConfigFromTF retrieves browser monitoring metadata from Terraform outputs.
func fetchBrowserConfigFromTF(tfArgs []string, env []string, cfg *Config) {
	cmd := exec.Command("terraform", append(tfArgs, "output", "-json", "browser_js_config")...)
	cmd.Env = env
	out, _ := cmd.Output()

	var tfOutput string
	json.Unmarshal(out, &tfOutput)
	var nrConfig BrowserConfig
	json.Unmarshal([]byte(tfOutput), &nrConfig)

	cmdKey := exec.Command("terraform", append(tfArgs, "output", "-raw", "browser_license_key")...)
	cmdKey.Env = env
	outKey, _ := cmdKey.Output()

	cfg.BrowserLicenseKey = strings.TrimSpace(string(outKey))
	cfg.BrowserAppID = formatID(nrConfig.Info.AppID)
	cfg.BrowserAccountID = formatID(nrConfig.LoaderConfig.AccountID)
	cfg.BrowserTrustKey = formatID(nrConfig.LoaderConfig.TrustKey)
	cfg.BrowserAgentID = formatID(nrConfig.LoaderConfig.AgentID)
}

// generateBrowserYaml populates the nr-browser.yaml file using a template.
func generateBrowserYaml(cfg *Config) {
	data := TemplateData{
		LicenseKey: cfg.BrowserLicenseKey,
		AppID:      cfg.BrowserAppID,
		AccountID:  cfg.BrowserAccountID,
		TrustKey:   cfg.BrowserTrustKey,
		AgentID:    cfg.BrowserAgentID,
	}

	yamlPath := Paths["otel-browser-values"]
	tmpl, err := template.ParseFiles(yamlPath + ".tmpl")
	if err != nil {
		fmt.Printf("Error: Template file not found at %s.tmpl\n", yamlPath)
		return
	}
	outFile, err := os.Create(yamlPath)
	if err != nil {
		fmt.Printf("Error creating %s: %v\n", yamlPath, err)
		return
	}
	defer outFile.Close()
	tmpl.Execute(outFile, data)
}

// applyLicenseSecret applies the license secret idempotently to a namespace,
// matching the behavior of install-k8s.sh.
func applyLicenseSecret(namespace, licenseKey string) {
	createCmd := exec.Command("kubectl", "create", "secret", "generic", "newrelic-license-key",
		"--from-literal=license-key="+licenseKey, "-n", namespace, "--dry-run=client", "-o", "yaml")
	out, err := createCmd.Output()
	if err != nil {
		fmt.Printf("Error generating secret manifest: %v\n", err)
		os.Exit(1)
	}
	applyCmd := exec.Command("kubectl", "apply", "-f", "-")
	applyCmd.Stdin = bytes.NewReader(out)
	applyCmd.Stdout = os.Stdout
	applyCmd.Stderr = os.Stderr
	if err := applyCmd.Run(); err != nil {
		fmt.Printf("Error applying license secret: %v\n", err)
		os.Exit(1)
	}
}

// handleK8s manages the Kubernetes installation, upgrade, and uninstallation workflows.
func handleK8s(action string, cfg *Config) {
	checkTools("kubectl", "helm")
	ns := Charts["otel-demo"].NS

	if action == "uninstall" {
		uninstallRelease := func(name, namespace string, wait bool) {
			statusCmd := exec.Command("helm", "status", name, "-n", namespace)
			if err := statusCmd.Run(); err != nil {
				return
			}
			args := []string{"uninstall", name, "-n", namespace}
			if wait {
				args = append(args, "--wait")
			}
			runCommand("helm", args, nil)
		}

		uninstallRelease(Charts["otel-demo"].Name, ns, false)
		uninstallRelease(Charts["nr-k8s"].Name, ns, false)
		// --wait so nri-bundle's cluster-scoped MutatingWebhookConfiguration is
		// gone before the namespace holding its Service is deleted; an orphaned
		// webhook stalls pod admission cluster-wide on later installs.
		nriNS := Charts["nri-bundle"].NS
		uninstallRelease(Charts["nri-bundle"].Name, nriNS, true)
		pcgNS := Charts["pcg"].NS
		uninstallRelease(Charts["pcg"].Name, pcgNS, false)
		uninstallRelease(Charts["agent-control"].Name, pcgNS, false)
		exec.Command("kubectl", "delete",
			"mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding",
			"-l", "app.kubernetes.io/instance="+Charts["nri-bundle"].Name, "--ignore-not-found").Run()
		if _, err := os.Stat(Paths["apm-test-apps"]); err == nil {
			runCommand("kubectl", []string{"delete", "-f", Paths["apm-test-apps"], "--ignore-not-found"}, nil)
		}
		runCommand("kubectl", []string{"delete", "secret", "newrelic-agent-control-secret", "-n", pcgNS, "--ignore-not-found"}, nil)
		runCommand("kubectl", []string{"delete", "ns", ns, "--ignore-not-found"}, nil)
		if nriNS != ns {
			runCommand("kubectl", []string{"delete", "ns", nriNS, "--ignore-not-found"}, nil)
		}
		if pcgNS != ns && pcgNS != nriNS {
			runCommand("kubectl", []string{"delete", "ns", pcgNS, "--ignore-not-found"}, nil)
		}
		return
	}

	// Browser setup logic: executes only if enabled and config is missing
	if cfg.EnableBrowser != nil && *cfg.EnableBrowser {
		if cfg.BrowserAppID == "" {
			fmt.Println("\n>>> Setting up Browser Monitoring (Terraform)...")
			oldTarget := cfg.Target
			cfg.Target = "browser"
			handleTerraform("install", cfg)
			cfg.Target = oldTarget
		}
		generateBrowserYaml(cfg)
	}

	runCommand("helm", []string{"repo", "add", "newrelic", "https://helm-charts.newrelic.com"}, nil)
	runCommand("helm", []string{"repo", "add", "open-telemetry", "https://open-telemetry.github.io/opentelemetry-helm-charts"}, nil)
	runCommand("helm", []string{"repo", "update", "newrelic", "open-telemetry"}, nil)

	detectOpenShift()
	exec.Command("kubectl", "create", "ns", ns).Run()
	applyLicenseSecret(ns, cfg.LicenseKey)

	if cfg.EnableNrdot == nil || *cfg.EnableNrdot {
		installChart("nr-k8s", []string{Paths["nr-k8s-values"]}, "global.region="+strings.ToLower(cfg.Region))
	}

	if cfg.EnableNriBundle != nil && *cfg.EnableNriBundle {
		nriNS := Charts["nri-bundle"].NS
		exec.Command("kubectl", "create", "ns", nriNS).Run()
		applyLicenseSecret(nriNS, cfg.LicenseKey)
		installChart("nri-bundle", []string{Paths["nri-bundle-values"]}, "global.region="+strings.ToLower(cfg.Region))
	}

	if cfg.EnablePcg != nil && *cfg.EnablePcg {
		pcgNS := Charts["pcg"].NS
		exec.Command("kubectl", "create", "ns", pcgNS).Run()
		applyLicenseSecret(pcgNS, cfg.LicenseKey)

		fleetId := cfg.PcgFleetName
		if fleetId == "" {
			fleetId = "otel-demo-fleet"
		}
		orgId := cfg.OrganizationId
		if orgId == "" {
			orgId = cfg.AccountId
		}

		if cfg.ClientId != "" && cfg.ClientSecret != "" && orgId != "" {
			fmt.Println("\n>>> Installing Agent Control Deployment (with System Identity credentials)...")
			installChart("agent-control", []string{Paths["agent-control-values"]},
				"global.region="+strings.ToLower(cfg.Region),
				"systemIdentity.organizationId="+orgId,
				"systemIdentity.parentIdentity.clientId="+cfg.ClientId,
				"systemIdentity.parentIdentity.clientSecret="+cfg.ClientSecret,
				"config.fleet_control.fleet_id="+fleetId,
				"config.cdEnabled=false",
				"subAgentsNamespace="+pcgNS,
			)

			fmt.Println("\n>>> Waiting up to 30s for Agent Control to create pipeline-control-gateway-custom-config ConfigMap...")
			found := false
			for waited := 0; waited < 30; waited += 3 {
				cmd := exec.Command("kubectl", "get", "configmap", "pipeline-control-gateway-custom-config", "-n", pcgNS)
				if err := cmd.Run(); err == nil {
					fmt.Printf("Found pipeline-control-gateway-custom-config ConfigMap in namespace %s.\n", pcgNS)
					found = true
					break
				}
				time.Sleep(3 * time.Second)
			}

			if found {
				fmt.Printf("\n>>> Deploying PCG with custom ConfigMap from Agent Control (Fleet: %s)...\n", fleetId)
				installChart("pcg", []string{Paths["pcg-values"]},
					"global.region="+strings.ToLower(cfg.Region),
					"fleet_id="+fleetId,
					"deployment.customConfigMap=pipeline-control-gateway-custom-config",
				)
			} else {
				fmt.Println("\n>>> Warning: pipeline-control-gateway-custom-config was not created within 30s.")
				fmt.Println(">>> Deploying PCG with in-cluster configuration rules as fallback...")
				installChart("pcg", []string{Paths["pcg-values"]},
					"global.region="+strings.ToLower(cfg.Region),
					"fleet_id="+fleetId,
				)
			}
		} else {
			fmt.Println("\n>>> Note: NEW_RELIC_CLIENT_ID / NEW_RELIC_CLIENT_SECRET not provided. Skipping Agent Control fleet daemon (PCG will run with in-cluster ConfigMap rules).")
			installChart("pcg", []string{Paths["pcg-values"]},
				"global.region="+strings.ToLower(cfg.Region),
				"fleet_id="+fleetId,
			)
		}
	}

	if cfg.EnableOtelDemoApps == nil || *cfg.EnableOtelDemoApps {
		otelValues := []string{Paths["otel-values"]}
		if cfg.EnableBrowser != nil && *cfg.EnableBrowser {
			otelValues = append(otelValues, Paths["otel-browser-values"])
		}
		otelSets := []string{}
		switch cfg.OtelDemoDest {
		case "pcg":
			otelValues = append(otelValues, Paths["otel-pcg-values"])
		case "nrdot":
			// Uses standard base values which route to NRDOT gateway
		case "otel-collector", "saas":
			otelValues = append(otelValues, Paths["otel-nri-values"])
			otelSets = append(otelSets, "opentelemetry-collector.config.exporters.otlphttp/newrelic.endpoint="+otlpEndpoint(cfg))
		default:
			if cfg.RouteDemoToPcg != nil && *cfg.RouteDemoToPcg {
				otelValues = append(otelValues, Paths["otel-pcg-values"])
			} else if (cfg.EnableNrdot != nil && !*cfg.EnableNrdot) && (cfg.EnableDemoOtelCollector != nil && *cfg.EnableDemoOtelCollector) {
				otelValues = append(otelValues, Paths["otel-nri-values"])
				otelSets = append(otelSets, "opentelemetry-collector.config.exporters.otlphttp/newrelic.endpoint="+otlpEndpoint(cfg))
			}
		}
		installChart("otel-demo", otelValues, otelSets...)
	} else {
		fmt.Println("\n>>> Skipping OpenTelemetry Demo microservices installation (ENABLE_OTEL_DEMO_APPS=false).")
	}

	if cfg.EnableApmTestApps != nil && *cfg.EnableApmTestApps {
		applyApmTestConfig(ns, cfg)

		if cfg.EnableApmNativeApps != nil && *cfg.EnableApmNativeApps {
			fmt.Printf("\n>>> Deploying New Relic APM Native test workloads (destination: %s)...\n", cfg.ApmNativeDest)
			runCommand("kubectl", []string{"apply", "-f", Paths["apm-test-apps"], "-l", "app.kubernetes.io/component=native-apm"}, nil)
		}

		if cfg.EnableApmHybridApps != nil && *cfg.EnableApmHybridApps {
			fmt.Printf("\n>>> Deploying New Relic APM Hybrid test workloads (destination: %s)...\n", cfg.ApmHybridDest)
			runCommand("kubectl", []string{"apply", "-f", Paths["apm-test-apps"], "-l", "app.kubernetes.io/component=hybrid-apm"}, nil)
		}
	}
}

// applyApmTestConfig creates or updates the apm-test-config ConfigMap with the chosen endpoints
func applyApmTestConfig(namespace string, cfg *Config) {
	defaultNrHost := "collector.newrelic.com"
	defaultNrPort := "443"
	defaultNrSSL := "true"
	defaultOtlpEndpoint := otlpEndpoint(cfg)
	defaultOtlpProtocol := "http/protobuf"

	switch strings.ToLower(cfg.Region) {
	case "eu":
		defaultNrHost = "collector.eu01.nr-data.net"
	case "jp":
		defaultNrHost = "collector.jp01.nr-data.net"
	}

	nativeNrHost := defaultNrHost
	nativeNrPort := defaultNrPort
	nativeNrSSL := defaultNrSSL

	if cfg.ApmNativeDest == "pcg" {
		nativeNrHost = "pipeline-control-gateway.newrelic.svc.cluster.local"
		nativeNrPort = "80"
		nativeNrSSL = "false"
	}

	hybridNrHost := defaultNrHost
	hybridNrPort := defaultNrPort
	hybridNrSSL := defaultNrSSL
	hybridOtlpEndpoint := defaultOtlpEndpoint
	hybridOtlpProtocol := defaultOtlpProtocol

	if cfg.ApmHybridDest == "pcg" {
		// Hybrid mode uses SaaS for agent registration/entity synthesis (TLS required by agents)
		// and routes OTLP trace spans through PCG port 4318
		hybridNrHost = defaultNrHost
		hybridNrPort = defaultNrPort
		hybridNrSSL = defaultNrSSL
		hybridOtlpEndpoint = "http://pipeline-control-gateway.newrelic.svc.cluster.local:4318"
		hybridOtlpProtocol = "http/protobuf"
	}

	fmt.Printf("\n>>> Applying APM test configuration ConfigMap...\n")
	fmt.Printf("    Native APM: host=%s:%s (ssl=%s)\n", nativeNrHost, nativeNrPort, nativeNrSSL)
	fmt.Printf("    Hybrid APM: host=%s:%s, otlp=%s\n", hybridNrHost, hybridNrPort, hybridOtlpEndpoint)

	createCmd := exec.Command("kubectl", "create", "configmap", "apm-test-config",
		"-n", namespace,
		"--from-literal=NATIVE_NEW_RELIC_HOST="+nativeNrHost,
		"--from-literal=NATIVE_NEW_RELIC_PORT="+nativeNrPort,
		"--from-literal=NATIVE_NEW_RELIC_SSL="+nativeNrSSL,
		"--from-literal=HYBRID_NEW_RELIC_HOST="+hybridNrHost,
		"--from-literal=HYBRID_NEW_RELIC_PORT="+hybridNrPort,
		"--from-literal=HYBRID_NEW_RELIC_SSL="+hybridNrSSL,
		"--from-literal=OTEL_EXPORTER_OTLP_ENDPOINT="+hybridOtlpEndpoint,
		"--from-literal=OTEL_EXPORTER_OTLP_PROTOCOL="+hybridOtlpProtocol,
		"--dry-run=client", "-o", "yaml")
	out, err := createCmd.Output()
	if err != nil {
		fmt.Printf("Error generating ConfigMap manifest: %v\n", err)
		return
	}
	applyCmd := exec.Command("kubectl", "apply", "-f", "-")
	applyCmd.Stdin = bytes.NewReader(out)
	applyCmd.Stdout = os.Stdout
	applyCmd.Stderr = os.Stderr
	if err := applyCmd.Run(); err != nil {
		fmt.Printf("Error applying APM test configmap: %v\n", err)
	}
}

// otlpEndpoint resolves the New Relic OTLP endpoint the demo's own collector
// exports to. One knob for both region selection and routing through a
// Pipeline Control gateway.
func otlpEndpoint(cfg *Config) string {
	if cfg.OtlpEndpoint != "" {
		return cfg.OtlpEndpoint
	}
	switch strings.ToLower(cfg.Region) {
	case "eu":
		return "https://otlp.eu01.nr-data.net:4318"
	case "jp":
		return "https://otlp.jp01.nr-data.net:4318"
	default:
		return "https://otlp.nr-data.net:4318"
	}
}

// installChart executes the helm upgrade --install command for a given chart.
func installChart(key string, values []string, extraSets ...string) {
	c := Charts[key]
	args := []string{"upgrade", "--install", c.Name, c.Repo, "--version", c.Version, "-n", c.NS}
	for _, v := range values {
		args = append(args, "-f", v)
	}
	for _, s := range extraSets {
		args = append(args, "--set", s)
	}

	if isOpenShift {
		if key == "nr-k8s" {
			args = append(args, "--set", "provider=OPEN_SHIFT")
		}
		if key == "otel-demo" {
			args = append(args, "--set", "serviceAccount.create=false", "--set", "serviceAccount.name="+c.NS)
		}
	}
	runCommand("helm", args, nil)
}

// detectOpenShift checks the cluster for OpenShift-specific API versions.
func detectOpenShift() {
	out, err := exec.Command("kubectl", "api-versions").Output()
	isOpenShift = (err == nil && strings.Contains(string(out), "security.openshift.io"))
	if isOpenShift {
		fmt.Println("OpenShift detected.")
	}
}
