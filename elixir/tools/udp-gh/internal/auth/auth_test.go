package auth

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseRepository(t *testing.T) {
	t.Parallel()

	for _, remote := range []string{
		"git@github.com:Acme/widgets.git",
		"https://github.com/Acme/widgets.git",
		"ssh://git@github.com/Acme/widgets.git",
	} {
		repository, err := ParseRepository(remote, "github.com")
		if err != nil {
			t.Fatalf("ParseRepository(%q) returned %v", remote, err)
		}
		if repository != "Acme/widgets" {
			t.Fatalf("ParseRepository(%q) = %q", remote, repository)
		}
	}

	if _, err := ParseRepository("git@gitlab.com:Acme/widgets.git", "github.com"); err == nil {
		t.Fatal("expected a non-GitHub remote to fail")
	}
}

func TestPrepareCreatesTokenFreeSessionAndReusesCache(t *testing.T) {
	workspace := initializeRepository(t)
	binDir := t.TempDir()
	realGH := filepath.Join(binDir, "gh")
	writeExecutable(t, realGH, "#!/bin/sh\nexit 0\n")
	cliPath := filepath.Join(binDir, "udp-gh")
	writeExecutable(t, cliPath, "#!/bin/sh\nexit 0\n")
	privateKey := testPrivateKey(t)
	now := time.Date(2026, time.August, 12, 18, 0, 0, 0, time.UTC)

	var requestCount atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestCount.Add(1)
		verifyJWT(t, request.Header.Get("Authorization"), privateKey, "12345")
		writer.Header().Set("Content-Type", "application/json")
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/repos/Acme/widgets/installation":
			_, _ = writer.Write([]byte(`{"id":987}`))
		case request.Method == http.MethodPost && request.URL.Path == "/app/installations/987/access_tokens":
			_, _ = writer.Write([]byte(`{"token":"secret-installation-token","expires_at":"2026-08-12T19:00:00Z"}`))
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)

	env := map[string]string{
		"GITHUB_APP_ID":          "12345",
		"GITHUB_APP_PRIVATE_KEY": encodePrivateKey(t, privateKey),
		"PATH":                   binDir,
		"UDP_AGENT_COMMIT_NAME":  "UDP Agent",
		"UDP_AGENT_COMMIT_EMAIL": "udp-agent@example.com",
	}
	opts := Options{
		Cwd:        workspace,
		Env:        env,
		CLIPath:    cliPath,
		RealGH:     realGH,
		Now:        func() time.Time { return now },
		APIBaseURL: server.URL,
	}

	session, err := Prepare(context.Background(), opts)
	if err != nil {
		t.Fatalf("Prepare returned %v", err)
	}
	if session.Repository != "Acme/widgets" || session.InstallationID != 987 {
		t.Fatalf("unexpected session: %#v", session)
	}
	if session.Set["UDP_GH_AUTH"] != "1" || session.Set["UDP_GH_REAL_GH"] != realGH {
		t.Fatalf("missing standalone auth environment: %#v", session.Set)
	}
	if session.Set["GIT_AUTHOR_NAME"] != "UDP Agent" || session.Set["GIT_COMMITTER_EMAIL"] != "udp-agent@example.com" {
		t.Fatalf("missing bot commit identity: %#v", session.Set)
	}
	for _, key := range []string{"GH_TOKEN", "GITHUB_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_ENTERPRISE_TOKEN"} {
		if _, found := session.Set[key]; found {
			t.Fatalf("%s must not be exported", key)
		}
		if !contains(session.Unset, key) {
			t.Fatalf("%s must be explicitly unset", key)
		}
	}

	cachePath := filepath.Join(session.AuthRoot, cacheFilename)
	cacheContents, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cacheContents), "secret-installation-token") {
		t.Fatal("token cache did not contain the minted token")
	}
	assertMode(t, cachePath, 0o600)

	shimPath := filepath.Join(session.AuthRoot, "shims", "gh")
	shimContents, err := os.ReadFile(shimPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(shimContents), "secret-installation-token") || !strings.Contains(string(shimContents), cliPath+"' gh") {
		t.Fatalf("unexpected shim: %s", shimContents)
	}
	assertMode(t, shimPath, 0o700)

	if _, err := os.Stat(filepath.Join(session.AuthRoot, "session.env")); !os.IsNotExist(err) {
		t.Fatal("standalone auth must not create the migration session.env")
	}
	excludePath := gitCommand(t, workspace, "rev-parse", "--git-path", "info/exclude")
	if !filepath.IsAbs(excludePath) {
		excludePath = filepath.Join(workspace, excludePath)
	}
	excludeContents, err := os.ReadFile(excludePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(excludeContents), "/.artifacts/") {
		t.Fatalf("Git exclude was not updated: %s", excludeContents)
	}

	if _, err := Prepare(context.Background(), opts); err != nil {
		t.Fatalf("cached Prepare returned %v", err)
	}
	if requestCount.Load() != 2 {
		t.Fatalf("expected the second prepare to reuse the cache; requests=%d", requestCount.Load())
	}
}

func initializeRepository(t *testing.T) string {
	t.Helper()
	workspace := t.TempDir()
	gitCommand(t, workspace, "init", "--quiet")
	gitCommand(t, workspace, "remote", "add", "origin", "git@github.com:Acme/widgets.git")
	return workspace
}

func gitCommand(t *testing.T, cwd string, args ...string) string {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", cwd}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, output)
	}
	return strings.TrimSpace(string(output))
}

func writeExecutable(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
}

func testPrivateKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func encodePrivateKey(t *testing.T, key *rsa.PrivateKey) string {
	t.Helper()
	return string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
}

func verifyJWT(t *testing.T, authorization string, key *rsa.PrivateKey, appID string) {
	t.Helper()
	token := strings.TrimPrefix(authorization, "Bearer ")
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("invalid JWT authorization header")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	if claims["iss"] != appID {
		t.Fatalf("JWT issuer = %#v", claims["iss"])
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], signature); err != nil {
		t.Fatalf("JWT signature failed verification: %v", err)
	}
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func assertMode(t *testing.T, path string, expected os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != expected {
		t.Fatalf("%s mode = %o, expected %o", path, info.Mode().Perm(), expected)
	}
}
