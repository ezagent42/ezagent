# How-to recipes (common contributor tasks)

## How-to: add a new plugin

1. Create OTP app under `apps/ezagent_plugin_<name>/` with standard Mix layout. (Tier 3.)
2. Add `:ezagent_core` (always) + any `:ezagent_domain_*` you depend on as `in_umbrella` deps in `mix.exs`.
3. Implement `EzagentPlugin<Name>.Application` with `start/2`:
   - Register Behaviors on EXISTING core Kinds: `Ezagent.BehaviorRegistry.register(kind_module, action, behavior_module)`. Do NOT introduce a new top-level URI scheme (SPEC v2 §5.8 / invariants 8 + 11).
   - Register spawn fns (only if your plugin contributes a new sub-type under an existing scheme — usually no): `Ezagent.SpawnRegistry.register(scheme, fn uri -> ... end)`. The SpawnRegistry co-registers with `Ezagent.URI.SchemeRegistry`.
   - Register Template Classes (if any): `Ezagent.TemplateRegistry.register(class_module)`
   - Declare routing tables: `Ezagent.RoutingRegistry.declare_table(name, opts)`
4. If the plugin spawns sessions, call `Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)` after `SpawnRegistry.spawn` to plumb workspace scope (invariant 4).
5. Test via `mix ezagent.plugin.install /path/to/plugin` against running Ezagent (invariant 8).

Pre-built examples:
- `apps/ezagent_plugin_echo/` (smallest reference plugin)
- `apps/ezagent_plugin_feishu/` (canonical "external integration" — registers `FeishuReceive` on User Kind, no owned scheme)
- `apps/ezagent_plugin_cc/` (canonical "agent flavor" — adds `cc.agent` Template Class; agents live under `entity://agent/<workspace>/cc_<name>`)

## How-to: add a Kind

1. Create `apps/<your_domain_or_plugin>/lib/<your>/entity/<your_kind>.ex`. New first-class Kinds usually go in `domain_*`; plugin-specific agent flavors live in their plugin app.
2. Implement `@behaviour Ezagent.Kind` with three callbacks:
   - `type_name/0 → :your_kind` (snake atom; appears in cap `kind` field)
   - `behaviors/0 → [Ezagent.Behavior.X, ...]` (what `init_slice` runs at boot; per-Kind `BehaviorRegistry.register` decides what actions dispatch)
   - `persistence/0 → :ephemeral | :on_terminate | {:snapshot, :on_change}`
3. The URI shape is fixed by SPEC v3 §5.15: `<scheme>://<type>/<workspace>/<name>` for per-tenant schemes. If your Kind is a new entity sub-kind, that's a parser allowlist change (rare — `entity://`'s axis is the closed set `{user, agent}`). More commonly: your Kind extends an existing scheme's type axis via free-form name prefix (agent flavor) or is a Behavior on an existing Kind (plugin side-channel).
4. **Implement `holds_cap?/2`** (PR-CC-2-v2 chokepoint callback — 2026-05-25): given the caller URI + the action's `required_caps/0` list, return `:ok` or `{:error, :unauthorized}`. The dispatch step 5.5 calls this; do NOT cap-check elsewhere.
5. If your Kind carries an Identity slice for caps, document the `init_slice/1` args shape (typically `%{initial_caps: MapSet.t()}`).

Reference Kinds:
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` (Agent — most complex)
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` (Session — typical container)
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` (Template Kind)

## How-to: add a Behavior

1. Create `apps/<your_domain_or_plugin>/lib/<your>/behavior/<your_behavior>.ex`.
2. `@behaviour Ezagent.Behavior`.
3. Implement `state_slice/0`, `init_slice/1`, `interface/0` (action schema), `invoke/4`.
4. **Implement `required_caps/0`** (PR-CC-2-v2 — 2026-05-25): return `%{action_atom => [cap_template, ...]}` — the per-action cap requirements consulted at dispatch step 5.5. Returning `%{}` means "no cap required" (dispatchable to anyone; reserved for read-only public actions).
5. Optional: `workspace_scoped?/0 → boolean` (dispatch step 5.6 — workspace isolation enforcement; defaults to `true` for per-tenant Kinds).
6. Register per-Kind in the plugin's `register_<X>_behaviors()`:
   `:ok = BehaviorRegistry.register(SomeKind, :action, YourBehavior)`.
7. Actions are dispatched via `?action=<your_behavior_dot_form>.<action>` per SPEC v2 §5.2. The behavior dot-form is what `interface/0` returns (e.g. `:chat` → `?action=chat.send`).

**Multi-action Behaviors and the action-axis limitation**: per docs/futures/todo.md "Capability struct lacks an action axis", `Capability` matches on kind+behavior+instance+workspace — NOT on action. Any holder of cap-on-Behavior holds all of the Behavior's actions. **Workaround until SPEC lands**: carve privileged actions into their own Behavior module (PR #356 pattern — `WorkspaceUserAdmin` for privileged `:create_user`, separate from generic `Workspace`).

Reference: `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` (most complex, well-commented).

## How-to: add a Template Class

1. Module implementing `@behaviour Ezagent.Kind.Template` with callbacks:
   - `template_name/0 → "your.class.name"` (stable string id; PR-D2 collapsed cc.pty + cc.channel_instance into `cc.agent` — current canonical name for cc plugin templates)
   - `validate/1 → :ok | {:error, _}` (pre-persist schema check; optional, default `:ok`)
   - `instantiate/3` → effectful spawn of one or more Kinds; **must be idempotent** (re-call on already-spawned returns same URIs)
2. Register at plugin boot: `:ok = Ezagent.TemplateRegistry.register(YourTemplateClass)`.
3. If your Template Class spawns sessions, call `Ezagent.WorkspaceRegistry.bind/2` for each spawned session URI (invariant 4) — `Ezagent.Workspace.Loader.invoke_template` does this for the canonical session classes; custom Template Classes follow the same pattern.
4. Per SPEC v2 §5.14: the AgentTemplate carries `kind_module` (the Behavior to use for instantiated agents). `Ezagent.AgentTypeRegistry` (PR #131) has been DELETED — the Template owns kind_module wiring directly.
5. **If your Template Class orchestrates spawning multiple Kinds** (e.g. a Generator-like flow that wires up several agents + routing rules + caps), follow the **reconciler pattern** — NOT a saga with `cleanup_partial`. The canonical reference is `Ezagent.Workspace.Loader.load_one/1` + `invoke_template/2`: idempotent re-run, `{:already_started, _}` → no-op, `fresh?`-gated bind, errors logged not raised. Use per-Kind idempotency helpers (`Agent.spawn_fresh/4`, `WorkspaceRegistry.bind_if_fresh/2`, `AgentLineage.record_if_fresh/3`, `RuleStore.upsert_by_logical_key/5`). See `docs/notes/2026-05-23-generator-reconciler-retrospective.md` for the post-mortem of why a saga over N stores is the wrong abstraction.

Reference: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (current cc.agent class) + `apps/ezagent_domain_chat/lib/ezagent/template/generic_session.ex` (Session class) + `apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex` (the canonical reconciler reference for multi-Kind orchestration).

## How-to: add a routing rule

Two paths:

- **Programmatic (test / runtime)**: `Ezagent.Routing.RuleStore.add(table_name, matcher, receivers, granted_by, opts)` then `RuleStore.load_into_registry(table_name)`.
- **LV / CLI (admin)**: `/admin/routing` form (unified per Allen's S-9 — Scope picker for global/workspace/session), or `mix ezagent.routing.add_rule`.

Always pass `workspace_uri:` opt unless the rule is intentionally global (matches messages from any workspace). Per SPEC v2 §5.4: scope hierarchy is `global ⊂ workspace ⊂ session`. Rules compose additively at dispatch time.

## How-to: write an ExternalMirror adapter + binding

Three modules + one declaration. The Domain owns everything else.

1. **Allow Behavior** (per-adapter cap subject) — `apps/ezagent_plugin_<name>/lib/ezagent/behavior/external_adapter/<name>/allow.ex`:
   ```elixir
   defmodule Ezagent.Behavior.ExternalAdapter.MyName.Allow do
     @behaviour Ezagent.Behavior
     @impl true; def actions, do: [:allow_myname]
     @impl true; def cap_subjects, do: [{:allow_myname, "Authorize binding myname adapter."}]
     @impl true; def dispatchable?, do: false       # cap-only — never dispatched
     @impl true; def state_slice, do: :external_adapter_myname
     @impl true; def init_slice(_), do: %{}
     @impl true; def invoke(_, _, _, _), do: raise("cap-only — Check 2 only consumer")
     @impl true; def interface, do: %{}
     @impl true; def data_owner(_), do: :any
   end
   ```

2. **Adapter** (stateless module) — `apps/ezagent_plugin_<name>/lib/ezagent/external_mirror/<name>_adapter.ex`:
   ```elixir
   defmodule Ezagent.Plugin.MyName.Adapter do
     @behaviour Ezagent.ExternalMirror.Adapter
     @impl true; def adapter_id, do: "myname"
     @impl true; def display_name, do: "My Name"
     @impl true; def description, do: "Mirror sessions to My Name."
     @impl true; def binding_module, do: Ezagent.Plugin.MyName.Binding
     @impl true; def cap_subject,
       do: %{behavior_module: Ezagent.Behavior.ExternalAdapter.MyName.Allow, description: "…"}
     @impl true
     def target_ownership_check(%URI{} = caller, target_id) do
       # External API call ALLOWED here. Re-entry to Ezagent.Invocation.dispatch
       # is FORBIDDEN — runs inside a Task with bounded timeout (default 5s).
       case MyName.API.is_member?(caller, target_id) do
         true -> :ok
         false -> {:error, :not_a_member}
       end
     end
     @impl true
     def event_to_payload(%Ezagent.Publisher.Event{} = event) do
       # PURE function — runs inside the Worker Kind quantum.
       # Returning :skip drops this event without publishing.
       {:publish, %{text: serialize(event)}}
     end
   end
   ```

3. **Binding** (stateful per-target GenServer-callbacks) — `apps/ezagent_plugin_<name>/lib/ezagent/external_mirror/<name>_binding.ex`:
   ```elixir
   defmodule Ezagent.Plugin.MyName.Binding do
     @behaviour Ezagent.ExternalMirror.Binding
     @impl true; def adapter_module, do: Ezagent.Plugin.MyName.Adapter
     @impl true
     def init({target_id, _adapter, opts}) do
       # External setup (open WS, fetch token). Synchronous IS OK here —
       # it runs in the Worker Kind's post_init handle_continue.
       state = %{target_id: target_id, token: MyName.API.token(opts)}
       {:ok, state}
     end
     @impl true
     def publish(payload, state) do
       # All transport I/O goes here. Return shapes (SPEC §2.3):
       #   {:ok, new_state}                — success
       #   {:error, reason, new_state}     — RECOVERABLE failure
       #   raise/throw                     — UNrecoverable invariant
       #     violation; let-it-crash → PerBindingSupervisor 3/30s
       #     budget catches it.
       # NEVER call Phoenix.PubSub.subscribe from this module —
       # invariant 16 grep gate.
       case MyName.API.send(state.token, state.target_id, payload) do
         :ok -> {:ok, state}
         {:error, reason} -> {:error, reason, state}
       end
     end
     @impl true
     def terminate(_reason, _state), do: :ok
   end
   ```

4. **Declare in plugin** — `apps/ezagent_plugin_<name>/lib/ezagent_plugin_<name>.ex`:
   ```elixir
   defmodule EzagentPluginMyName do
     use Ezagent.Plugin
     @impl true; def plugin_info, do: %{slug: "my_name", …}
     @impl true; def adapters, do: [{Ezagent.Plugin.MyName.Adapter, Ezagent.Plugin.MyName.Binding}]
   end
   ```

5. **Verify** — `mix ezagent.external_mirror.list_adapters --as user://your_admin` should list "myname"; `mix ezagent.external_mirror.bind --as <user> --session <session_uri> --adapter myname --target <id>` should succeed against a real target the caller is a member of.

Reference: `apps/ezagent_plugin_feishu/lib/ezagent_plugin_feishu/external_mirror/feishu_chat_adapter.ex` + `feishu_chat_binding.ex` (PR-EM-6 — production reference) + SPEC §2.2 / §2.3 / §5.

## How-to: write an invariant test

Pattern (see `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs` for the canonical example):

1. **`use EzagentCore.DataCase, async: false`** (the test exercises persistence + dispatch + sandbox semantics)
2. Spawn the production setup (`Ezagent.SpawnRegistry.spawn(uri)`, `WorkspaceRegistry.bind`, `RuleStore.add` etc.) — not mock objects
3. Drive the production code path (`Ezagent.Invocation.dispatch`) — not direct function calls
4. Assert via observable side-effects (audit log `invocations` table, `messages` table, message_routings table) — not internal slice state
5. Name the test file `<invariant>_test.exs` so it's discoverable; tag `:slow` if it spawns OS subprocesses

The invariant test is what stops a future PR from re-breaking the architectural rule. Phrase the failure message so a future debugger immediately understands what was violated. Memory `feedback_completion_requires_invariant_test`: "done" claims require a test that fails when the goal is unmet.

## How-to: install a new plugin into running Ezagent (no phx restart)

`mix ezagent.plugin.install /path/to/your_plugin_otp_app`

Caveats:
- `Mix.env()` returns BUILD-time env (use `System.get_env("MIX_ENV")` if env-sensitive)
- Plugin unload is NOT supported (Decision #142). To remove a plugin, restart phx after deleting its OTP app from the umbrella.
