package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/Pauca-Technologies/udp-gh/internal/auth"
)

var version = "dev"

const (
	stashPrefix = "UDP_GH_PREV_"
	unsetMarker = "__UDP_GH_UNSET__"
	emptyMarker = "__UDP_GH_EMPTY__"
)

type commonFlags struct {
	cwd     string
	host    string
	repo    string
	remote  string
	realGH  string
	refresh bool
}

type prepareOutput struct {
	Version        int               `json:"version"`
	Repository     string            `json:"repository"`
	Host           string            `json:"host"`
	AuthRoot       string            `json:"authRoot"`
	ExpiresAt      string            `json:"expiresAt"`
	InstallationID int64             `json:"installationId"`
	Set            map[string]string `json:"set"`
	Unset          []string          `json:"unset"`
}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout, os.Stderr); err != nil {
		var statusError exitStatusError
		if errors.As(err, &statusError) {
			os.Exit(statusError.status)
		}
		fmt.Fprintf(os.Stderr, "udp-gh: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		printUsage(stderr)
		return flag.ErrHelp
	}
	switch args[0] {
	case "prepare":
		return runPrepare(ctx, args[1:], stdout, stderr)
	case "check":
		return runCheck(ctx, args[1:], stdout, stderr)
	case "on":
		return runOn(ctx, args[1:], stdout, stderr)
	case "off":
		return runOff(args[1:], stdout, stderr)
	case "gh":
		return runGH(ctx, args[1:], stdout, stderr)
	case "version", "--version", "-version":
		fmt.Fprintf(stdout, "udp-gh %s\n", version)
		return nil
	case "help", "--help", "-h":
		printUsage(stdout)
		return nil
	default:
		printUsage(stderr)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func runPrepare(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	flags, err := parseCommonFlags("prepare", args, stderr)
	if err != nil {
		return err
	}
	session, err := auth.Prepare(ctx, options(flags))
	if err != nil {
		return err
	}
	output := prepareOutput{
		Version:        1,
		Repository:     session.Repository,
		Host:           session.Host,
		AuthRoot:       session.AuthRoot,
		ExpiresAt:      session.ExpiresAt.UTC().Format(time.RFC3339),
		InstallationID: session.InstallationID,
		Set:            session.Set,
		Unset:          session.Unset,
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(output)
}

func runCheck(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	flags, err := parseCommonFlags("check", args, stderr)
	if err != nil {
		return err
	}
	session, err := auth.Prepare(ctx, options(flags))
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "GitHub App authentication ready for %s until %s\n", session.Repository, session.ExpiresAt.UTC().Format(time.RFC3339))
	return nil
}

func runOn(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	flags, err := parseCommonFlags("on", args, stderr)
	if err != nil {
		return err
	}
	session, err := auth.Prepare(ctx, options(flags))
	if err != nil {
		return err
	}
	current := auth.Environment()
	set := session.Set
	unset := make(map[string]bool, len(session.Unset))
	for _, name := range session.Unset {
		unset[name] = true
	}
	for _, name := range auth.ManagedKeys() {
		stash := stashPrefix + name
		value, alreadyStashed := current[stash]
		if !alreadyStashed {
			original, present := current[name]
			switch {
			case !present:
				value = unsetMarker
			case original == "":
				value = emptyMarker
			default:
				value = original
			}
		}
		fmt.Fprintf(stdout, "export %s=%s\n", stash, shellQuote(value))
		if value, ok := set[name]; ok {
			fmt.Fprintf(stdout, "export %s=%s\n", name, shellQuote(value))
		} else if unset[name] || !ok {
			fmt.Fprintf(stdout, "unset %s\n", name)
		}
	}
	return nil
}

func runOff(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("off", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("off does not accept positional arguments")
	}
	for _, name := range auth.ManagedKeys() {
		stash := stashPrefix + name
		fmt.Fprintf(stdout,
			"if [ \"${%s+x}\" = x ]; then case \"${%s}\" in %s) unset %s ;; %s) export %s=\"\" ;; *) export %s=\"${%s}\" ;; esac; unset %s; fi\n",
			stash, stash, unsetMarker, name, emptyMarker, name, name, stash, stash,
		)
	}
	return nil
}

func runGH(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("gh requires GitHub CLI arguments")
	}
	opts := options(commonFlags{})
	token, err := auth.ResolveToken(ctx, opts)
	if err != nil {
		return err
	}
	realGH, err := auth.FindRealGH(opts)
	if err != nil {
		return err
	}
	status, combined, err := executeGH(realGH, args, token.Value, token.Host, stdout, stderr)
	if err != nil {
		return err
	}
	if status != 0 && authenticationFailure(combined) {
		fmt.Fprintln(stderr, "udp-gh: GitHub rejected the cached token; refreshing once")
		opts.ForceRefresh = true
		refreshed, refreshErr := auth.ResolveToken(ctx, opts)
		if refreshErr != nil {
			return refreshErr
		}
		status, _, err = executeGH(realGH, args, refreshed.Value, refreshed.Host, stdout, stderr)
		if err != nil {
			return err
		}
	}
	if status != 0 {
		return exitStatusError{status: status}
	}
	return nil
}

type exitStatusError struct {
	status int
}

func (err exitStatusError) Error() string {
	return fmt.Sprintf("gh exited with status %d", err.status)
}

func executeGH(path string, args []string, token, host string, stdout, stderr io.Writer) (int, string, error) {
	command := exec.Command(path, args...)
	command.Stdin = os.Stdin
	var captured bytes.Buffer
	command.Stdout = io.MultiWriter(stdout, &captured)
	command.Stderr = io.MultiWriter(stderr, &captured)
	overrides := map[string]string{}
	if host == "github.com" {
		overrides["GH_TOKEN"] = token
		overrides["GITHUB_TOKEN"] = token
	} else {
		overrides["GH_ENTERPRISE_TOKEN"] = token
		overrides["GITHUB_ENTERPRISE_TOKEN"] = token
	}
	command.Env = mergedEnvironment(
		overrides,
		[]string{"GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"},
	)
	err := command.Run()
	if err == nil {
		return 0, captured.String(), nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), captured.String(), nil
	}
	return 0, captured.String(), err
}

func parseCommonFlags(name string, args []string, stderr io.Writer) (commonFlags, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	var parsed commonFlags
	flags.StringVar(&parsed.cwd, "cwd", "", "Git repository or subdirectory")
	flags.StringVar(&parsed.host, "host", "", "GitHub hostname")
	flags.StringVar(&parsed.repo, "repo", "", "owner/repository override")
	flags.StringVar(&parsed.remote, "remote", "origin", "Git remote used for repository discovery")
	flags.StringVar(&parsed.realGH, "real-gh", "", "real GitHub CLI executable")
	flags.BoolVar(&parsed.refresh, "force-refresh", false, "ignore a cached installation token")
	if err := flags.Parse(args); err != nil {
		return commonFlags{}, err
	}
	if flags.NArg() != 0 {
		return commonFlags{}, fmt.Errorf("unexpected %s argument(s): %s", name, strings.Join(flags.Args(), " "))
	}
	return parsed, nil
}

func options(flags commonFlags) auth.Options {
	return auth.Options{
		Cwd:          flags.cwd,
		Host:         flags.host,
		Repo:         flags.repo,
		Remote:       flags.remote,
		RealGH:       flags.realGH,
		Env:          auth.Environment(),
		ForceRefresh: flags.refresh,
	}
}

func mergedEnvironment(overrides map[string]string, unset []string) []string {
	env := auth.Environment()
	for _, name := range unset {
		delete(env, name)
	}
	for name, value := range overrides {
		env[name] = value
	}
	names := make([]string, 0, len(env))
	for name := range env {
		names = append(names, name)
	}
	sort.Strings(names)
	result := make([]string, 0, len(names))
	for _, name := range names {
		result = append(result, name+"="+env[name])
	}
	return result
}

func authenticationFailure(output string) bool {
	normalized := strings.ToLower(output)
	for _, marker := range []string{"bad credentials", "http 401", "requires authentication", "token has expired", "authentication failed"} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, `Usage:
  udp-gh prepare [--cwd PATH] [--repo OWNER/REPO]
  udp-gh check [--cwd PATH] [--repo OWNER/REPO]
  udp-gh on [--cwd PATH] [--repo OWNER/REPO]
  udp-gh off
  udp-gh gh <gh arguments...>
  udp-gh version`)
}
