# AutoService v2 Full Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the complete AutoService v2 on the `autoservice` base in ONE continuous run (per gagameow: 全量, no stage gates): content plugin → CR publishing → autoservice orchestrator (biphasic customer path) → operator takeover → multi-tenant + roles + admin → live E2E, absorbing PR #715's proven logic by relocation.

**Architecture:** Per `docs/superpowers/specs/2026-06-10-autoservice-v2-design.md` (gagameow, commit 27215ef1, all review fixes in) + `docs/superpowers/specs/2026-06-10-autoservice-phaseB-customer-path-design.md` (customer-path detail). Orchestration = a native `use Ezagent.Lifecycle` Kind in `ezagent_plugin_autoservice` (dispatch + effects; NOT Stage-1's PubSub-observe GenServer). Content (soul/skill/KB/agent-config) = new `ezagent_plugin_content` reading `release/_current`. Publishing = new `ezagent_plugin_cr` (full-sandbox `cp -r` → flip `_current` symlink). UI = LiveViews in plugins, routes in `ezagent_web` (existing pattern).

**Tech Stack:** Elixir umbrella plugins, `use Ezagent.Lifecycle` (NOT `use Ezagent.Behavior` — CI gate), socialware `Behavior.Turn`/`CustomerFeed`/`Settlement`, `MentionRouting` RuleStore, curl_agent (fast deepseek), cc agent (slow claude; per-template model/effort/endpoint via #730), yaml_elixir.

**Base:** branch `feat/autoservice-phaseB-customer-path` off `origin/autoservice`. **Execution style: continuous — no user gates between stages; every task verifies (TDD) before the next.**

**Source-of-truth references** (verified against code, do NOT re-invent):
- Lifecycle contract: `.claude/skills/ezagent-developer/references/lifecycle.md` — `create/1` (persistent state, once-ever), `activate/2` (transients, EVERY start), `handle_<action>/2 → {:ok, result, [effect]}`, `handle_signal/2`; effects `:set`/`:set_transient`/`:dispatch`/`:emit`.
- Turn actions (socialware): `open(%{trigger, opened_at})`, `compose(%{turn_id, result_refs})`, `settle(%{turn_id})`, `claim(%{turn_id, by})` — dispatched as `%Ezagent.Invocation{target: "<session>?action=turn.<a>", mode: :call}`.
- CustomerFeed real API: `topic/1`, `snapshot/2`, `history/2`; delivery = Settlement→CustomerOutbox broadcasts `{:customer_delivery, %{message_ids: …}}` on `CustomerFeed.topic(session)`; subscribers use `Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)`. NO `CustomerFeed.subscribe/deliver/notify`.
- `RuleStore.disable/1` + `enable/1` exist (`ezagent_core/lib/ezagent/routing/rule_store.ex`).
- #715 sources to port: `git show origin/feat/autoservice-cs-stage1:apps/ezagent_plugin_autoservice/lib/...` (socialware_cs.ex, socialware_cs_turn_adapter.ex, customer_live.ex, chat_ui.ex, cinnox_assets.ex, seed task) and `.../priv/cinnox/` (souls, skills, kb incl. ready-made `kb.db` + `kb_search_mcp.py`, fast-deepseek-prompt).
- cc knobs: #730 (`fix/cc-effort-per-template`, commit afe376b6) reads `model`/`effort`/`endpoint` from template_data; #723 (a9c2122d) adds the 2.1.170 dialogs. Cherry-pick BOTH locally for live E2E (they land on main separately).
- curl_agent template fields: `provider`, `api_url`, `model`, `system_prompt`, `max_tokens` in template_data (`apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex`).
- P14: dispatch-only between Kinds (no PubSub to inbound). P22: no silent drop. Three-tier: plugins never import EventLog/SnapshotStore/StateRebuilder/Router internals.

---

## Stage A — `ezagent_plugin_content` (foundation; everything depends on it)

### Task A1: Plugin scaffold

**Files:**
- Create: `apps/ezagent_plugin_content/mix.exs`
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/application.ex`
- Create: `apps/ezagent_plugin_content/test/test_helper.exs`

- [ ] **Step 1: mix.exs** (mirror another plugin's umbrella mix.exs, e.g. curl_agent's; app `:ezagent_plugin_content`; deps: `{:ezagent_core, in_umbrella: true}, {:yaml_elixir, "~> 2.9"}`; `elixirc_paths(:test) = ["lib", "test/support"]`)
- [ ] **Step 2: application.ex** — minimal OTP app following the Plugin contract used by other plugins (copy the shape of `ezagent_plugin_curl_agent/application.ex`; no children initially).
- [ ] **Step 3: test_helper.exs** — `{:ok, _} = Application.ensure_all_started(:ezagent_plugin_content); ExUnit.start()`
- [ ] **Step 4: Verify** `mix compile` clean; `mix test apps/ezagent_plugin_content` runs 0 tests green.
- [ ] **Step 5: Commit** `feat(content): plugin scaffold`

### Task A2: Tenant paths + skeleton assets (relocated from #715)

**Files:**
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant_paths.ex`
- Create: `apps/ezagent_plugin_content/priv/skeleton/` (souls/, skills/, kb/, slots/, config/agents.yaml, fast-deepseek-prompt/)
- Test: `apps/ezagent_plugin_content/test/tenant_paths_test.exs`

- [ ] **Step 1: Port assets.** `git show`-extract every file under `origin/feat/autoservice-cs-stage1:apps/ezagent_plugin_autoservice/priv/cinnox/` into `apps/ezagent_plugin_content/priv/skeleton/` preserving sub-structure (`souls/customer_soul.md`, `skills/`, `flow_chunks/`, `references/`, `kb/` incl. **kb.db + kb_search_mcp.py + query_expansion.py**, `fast-deepseek-prompt/`, `skill-packages/`). Add `slots/customer.yaml` (initial slot values: extract the `default_soul_slot_values` map from #715 `cinnox_assets.ex` into YAML, nested keys, e.g. `identity: {brand_short_name: CINNOX}` / `gate: {escalation_triggers: "转人工, 找真人, 我要人工, 投诉"}` …).
- [ ] **Step 2: agents.yaml** at `priv/skeleton/config/agents.yaml` (master-only; v2 §3.5 shape):
```yaml
fast:
  runtime: curl
  provider: deepseek
  api_url: https://api.deepseek.com/chat/completions
  model: deepseek-v4-flash
  max_tokens: 256
  thinking: disabled
slow:
  runtime: cc
  model: ""            # empty = claude account default; set e.g. deepseek-v4-flash with endpoint below
  endpoint: ""         # e.g. https://api.deepseek.com/anthropic
  effort: low          # measured: high → 1-4 min/reply; low → ~26 s (PR #715)
```
- [ ] **Step 3: TenantPaths** — pure path module:
```elixir
defmodule EzagentPluginContent.TenantPaths do
  @moduledoc "Tenant content roots: sandbox (admin edits) vs release/_current (agents read)."
  def tenant_root(tid), do: Path.join([Ezagent.Home.profile_dir(), "tenants", tid])
  def sandbox_dir(tid), do: Path.join(tenant_root(tid), "sandbox")
  def release_root(tid), do: Path.join(tenant_root(tid), "release")
  def release_dir(tid, n), do: Path.join(release_root(tid), "v#{n}")
  def current_link(tid), do: Path.join(release_root(tid), "_current")
  def current_dir(tid) do
    link = current_link(tid)
    case File.read_link(link) do
      {:ok, target} -> {:ok, Path.expand(target, release_root(tid))}
      {:error, _} -> {:error, :no_release}
    end
  end
  def work_dir(tid, role), do: Path.join([Ezagent.Home.profile_dir(), "tenants", tid, "cc-agents", "#{role}-work"])
  def skeleton_dir, do: Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton")
end
```
- [ ] **Step 4: Test** (tmp EZAGENT_HOME): paths compose; `current_dir` errors with no release; resolves after creating `release/v1` + symlink. Run, green.
- [ ] **Step 5: Commit** `feat(content): tenant paths + cinnox skeleton assets (relocated from #715)`

### Task A3: SoulRenderer (template + slot)

**Files:**
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul_renderer.ex`
- Test: `apps/ezagent_plugin_content/test/soul_renderer_test.exs`

- [ ] **Step 1: failing tests** — render replaces `{{a.b}}` from flattened slot map; missing key keeps literal `{{a.b}}` (unconfigured signal); layers join with `\n\n`; non-string slot values `to_string`ed.
- [ ] **Step 2: implement**:
```elixir
defmodule EzagentPluginContent.SoulRenderer do
  @moduledoc "Render {{key}} templates against flattened slot values (v2 §3.2.2). Missing key → keep {{key}}."
  @slot_re ~r/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/
  def render(layers, slot_values) when is_list(layers),
    do: layers |> Enum.map(&render(&1, slot_values)) |> Enum.join("\n\n")
  def render(template, slot_values) when is_binary(template) and is_map(slot_values) do
    Regex.replace(@slot_re, template, fn whole, key ->
      case Map.fetch(slot_values, key) do
        {:ok, v} -> to_string(v)
        :error -> whole
      end
    end)
  end
  @doc "Flatten nested YAML map to dotted keys: %{\"a\" => %{\"b\" => 1}} → %{\"a.b\" => 1}"
  def flatten(map, prefix \\ "") when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key = if prefix == "", do: to_string(k), else: "#{prefix}.#{k}"
      case v do
        %{} = nested -> Map.merge(acc, flatten(nested, key))
        _ -> Map.put(acc, key, v)
      end
    end)
  end
end
```
- [ ] **Step 3: green + Commit** `feat(content): SoulRenderer (template+slot, missing-key passthrough)`

### Task A4: SkillIndexer

**Files:**
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/skill_indexer.ex`
- Test: `apps/ezagent_plugin_content/test/skill_indexer_test.exs`

- [ ] **Step 1: failing tests** — given a dir with `skills/<group>/<name>/SKILL.md` files having YAML frontmatter `name:`/`description:`, `build/1` returns markdown "## Skill Index" listing `- <name> — <description> (plugins/<tid>/skills/<rel-path>)`; empty dir → "## Skill Index\n(none)".
- [ ] **Step 2: implement** — `Path.wildcard(dir <> "/**/SKILL.md")`, parse frontmatter with a 10-line regex split (`---\n...\n---`), YamlElixir for the block; sort by name.
- [ ] **Step 3: green + Commit** `feat(content): SkillIndexer`

### Task A5: AgentsConfig + TenantContent.provision_context

**Files:**
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/agents_config.ex`
- Create: `apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant_content.ex`
- Test: `apps/ezagent_plugin_content/test/tenant_content_test.exs`

- [ ] **Step 1: AgentsConfig** — `load/0` reads `TenantPaths.skeleton_dir()/config/agents.yaml` (master-only, packaged in priv, NOT tenant-writable — v2 ⑦) via `YamlElixir.read_from_file!`; returns `%{"fast" => map, "slow" => map}`.
- [ ] **Step 2: TenantContent.provision_context(tid, role, opts \\ [])** — `opts[:source]` `:release` (default) | `:sandbox` (admin preview):
```elixir
@spec provision_context(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
# returns %{claude_md:, system_prompt:, agent_config:, work_dir:, kb_db_path: nil | path, skills_dir:}
```
Logic: resolve base dir (`current_dir(tid)` or `sandbox_dir(tid)`); souls = ordered layers `[skeleton souls/customer_soul.md]` + tenant override `<base>/souls/customer.md` if exists; slots = `<base>/slots/<role>.yaml` (missing → `%{}`) flattened; `claude_md` (slow role) = the #715 preamble (port `build_cc_claude_md`'s preamble VERBATIM from `origin/feat/autoservice-cs-stage1:.../cinnox_assets.ex` — the role-based RESPONSE GATE version, lines with "Answer the customer") <> rendered soul <> "\n\n" <> SkillIndexer.build(`<base>/skills`); `system_prompt` (fast role) = render of `<base>/fast-deepseek-prompt/` prompt source (port the prompt-assembly from #715 `prompts.py` usage — read the .md/.py prompt text file as template); `agent_config` = AgentsConfig role map; `kb_db_path` = `<base>/kb/kb.db` if exists.
- [ ] **Step 3: tests** — fixture tenant in tmp: skeleton-only (no release) errors `:no_release`; after fake `release/v1` + `_current`, slow context has gate text + rendered slot + skill index; sandbox source reads sandbox.
- [ ] **Step 4: green + Commit** `feat(content): AgentsConfig + TenantContent.provision_context`

## Stage B — `ezagent_plugin_cr` (publish flow)

### Task B1: Scaffold + CR store

**Files:**
- Create: `apps/ezagent_plugin_cr/mix.exs` (deps: ezagent_core, ezagent_plugin_content in_umbrella), `application.ex`, `test/test_helper.exs`
- Create: `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_store.ex`
- Test: `apps/ezagent_plugin_cr/test/cr_store_test.exs`

- [ ] **Step 1:** scaffold (as A1).
- [ ] **Step 2: CrStore** — one CR per tenant (v2 ⑥, no scope lock/TTL). Persist via `Ezagent.ConfigStore` key `"cr:<tid>"` (body: `%{"cr_id", "status" ("draft"|"published"), "created_by", "published_version", "notes"}`); functions `ensure_active_cr/2` (get-or-create draft), `get/1`, `mark_published/3`. Use the same `ConfigStore.write_and_point` call shape as #715 `cinnox_soul_seed.ex` (port the call, change key/body).
- [ ] **Step 3: tests** green. **Commit** `feat(cr): scaffold + one-CR-per-tenant store`

### Task B2: Lint + Publish (atomic flip)

**Files:**
- Create: `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/lint.ex`
- Create: `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/publisher.ex`
- Test: `apps/ezagent_plugin_cr/test/publisher_test.exs`

- [ ] **Step 1: Lint.run(tid)** (v2 §5.4 R01/R03 minimum): render sandbox soul via TenantContent (source: :sandbox) → collect leftover `{{key}}` (warnings list, not fatal); every `plugins/<tid>/skills/<path>` referenced in the rendered soul exists under sandbox skills (missing → `{:error, {:missing_skill, path}}`). Returns `{:ok, warnings} | {:error, reason}`.
- [ ] **Step 2: Publisher.publish(tid, actor_uri)** — FULL sandbox, build-then-flip (review ⑥):
```elixir
def publish(tid, actor_uri) do
  with {:ok, warnings} <- Lint.run(tid),
       {:ok, cr} <- CrStore.ensure_active_cr(tid, actor_uri),
       n <- next_version(tid),
       vdir <- TenantPaths.release_dir(tid, n),
       :ok <- File.mkdir_p!(TenantPaths.release_root(tid)) |> then(fn _ -> :ok end),
       {:ok, _} <- File.cp_r(TenantPaths.sandbox_dir(tid), vdir),
       :ok <- flip_current(tid, vdir),
       :ok <- CrStore.mark_published(tid, cr["cr_id"], n) do
    {:ok, %{version: n, warnings: warnings}}
  end
end
defp flip_current(tid, vdir) do
  link = TenantPaths.current_link(tid); tmp = link <> ".tmp"
  _ = File.rm(tmp)
  with :ok <- :file.make_symlink(String.to_charlist(vdir), String.to_charlist(tmp)),
       :ok <- :file.rename(tmp, link), do: :ok
end
defp next_version(tid) do
  case File.ls(TenantPaths.release_root(tid)) do
    {:ok, es} -> (es |> Enum.flat_map(fn "v" <> n -> [String.to_integer(n)]; _ -> [] end) |> Enum.max(fn -> 0 end)) + 1
    _ -> 1
  end
end
```
- [ ] **Step 3: TenantInit.init(tid)** (in publisher.ex or own module): `File.cp_r(skeleton_dir, sandbox_dir(tid))` (idempotent: skip if sandbox exists) + `publish(tid, admin)` → v1.
- [ ] **Step 4: tests** — init→v1 `_current` resolves; edit sandbox → publish → v2; missing-skill ref blocks; flip is rename-atomic (tmp link gone).
- [ ] **Step 5: Commit** `feat(cr): lint + full-sandbox publish with atomic _current flip`

## Stage C — `ezagent_plugin_autoservice` (orchestrator + assembly + seed)

### Task C1: Scaffold + ported UI/shared modules

**Files:**
- Create: `apps/ezagent_plugin_autoservice/` (mix.exs deps: ezagent_core, ezagent_domain_socialware, ezagent_domain_instance_message, ezagent_plugin_content, ezagent_plugin_cr, ezagent_plugin_curl_agent, ezagent_plugin_cc — in_umbrella; application.ex; test_helper)
- Create: `lib/ezagent_plugin_autoservice/chat_ui.ex` — **port VERBATIM** from `origin/feat/autoservice-cs-stage1` (already has 我/AI 客服/人工客服 labels for both URI shapes).
- [ ] Verify compile + commit `feat(autoservice): scaffold + ChatUI (ported from #715)`

### Task C2: TurnDriver (corrected v2 §6.6.1 form)

**Files:**
- Create: `lib/ezagent_plugin_autoservice/turn_driver.ex`
- Test: `test/turn_driver_test.exs`

- [ ] **Step 1:** Pure builders + dispatcher (port the dispatch/5 + helpers from #715 `socialware_cs_turn_adapter.ex` §functional-core, dropping the GenServer half):
```elixir
defmodule EzagentPluginAutoservice.TurnDriver do
  @moduledoc "Drive socialware Behavior.Turn via %Invocation{?action=turn.<a>, mode: :call} (v2 §6.6.1)."
  def open(s, trigger, ctx), do: call(s, :open, %{trigger: trigger, opened_at: System.system_time(:millisecond)}, ctx)
  def compose(s, tid, text, ctx), do: call(s, :compose, %{turn_id: tid, result_refs: [%{kind: :chat, text: text}]}, ctx)
  def settle(s, tid, ctx), do: call(s, :settle, %{turn_id: tid}, ctx)
  def claim(s, tid, by, ctx), do: call(s, :claim, %{turn_id: tid, by: by}, ctx)
  defp call(session_uri, action, args, %{caller: caller, caps: caps}) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.#{action}"),
      mode: :call, args: args, ctx: %{caller: caller, caps: caps, reply: :await}
    })
  end
end
```
- [ ] **Step 2:** test against a seeded SocialwareSession (reuse #715's adapter test harness — port `test/.../socialware_cs_turn_adapter_test.exs` setup): open→compose→settle ends `:settled` + message committed customer_visible. Green. **Commit.**

### Task C3: Orchestrator Lifecycle Kind ⚠️ load-bearing

**Files:**
- Create: `lib/ezagent_plugin_autoservice/orchestrator.ex`
- Test: `test/orchestrator_test.exs`

- [ ] **Step 0 (verification spike, 30 min):** Read how routing receivers get `chat.receive` dispatched (`apps/ezagent_domain_instance_message/lib/ezagent/.../routing/` + how the agent entity Kind registers/handles `chat.receive` — `entity/agent.ex`). Determine EXACTLY how a custom Kind registers to accept `?action=chat.receive` (KindRegistry registration + behavior mount vs Lifecycle action naming). Record the answer as a comment atop orchestrator.ex. This is the one unknown; everything else below is verified.
- [ ] **Step 1: failing tests** — handler-level (call `handle_receive/2` directly with a fake ctx exposing `read`):
  - customer msg, no operator → result ok; effects contain `{:set, :open_turn_id, _}` and two `{:dispatch, %Ezagent.Cmd{}}` (fast + slow `chat.receive` fan-out)
  - fast reply → ACK quick-turn driven (TurnDriver mocked via ctx-injected fun or Mox-style module attribute), no `:open_turn_id` change
  - slow reply → compose+settle on `open_turn_id`, effects `{:set, :open_turn_id, nil}`
  - customer msg with `operator_active: true` → Turn.open ONLY (no fan-out dispatches)
  - slow reply with `open_turn_id: nil` → self-heal: open+compose+settle (no crash, P22)
- [ ] **Step 2: implement**:
```elixir
defmodule EzagentPluginAutoservice.Orchestrator do
  use Ezagent.Lifecycle
  # state: session_uri, tenant, customer_uri, fast_uri, slow_uri (strings),
  #        open_turn_id (nil|string), operator_active (bool)
  action :receive, args: %{message: :map}, returns: %{ok: :boolean}, caps: [:receive], modes: [:cast],
    description: "Session hub: customer → Turn.open + fan-out; fast → ACK quick-turn; slow → compose+settle."
  action :operator_claim, args: %{turn_id: :string, operator_uri: :uri}, returns: %{ok: :boolean}, caps: [:operator_claim], modes: [:call],
    description: "Operator takes over: Turn.claim + pause fan-out."
  action :operator_settle, args: %{turn_id: :string}, returns: %{ok: :boolean}, caps: [:operator_settle], modes: [:call],
    description: "Operator done: Turn.settle + resume fan-out."

  def create(args) do
    {:ok, %{session_uri: args.session_uri, tenant: args.tenant, customer_uri: args.customer_uri,
            fast_uri: args.fast_uri, slow_uri: args.slow_uri, open_turn_id: nil, operator_active: false}}
  end
  def activate(_state, _ctx), do: {:ok, %{}}

  def handle_receive(%{message: msg}, ctx) do
    sender = to_string(msg.sender || msg["sender"])
    cond do
      sender == ctx.read.(:customer_uri, nil) -> on_customer(msg, ctx)
      sender == ctx.read.(:fast_uri, nil) -> on_fast_reply(msg, ctx)
      sender == ctx.read.(:slow_uri, nil) -> on_slow_reply(msg, ctx)
      true -> {:ok, %{ok: true}, []}   # operator/self messages: turn machinery handles visibility
    end
  end
  defp on_customer(msg, ctx) do
    session = sess(ctx)
    {:ok, %{turn_id: tid}} = TurnDriver.open(session, %{message_id: msg_id(msg), text: text(msg)}, turn_ctx(ctx))
    fanout = if ctx.read.(:operator_active, false), do: [], else: [agent_cmd(ctx.read.(:fast_uri, nil), msg), agent_cmd(ctx.read.(:slow_uri, nil), msg)]
    {:ok, %{ok: true}, [{:set, :open_turn_id, tid} | fanout]}
  end
  defp on_fast_reply(msg, ctx) do
    session = sess(ctx); tctx = turn_ctx(ctx)
    {:ok, %{turn_id: t}} = TurnDriver.open(session, %{message_id: msg_id(msg), text: "[ack]"}, tctx)
    {:ok, _} = TurnDriver.compose(session, t, text(msg), tctx)
    {:ok, _} = TurnDriver.settle(session, t, tctx)
    {:ok, %{ok: true}, []}
  end
  defp on_slow_reply(msg, ctx) do
    session = sess(ctx); tctx = turn_ctx(ctx)
    tid = ctx.read.(:open_turn_id, nil) ||
            (TurnDriver.open(session, %{message_id: msg_id(msg), text: "[late]"}, tctx) |> elem(1) |> Map.fetch!(:turn_id))
    {:ok, _} = TurnDriver.compose(session, tid, text(msg), tctx)
    {:ok, _} = TurnDriver.settle(session, tid, tctx)
    {:ok, %{ok: true}, [{:set, :open_turn_id, nil}]}
  end
  def handle_operator_claim(%{turn_id: t, operator_uri: op}, ctx) do
    {:ok, _} = TurnDriver.claim(sess(ctx), t, op, turn_ctx(ctx))
    {:ok, %{ok: true}, [{:set, :operator_active, true}]}
  end
  def handle_operator_settle(%{turn_id: t}, ctx) do
    {:ok, _} = TurnDriver.settle(sess(ctx), t, turn_ctx(ctx))
    {:ok, %{ok: true}, [{:set, :operator_active, false}, {:set, :open_turn_id, nil}]}
  end
  defp agent_cmd(agent_uri, msg),
    do: {:dispatch, %Ezagent.Cmd{target: Ezagent.URI.new!("#{agent_uri}?action=chat.receive"), action: :receive, args: %{message: msg}, mode: :cast}}
  # sess/turn_ctx/msg_id/text: small helpers; turn_ctx uses ctx.self_uri + ctx.caps
end
```
(Adjust `%Ezagent.Cmd{}` field shape per the Step-0 spike — match what routing itself builds. TurnDriver mocking in tests: define `@turn_driver Application.compile_env(:ezagent_plugin_autoservice, :turn_driver, TurnDriver)`.)
- [ ] **Step 3:** green; integration: spawn the Kind for a real seeded session, dispatch a customer message, assert turn opened (handler-through-router). **Commit** `feat(autoservice): Orchestrator Lifecycle Kind (dispatch+effects, P14/P22 native)`

> **Operator pause note (deviation from v2 §7.2, rationale in spec §4.1):** with routing → orchestrator, pause = orchestrator's `operator_active` gate (Turn.open still runs — operator sees turns, H2). `RuleStore.disable` of the →orchestrator rule would blind Turn.open; do NOT use it here.

### Task C4: Assembly (provision) + routing install

**Files:**
- Create: `lib/ezagent_plugin_autoservice/assembly.ex`
- Test: `test/assembly_test.exs`

- [ ] **Step 1:** Port #715 `socialware_cs.ex` provision with-chain (`ensure_user_alive → ensure_session → ensure_bot → join → install_routing`), modified:
  - soul/config from `TenantContent.provision_context(tid, "slow")` → write `claude_md` to `TenantPaths.work_dir(tid, "slow")/CLAUDE.md`; cc `Workspace.create_agent(ws, %{flavor: "cc", name: "cs-slow-<customer>", cwd: work_dir, with_pty: false, data: %{"model" => cfg["model"], "effort" => cfg["effort"], "endpoint" => cfg["endpoint"]}}, ctx)` (template_data → #730 reads; empty strings omitted). Wire kb MCP: extend the agent's `.mcp.json` writing (follow how #715's work-dir got `.mcp.json` via McpConfigWriter — ADD `cinnox-kb` server entry `{command: "python3", args: [kb_search_mcp.py], env: {KB_DB_PATH: kb_db_path}}` when `kb_db_path` present; verify McpConfigWriter merge behavior, else write a work-dir `.mcp.json` the cc argv already passes).
  - fast agent: create via curl_agent template (`Workspace.create_agent(ws, %{flavor: "curl", name: "cs-fast-<customer>", data: %{"provider" => cfg["provider"], "api_url" => cfg["api_url"], "model" => cfg["model"], "system_prompt" => system_prompt, "max_tokens" => cfg["max_tokens"]}}, ctx)` — confirm exact flavor string + required fields from `template/curl_agent.ex` `validate/1`).
  - spawn Orchestrator Kind (URI e.g. `entity://<tid>/orchestrator/cs-<customer>` — follow Step-0 registration finding), grant it turn caps on the session (port the caps-grant pattern #715 used for the turn-driving principal).
  - `install_routing`: port #715 `install_routing/4` changing receivers to `[orchestrator_uri]`, matcher `{in_session, session}` only (orchestrator classifies senders — covers agent replies too). KEEP #715's G1-b lesson: seed runs before server OR RPC `RuleStore.load_into_registry` after install (port the comment).
- [ ] **Step 2:** integration test: provision in tmp-home test env → all kinds exist, routing row present, CLAUDE.md contains rendered soul. **Commit** `feat(autoservice): assembly provision (content-fed, biphasic, orchestrator-routed)`

### Task C5: Seed task

**Files:**
- Create: `lib/mix/tasks/ezagent.tenant.seed.ex`

- [ ] Port #715 `seed_autoservice_socialware.ex` VERBATIM-then-modify: params `--tenant cinnox --customer alice`; flow = `CrPublisher.TenantInit.init(tid)` (skeleton→sandbox→release v1) → `Assembly.provision_session(tid, customer)`. Keep ALL #715 absorbed fixes (URI v3 `Ezagent.URI.user/2`, admin caller + `ensure_admin_alive`, `already_exists`=success, `with_pty: false`). Manual verify: `mix ezagent.tenant.seed --tenant cinnox --customer alice` on fresh home boots clean. **Commit** `feat(autoservice): tenant seed (cr-init + provision)`

## Stage D — Customer surface

### Task D1: CustomerLive + route

**Files:**
- Create: `lib/ezagent_plugin_autoservice/customer_live.ex` (port from #715 — keep optimistic echo `my_messages`/`merge_rows`, CustomerFeed-only source, `{:customer_delivery}` handler)
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex` (+ scope, as #715 fix #8), `apps/ezagent_web/mix.exs` (+ dep)

- [ ] Port; change `ensure_joined` to call `Assembly.ensure_joined(customer_uri)` (thin: resolve tenant from workspace, return session). Route `live "/autoservice", CustomerLive` in a `live_session :autoservice_customer` requiring entity (copy #715's router scope verbatim). Compile + `mix test apps/ezagent_plugin_autoservice` green. **Commit** `feat(autoservice): CustomerLive (ported, feed-gated + echo) + /autoservice route`

## Stage E — Operator

### Task E1: OperatorLive (claim/settle via orchestrator)

**Files:**
- Create: `lib/ezagent_plugin_autoservice/operator_live.ex` (port #715 list/select/refresh skeleton)
- Modify: router (`live "/autoservice/operator", OperatorLive` — the route #715 NEVER added; this closes that gap)
- Test: `test/operator_flow_test.exs`

- [ ] **Step 1:** Port list/select (sessions via `MessageStore.recent_in_session` + snapshot list, operator view shows operator_only too — use `MessageStore.recent_in_session`, NOT customer feed). Subscribe `CustomerFeed.topic` for live refresh (P14-OK: outbound delivery topic, the Stage-1-proven pattern).
- [ ] **Step 2:** Replace #715's simplified "send as chat.send" with the REAL takeover: "接管" button → dispatch orchestrator `operator_claim` (`%Invocation{target: "<orch>?action=orchestrator.operator_claim", mode: :call}` — exact action prefix per C3 Step-0 finding) with current open turn_id (from session snapshot turns; expose a `Assembly.open_turn_id(session)` helper reading the session Kind state); compose box → `TurnDriver.compose(session, turn_id, text, operator_ctx)`; "提交" → orchestrator `operator_settle`.
- [ ] **Step 3:** Flow test (operator claims → customer feed hides draft (operator_only); operator settles → visible). Seed an operator user in seed task (`--operator bob` param; role grant per v2 §4.2 operator caps). **Commit** `feat(autoservice): operator takeover (claim/settle via orchestrator gate) + route`

## Stage F — Multi-tenant + roles + admin

### Task F1: Roles (CapBAC, v2 §4)

**Files:**
- Create: `lib/ezagent_plugin_autoservice/roles.ex`
- Test: `test/roles_test.exs`

- [ ] `grant_role(user_uri, role, workspace_uri)` for `:master_admin | :tenant_admin | :operator | :customer` — encode v2 §4.2 cap tuples (master: `:any` scope; tenant_admin: workspace-scoped manage+cr; operator: session claim/settle + read; customer: send on own session). Use the existing caps-grant API (the one #715's creator-Manage-cap fix used — `Ezagent.Identity`/caps grant path; port the call shape). Seed task gains `--admin carol`. Tests: granted caps resolvable via `Ezagent.Identity.list_caps_for/1`. **Commit**

### Task F2: Multi-tenant proof

- [ ] Seed a SECOND tenant end-to-end (`mix ezagent.tenant.seed --tenant acme --customer bob`) — needs only: skeleton copy works per-tid (already path-parameterized), workspace `workspace://acme`, no cross-tenant leakage (test: acme customer feed never returns cinnox messages; routing rows scoped per session). Fix anything tid-hardcoded found (grep `"cinnox"` outside skeleton assets). **Commit** `feat(autoservice): multi-tenant proof (second tenant e2e)`

### Task F3: Admin LVs (soul edit + CR publish + skills list)

**Files:**
- Create: `lib/ezagent_plugin_autoservice/admin/tenant_admin_live.ex`
- Modify: router (`live "/autoservice/admin", TenantAdminLive` under require_entity)

- [ ] One LV, three panels (keep minimal, v2 §8 core): **Soul** — textarea editing `sandbox/souls/customer.md` (load via File, save writes sandbox; tenant_admin cap gated); **Slots** — textarea for `sandbox/slots/customer.yaml` (validate YAML on save); **CR** — show active CR + lint results + [发布] button → `Publisher.publish(tid, admin_uri)`, flash version + warnings; **Skills** — read-only list from SkillIndexer(sandbox). Preview deferred-not-dropped: a [预览渲染] button rendering `provision_context(tid, "slow", source: :sandbox).claude_md` into a `<pre>` (cheap, no preview agent). **Commit** `feat(autoservice): tenant admin LV (soul/slots edit + CR publish + skill list)`

### Task F4: Publish → running-agent refresh

- [ ] On successful publish: re-render + rewrite slow work-dir CLAUDE.md + dispatch cc respawn (use the existing respawn path — `cc.agent.ensure_subprocess_alive` / template respawn action; verify exact call in `template/cc_agent.ex`), and update fast agent's `system_prompt` via the curl template's update/dispatch path (v2 补充澄清: AgentTemplate system_prompt updated by dispatch). Integration test: publish flips soul fact → new CLAUDE.md on disk contains it. **Commit** `feat(autoservice): publish refreshes running agents (slow rewrite+respawn, fast prompt update)`

## Stage G — Full verification + live E2E

### Task G1: Suite + invariants

- [ ] `mix test` per new app + full umbrella compile; `mix format --check-formatted`; run repo invariant greps (CLAUDE.md §不变式自查: no `PubSub.broadcast` on inbound paths in new code, no `use Ezagent.Behavior` in our plugins — `mix ezagent.check_invariants.lifecycle` if present). Fix all red. **Commit** fixes.

### Task G2: Live biphasic E2E + demo recording

- [ ] Local: cherry-pick `a9c2122d` (#723 dialogs) + `afe376b6` (#730 knobs) onto the working branch (they land via main; needed locally for cc JOIN + model/effort). Fresh `EZAGENT_HOME` → `mix ezagent.tenant.seed --tenant cinnox --customer alice --operator bob --admin carol` → server with `CLAUDE_CODE_OAUTH_TOKEN` (macOS workaround; Linux = real target) → browser: alice asks; **expect fast ACK bubble <5s, slow on-brand reply ~30s**; operator bob claims+settles one turn; admin carol edits a slot → publish → next session reflects it. Record with the `recording-demo-videos` skill scripts (extend record-customer.js: assert TWO left bubbles per question — ACK + main). Verify by reading PNGs. **Commit** demo assets + findings update.

---

## Self-review (done at write time)
- Spec coverage: v2 §2 plugin split (A1-C1), §3 soul/slot/skill/KB+agents.yaml (A2-A5), §5 CR (B1-B2, full-sandbox per ⑥), §6 customer biphasic + Turn + feed (C2-C4, D1), §6.5 work dirs (A2/C4), §7 operator (E1, orchestrator-gate deviation documented), §4 roles (F1), multi-tenant (F2), §8 admin core (F3) + publish-refresh (F4, 补充澄清), E2E (G). Deferred WITH note: loom front-end (v2 D1 defers it too), preview agent (F3 renders inline instead), KB admin UI (kb.db ships ready-made; rebuild UI when needed).
- Placeholders: none — every step has code, exact port source (`git show origin/feat/autoservice-cs-stage1:<path>`), or a bounded verification spike with exact file pointers (C3 Step-0, C4 mcp merge, E1 action prefix).
- Type consistency: TurnDriver ctx `%{caller, caps}` used by orchestrator `turn_ctx`; provision_context return map keys match C4/F4 consumers; TenantPaths used by content/cr/assembly consistently.
