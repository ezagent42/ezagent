# AutoService Live Verify - Codex Session

Date: 2026-06-29
Branch: `worktree-verify+autoservice-live-codex`
Base: `origin/main` `755b2a9b`

## Scope

This is the second isolated verification line for the 2026-06-29 AutoService live task. The other line is running separately on `verify/autoservice-live`; this run uses its own worktree, DB, home dir, and service ports.

## Runtime

- Worktree: `/home/huangjiajia/ezagent/.claude/worktrees/verify+autoservice-live-codex`
- Phoenix port: `10144`
- World Vite watcher port: `15144`
- DB: `ezagent_pg_compat_dev_codex`
- `EZAGENT_HOME`: `/tmp/ezagent_autosvc_live_codex`
- Seed script: `scripts/autoservice_tier1_serve_seed.exs`

Setup completed:

- `mix deps.get`
- `pnpm install --no-frozen-lockfile` in web/world/hello asset dirs
- `MIX_ENV=dev POSTGRES_DB=ezagent_pg_compat_dev_codex EZAGENT_HOME=/tmp/ezagent_autosvc_live_codex mix ecto.create --quiet`
- `MIX_ENV=dev POSTGRES_DB=ezagent_pg_compat_dev_codex EZAGENT_HOME=/tmp/ezagent_autosvc_live_codex mix ecto.migrate --quiet`
- `MIX_ENV=dev mix assets.build`

## Seed / Fix Result

After the cc-orchestrator materialization fix, the seed completed and created the deterministic Tier-1 stack:

- Workspace: `workspace://autosvc`
- KB agent: `entity://autosvc/agent/kb-tier1`
- AutoService agent: `entity://autosvc/agent/autoservice`
- Session: `session://autosvc/default/tier1`
- Route: `always(in_session) -> AutoService-agent`

The original blocker is fixed:

```elixir
{:autoservice_agent_create_failed, {:role_unsupported_for_flavor, "cc"}}
```

The seed now mirrors the session-create orchestrator-template path:

- reads `template://system/agent/cc-orchestrator`
- overrides the working cwd for `entity://autosvc/agent/autoservice`
- calls `Ezagent.Entity.Agent.spawn_from_template_content/5`
- initializes sandbox config as Agent Kind create-time state through `Sandbox.create/1`
- skips the fallback `sandbox.update_config` dispatch when the initialized sandbox state already matches the Template Class meta
- grants `kb.query` through the normal Identity grant chokepoint

Live IEx evidence after restart:

```elixir
uri = URI.new!("entity://autosvc/agent/autoservice")
{
  Ezagent.KindRegistry.lookup(uri),
  Ezagent.ReadyGate.status(uri),
  length(Ezagent.Identity.read_entity_caps(uri)),
  Enum.any?(
    Ezagent.Identity.read_entity_caps(uri),
    &(&1.behavior == Ezagent.Behavior.Kb and Ezagent.Capability.action_of(&1) == :query)
  )
}
```

Result:

```elixir
{{:ok, #PID<...>}, :failed, 4, true}
```

Interpretation: the AutoService agent exists and its durable identity slice includes `kb.query`. `ReadyGate.status == :failed` is currently caused by the local Claude Code process not being logged in, so the external bridge never joins.

## HTTP Surface

Phoenix endpoint is alive:

- `GET /` returns `302 /login`
- `GET /socialware/chat?session_uri=session%3A%2F%2Fautosvc%2Fdefault%2Ftier1` returns the chat HTML shell
- `GET /socialware/external?session_uri=session%3A%2F%2Fautosvc%2Fdefault%2Ftier1` returns the external HTML shell
- `GET /assets/js/viewer_app.js` returns `200`
- `GET /assets/css/viewer.css` returns `200`

The seed output still prints hard-coded/default `10042` URLs. For this isolated run the equivalent URLs use port `10144`.

Screenshots captured from the restarted `10144` service:

- `docs/together/2026-06-29/returns/screenshots/autoservice-chat-10144.png`
- `docs/together/2026-06-29/returns/screenshots/autoservice-external-10144.png`
- `docs/together/2026-06-29/returns/screenshots/autoservice-chat-fixed-10144.png`

Observed visual state:

- Chat page renders the shell but shows `Unsupported node: container`.
- External page renders the shell but shows the empty state `还没有页面`.
- Latest fixed-run screenshot still shows the chat shell/login input; the render issue is separate from the cc agent creation chain.

## WebSocket Surface

Direct Phoenix WebSocket probes:

- Chat socket joined topic `socialware:chat_feed:session://autosvc/default/tier1` successfully and returned an empty snapshot.
- Chat `join`, `post`, and `history` events returned `read_only`, consistent with `Ezagent.Socialware.ChatFeedAdapter.participation_profile/0`.
- External socket joined topic `socialware:external:session://autosvc/default/tier1` successfully and returned an empty snapshot.
- External anonymous `join`/`post` returned `not_logged_in`; `history` returned empty messages.
- An admin token alone was not sufficient to join the external channel because the channel join requires an already authorized/member principal before a channel-level `join` event can be sent.

## KB Probe

Live IEx probe:

```elixir
Ezagent.Orchestrator.Tools.kb_query(
  "kb-tier1",
  Ezagent.AutoService.Tier1Seed.kb_probe_query(),
  5,
  caller: Ezagent.URI.new!("entity://autosvc/agent/autoservice"),
  caps: Ezagent.AutoService.Tier1Seed.orchestrator_kb_caps(),
  workspace_uri: Ezagent.URI.new!("workspace://autosvc")
)
```

Result: `{:ok, %{chunks: [...]}}` with the expected corpus chunk containing `ZEPHYR-7731`.

Conclusion: deterministic KB retrieval is green.

## Message And Routing Probe

Two admin messages were sent through `session.send`; both were stored and marked routed:

- `What is the tier-one support hotline access code?`
- `Please answer with ZEPHYR-7731 if retrieved.`

`messages` table evidence:

- Sender: `entity://system/user/admin`
- Visibility: `external_visible`
- `routed_at`: present for both messages
- No AutoService agent reply rows were produced

Recent `invocations` evidence:

- `session://autosvc/default/tier1?action=session.send` authorized as `granted`
- fan-out to anonymous users via `user.receive` authorized as `granted`
- `entity://autosvc/agent/kb-tier1?action=kb.query` authorized as `granted`
- session snapshots written after sends
- no invocation exception was recorded for the live sends

Conclusion: message write, broadcast/fan-out, route marking, and KB tool auth work. The AutoService cc agent is now materialized, but the local Claude Code bridge does not become ready because the CLI reports `Not logged in · Run /login`.

## Runtime Noise / Secondary Issues

The world Vite dev watcher repeatedly fails under pnpm:

```text
node node_modules/.bin/vite ...
SyntaxError: missing ) after argument list
```

Cause observed: Phoenix watcher invokes `node node_modules/.bin/vite`, but pnpm's `.bin/vite` is a shell shim, so Node tries to parse shell syntax. Static assets had already been built and served successfully, so this did not block the viewer HTML/static verification.

Other expected local noise:

- `watchman` and `inotify-tools` missing warnings for live reload
- Feishu credentials missing
- inbound email inbox not configured
- local runtime distribution unavailable in this environment
- Claude Code spawned for `entity://autosvc/agent/autoservice`, but the TUI reports `Not logged in · Run /login` and `Channels are not currently available`; this prevents the AgentBridge readiness event and keeps `ReadyGate` failed.

## Verdict

Green:

- AutoService cc orchestrator is materialized at `entity://autosvc/agent/autoservice`.
- The generic `Workspace.create_agent` `{:role_unsupported_for_flavor, "cc"}` blocker is fixed.
- Sandbox config is initialized during Agent Kind create, so creation no longer depends on external cc transport readiness.
- No core local-dispatch exception is required; `Ezagent.Invocation.dispatch/1` remains the dispatch path.
- The AutoService agent's durable identity slice includes `kb.query`.
- `SessionManager.load_orchestrator_caps/1` now reads delegated orchestrator caps from durable entity identity state instead of public ReadyGate-gated `list_caps_for/1`.
- Isolated stack bootstraps on non-conflicting ports.
- DB create/migrate works against an isolated DB.
- Seed is idempotent enough for this live run.
- HTTP chat/external shells and built viewer assets are served.
- WebSocket topics can be joined.
- KB retrieval returns the expected non-model corpus fact `ZEPHYR-7731`.
- `session.send` stores messages, authorizes, fans out, writes snapshots, and marks `routed_at`.

Blocked / not green:

- AutoService cc answer-loop is still not live in this machine because Claude Code is not logged in and the bridge never joins.
- Anonymous external posting is not currently enabled through the probed channel path (`not_logged_in`).
- Chat feed adapter is read-only by design in this path.
- Chat page still shows `Unsupported node: container`.
- World Vite dev watcher is broken with pnpm shell shims when launched as `node node_modules/.bin/vite`.

Recommended next fix targets:

- Log in Claude Code or provide a testable headless auth path, then rerun `session.send` and expect an agent-authored reply containing `ZEPHYR-7731`.
- Fix the chat renderer's unsupported `container` node handling.
- Fix dev watcher invocation to execute the Vite shim through the shell or the package manager rather than `node node_modules/.bin/vite`.
