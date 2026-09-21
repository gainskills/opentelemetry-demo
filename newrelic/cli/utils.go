package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func runCommand(name string, args []string, env []string) error {
	fmt.Printf("\x1b[?2004l")
	defer fmt.Printf("\x1b[?2004h")

	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if env != nil {
		cmd.Env = env
	}
	if err := cmd.Run(); err != nil {
		fmt.Printf("Error running %s: %v\n", name, err)
		return err
	}
	return nil
}

func checkTools(tools ...string) {
	for _, t := range tools {
		if _, err := exec.LookPath(t); err != nil {
			fmt.Printf("Error: %s is not installed.\n", t)
			os.Exit(1)
		}
	}
}

func promptUser(label string, validator func(string) error) string {
	fmt.Printf("\x1b[?2004l")
	defer fmt.Printf("\x1b[?2004h")
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Printf("%s: ", label)
		rawInput, err := reader.ReadString('\n')
		if err != nil {
			fmt.Fprintf(os.Stderr, "\nError: unexpected end of input while prompting for %s\n", label)
			os.Exit(1)
		}
		cleanedInput := strings.TrimSpace(rawInput)
		if validator != nil {
			if err := validator(cleanedInput); err != nil {
				fmt.Printf("Invalid input: %v. Please try again.\n", err)
				continue
			}
		}
		if cleanedInput != "" {
			return cleanedInput
		}
	}
}

func promptUserWithDefault(label, defaultVal string) string {
	fmt.Printf("\x1b[?2004l")
	defer fmt.Printf("\x1b[?2004h")
	reader := bufio.NewReader(os.Stdin)
	fmt.Printf("%s (default: %s): ", label, defaultVal)
	rawInput, err := reader.ReadString('\n')
	if err != nil {
		return defaultVal
	}
	cleaned := strings.TrimSpace(rawInput)
	if cleaned == "" {
		return defaultVal
	}
	return cleaned
}

func promptUserOptional(label string) string {
	fmt.Printf("\x1b[?2004l")
	defer fmt.Printf("\x1b[?2004h")
	reader := bufio.NewReader(os.Stdin)
	fmt.Printf("%s: ", label)
	rawInput, err := reader.ReadString('\n')
	if err != nil {
		return ""
	}
	return strings.TrimSpace(rawInput)
}

func promptBool(label string) bool {
	return promptBoolWithDefault(label, false)
}

func promptBoolWithDefault(label string, defaultVal bool) bool {
	reader := bufio.NewReader(os.Stdin)
	prompt := "[y/N]"
	if defaultVal {
		prompt = "[Y/n]"
	}
	for {
		fmt.Printf("%s %s: ", label, prompt)
		text, err := reader.ReadString('\n')
		if err != nil {
			fmt.Println()
			return defaultVal
		}
		text = strings.TrimSpace(strings.ToLower(text))
		if text == "" {
			return defaultVal
		}
		if text == "y" || text == "yes" {
			return true
		}
		if text == "n" || text == "no" {
			return false
		}
	}
}

type ChoiceOption struct {
	Key  string
	Desc string
}

func promptChoice(title string, defaultIdx int, options []ChoiceOption) string {
	fmt.Printf("\x1b[?2004l")
	defer fmt.Printf("\x1b[?2004h")
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Println(title)
		for i, opt := range options {
			idx := i + 1
			if idx == defaultIdx {
				fmt.Printf("  [%d] %s (default)\n", idx, opt.Desc)
			} else {
				fmt.Printf("  [%d] %s\n", idx, opt.Desc)
			}
		}
		fmt.Printf("Enter choice [1-%d] (default: %d): ", len(options), defaultIdx)
		text, err := reader.ReadString('\n')
		if err != nil {
			fmt.Println()
			if defaultIdx >= 1 && defaultIdx <= len(options) {
				return options[defaultIdx-1].Key
			}
			return ""
		}
		text = strings.TrimSpace(text)
		if text == "" {
			if defaultIdx >= 1 && defaultIdx <= len(options) {
				return options[defaultIdx-1].Key
			}
		}
		var num int
		if _, err := fmt.Sscanf(text, "%d", &num); err == nil && num >= 1 && num <= len(options) {
			return options[num-1].Key
		}
		for _, opt := range options {
			if strings.EqualFold(text, opt.Key) {
				return opt.Key
			}
		}
		fmt.Printf("Invalid choice '%s'. Please select 1-%d.\n", text, len(options))
	}
}

func getEnvOrDefault(key, def string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return def
}

// overrideEnv returns a copy of the process environment with the given
// key/value overrides applied. It's not enough to just append "KEY=value" to
// os.Environ(): exec.Cmd.Env passes duplicate keys straight through to the
// OS, and most getenv() implementations (including Terraform's and
// docker's) return the FIRST match, not the last. Appending a duplicate
// therefore silently loses to whatever os.Environ() already had for that
// key. Empty override values are skipped, leaving any existing value (or
// none) in place.
func overrideEnv(overrides map[string]string) []string {
	env := make([]string, 0, len(os.Environ())+len(overrides))
	for _, kv := range os.Environ() {
		key := strings.SplitN(kv, "=", 2)[0]
		if _, ok := overrides[key]; ok {
			continue
		}
		env = append(env, kv)
	}
	for k, v := range overrides {
		if v != "" {
			env = append(env, k+"="+v)
		}
	}
	return env
}

func validateLicenseKey(val string) error {
	if len(val) != 40 || !strings.HasSuffix(val, "NRAL") {
		return fmt.Errorf("must be 40 chars and end with 'NRAL'")
	}
	return nil
}

func validateUserApiKey(val string) error {
	if !strings.HasPrefix(val, "NRAK-") || len(val) != 32 {
		return fmt.Errorf("must start with 'NRAK-' and be 32 chars")
	}
	return nil
}

func validateNotEmpty(val string) error {
	if strings.TrimSpace(val) == "" {
		return fmt.Errorf("value is required")
	}
	return nil
}

func saveConfigToEnv(cfg *Config) {
	accountIDForTF := cfg.SubAccountId
	if accountIDForTF == "" {
		accountIDForTF = cfg.AccountId
	}

	envMap := map[string]string{
		"NEW_RELIC_LICENSE_KEY":             cfg.LicenseKey,
		"NEW_RELIC_API_KEY":                 cfg.ApiKey,
		"NEW_RELIC_ACCOUNT_ID":              cfg.AccountId,
		"NEW_RELIC_REGION":                  cfg.Region,
		"TF_VAR_newrelic_api_key":           cfg.ApiKey,
		"TF_VAR_newrelic_account_id":        accountIDForTF,
		"TF_VAR_newrelic_parent_account_id": cfg.ParentAccountId,
		"TF_VAR_subaccount_name":            cfg.SubaccountName,
		"TF_VAR_admin_group_name":           cfg.AdminGroupName,
		"TF_VAR_readonly_user_email":        cfg.ReadonlyUserEmail,
		"TF_VAR_readonly_user_name":         cfg.ReadonlyUserName,
		"BROWSER_LICENSE_KEY":               cfg.BrowserLicenseKey,
		"BROWSER_APPLICATION_ID":            cfg.BrowserAppID,
		"BROWSER_ACCOUNT_ID":                cfg.BrowserAccountID,
		"BROWSER_TRUST_KEY":                 cfg.BrowserTrustKey,
		"BROWSER_AGENT_ID":                  cfg.BrowserAgentID,
		"NEW_RELIC_CLIENT_ID":               cfg.ClientId,
		"NEW_RELIC_CLIENT_SECRET":           cfg.ClientSecret,
		"NEW_RELIC_ORGANIZATION_ID":         cfg.OrganizationId,
		"NEW_RELIC_GATEWAY_FLEET":           cfg.PcgFleetName,
	}

	var lines []string
	for k, v := range envMap {
		if v != "" {
			lines = append(lines, fmt.Sprintf("%s=%s", k, v))
		}
	}

	os.WriteFile(".env", []byte(strings.Join(lines, "\n")+"\n"), 0644)
	fmt.Println("\n>>> Configuration updated in .env")
}
