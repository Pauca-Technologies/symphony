package auth

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	artifactSubdir   = ".artifacts/udp-gh"
	cacheFilename    = "installation-token.json"
	lockDirname      = "token.lock"
	refreshSkew      = 5 * time.Minute
	lockTimeout      = 15 * time.Second
	lockPollInterval = 150 * time.Millisecond
	staleLockAge     = 60 * time.Second
	githubAPIVersion = "2022-11-28"
)

var scpRemotePattern = regexp.MustCompile(`^git@([^:]+):(.+)$`)

// Options controls repository discovery and GitHub App authentication.
type Options struct {
	Cwd            string
	Host           string
	Repo           string
	Remote         string
	RealGH         string
	CLIPath        string
	Env            map[string]string
	ForceRefresh   bool
	Now            func() time.Time
	HTTPClient     *http.Client
	APIBaseURL     string
	LockTimeout    time.Duration
	RefreshSkew    time.Duration
	SkipGitExclude bool
}

// Session is the token-free environment contract consumed by shells and Symphony.
type Session struct {
	Set            map[string]string
	Unset          []string
	Repository     string
	Host           string
	AuthRoot       string
	ExpiresAt      time.Time
	InstallationID int64
}

// Token is a cached or freshly minted GitHub App installation token.
type Token struct {
	Value          string    `json:"token"`
	ExpiresAt      time.Time `json:"-"`
	Host           string    `json:"host"`
	Repository     string    `json:"repo"`
	InstallationID int64     `json:"installationId"`
}

type tokenCache struct {
	Token          string `json:"token"`
	ExpiresAt      string `json:"expiresAt"`
	Host           string `json:"host"`
	Repository     string `json:"repo"`
	InstallationID int64  `json:"installationId"`
}

type authContext struct {
	workspaceRoot string
	host          string
	repository    string
	appID         string
	privateKey    *rsa.PrivateKey
	installation  int64
	env           map[string]string
	authRoot      string
	ghConfigDir   string
	shimDir       string
	cachePath     string
	lockDir       string
	cliPath       string
	realGH        string
}

// ManagedKeys returns the complete shell environment owned by udp-gh activation.
func ManagedKeys() []string {
	return []string{
		"GH_CONFIG_DIR",
		"GH_ENTERPRISE_TOKEN",
		"GH_HOST",
		"GH_PROMPT_DISABLED",
		"GH_TOKEN",
		"GIT_AUTHOR_EMAIL",
		"GIT_AUTHOR_NAME",
		"GIT_COMMITTER_EMAIL",
		"GIT_COMMITTER_NAME",
		"GITHUB_ENTERPRISE_TOKEN",
		"GITHUB_TOKEN",
		"PATH",
		"UDP_BOT_MODE",
		"UDP_GH_AUTH",
		"UDP_GH_AUTH_ROOT",
		"UDP_GH_REAL_GH",
		"UDP_GH_REPOSITORY",
	}
}

// Prepare preflights authentication and creates the token-free gh shim environment.
func Prepare(ctx context.Context, opts Options) (Session, error) {
	authCtx, err := buildContext(opts)
	if err != nil {
		return Session{}, err
	}
	if err := ensureAuthDirectories(authCtx); err != nil {
		return Session{}, err
	}
	token, err := resolveToken(ctx, authCtx, opts)
	if err != nil {
		return Session{}, err
	}
	if err := writeGHShim(authCtx); err != nil {
		return Session{}, err
	}
	if !opts.SkipGitExclude {
		if err := excludeAuthArtifacts(authCtx.workspaceRoot); err != nil {
			return Session{}, err
		}
	}

	set := sessionEnvironment(authCtx)
	return Session{
		Set:            set,
		Unset:          []string{"GH_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN"},
		Repository:     authCtx.repository,
		Host:           authCtx.host,
		AuthRoot:       authCtx.authRoot,
		ExpiresAt:      token.ExpiresAt,
		InstallationID: token.InstallationID,
	}, nil
}

// ResolveToken returns a valid installation token without preparing shell artifacts.
func ResolveToken(ctx context.Context, opts Options) (Token, error) {
	authCtx, err := buildContext(opts)
	if err != nil {
		return Token{}, err
	}
	if err := ensureAuthDirectories(authCtx); err != nil {
		return Token{}, err
	}
	return resolveToken(ctx, authCtx, opts)
}

// FindRealGH resolves the non-shim GitHub CLI executable.
func FindRealGH(opts Options) (string, error) {
	env := opts.Env
	if env == nil {
		env = currentEnvironment()
	}
	candidates := []string{opts.RealGH, env["UDP_GH_REAL_GH"]}
	for _, candidate := range candidates {
		if executableFile(candidate) {
			absolute, err := filepath.Abs(candidate)
			if err == nil {
				return absolute, nil
			}
		}
	}

	for _, directory := range filepath.SplitList(env["PATH"]) {
		candidate := filepath.Join(directory, executableName("gh"))
		normalized := filepath.ToSlash(candidate)
		if strings.Contains(normalized, "/.artifacts/udp-gh/shims/") ||
			strings.Contains(normalized, "/.artifacts/github-app-auth/shims/") ||
			strings.Contains(normalized, "/scripts/github/shims/") {
			continue
		}
		if executableFile(candidate) {
			absolute, err := filepath.Abs(candidate)
			if err == nil {
				return absolute, nil
			}
		}
	}
	return "", errors.New("GitHub CLI executable not found")
}

func buildContext(opts Options) (*authContext, error) {
	env := opts.Env
	if env == nil {
		env = currentEnvironment()
	}
	cwd := strings.TrimSpace(opts.Cwd)
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("resolve working directory: %w", err)
		}
	}
	host := firstNonBlank(opts.Host, env["GH_HOST"], env["GITHUB_HOST"], "github.com")
	workspaceRoot, err := gitOutput(cwd, "rev-parse", "--show-toplevel")
	if err != nil {
		return nil, fmt.Errorf("resolve Git repository root: %w", err)
	}
	workspaceRoot, err = filepath.Abs(strings.TrimSpace(workspaceRoot))
	if err != nil {
		return nil, fmt.Errorf("normalize Git repository root: %w", err)
	}
	repository, err := resolveRepository(workspaceRoot, host, opts, env)
	if err != nil {
		return nil, err
	}
	appID := strings.TrimSpace(env["GITHUB_APP_ID"])
	if appID == "" {
		return nil, errors.New("missing required credential GITHUB_APP_ID")
	}
	privateKey, err := readPrivateKey(workspaceRoot, env)
	if err != nil {
		return nil, err
	}
	installation, err := optionalPositiveInteger(env["GITHUB_APP_INSTALLATION_ID"])
	if err != nil {
		return nil, err
	}
	cliPath := firstNonBlank(opts.CLIPath, env["UDP_GH_CLI"])
	if cliPath == "" {
		cliPath, err = os.Executable()
		if err != nil {
			return nil, fmt.Errorf("resolve udp-gh executable: %w", err)
		}
	}
	if !executableFile(cliPath) {
		return nil, fmt.Errorf("udp-gh executable is unavailable: %s", cliPath)
	}
	cliPath, err = filepath.Abs(cliPath)
	if err != nil {
		return nil, fmt.Errorf("normalize udp-gh executable: %w", err)
	}
	realGH, err := FindRealGH(Options{Env: env, RealGH: opts.RealGH})
	if err != nil {
		return nil, err
	}
	authRoot := filepath.Join(workspaceRoot, artifactSubdir)
	return &authContext{
		workspaceRoot: workspaceRoot,
		host:          host,
		repository:    repository,
		appID:         appID,
		privateKey:    privateKey,
		installation:  installation,
		env:           env,
		authRoot:      authRoot,
		ghConfigDir:   filepath.Join(authRoot, "gh-config"),
		shimDir:       filepath.Join(authRoot, "shims"),
		cachePath:     filepath.Join(authRoot, cacheFilename),
		lockDir:       filepath.Join(authRoot, lockDirname),
		cliPath:       cliPath,
		realGH:        realGH,
	}, nil
}

func resolveRepository(workspaceRoot, host string, opts Options, env map[string]string) (string, error) {
	for _, candidate := range []string{opts.Repo, env["UDP_GH_REPOSITORY"], env["GITHUB_REPOSITORY"]} {
		if strings.TrimSpace(candidate) != "" {
			return validateRepository(candidate)
		}
	}
	remote := firstNonBlank(opts.Remote, "origin")
	remoteURL, err := gitOutput(workspaceRoot, "remote", "get-url", remote)
	if err != nil {
		return "", fmt.Errorf("resolve GitHub repository from remote %q: %w", remote, err)
	}
	return ParseRepository(strings.TrimSpace(remoteURL), host)
}

// ParseRepository extracts owner/name from supported HTTPS, SSH, and scp-style remotes.
func ParseRepository(remote, host string) (string, error) {
	remote = strings.TrimSpace(remote)
	host = strings.TrimSpace(host)
	if match := scpRemotePattern.FindStringSubmatch(remote); len(match) == 3 {
		if strings.EqualFold(match[1], host) {
			return validateRepository(match[2])
		}
	}
	parsed, err := url.Parse(remote)
	if err == nil && parsed.Hostname() != "" && strings.EqualFold(parsed.Hostname(), host) {
		if parsed.Scheme == "https" || parsed.Scheme == "http" || parsed.Scheme == "ssh" {
			return validateRepository(strings.TrimPrefix(parsed.Path, "/"))
		}
	}
	return "", fmt.Errorf("unsupported GitHub remote for host %s", host)
}

func validateRepository(repository string) (string, error) {
	repository = strings.TrimSpace(strings.TrimSuffix(strings.TrimSuffix(repository, "/"), ".git"))
	parts := strings.Split(repository, "/")
	if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" || strings.TrimSpace(parts[1]) == "" {
		return "", fmt.Errorf("invalid GitHub repository %q", repository)
	}
	return parts[0] + "/" + parts[1], nil
}

func readPrivateKey(workspaceRoot string, env map[string]string) (*rsa.PrivateKey, error) {
	value := strings.TrimSpace(env["GITHUB_APP_PRIVATE_KEY"])
	if value == "" {
		path := strings.TrimSpace(env["GITHUB_APP_PRIVATE_KEY_FILE"])
		if path == "" {
			return nil, errors.New("missing required credential GITHUB_APP_PRIVATE_KEY_FILE or GITHUB_APP_PRIVATE_KEY")
		}
		if !filepath.IsAbs(path) {
			path = filepath.Join(workspaceRoot, path)
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read GitHub App private key %s: %w", path, err)
		}
		value = string(contents)
	}
	value = strings.ReplaceAll(value, `\n`, "\n")
	block, _ := pem.Decode([]byte(value))
	if block == nil {
		return nil, errors.New("GitHub App private key is not valid PEM")
	}
	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("GitHub App private key is not valid RSA PKCS#1 or PKCS#8")
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("GitHub App private key is not RSA")
	}
	return key, nil
}

func optionalPositiveInteger(value string) (int64, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 {
		return 0, errors.New("GITHUB_APP_INSTALLATION_ID must be a positive integer")
	}
	return parsed, nil
}

func ensureAuthDirectories(authCtx *authContext) error {
	for _, path := range []string{authCtx.authRoot, authCtx.ghConfigDir, authCtx.shimDir} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("create auth directory %s: %w", path, err)
		}
		if err := os.Chmod(path, 0o700); err != nil {
			return fmt.Errorf("protect auth directory %s: %w", path, err)
		}
	}
	return nil
}

func resolveToken(ctx context.Context, authCtx *authContext, opts Options) (Token, error) {
	now := currentTime(opts)
	skew := opts.RefreshSkew
	if skew <= 0 {
		skew = refreshSkew
	}
	if !opts.ForceRefresh {
		if token, ok := readCachedToken(authCtx.cachePath, authCtx.host, authCtx.repository, now, skew); ok {
			return token, nil
		}
	}
	return refreshTokenUnderLock(ctx, authCtx, opts)
}

func refreshTokenUnderLock(ctx context.Context, authCtx *authContext, opts Options) (Token, error) {
	timeout := opts.LockTimeout
	if timeout <= 0 {
		timeout = lockTimeout
	}
	if err := acquireLock(ctx, authCtx.lockDir, timeout); err != nil {
		return Token{}, err
	}
	defer os.RemoveAll(authCtx.lockDir)

	if !opts.ForceRefresh {
		skew := opts.RefreshSkew
		if skew <= 0 {
			skew = refreshSkew
		}
		if token, ok := readCachedToken(authCtx.cachePath, authCtx.host, authCtx.repository, currentTime(opts), skew); ok {
			return token, nil
		}
	}
	token, err := mintToken(ctx, authCtx, opts)
	if err != nil {
		return Token{}, err
	}
	if err := writeTokenCache(authCtx.cachePath, token); err != nil {
		return Token{}, err
	}
	return token, nil
}

func acquireLock(ctx context.Context, path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		err := os.Mkdir(path, 0o700)
		if err == nil {
			return nil
		}
		if !errors.Is(err, os.ErrExist) {
			return fmt.Errorf("acquire token lock: %w", err)
		}
		if info, statErr := os.Stat(path); statErr == nil && time.Since(info.ModTime()) > staleLockAge {
			_ = os.RemoveAll(path)
			continue
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for token lock %s", path)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(lockPollInterval):
		}
	}
}

func readCachedToken(path, host, repository string, now time.Time, skew time.Duration) (Token, bool) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return Token{}, false
	}
	var cached tokenCache
	if json.Unmarshal(contents, &cached) != nil {
		return Token{}, false
	}
	expiresAt, err := time.Parse(time.RFC3339, cached.ExpiresAt)
	if err != nil || cached.Token == "" || cached.InstallationID <= 0 || cached.Host != host || cached.Repository != repository {
		return Token{}, false
	}
	if expiresAt.Sub(now) <= skew {
		return Token{}, false
	}
	return Token{
		Value:          cached.Token,
		ExpiresAt:      expiresAt,
		Host:           cached.Host,
		Repository:     cached.Repository,
		InstallationID: cached.InstallationID,
	}, true
}

func mintToken(ctx context.Context, authCtx *authContext, opts Options) (Token, error) {
	jwt, err := createAppJWT(authCtx, currentTime(opts))
	if err != nil {
		return Token{}, err
	}
	installation := authCtx.installation
	if installation == 0 {
		installation, err = resolveInstallationID(ctx, authCtx, jwt, opts)
		if err != nil {
			return Token{}, err
		}
	}
	return requestInstallationToken(ctx, authCtx, jwt, installation, opts)
}

func createAppJWT(authCtx *authContext, now time.Time) (string, error) {
	issuedAt := now.Unix() - 60
	header, err := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	payload, err := json.Marshal(map[string]any{"exp": issuedAt + 9*60, "iat": issuedAt, "iss": authCtx.appID})
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(payload)
	digest := sha256.Sum256([]byte(encoded))
	signature, err := rsa.SignPKCS1v15(rand.Reader, authCtx.privateKey, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign GitHub App JWT: %w", err)
	}
	return encoded + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func resolveInstallationID(ctx context.Context, authCtx *authContext, jwt string, opts Options) (int64, error) {
	parts := strings.Split(authCtx.repository, "/")
	endpoint := apiBaseURL(authCtx, opts) + "/repos/" + url.PathEscape(parts[0]) + "/" + url.PathEscape(parts[1]) + "/installation"
	var response struct {
		ID int64 `json:"id"`
	}
	if err := githubRequest(ctx, opts, http.MethodGet, endpoint, jwt, nil, &response); err != nil {
		return 0, fmt.Errorf("resolve GitHub App installation: %w", err)
	}
	if response.ID <= 0 {
		return 0, errors.New("GitHub installation lookup response did not include an id")
	}
	return response.ID, nil
}

func requestInstallationToken(ctx context.Context, authCtx *authContext, jwt string, installation int64, opts Options) (Token, error) {
	endpoint := fmt.Sprintf("%s/app/installations/%d/access_tokens", apiBaseURL(authCtx, opts), installation)
	var response struct {
		Token     string `json:"token"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := githubRequest(ctx, opts, http.MethodPost, endpoint, jwt, map[string]any{}, &response); err != nil {
		return Token{}, fmt.Errorf("mint GitHub App installation token: %w", err)
	}
	expiresAt, err := time.Parse(time.RFC3339, response.ExpiresAt)
	if err != nil || response.Token == "" {
		return Token{}, errors.New("GitHub installation token response is invalid")
	}
	return Token{
		Value:          response.Token,
		ExpiresAt:      expiresAt,
		Host:           authCtx.host,
		Repository:     authCtx.repository,
		InstallationID: installation,
	}, nil
}

func githubRequest(ctx context.Context, opts Options, method, endpoint, jwt string, body any, destination any) error {
	var encoded io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return err
		}
		encoded = bytes.NewReader(payload)
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint, encoded)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+jwt)
	request.Header.Set("User-Agent", "udp-gh")
	request.Header.Set("X-GitHub-Api-Version", githubAPIVersion)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	contents, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(contents, &failure)
		message := strings.TrimSpace(failure.Message)
		if message == "" {
			message = "GitHub API request failed"
		}
		if len(message) > 500 {
			message = message[:500]
		}
		return fmt.Errorf("GitHub API returned %d: %s", response.StatusCode, message)
	}
	if err := json.Unmarshal(contents, destination); err != nil {
		return fmt.Errorf("decode GitHub API response: %w", err)
	}
	return nil
}

func apiBaseURL(authCtx *authContext, opts Options) string {
	if strings.TrimSpace(opts.APIBaseURL) != "" {
		return strings.TrimRight(opts.APIBaseURL, "/")
	}
	if authCtx.host == "github.com" {
		return "https://api.github.com"
	}
	return "https://" + authCtx.host + "/api/v3"
}

func writeTokenCache(path string, token Token) error {
	cached := tokenCache{
		Token:          token.Value,
		ExpiresAt:      token.ExpiresAt.UTC().Format(time.RFC3339),
		Host:           token.Host,
		Repository:     token.Repository,
		InstallationID: token.InstallationID,
	}
	contents, err := json.MarshalIndent(cached, "", "  ")
	if err != nil {
		return err
	}
	contents = append(contents, '\n')
	return writePrivateFile(path, contents, 0o600)
}

func sessionEnvironment(authCtx *authContext) map[string]string {
	set := map[string]string{
		"GH_CONFIG_DIR":      authCtx.ghConfigDir,
		"GH_HOST":            authCtx.host,
		"GH_PROMPT_DISABLED": "1",
		"PATH":               authCtx.shimDir + string(os.PathListSeparator) + authCtx.env["PATH"],
		"UDP_BOT_MODE":       "1",
		"UDP_GH_AUTH":        "1",
		"UDP_GH_AUTH_ROOT":   authCtx.authRoot,
		"UDP_GH_REAL_GH":     authCtx.realGH,
		"UDP_GH_REPOSITORY":  authCtx.repository,
	}
	name := strings.TrimSpace(authCtx.env["UDP_AGENT_COMMIT_NAME"])
	email := strings.TrimSpace(authCtx.env["UDP_AGENT_COMMIT_EMAIL"])
	if name != "" && email != "" {
		set["GIT_AUTHOR_NAME"] = name
		set["GIT_AUTHOR_EMAIL"] = email
		set["GIT_COMMITTER_NAME"] = name
		set["GIT_COMMITTER_EMAIL"] = email
	}
	return set
}

func writeGHShim(authCtx *authContext) error {
	path := filepath.Join(authCtx.shimDir, executableName("gh"))
	var body string
	if runtime.GOOS == "windows" {
		body = "@echo off\r\n\"" + strings.ReplaceAll(authCtx.cliPath, "\"", "\"\"") + "\" gh %*\r\n"
	} else {
		body = "#!/bin/sh\nexec " + shellQuote(authCtx.cliPath) + " gh \"$@\"\n"
	}
	return writePrivateFile(path, []byte(body), 0o700)
}

func writePrivateFile(path string, contents []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".udp-gh-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(contents); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}

func excludeAuthArtifacts(workspaceRoot string) error {
	path, err := gitOutput(workspaceRoot, "rev-parse", "--git-path", "info/exclude")
	if err != nil {
		return nil
	}
	path = strings.TrimSpace(path)
	if !filepath.IsAbs(path) {
		path = filepath.Join(workspaceRoot, path)
	}
	contents, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read Git exclude file: %w", err)
	}
	for _, line := range strings.Split(string(contents), "\n") {
		if strings.TrimSpace(line) == "/.artifacts/" {
			return nil
		}
	}
	separator := ""
	if len(contents) > 0 && !bytes.HasSuffix(contents, []byte("\n")) {
		separator = "\n"
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open Git exclude file: %w", err)
	}
	defer file.Close()
	if _, err := file.WriteString(separator + "/.artifacts/\n"); err != nil {
		return fmt.Errorf("update Git exclude file: %w", err)
	}
	return nil
}

func gitOutput(cwd string, args ...string) (string, error) {
	command := exec.Command("git", append([]string{"-C", cwd}, args...)...)
	output, err := command.CombinedOutput()
	if err != nil {
		message := strings.TrimSpace(string(output))
		if message == "" {
			message = err.Error()
		}
		return "", errors.New(message)
	}
	return string(output), nil
}

func currentEnvironment() map[string]string {
	env := make(map[string]string)
	for _, entry := range os.Environ() {
		name, value, ok := strings.Cut(entry, "=")
		if ok {
			env[name] = value
		}
	}
	return env
}

// Environment returns a copy of the current process environment.
func Environment() map[string]string {
	current := currentEnvironment()
	copy := make(map[string]string, len(current))
	for name, value := range current {
		copy[name] = value
	}
	return copy
}

func currentTime(opts Options) time.Time {
	if opts.Now != nil {
		return opts.Now().UTC().Truncate(time.Second)
	}
	return time.Now().UTC().Truncate(time.Second)
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func executableFile(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

func executableName(name string) string {
	if runtime.GOOS == "windows" {
		return name + ".exe"
	}
	return name
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
