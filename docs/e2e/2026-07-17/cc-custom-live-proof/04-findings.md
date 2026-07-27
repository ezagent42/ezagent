# T7 — findings surfaced by the live proof

Ordered by severity. Each entry: what happened, whether it is cc-custom-build
regression or pre-existing, and the evidence pointer.

## F1 — CRITICAL: PtyServer crash dump logs the full launch env, including `ANTHROPIC_AUTH_TOKEN`

When a claude PTY child exits abnormally (here: the `{:exit_status, 256}` that
precedes every DEGRADED-respawn fallback on this host), the PtyServer
GenServer's terminate log dumps its full state — which contains `cmd_env` with
the live vendor key:

```
State: %Ezagent.Domain.Pty.Server{..., cmd_env: %{
  "ANTHROPIC_AUTH_TOKEN" => "sk-<REDACTED>",
  "ANTHROPIC_BASE_URL" => "https://api.deepseek.com/anthropic", ...,
  "EZAGENT_AGENT_TOKEN" => "tok_<REDACTED>", ...}, ...}
```

This violates the build's own §4.7 redaction boundary ("The key NEVER enters:
… logs") and the design's secret-hygiene rule. **Class: pre-existing** (the
`cmd_env` state field + crash-dump path predate this build — the retired
cc-deepseek flavor had the same exposure; cc-custom inherits it and makes it
the common case because the profile key now lives in the launch env by
design). The local proof logs were sanitized before any evidence use; the raw
copies were destroyed. **The operator should consider the run-1/run-2
DeepSeek key exposed to anyone who can read this host's `/tmp` and rotate
it.** Recommended fix direction: never keep the raw child env in the logged
GenServer state (scrub at the terminate-report boundary, or keep only a
redacted view in the struct).

## F2 — pre-existing: `agent_template instantiate` + `config_dir` in content → cascade `{:calling_self}` crash

Any AgentTemplate whose content carries `config_dir` fails to instantiate via
the template's OWN `template.instantiate` dispatch:

```
error: {:cascade_layer_dir_failed,
        %{source: <template-uri>, layer: :workspace, present: true},
        {:get_slice_exit, {:calling_self, {GenServer, :call, [<pid>, {:ezagent_get_slice, :template}, 5000]}}}}
```

The #17 cascade layer resolution reads the source template's `:template`
slice from inside the template Kind's own dispatch process → self-call. It is
GENERIC: reproduced identically with plain `cc-headless` (control) and with
`cc-custom` PTY. It does NOT affect the seeded-orchestrator lane (the
Generator/session-create process materializes from a different pid) nor
content without `config_dir` (the cc-custom PTY proof spawned fine without
one). **Not a cc-custom-build regression** — but it is the reason an ad-hoc
cc-headless-custom agent cannot be instantiated via the template lane (the
headless transport needs a config home; see F4).

## F3 — gap: `workspace create_agent` cannot pass `provider` for custom flavors

`FlavorConfig.coerce/2` validates flavor-config keys against the Template
Class's `config_schema()`. `CcCustomAgent.config_schema` delegates to cc's
schema (`model`/`effort`/`permission_mode`/`tools`) — `provider` is not in it
(design intent: the provider select lives in the TEMPLATE form's
`form_fields/0`, spec §4.5 "operator adds a template"). Empirical:

```
FlavorConfig.coerce("cc-custom", %{flavor_config: %{"provider" => "deepseek"}})
# => {:error, {:unknown_flavor_config_keys, "cc-custom", ["provider"]}}
FlavorConfig.coerce("cc-headless-custom", %{flavor_config: %{"provider" => "kimi"}})
# => {:error, {:unknown_flavor_config_keys, "cc-headless-custom", ["provider"]}}
```

Consequence: the ad-hoc `mix ezagent.agent.create` / world "New Agent" form /
`workspace create_agent` CLI cannot create a custom-flavor agent at all (with
provider → rejected; without → `:missing_backend_profile` at instantiate).
The sanctioned create lane for custom flavors is the AgentTemplate content
seam (fork → write → instantiate), which the proof used. If the lead wants the
ad-hoc lane for custom flavors, `provider` needs to be added to the custom
classes' `config_schema` (or FlavorConfig needs to consult `form_fields/0`) —
a one-field change plus tests.

## F4 — pre-existing: headless `template.instantiate` without `config_dir` → sidecar `String.to_charlist(nil)` crash

When a cc-headless(-custom) AgentTemplate has no `config_dir`,
`create_agent_config_dir` returns `{:ok, nil}`, `put_agent_config_dir` no-ops,
and the SDK sidecar crashes on `Map.fetch!(:config_dir) |> String.to_charlist()`
(a `FunctionClauseError` — not a graceful validation error). Generic to plain
cc-headless (same code path); the `create_agent` lane is unaffected because
`file_flavor_template` always allocates a per-agent config dir.

## F5 — pre-existing: `mix ezagent session send` cannot deliver (message-map ≠ `%Message{}`)

The generic CLI passes the `--message` JSON map straight into
`Invocation.args`, but `Ezagent.ActionSet.Session.handle_send/2`
pattern-matches `%Message{}` → `:function_clause` (observed in the server log
as `Behavior Ezagent.ActionSet.Session.handle_send/2 crashed`). The world UI
path (which builds the struct in-BEAM) is unaffected and was used for the chat
proof. This means the CLI currently has NO working chat-send verb — a CLI/GUI
parity gap worth its own issue.

## F6 — environment notes (not product defects)

- `~/.ezagent/default/credentials/cc-custom.env` has CRLF line endings;
  `DEEPSEEK_API_KEY` picks up a trailing `\r` when sourced (DeepSeek's
  endpoint tolerated it in this proof — the Moonshot line is CR-free, so CRLF
  is NOT the kimi-401 cause). File mode is `0644`, not the brief's `0600`.
- A fresh worktree cannot serve the world UI until
  `apps/ezagent_plugin_world/assets` (pnpm install + pnpm build) and
  `apps/ezagent_web/assets` (pnpm install; esbuild/tailwind watchers or
  `mix tailwind ezagent_web`) are built — the vite/esbuild watchers fail
  noisily but do not block the endpoint. `epmd -daemon` is required before the
  first boot or the `ezagent_runtime` node name cannot be claimed and the CLI
  cannot connect.
- Run 1 of this proof booted the server from a shell that itself runs on a
  custom backend (ambient `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL`); the
  claude TUI warned "Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set". Run
  2 (the evidence run) scrubbed the ambient vars — the agents' only auth
  material is the profile's.
