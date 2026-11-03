# Shared Inkdrop MCP

The shared service is opt-in. `inherit` keeps the provider's existing MCP setup;
`shared` requires the configured local HTTP endpoint and never falls back to a
new STDIO backend. The canonical server name stays `inkdrop`.

## Ownership

launchd owns one user job, `io.crafts69guy.orc.inkdrop-mcp`. That job runs
`mcp-proxy` 0.13.3, which owns one Inkdrop MCP backend from
`@inkdropapp/mcp-server` 1.5.0. These are external dependencies; orc's owned
implementation remains Lua. Closing a task, worker, MCP client, or Neovim panel
does not stop the service.

The service uses mcp-proxy's native named-server configuration rather than a
resident wrapper. Its endpoint is:

```text
http://127.0.0.1:<port>/servers/inkdrop/mcp
```

Only the user explicitly installs or controls the job. Providers, hooks and
doctor never start it. Other applications share the backend only if their MCP
configuration points at the same endpoint. Existing STDIO clients must finish
or be restarted before claiming that only one backend remains on the machine.

## Private configuration

Settings, the backend configuration and migration backups live under:

```text
~/Library/Application Support/orc/inkdrop-mcp/
```

Directories are private and credential-bearing files use mode `0600`. The
LaunchAgent contains executable paths and the private configuration path, not
credentials. Backend credentials are passed through the private native proxy
configuration, not command-line `--env` arguments. Installation imports only
`INKDROP_LOCAL_USERNAME`, `INKDROP_LOCAL_PASSWORD` and
`INKDROP_LOCAL_SERVER_URL` from the explicit credential source.

`ORC_INKDROP_MCP_CONFIG` can select an absolute user-owned settings file. This is
an explicit user input, not a value taken from a task brief or repository config.
Never commit the settings, backend configuration, credential source or backups.

Shared provider launches remove Inkdrop credential variables from their
environment. Rex workers explicitly carry the selected mode/configuration and
remove inherited credentials rather than assuming the Rex app has the same
environment as the orchestrator. `orc inkdrop` continues to use the data REST
API, reading the private backend credential source before legacy environment
variables. The HTTP MCP endpoint is not the Inkdrop data API endpoint.

## Explicit setup

Install the pinned dependencies using your normal package workflow. Supply
absolute executable/backend paths; a LaunchAgent does not run a login shell or
initialize fnm. A Node/package upgrade that moves those paths requires an
explicit service update.

The setup sequence is:

1. `orc inkdrop-mcp install` with the proxy, Node, backend and port options.
   Installation creates an `inherit` configuration and does not start the job.
2. `orc inkdrop-mcp start` to explicitly load the user job.
3. Preview `orc inkdrop-mcp migrate --provider claude` and
   `orc inkdrop-mcp migrate --provider codex`.
4. Repeat the intended migrations with `--apply` after reviewing the preview.
5. `orc inkdrop-mcp enable`, or select `--inkdrop-mcp shared` for an orc launch.
6. Check `orc inkdrop-mcp status --json` and `orc doctor --json`.

`--file` selects a specific provider configuration for migration or rollback.
This is needed when a profile/project overrides the user entry; changing the
user config does not silently rewrite every project. Normal provider trust and
approval controls still apply.

In shared mode, select the working directory before launching orc (or use its
`--wt` option). Native Codex `-C`/`--cd` overrides are rejected so the configuration
checked before launch cannot differ from the configuration actually loaded.
Profile selection is passed to both the preflight and the native provider.
Claude entries carrying transport authentication require explicit manual review
before migration to this unauthenticated local bridge; authentication values
are never copied into an inline CLI overlay.

## Migration and rollback

Migration changes only the canonical Inkdrop entry. It removes STDIO transport
fields while retaining unrelated MCPs, Inkdrop tool filters, timeouts and approval
policies. Claude's separate permission settings are not rewritten.

Codex CLI overrides merge tables: adding `url`, even through an inline table,
does not remove an existing STDIO `command`. Native `codex mcp add` replaces the
transport but does not retain all per-server policy. Orc therefore uses an
explicit, validated migration instead. Unsupported TOML shapes are rejected
before the configuration is changed.

An applied migration stores a private exact-byte backup and before/after hashes.
It refuses a concurrent change before writing. Rollback refuses to overwrite
subsequent user edits; reconcile those changes manually rather than forcing an
old snapshot over them.

To retire the service, roll back the migrated provider entries, disable shared
mode, stop the owned job, then uninstall it. Uninstallation must not discard an
active migration's rollback data or stop another process occupying the port.

## Failures and security

A failed shared connection is a startup error, not an invitation to spawn STDIO.
Doctor distinguishes MCP connectivity from Inkdrop data API health. A listening
TCP port alone is insufficient: health checks perform a bounded MCP handshake
and close their downstream session without invoking a tool.

The bridge is bound to literal loopback and validates Host/Origin, but this
version has no inbound authentication. Loopback does not isolate operating-system
users or applications. Use it only where local-client trust is acceptable; an
untrusted multi-user machine needs an authenticated design before rollout.
Per-user launchd ownership is lifecycle control, not HTTP authorization.

Clients have independent downstream protocol sessions but share one upstream
identity and Inkdrop account. Filesystem sandbox read-only mode does not prevent
a remote MCP write; retain provider tool allowlists and approvals. Neither orc
nor service installation grants new tool permissions.

Attachment tools can also read `filePath` or write `outputPath` with the service
user's filesystem access. This capability is not confined by the calling
agent's workspace sandbox. Treat attachment tool permission as filesystem
access when reviewing provider policy.
Use absolute attachment paths: the backend's working directory is its private
service directory, independent of the agent's current project.

Concurrent note updates still require `_rev` conflict handling. An interrupted
write can have an unknown outcome; do not blindly retry creates or writes after
reconnecting. Shared process count is not transaction serialization or exactly
once delivery.

## Acceptance

The offline suite covers configuration validation, permissions/redaction,
provider argv/environment, safe migration/rollback and owned-job lifecycle.
Live acceptance uses disposable configurations and service state: both native
providers, overlapping HTTP clients, one backend PID, worker/client disconnect,
resource/attachment flows, stale revisions, and backend/proxy crash recovery.
Paid model calls are separate from ordinary tests. Memory samples from the
earlier read-only trial are not a benchmark or a promised saving.
