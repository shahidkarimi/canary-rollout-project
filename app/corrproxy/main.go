// corrproxy is a tiny correlation-ID front for podinfo. It runs as the
// container's entrypoint, starts podinfo on an internal port, and reverse-
// proxies the public port to it. For every request it ensures an
// X-Request-Id (propagating an inbound one, else minting one), echoes it on
// the response, and emits a structured access-log line — identical behaviour
// whether the container runs on EC2/Docker or on Lambda (where the Web
// Adapter forwards API GW events to this same public port). That makes the
// correlation ID uniform and end-to-end across both targets.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

const requestIDHeader = "X-Request-Id"

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func main() {
	log.SetFlags(0)
	listenPort := getenv("PORT", "9898")        // public port (ALB target / LWA)
	upstreamPort := getenv("PODINFO_PORT", "8080") // podinfo internal port
	env := getenv("ENVIRONMENT", "unknown")
	color := getenv("COLOR", "none")

	// Start podinfo as a child process on the internal port.
	cmd := exec.Command("/home/app/podinfo", "--port="+upstreamPort)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Fatalf(`{"proxy":"corrproxy","fatal":"cannot start podinfo: %v"}`, err)
	}

	// Forward termination signals to podinfo; when podinfo exits, so do we.
	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		s := <-sigc
		_ = cmd.Process.Signal(s)
	}()
	go func() {
		_ = cmd.Wait()
		os.Exit(0) // if podinfo dies, the container should too
	}()

	target, _ := url.Parse("http://127.0.0.1:" + upstreamPort)
	proxy := httputil.NewSingleHostReverseProxy(target)

	// Echo the correlation id back on the response.
	proxy.ModifyResponse = func(resp *http.Response) error {
		if id := resp.Request.Header.Get(requestIDHeader); id != "" {
			resp.Header.Set(requestIDHeader, id)
		}
		return nil
	}
	// During podinfo startup the upstream refuses connections; return 503 so
	// health checks simply retry instead of the proxy logging a hard error.
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(requestIDHeader)
		if id == "" {
			// Fall back to an AWS-provided id if present, else mint one.
			if t := r.Header.Get("X-Amzn-Trace-Id"); t != "" {
				id = t
			} else {
				id = newID()
			}
		}
		r.Header.Set(requestIDHeader, id)
		w.Header().Set(requestIDHeader, id)

		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		proxy.ServeHTTP(rec, r)

		entry, _ := json.Marshal(map[string]any{
			"log":            "access",
			"correlation_id": id,
			"method":         r.Method,
			"path":           r.URL.Path,
			"status":         rec.status,
			"duration_ms":    time.Since(start).Milliseconds(),
			"env":            env,
			"color":          color,
		})
		log.Println(string(entry))
	})

	srv := &http.Server{
		Addr:              ":" + listenPort,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf(`{"proxy":"corrproxy","msg":"listening","port":%s,"upstream":%q}`,
		strconv.Quote(listenPort), target.String())

	// Serve until podinfo exits (the cmd.Wait goroutine calls os.Exit) or a
	// signal is forwarded and podinfo terminates.
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf(`{"proxy":"corrproxy","fatal":%q}`, err.Error())
	}
}
