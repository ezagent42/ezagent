# Loom backend map

All paths under `apps/ezagent_plugin_loom/`. This is a navigation map, not a line-by-line spec — function/module names are durable, line numbers drift, so grep by name.

## 1. The 4-file pattern per agent type

Every Loom agent type is declared across **four parallel files**. Using `loomworker` as the worked example:

| Layer | File | What it declares | Key contents |
|---|---|---|---|
| **Behavior** | `lib/ezagent/behavior/loom_worker.ex` | the action + business logic | `use Ezagent.Behavior`; `action(:receive, ...)`; `handle_receive/2`; `state_slice/0`; `init_slice/1`; `data_owner/1` |
| **Kind (Entity)** | `lib/ezagent/entity/loom_worker.ex` | the agent *type* | `@behaviour Ezagent.Kind`; `type_name/0 → :loomworker`; `behaviors/0 → [Ezagent.Behavior.LoomWorker]`; `persistence/0 → :ephemeral`; `supervisor/0` |
| **Template Class** | `lib/ezagent/template/loom_worker.ex` | how to spawn an instance | `@behaviour Ezagent.Kind.Template`; `template_name/0 → "loom.worker"`; `validate/1` (enforces the URI shape); `instantiate/3 → {:ok, [uri], %{fresh?: bool}}` |
| **Wiring** | `lib/ezagent_plugin_loom/application.ex` | registers all of the above | `behaviors/0`, `template_classes/0`, `agent_flavors/0` lists |

The same quadruplet exists for: `loom` (the original fixed-reply test bot), `loom_orchestrator`, `loom_worker`, `loom_v0_worker`, `loom_meta_agent`. Plus two extra Template Classes with no Behavior/Kind: `template/loom_agent.ex` and `template/loom_session.ex` (the latter assembles the whole team — see §3).

### How a chat message reaches a worker

```
chat message dispatched into session
  → session fan-out hook delivers to each member's :receive action
    → Behavior.handle_receive(%{message: %Message{}}, ctx)
      → addressed_to_self?(msg, ctx)   # is THIS worker @mentioned?
        → yes: LLM.chat(...) → {:ok, %{}, [{:set, ...}, {:dispatch, %Cmd{}}]}
        → no:  {:ok, %{}, []}          # loop-guard: silent ignore
```

The reply is a `{:dispatch, %Cmd{}}` effect targeting `session://...?action=chat.send`, carrying `ref_id: subtask_msg.id` and `mentions: [subtask_msg.sender]` so the orchestrator can **correlate the deliverable to the turn that fanned it out**. Caps come from `Ezagent.SystemPrincipal.caps("system://chat-reply")`.

### The agents, one line each

- **`loom`** — the original fixed-reply test bot (`你好！我是测试机器人！`). Has both `:say` (programmatic) and `:receive` (chat) actions. Mostly legacy/demo scaffolding.
- **`loomorch` (orchestrator)** — the brain. On each user turn: decompose → fan out subtasks to workers (each `@mentioned`) → aggregate replies (correlated by `ref_id`) → compose a final card. Holds the page source in its `:loom_orchestrator` slice (`loom_source`, a `%{path => content}` map). Its dead-worker aggregation timeout is derived from `LLM.max_run_ms() + margin` — it scales with model speed, so don't hard-code it.
- **`loomworker` (worker)** — produces one content fragment for one subtask. Two demo instances carry `policy` / `company` *themes* derived purely from their URI name (`loomworker_<sid>_policy` / `_company`). Acts ONLY when `@mentioned` (loop-guard).
- **`loomv0` (v0worker)** — the AI **page generator**. Dispatched by the orchestrator with the current source + the user request; replies with a `<span type="page_update">` body. **The only agent that edits page source.** Streams generation progress over a PubSub topic the SSE endpoint relays to the browser.
- **`loommeta` (meta-agent)** — team manager. Parses `@`-mention NL commands ("加一个法务 worker") via DeepSeek → spawns/terminates Kinds + `chat.join`/`chat.leave`.

## 2. LLM backends — two planes

### Plane A: the swappable dispatcher (`lib/ezagent/llm.ex`)

`EzagentPluginLoom.LLM` is a thin façade. `LLM.chat/2`, `LLM.max_run_ms/1`, `LLM.stop/1` delegate to whichever backend is selected at **boot** by app env `:llm_backend` (set from `LOOM_LLM_BACKEND` in `config/runtime.exs`, default `:claude_code`). **Not a runtime hot-switch** — change `.env`, restart `phx.server`.

- **`claude_code.ex`** — drives a local `claude` binary headless via `:exec` (erlexec), streaming `stream-json`. Notable: prompt goes through **stdin** (not argv — `ARG_MAX`); three isolation flags (`--setting-sources ""`, `--strict-mcp-config`, `--exclude-dynamic-system-prompt-sections`) stop it from drifting into "dev assistant" answers; the timeout is an **idle** timeout reset by token events, not a hard wall-clock cap; completion is signalled by the stream-json `result` event, not the process `:DOWN`; `stop/1` SIGINTs all runs in a `group` (= session string). When editing this file, load the `erlexec-elixir` skill.
- **`deepseek.ex`** — single non-streaming HTTP POST to DeepSeek. Auth via `DEEPSEEK_KEY`. No retry; failures are final. Thinking disabled by default.

Both expose the same `chat/2 → {:ok, content} | {:error, reason}` so the Behavior layer is backend-agnostic.

### Plane B: preview-side AI — ALWAYS DeepSeek, direct

`stitch_chat.ex` (the store) + the `/api/.../stitch` and `/api/.../aispot` endpoints call `EzagentPluginLoom.DeepSeek.chat/2` **directly**, bypassing `LLM`. This is intentional and load-bearing (memory `feedback-preview-ai-independent-deepseek`): Stitch/AiSpot are a separate consumer-facing assistant, not the editor's reasoning model and not the agent team. **Never** "unify" them onto the `LLM` dispatcher.

- **Stitch** maps natural language → either a component drive (`DRIVE: {id, action, params}` applied by the frontend, *not* persisted) or a plain reply / `addText` op (appended to `user_schema`). It reads `Knowledge.get(ws, sid)` as grounding.
- **AiSpot** answers about a specific on-page hotspot, given the v0-injected local context, also grounded by `Knowledge`.

## 3. Web entry & SDK bridge (`lib/ezagent/web_plug.ex`)

`EzagentPluginLoom.WebPlug` is a `Plug.Router` and the **only** touch-point into `ezagent_web` (one line: `forward "/loom", EzagentPluginLoom.WebPlug`). The `forward` strips `/loom`, so routes inside the plug are relative. A `Plug.Static` serves the Next.js export for `_next`, `favicon.ico`, `404.html`, `index.txt`; everything else falls through to the routes; `GET /*_path` is the SPA fallback → `index.html`.

Route table (all prefixed `/loom` from the browser; `:ws`/`:sid` = workspace / session id):

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/:ws/:sid/messages` | send a chat message into the session (as stable temp user `loomui_<sid>`, auto-@orchestrator) |
| GET | `/api/:ws/:sid/history` | last 50 messages, oldest-first |
| GET | `/api/:ws/:sid/stream` | **SSE** — full session message stream + v0 generation progress frames |
| POST | `/api/:ws/:sid/stop` | SIGINT all running `claude` for the session + clear orchestrator's in-flight turns |
| POST | `/api/:ws/:sid/save-as-template` | snapshot orchestrator `:loom_source` into a workspace session template |
| GET | `/api/:ws/templates` | list registered templates |
| GET | `/api/:ws/published` | published share-link templates + links for the ws |
| DELETE | `/api/:ws/templates/:name` | delete a template entry |
| POST | `/api/:ws/:sid/publish` | freeze session → immutable published Template Class + 16-hex token + `/loom/p/<token>` link |
| GET/POST | `/api/:ws/:sid/user-schema` | read / append-or-replace the per-session page-edit ops |
| GET/POST | `/api/:ws/:sid/stitch` | read Stitch conversation / send (→ **direct DeepSeek** + DRIVE/op parse) |
| POST | `/api/:ws/:sid/aispot` | dynamic ✨ card for a hotspot (→ **direct DeepSeek** + Knowledge grounding) |
| GET/POST | `/api/:ws/:sid/knowledge` | read / write the per-session Markdown knowledge base |
| POST | `/api/:ws/:sid/snapshot` | freeze current page + ops + Stitch convo → snapshot token + link (copy-on-snapshot) |
| POST | `/api/:ws/:sid/upload` | multipart upload → `resource://uploads/<ws>/<name>` URI |
| GET | `/api/:ws/:sid/resource` | resolve a `resource://` URI → 302 to `/files/<name>` (strict ws check) |
| POST | `/api/:ws/:sid/fetch` | whitelisted HTTP proxy (FetchProxy presets) |
| POST | `/api/:ws/:sid/tool` | named server-side tool RPC (ToolRegistry) |
| POST | `/p/:token/open` | open a published link → mint a NEW no-v0 session (`pub_<hex>`) + temp user |
| GET | `/snapshot/:token` | read-only frozen page+ops+convo for a snapshot link (no session minted) |
| POST | `/p/:token/fork` | snapshot → a NEW *editable-by-ops* session (copies frozen page as base + ops + convo) |
| GET | `/whoami` | current entity URI from the ezagent auth cookie (used as the fork gate) |
| POST | `/api/:ws/templates/:name/spawn` | instantiate a new session from a template |

The SDK bridge (`/api/:ws/:sid/*`) is what the AI-generated page (running in a Sandpack iframe) calls — via `postMessage` to the host page, which does same-origin `fetch`/SSE here. See `references/frontend-and-sdk.md` §SDK.

> **Stale doc warning:** `web_plug.ex`'s moduledoc still describes a `POST /api/chat` DeepSeek page-gen endpoint. **That route was removed in the 2026-06-01 redesign** — page generation is now the `loomv0` worker, dispatched by the orchestrator. Don't add it back or curl it.

## 4. State & data stores

Loom data lives in **three** places (full walkthrough: `docs/loom/2026-06-08-loom-data-lifecycle.md`):

1. **Kind slices** (framework-owned, snapshot-on-change, persisted by ezagent core) — `:loom_orchestrator` holds `loom_source` (the page code!), worker/v0 slices hold prompts/config.
2. **MessageStore** (framework-owned) — every chat message in the session.
3. **Four local JSON files** in `~/.ezagent/<profile>/`, keyed by `session://loom/<ws>/<sid>` or a token, written by the plug:
   - `loom_user_schemas.json` → `user_schema.ex` — per-session page-edit ops (append/replace)
   - `loom_stitch_chats.json` → `stitch_chat.ex` — per-session Stitch conversation
   - `loom_snapshots.json` → `snapshots.ex` — frozen page+ops+convo+knowledge copies (share)
   - `loom_saved_classes.json` → `saved_classes.ex` — published Template Classes (reincarnated at boot via `Module.create`)
   - (plus `loom_knowledge.json` → `knowledge.ex` — per-session grounding Markdown)

Supporting modules: `team.ex` (`ensure_team/1` — idempotently spawns the whole team with **canonical** URIs), `span.ex` (`normalize/1` — wraps raw LLM output in `<span type="...">{json}</span>` scene cards; greedy JSON extraction handles nested `</span>` in generated JSX), `bootstrap.ex` (`run/1` — per-visitor: ensure session → provision temp user → ensure team → join), `temp_user.ex` (ephemeral `entity://user/<ws>/tmp_<hex>` or stable `loomui_<sid>` visitors), `feishu.ex` (optional one-way mirror, gated behind `FEISHU_MIRROR_ENABLED=1`, default off).

## 5. Tools (the page-callable function plugin)

AI-generated pages can call whitelisted server-side functions via `POST /api/:ws/:sid/tool`.

- `tool.ex` — the behaviour: `name/0`, `args_schema/0` (a hint for the AI prompt; **not** runtime-validated), `description/0`, `call/2 → {:ok, result} | {:error, reason}`.
- `tool_registry.ex` — boot-time ETS registry. `register_all/0` runs in `after_boot/0`; a name collision skips that tool (others continue), it does not fail boot. Lookups are lock-free.
- `tools/echo.ex`, `tools/now.ex` — the two built-ins. Config list: `config :ezagent_plugin_loom, :tools, [...]`.

To add one: see `references/recipes.md`.

## 6. Boot (`application.ex`)

`use Application` + `use Ezagent.Plugin`. `start/2` = `Ezagent.Plugin.boot(__MODULE__)` then registers the 4th session-view tab (`LoomSessionView`). The plugin **declares** (never calls registries itself):

- `behaviors/0` — 6 `{Kind, action, Behavior}` triples (loom say+receive, worker/orch/v0/meta receive).
- `template_classes/0` — 6 Template Classes (incl. `LoomSession`, which assembles the team).
- `agent_flavors/0` — maps URI name prefixes `loom` / `loomworker` / `loomorch` / `loomv0` / `loommeta` → `{Kind, TemplateClass}`.
- `after_boot/0` (Phase 3) — spawns the default `entity://agent/system/loom_agent`, then `SavedClasses.register_all_from_disk/0`, then `ToolRegistry.register_all/0`. Failures are logged, never raised (must not abort boot).

The `:ezagent_plugin_check` Mix compiler gate enforces the declaration shape — if a flavor/behavior is declared but its module is missing/malformed, compile fails.
