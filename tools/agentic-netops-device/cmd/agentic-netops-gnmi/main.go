// agentic-netops-gnmi is the Agentic NetOps SONiC device gNMI server: it bridges the
// SONiC redis CONFIG_DB/STATE_DB to gNMI (Capabilities/Get/Set/Subscribe)
// with mTLS + username/password authentication and JSON_IETF encoding.
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/mairp/agentic-netops-device/internal/gnmi"
)

func main() {
	cfg := gnmi.Config{
		Addr:      envOr("GNMI_ADDR", "0.0.0.0:8080"),
		RedisAddr: envOr("REDIS_ADDR", "127.0.0.1:6379"),
		CertDir:   envOr("GNMI_CERT_DIR", "/etc/sonic/telemetry"),
		User:      envOr("GNMI_USER", "admin"),
		Pass:      envOr("GNMI_PASS", "admin"),
		ConfigDB:  envIntOr("CONFIG_DB_ID", 4),
		StateDB:   envIntOr("STATE_DB_ID", 6),
	}
	// Run plaintext when no certs are installed yet (bootstrap installs them).
	if _, err := os.Stat(cfg.CertDir + "/gnmi.crt"); err != nil {
		cfg.CertDir = ""
		log.Printf("agentic-netops-gnmi: no certs in %s; serving without mTLS until bootstrap installs them", cfg.CertDir)
	}
	srv, err := gnmi.New(cfg)
	if err != nil {
		log.Fatalf("agentic-netops-gnmi: %v", err)
	}
	log.Printf("agentic-netops-gnmi: listening on %s (redis=%s)", cfg.Addr, cfg.RedisAddr)
	if err := srv.Serve(); err != nil {
		log.Fatalf("agentic-netops-gnmi: serve: %v", err)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envIntOr(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return def
}
