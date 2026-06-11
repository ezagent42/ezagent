# Loom gotchas — the things that pass compile and are still wrong

Read this before any non-trivial Loom change. Each item is something the code does *on purpose* that looks like a bug, or a mistake that's easy to make and silent. Grep by name to find the current line.

## Contract / architecture

1. **Loom Behaviors use `use Ezagent.Behavior`, not `use Ezagent.Lifecycle`.**
   The generic `ezagent-developer` skill says Lifecycle is the only developer surface. Loom predates/opts out of that. Loom Behaviors write `use Ezagent.Behavior` + `action/3` + `handle_<action>/2` + hand-rolled `state_slice/0` + `init_slice/1` + `data_owner/1`. **Match the existing Loom code; do not migrate to Lifecycle** unless Allen decides to. Reads are `ctx[:read].(:key, default)`; state writes are the `{:set, k, v}` effect; cross-Kind sends are `{:dispatch, %Cmd{}}`.

2. **Plugin Behaviors dispatch via `Router` (the `{:dispatch, %Cmd{}}` effect), NOT `Invocation.dispatch`.**
   Inside a `handle_<action>`, reply by returning a `{:dispatch, %Cmd{}}` effect. The legacy `Ezagent.Invocation.dispatch/1` path still exists in `web_plug.ex` (the SDK bridge calls it to inject inbound messages) — that's the inbound transport surface, a different role. Don't call `Invocation.dispatch` from inside a Behavior.

3. **`Ezagent.URI.new!`, never `URI.parse`, for session/agent URIs used as `chat.members` keys.**
   `URI.parse` populates the `:authority` field; the canonical form doesn't. The mismatch makes the same agent appear twice in the members map (the 2026-06-01 demo6 bug). `Team.ensure_team/1` already canonicalizes — copy that, don't reinvent.

4. **The `:ezagent_plugin_check` compile gate enforces the declaration triplet.**
   If you add an agent type, you must add it in *all four* places (Behavior + Entity + Template + the three lists in `application.ex`). A declared-but-missing module fails compile. Adding a flavor whose Template `validate/1` rejects the URI shape fails at spawn, not compile.

## Agents & dispatch

5. **Workers/v0/meta act ONLY when `@mentioned` (loop-guard).**
   `handle_receive` fires for *every* session message routed to the member. `addressed_to_self?/2` checks the message's `mentions` list for this agent's own URI; if absent → `{:ok, %{}, []}` (silent ignore). This is deliberate defense against feedback storms. If your new agent "doesn't respond," check that the orchestrator actually `@mentions` it.

6. **Replies must carry `ref_id` + `mentions`.**
   A worker reply sets `ref_id: subtask_msg.id` and `mentions: [subtask_msg.sender]`. The orchestrator correlates deliverables to the turn it fanned out *by `ref_id`*. Drop `ref_id` and the orchestrator can't match the reply → it waits out the dead-worker timeout and degrades.

7. **The orchestrator's aggregation timeout is derived, not constant.**
   It's `LLM.max_run_ms() + margin`. This scales with the (possibly slow / long-thinking) backend so it doesn't race the model. Don't replace it with a hard-coded number — a slow `claude_code` run would be falsely declared dead.

8. **`/stop` discards in-flight work; late deliverables are dropped, not saved.**
   `POST /api/:ws/:sid/stop` SIGINTs all `claude` runs for the session and clears the orchestrator's `pending` map. A worker that replies *after* stop becomes a stray message and is dropped — there's no "partial result" card by design.

## LLM backends

9. **Stitch and AiSpot ALWAYS call `EzagentPluginLoom.DeepSeek` directly — never `LLM`.**
   This is load-bearing (memory `feedback-preview-ai-independent-deepseek`). They are a separate consumer-side assistant, independent of the editor's swappable backend and of the agent team. Do not "unify" them onto `LLM.chat`. Conversely, agent-team code must go *through* `LLM` so the `LOOM_LLM_BACKEND` switch works.

10. **`LOOM_LLM_BACKEND` is a boot-time switch, not runtime.**
    Read once from app env (`config/runtime.exs` ← env var, default `:claude_code`). Changing it requires a `phx.server` restart. Don't add code that expects to flip it live.

11. **ClaudeCode prompt goes through stdin, not argv.**
    Large page-gen prompts (~340KB of source) overflow `ARG_MAX` and crash `:exec` with a 30s call timeout (memory `project-loom-claude-prompt-via-stdin`). Keep it on stdin.

12. **ClaudeCode's timeout is an *idle* timeout.**
    `@idle_timeout_ms` (~90s) resets on every stream-json token event. A long-thinking model that keeps emitting never times out; only true silence does. Don't reinterpret it as a hard wall-clock cap. Completion is the stream-json `result` event, **not** the OS process `:DOWN` (erlexec exit notifications are unreliable here). When touching this file, load the `erlexec-elixir` skill.

13. **The three ClaudeCode isolation flags are intentional.**
    `--setting-sources ""`, `--strict-mcp-config`, `--exclude-dynamic-system-prompt-sections` stop the headless `claude` from loading the user's `~/.claude/CLAUDE.md`, MCP servers, or cwd/git context — otherwise it "串戏" and answers like a dev assistant instead of staying in the Loom page-gen role. Don't remove them.

## Frontend / serving

14. **Don't hand-edit `priv/static/loom_ui/`.**
    It's build output from the Desktop `ai-ui-builder` repo. Edits there are overwritten on the next build→sync and the bundle filenames are content-hashed. Real UI changes happen in the Desktop source. If that source isn't reachable, say so — you can't meaningfully edit the UI from hashed bundles. (See `frontend-and-sdk.md`.)

15. **Frontend-only change = no backend restart; backend `.ex` change = ~4.5-min restart, tell Allen first.**
    Memory `feedback-warn-before-dev-server-restart`. The static export is served fresh on each request; a hard browser refresh is enough after a re-sync.

16. **Guard every sync delete.**
    Use `rsync -av --delete out/ <target>/` or `rm -rf` of a **literal** path only. Never `rm -rf $VAR/*` (memory `feedback-destructive-file-ops-guardrails`).

17. **The SDK is a two-repo change.**
    A new SDK method needs the backend endpoint in `web_plug.ex` **and** the client (`sdk.js` + `LoomBridge`) in the Desktop repo. Adding only the backend route does nothing for the in-iframe page until the client exposes it.

## Known-stale spots (code/doc drift)

18. **`web_plug.ex` moduledoc still mentions `POST /api/chat`. That route is GONE.**
    Removed in the 2026-06-01 redesign — page generation is the `loomv0` worker now, dispatched by the orchestrator. There is no `/api/chat` route in the `Plug.Router`. Don't curl it, don't re-add it. (The moduledoc is the stale part; the route block is authoritative.)

19. **`docs/loom/FRONTEND_DIST_PLAN.md` describes the predecessor (`studio-mobile`, Vite, `dist/`, port 5175, `npm`).**
    The current Loom frontend is Next.js `ai-ui-builder` (`out/`, `pnpm`, `NEXT_PUBLIC_ESR_MODE`). Use `2026-05-29-frontend-plugin-integration.md` for the current flow, not that file.

## Data

20. **Only the authoring `loomv0` writes page source. Everything else is overlay ops.**
    Published links, snapshots, and forks all get a *frozen* base; they can only append `user_schema` ops. Stitch appends ops too — it never edits source. If you find yourself writing code that mutates `loom_source` from a consumer surface, it's wrong.

21. **The local JSON stores are keyed by canonical `session://loom/<ws>/<sid>` (or a token).**
    `user_schema.ex`, `stitch_chat.ex`, `knowledge.ex`, `snapshots.ex`, `saved_classes.ex` all live in `~/.ezagent/<profile>/loom_*.json`. Use the same key derivation; a non-canonical key silently splits a session's data across two buckets.
