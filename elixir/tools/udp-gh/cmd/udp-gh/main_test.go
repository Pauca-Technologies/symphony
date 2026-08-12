package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestPrepareOutputKeepsSetAndUnsetTyped(t *testing.T) {
	t.Parallel()

	payload, err := json.Marshal(prepareOutput{
		Version:    1,
		Repository: "Acme/widgets",
		Set:        map[string]string{"PATH": "/tmp/shims:/usr/bin"},
		Unset:      []string{"GH_TOKEN"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Set   map[string]string `json:"set"`
		Unset []string          `json:"unset"`
	}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Set["PATH"] == "" || len(decoded.Unset) != 1 || decoded.Unset[0] != "GH_TOKEN" {
		t.Fatalf("typed contract was lost: %s", payload)
	}
}

func TestOffRestoresOnlyStashedVariables(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := run(context.Background(), []string{"off"}, &stdout, &stderr); err != nil {
		t.Fatal(err)
	}
	output := stdout.String()
	if !strings.Contains(output, `if [ "${UDP_GH_PREV_GH_TOKEN+x}" = x ]`) {
		t.Fatalf("off did not guard restoration with the stash: %s", output)
	}
	if !strings.Contains(output, unsetMarker+") unset GH_TOKEN") {
		t.Fatalf("off did not restore the unset state: %s", output)
	}
}

func TestAuthenticationFailureDetection(t *testing.T) {
	t.Parallel()

	if !authenticationFailure("HTTP 401: Bad credentials") {
		t.Fatal("expected auth failure to be detected")
	}
	if authenticationFailure("validation failed") {
		t.Fatal("ordinary command failure must not trigger a token refresh")
	}
}
