// secret-fp is a minimal Lambda external extension that proves live secret
// consumption without ever exposing the value: it fetches the Secrets Manager
// secret at init and every refreshInterval, and logs a SHA-256 fingerprint
// plus the secret VersionId. After a rotation, function logs show the new
// fingerprint while the alias keeps serving traffic.
//
// Outside Lambda (EC2/Docker) nothing executes /opt/extensions, so this
// binary is inert dead weight (~6 MB) and the image digest stays identical
// across both targets.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

const refreshInterval = 60 * time.Second

func main() {
	log.SetFlags(0)
	api := os.Getenv("AWS_LAMBDA_RUNTIME_API")
	if api == "" {
		return // not running in Lambda
	}
	base := "http://" + api + "/2020-01-01/extension"

	extensionID, err := register(base)
	if err != nil {
		// Failing to register would break the function's event loop, so log
		// and exit instead of crash-looping the environment.
		log.Printf(`{"extension":"secret-fp","error":%q}`, err.Error())
		return
	}

	go refreshLoop()

	// Event loop: Lambda requires registered extensions to poll for events.
	for {
		req, _ := http.NewRequest(http.MethodGet, base+"/event/next", nil)
		req.Header.Set("Lambda-Extension-Identifier", extensionID)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Printf(`{"extension":"secret-fp","error":%q}`, err.Error())
			time.Sleep(time.Second)
			continue
		}
		var event struct {
			EventType string `json:"eventType"`
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		_ = json.Unmarshal(body, &event)
		if event.EventType == "SHUTDOWN" {
			return
		}
	}
}

func register(base string) (string, error) {
	name := filepath.Base(os.Args[0]) // must match the filename in /opt/extensions
	payload := []byte(`{"events":["INVOKE","SHUTDOWN"]}`)
	req, err := http.NewRequest(http.MethodPost, base+"/register", newReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Lambda-Extension-Name", name)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("register: %s: %s", resp.Status, string(b))
	}
	return resp.Header.Get("Lambda-Extension-Identifier"), nil
}

func refreshLoop() {
	arn := os.Getenv("SECRET_ARN")
	if arn == "" {
		log.Print(`{"extension":"secret-fp","warn":"SECRET_ARN not set"}`)
		return
	}
	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Printf(`{"extension":"secret-fp","error":%q}`, err.Error())
		return
	}
	client := secretsmanager.NewFromConfig(cfg)

	fetch := func() {
		out, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: &arn})
		if err != nil {
			log.Printf(`{"extension":"secret-fp","error":%q}`, err.Error())
			return
		}
		sum := sha256.Sum256([]byte(*out.SecretString))
		log.Printf(`{"extension":"secret-fp","msg":"secret loaded","fingerprint":%q,"version_id":%q}`,
			hex.EncodeToString(sum[:])[:16], *out.VersionId)
	}

	fetch()
	for range time.Tick(refreshInterval) {
		fetch()
	}
}

type reader struct{ b []byte }

func newReader(b []byte) io.Reader { return &reader{b} }
func (r *reader) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}
