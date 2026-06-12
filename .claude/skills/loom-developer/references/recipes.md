# Loom how-to recipes

Common Loom contributor tasks. Each lists the files to touch and the order. Always have `ezagent-developer` + `elixir-phoenix-helper` loaded too. Read `gotchas.md` before starting.

## Add a page-callable tool (e.g. `weather.current`)

The cheapest extension point. A tool is a server-side function the AI-generated page calls via `POST /api/:ws/:sid/tool`.

1. Create `lib/ezagent/tools/weather.ex` implementing the `EzagentPluginLoom.Tool` behaviour:
   ```elixir
   defmodule EzagentPluginLoom.Tools.Weather do
     @behaviour EzagentPluginLoom.Tool
     @impl true
     def name, do: "weather.current"
     @impl true
     def description, do: "Current weather for a city"
     @impl true
     def args_schema, do: %{"city" => "string"}   # hint for the AI prompt; NOT runtime-validated
     @impl true
     def call(%{"city" => city}, _ctx), do: {:ok, %{city: city, tempC: 21}}
     def call(_, _), do: {:error, :missing_city}
   end
   ```
2. Register it in the `:tools` config list (where `Echo`/`Now` are): `config :ezagent_plugin_loom, :tools, [...]`. `ToolRegistry.register_all/0` (called from `after_boot/0`) picks it up at boot.
3. The AI learns the tool exists via the page-gen system prompt's tool block (rendered from the registry) — no manual prompt edit needed.
4. Test: `POST /loom/api/:ws/:sid/tool` with `{"name":"weather.current","args":{"city":"上海"}}`. Backend restart required (new module).

Model on `lib/ezagent/tools/now.ex`.

## Add a new agent type to the team (e.g. a `legal` worker theme)

If you just want another *themed* worker, you may not need a new type at all — the two demo workers (`policy`/`company`) differ only by a theme derived from their URI name in `behavior/loom_worker.ex` (`theme_for/1` + `@theme_prompts`). Add a `"legal"` theme there and have `Team.ensure_team/1` spawn a `loomworker_<sid>_legal`.

For a genuinely new *Kind* (different behavior), create the full quadruplet:

1. `lib/ezagent/behavior/loom_<x>.ex` — `use Ezagent.Behavior`, `action(:receive, ...)`, `handle_receive/2`, `state_slice/0`, `init_slice/1`, `data_owner/1`. Copy `loom_worker.ex` as the template; keep the `@mention` loop-guard and the `ref_id`/`mentions` reply shape.
2. `lib/ezagent/entity/loom_<x>.ex` — `@behaviour Ezagent.Kind`; `type_name/0`, `behaviors/0`, `persistence/0` (`:ephemeral` for team members), `supervisor/0`.
3. `lib/ezagent/template/loom_<x>.ex` — `@behaviour Ezagent.Kind.Template`; `template_name/0`, `validate/1` (enforce `entity://agent/<ws>/loom<x>_<name>`), `instantiate/3` via `SpawnRegistry.spawn_detailed/1` returning `{:ok, [uri], %{fresh?: _}}`.
4. `lib/ezagent_plugin_loom/application.ex` — add to all three lists: `behaviors/0`, `template_classes/0`, `agent_flavors/0`.
5. Wire it into `Team.ensure_team/1` so it spawns + joins the session.
6. If the orchestrator should delegate to it, update the orchestrator's decompose/fan-out logic (`behavior/loom_orchestrator.ex`) to `@mention` it.

Compile (`:ezagent_plugin_check` gate will catch a missing piece), then restart.

## Add an SDK bridge endpoint (e.g. `sdk.deleteUpload`)

Two-repo change.

1. **Backend** — add a route in `web_plug.ex` under the SDK section, delegating to a private helper, returning `json_resp(conn, 200, %{ok: ...})`. Follow the `:ws`/`:sid` param convention and the existing `do_*` helper style. If it touches a session, dispatch through the same path as `send_to_session/3`.
2. **Frontend (Desktop repo)** — add the method to `sdk.js` (postMessage client) and handle it in `LoomBridge` (the same-origin fetch). Rebuild + sync (`frontend-and-sdk.md` §3).
3. Document it in `docs/loom/sdk-v2-additions.md` (or a new dated doc).

Backend restart for the route; frontend re-sync + refresh for the client.

## Change an agent's prompt / persona

Prompts live in `lib/ezagent/prompts.ex` (shared: `web_system_prompt/0`, `chat_system_prompt/0`, `page_gen_system_prompt/0`, `persona_line/1`, …) and as `@theme_prompts` / `@default_system_prompt` inside individual Behaviors (e.g. `behavior/loom_worker.ex`). The **Stitch/AiSpot** prompts are separate — `EzagentPluginLoom.Stitch.system_prompt/2` and `aispot_prompt/4` in `lib/ezagent/stitch.ex` (consumed by `behavior/loom_stitch_worker.ex`). Edit the right one; restart. The Stitch/AiSpot prompts incorporate `Knowledge.get(ws, sid)` — the per-session knowledge base is editable from the UI, so persona vs. grounding are separate levers.

## Change the published/share/fork behavior

Read `docs/loom/2026-06-05-shareable-snapshots-and-fork.md` first. The endpoints (`/publish`, `/p/:token/open`, `/snapshot`, `/snapshot/:token`, `/p/:token/fork`) and the stores (`snapshots.ex`, `saved_classes.ex`, `user_schema.ex`, `stitch_chat.ex`) are in play. Keep the invariant: consumer surfaces get a **frozen** base, only `user_schema` ops are layered. A fork that lets a viewer edit *source* would break the model.

## Rebuild & redeploy the frontend

See `frontend-and-sdk.md` §3. Short version: in the Desktop repo (`/mnt/c/Users/ning/Desktop/work/loom`) run `rm -rf .next out && NEXT_PUBLIC_ESR=1 npx next build`, then `rsync -a --delete out/ → priv/static/loom_ui/`, hard-refresh the browser. No backend restart for a pure frontend change. Commit the vendored output only when asked. **WSL caveat:** `node` is Windows `node.exe`, so the env var won't cross the boundary — feed `NEXT_PUBLIC_ESR=1` via a throwaway `.env.production` instead (gotcha #22).

## Switch / debug the LLM backend

- Switch: set `LOOM_LLM_BACKEND=deepseek` (or `claude_code`) in `.env`, restart `phx.server`. Verify with `EzagentPluginLoom.LLM.backend/0` in IEx.
- DeepSeek needs `DEEPSEEK_KEY` in `.env` (memory `project-deepseek-key`).
- ClaudeCode debug: it drives a local `claude` headless via `:exec`. Check the three isolation flags and the stdin prompt path are intact (`gotchas.md` #11–#13). Load `erlexec-elixir`.

## Verify a Loom change end-to-end

Loom is a router-app with a browser frontend — don't "try it and tell me what you see." Drive it from the agent side: start/confirm `mix phx.server` is up on 10042, open `/loom/<ws>/<sid>` headless, exercise the path (send a message → watch the SSE stream → see the orchestrated card). For backend-only logic, prefer a unit/integration test in `apps/ezagent_plugin_loom/test/` over a manual round-trip. A failing manual e2e should earn a regression test.
