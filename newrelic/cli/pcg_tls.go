package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ensurePcgTLS provisions the TLS material for PCG's nrproprietaryreceiver;
// see "Pipeline Control Gateway TLS" in newrelic/README.md (incl. rotation).
// Mirrors ensure_pcg_tls in scripts/install-k8s.sh:
//
//	Secret    PcgTLSSecret   (tls.crt, tls.key, ca.crt) in pcgNS
//	ConfigMap PcgCAConfigMap (ca.crt)                   in appsNS
func ensurePcgTLS(pcgNS, appsNS string) {
	if exec.Command("kubectl", "get", "secret", PcgTLSSecret, "-n", pcgNS).Run() == nil {
		fmt.Printf("Reusing existing TLS secret '%s' in namespace %s.\n", PcgTLSSecret, pcgNS)
	} else {
		fmt.Println("\n>>> Generating CA and TLS certificate for PCG...")
		caPEM, certPEM, keyPEM, err := generatePcgCerts(pcgNS)
		if err != nil {
			fmt.Printf("Error generating PCG TLS certificates: %v\n", err)
			os.Exit(1)
		}
		secret := map[string]any{
			"apiVersion": "v1",
			"kind":       "Secret",
			"metadata":   map[string]string{"name": PcgTLSSecret, "namespace": pcgNS},
			"type":       "Opaque",
			"data": map[string]string{
				"tls.crt": base64.StdEncoding.EncodeToString(certPEM),
				"tls.key": base64.StdEncoding.EncodeToString(keyPEM),
				"ca.crt":  base64.StdEncoding.EncodeToString(caPEM),
			},
		}
		if err := kubectlObject("create", secret); err != nil {
			fmt.Printf("Error creating TLS secret '%s': %v\n", PcgTLSSecret, err)
			os.Exit(1)
		}
	}

	fmt.Printf("Publishing PCG CA to ConfigMap '%s' in namespace %s...\n", PcgCAConfigMap, appsNS)
	out, err := exec.Command("kubectl", "get", "secret", PcgTLSSecret, "-n", pcgNS,
		"-o", `jsonpath={.data.ca\.crt}`).Output()
	if err != nil {
		fmt.Printf("Error reading CA from secret '%s': %v\n", PcgTLSSecret, err)
		os.Exit(1)
	}
	caPEM, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil {
		fmt.Printf("Error decoding CA from secret '%s': %v\n", PcgTLSSecret, err)
		os.Exit(1)
	}
	configMap := map[string]any{
		"apiVersion": "v1",
		"kind":       "ConfigMap",
		"metadata":   map[string]string{"name": PcgCAConfigMap, "namespace": appsNS},
		"data":       map[string]string{"ca.crt": string(caPEM)},
	}
	if err := kubectlObject("apply", configMap); err != nil {
		fmt.Printf("Error publishing CA ConfigMap '%s': %v\n", PcgCAConfigMap, err)
		os.Exit(1)
	}
}

// generatePcgCerts returns PEM-encoded CA cert, leaf cert and leaf key (PKCS#8)
// for every DNS form of the PCG Service.
func generatePcgCerts(pcgNS string) (caPEM, certPEM, keyPEM []byte, err error) {
	const svc = "pipeline-control-gateway"
	now := time.Now()

	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, nil, err
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          randomSerial(),
		Subject:               pkix.Name{CommonName: "pcg-demo-ca"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, nil, nil, err
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		return nil, nil, nil, err
	}

	leafKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, nil, err
	}
	fqdn := fmt.Sprintf("%s.%s.svc.cluster.local", svc, pcgNS)
	leafTmpl := &x509.Certificate{
		SerialNumber: randomSerial(),
		Subject:      pkix.Name{CommonName: fqdn},
		DNSNames: []string{
			svc,
			fmt.Sprintf("%s.%s", svc, pcgNS),
			fmt.Sprintf("%s.%s.svc", svc, pcgNS),
			fqdn,
		},
		NotBefore:   now.Add(-time.Hour),
		NotAfter:    now.AddDate(0, 0, 825),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		return nil, nil, nil, err
	}
	leafKeyDER, err := x509.MarshalPKCS8PrivateKey(leafKey)
	if err != nil {
		return nil, nil, nil, err
	}

	caPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: leafKeyDER})
	return caPEM, certPEM, keyPEM, nil
}

func randomSerial() *big.Int {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		panic(err)
	}
	return serial
}

// kubectlObject runs `kubectl <verb> -f -` with the object on stdin so secrets
// never touch disk or process arguments.
func kubectlObject(verb string, obj any) error {
	manifest, err := json.Marshal(obj)
	if err != nil {
		return err
	}
	cmd := exec.Command("kubectl", verb, "-f", "-")
	cmd.Stdin = bytes.NewReader(manifest)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
