# udp-gh

`udp-gh` is a standalone GitHub App authentication CLI. It does not require
Symphony, Elixir, Node.js, or repository-local packages at runtime. The built
executable contains only Go's standard library.

Build and install it independently:

```bash
cd tools/udp-gh
CGO_ENABLED=0 go build -trimpath -o udp-gh ./cmd/udp-gh
install -m 0755 udp-gh "$HOME/.local/bin/udp-gh"
```

Interactive use from any Git checkout:

```bash
udp-gh check
eval "$(udp-gh on)"
gh auth status
eval "$(udp-gh off)"
```

`udp-gh gh <arguments...>` runs one GitHub CLI command with an installation
token without changing the calling shell. The shim created by `udp-gh on`
uses that command and refreshes the installation token before expiry.

Configure the host environment with:

- `GITHUB_APP_ID`
- `GITHUB_APP_PRIVATE_KEY_FILE` or `GITHUB_APP_PRIVATE_KEY`
- optionally `GITHUB_APP_INSTALLATION_ID`
- optionally `UDP_AGENT_COMMIT_NAME` and `UDP_AGENT_COMMIT_EMAIL`

For machine integrations, `udp-gh prepare` emits a versioned token-free JSON
document. Variables to export and variables to remove are separate fields:

```json
{
  "version": 1,
  "repository": "owner/repository",
  "host": "github.com",
  "authRoot": "/checkout/.artifacts/udp-gh",
  "expiresAt": "2026-08-12T19:00:00Z",
  "installationId": 123,
  "set": {"UDP_GH_AUTH": "1"},
  "unset": ["GH_TOKEN", "GITHUB_TOKEN"]
}
```

Installation tokens are stored with mode `0600` below
`.artifacts/udp-gh/`. They are never printed by `prepare`, `check`, or `on`.
