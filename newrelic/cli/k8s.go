package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"text/template"
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
		exec.Command("kubectl", "delete",
			"mutatingwebhookconfiguration,validatingwebhookconfiguration,clusterrole,clusterrolebinding",
			"-l", "app.kubernetes.io/instance="+Charts["nri-bundle"].Name, "--ignore-not-found").Run()
		runCommand("kubectl", []string{"delete", "ns", ns, "--ignore-not-found"}, nil)
		if nriNS != ns {
			runCommand("kubectl", []string{"delete", "ns", nriNS, "--ignore-not-found"}, nil)
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

	otelValues := []string{Paths["otel-values"]}
	if cfg.EnableBrowser != nil && *cfg.EnableBrowser {
		otelValues = append(otelValues, Paths["otel-browser-values"])
	}
	otelSets := []string{}
	if (cfg.EnableNrdot != nil && !*cfg.EnableNrdot) && (cfg.EnableDemoOtelCollector != nil && *cfg.EnableDemoOtelCollector) {
		otelValues = append(otelValues, Paths["otel-nri-values"])
		otelSets = append(otelSets, "opentelemetry-collector.config.exporters.otlphttp/newrelic.endpoint="+otlpEndpoint(cfg))
	}
	installChart("otel-demo", otelValues, otelSets...)
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
