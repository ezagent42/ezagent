# Codex host credential materialization failure (2026-07-27)

## Symptom

The host has a valid `~/.codex/auth.json`, but creating a Hello role with
`llm_flavor: "codex"` fails before the page-generation flow starts:

```text
{:agent_spawn_failed, "llm",
 {:codex_app_server_not_ready,
  {:codex_app_server_exited_before_ready, "/.../codex/<agent>/app-server.sock", ""}}}
```

The per-agent `CODEX_HOME` is created without `auth.json`, so the Codex
app-server exits before the PTY/TUI is started.

## Evidence

- Host credential: `/home/lenovo/.codex/auth.json` exists, mode `0600`, valid
  JSON, and contains Codex auth metadata.
- `Ezagent.Credential.HomeRuntime.host_login_dir("CODEX_HOME", ".codex")`
  resolves to `/home/lenovo/.codex`.
- The workspace default source is registered as
  `entity://system/agent/codex-host-login`.
- Repeated Codex Hello materialization attempts still leave the allocated
  per-agent directory without `auth.json` and fail in
  `CodexAgent.ensure_app_server/…`.
- The normal curl-backed Hello path is unaffected and generates pages
  successfully.
- A repeat using both `llm_flavor: "codex"` and `llm_flavor: "codex-remote"`
  failed at the same app-server readiness boundary; the remote flavor used its
  own socket but also had no materialized `auth.json`.

## Current hypothesis

The host-login source registration and the per-agent credential cascade are not
converging before `codex.agent` launches its sidecars. The failure is in
credential-source materialization/authorization, not in the host's Codex login
and not in the Hello page generator.

## Reproduction

```elixir
EzagentPluginHello.App.ensure_app("system", "codex-e2e", llm_flavor: "codex")
```

Expected: the `llm` role starts with a populated Codex home and the Hello
session can generate a page. Actual: `codex_app_server_exited_before_ready`.

## Next investigation

Trace `Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant/4`
through source resolution, grant verification, and `stage_and_swap/7`; add an
integration regression test that asserts the allocated Codex home contains
`auth.json` before `AppServer.start/2` is called.
