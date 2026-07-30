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

### The three gates a new plugin app trips (verified 2026-07-29, `ezagent_plugin_forgejo`)

**`mix test apps/ezagent_plugin_<name>/test` cannot see any of these.** A new plugin
went 41/41 green on its own suite while `mix ci.fast` exited 2 with four reds. Run
`mix ci.fast` (`timeout: 300000`) before believing a new plugin app is done.

| Gate | Symptom | Fix |
|---|---|---|
| `Invariants.AllPluginAppsWiredToWebTest` | "these plugin apps exist under apps/ but are NOT wired into apps/ezagent_web/mix.exs deps" | Add `{:ezagent_plugin_<name>, in_umbrella: true}` to `apps/ezagent_web/mix.exs` `defp deps`. Without it the plugin's `Application.start/2` **never runs at web boot** — `Ezagent.Plugin.boot/1` never fires, nothing registers, and call sites get `:no_kind_module_for_agent`. (A genuinely-unwired plugin uses `# plugin-wire-exempt: <reason>`.) |
| `Invariants.PluginWorkspaceLocalityContractTest` (A) and (B) | your file enumerated with `atomic_ownership_access - :unknown_value.<field>/0` | You wrote non-assertive access: `def store(command)` then `command.credential_ref`. **Destructure in the function head** (`def store(%{credential_ref: ref})`). Both enumerators go quiet and the code follows the documented Elixir idiom — this is the fix, not a baseline entry. |
| `Architecture.CrossFileDuplicateFnTest` | `measured N, cap N-1` after mirroring a sibling plugin | Mirroring an existing plugin file-for-file is exactly what this ratchet is for. Prefer making the bodies genuinely different over `# arch-cap-bump:` — the head-destructuring fix above did it on its own. Reach for the bump only when the duplication is deliberate and argued. |

Ordering note: fix the enumerators **before** re-measuring the duplicate ratchet —
rewriting accessors changes function bodies, so the duplicate count moves too.
Doing it in the other order wastes a cap-bump argument on debt that was about to
disappear.

CI shards need **no** manifest edit: the bare `apps/ezagent_plugin_` catch-all in
`ci_shards.exs` auto-absorbs new plugin apps.

Two more, verified 2026-07-30 on the same plugin:

- **Ecto query bindings trip (A)/(B) too.** `from(r in Schema, where: r.id == ^id)`
  enumerates as `:unknown_value.id/0` — the enumerator cannot see through a query
  binding any more than through a bare variable. Use keyword syntax instead:
  `from(Schema, where: [id: ^id, version: ^v])`, and `Repo.get/2` + struct
  destructuring instead of `select: r.field`. Semantics are unchanged (both
  columns still land in the WHERE clause), so re-run any mutation check you were
  relying on to confirm the guard is still load-bearing.
- **A `config/config.exs` edit forces a full recompile, which surfaces latent
  missing deps.** Removing one plugin's config block turned
  `Architecture.CompilerDeadCodeGateTest` red with a warning in a completely
  unrelated app: `ezagent_plugin_git_workflow`'s `test/support` calls
  `EzagentPluginGithub.GitHubAppJwt` without declaring the dep, and
  `git_workflow` sorts **before** `github`, so the reference only resolved while a
  stale beam happened to be on the path. `UndeclaredUmbrellaDepTest` does not
  cover `test/support`. Fix = declare the dep (check for a cycle first); do not
  reach for `apply/3`, which trades this for a dynamic-receiver violation.

Pre-built examples:
- `apps/ezagent_plugin_echo/` (smallest reference plugin)
- `apps/ezagent_plugin_feishu/` (canonical "external integration" — registers `FeishuReceive` on User Kind, no owned scheme)
- `apps/ezagent_plugin_cc/` (canonical "agent flavor" — adds `cc.agent` Template Class; agents live under `entity://agent/<workspace>/cc_<name>`)

## How-to: add a Kind

1. Create `apps/<your_domain_or_plugin>/lib/<your>/entity/<your_kind>.ex`. New first-class Kinds usually go in `domain_*`; plugin-specific agent flavors live in their plugin app.
2. Implement `@behaviour Ezagent.Kind` with three callbacks:
   - `type_name/0 → :your_kind` (snake atom; appears in cap `kind` field)
   - `behaviors/0 → [Ezagent.ActionSet.X, ...]` (what `init_slice` runs at boot; per-Kind `BehaviorRegistry.register` decides what actions dispatch)
   - `persistence/0 → :ephemeral | :on_terminate | {:snapshot, :on_change}`
3. The URI shape is fixed by SPEC v3 §5.15 (Amendment 2, **workspace-first**): `<scheme>://<workspace>/<type>/<name>` for per-tenant schemes (authoritative `uri.ex` `per_tenant(scheme, workspace, type, name)`). If your Kind is a new entity sub-kind, that's a parser allowlist change (rare — `entity://`'s axis is the closed set `{user, agent}`). More commonly: your Kind extends an existing scheme's type axis via free-form name prefix (agent flavor) or is a Behavior on an existing Kind (plugin side-channel).
4. **`holds_cap?/2` is OPTIONAL** (PR-CC-2-v2 chokepoint callback — 2026-05-25). Signature: `holds_cap?(entity_uri, needed :: Capability.t()) :: boolean()`. Override only for Kind-specific bypass (e.g. `:system` caller). Otherwise leave it out — `Ezagent.Kind.default_holds_cap?/2` reads caps via `Ezagent.Identity.list_caps_for/1` and tests with `Capability.matches?/2`. The dispatch step 5.5 calls `Ezagent.Kind.holds_cap?/3` (the dispatcher) — do NOT cap-check elsewhere.
5. If your Kind carries an Identity slice for caps, document the `init_slice/1` args shape (typically `%{initial_caps: MapSet.t()}`).

Reference Kinds:
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` (Agent — most complex)
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` (Session — typical container)
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` (Template Kind)

## How-to: add a Behavior

**Post-2026-05-28 — new contract (SPEC PR #445, Phase 1-4 complete).** Use this recipe for all greenfield Behaviors. The legacy `invoke/4` recipe below is kept only for git archaeology — `Behavior.invoke/4` is `@optional_callbacks` post Phase 3 (PR #464) and no production path consults it.

1. Read `references/new-contract.md` first — the 9-effect vocabulary, the `action/3` macro grammar, and the bucket execution order are normative.
2. Create `apps/<your_domain_or_plugin>/lib/<your>/behavior/<your_behavior>.ex`.
3. `use Ezagent.ActionSet` (opts into the new contract — injects `action/3` macro + `@before_compile` invariants + derived `actions/0` / `interface/0` / `required_caps/0` / `cap_subjects/0`).
4. Declare each action with the `action/3` macro:

   ```elixir
   action :send,
     args:        %{message: Ezagent.Message},      # validated by InterfaceValidator
     returns:     %{stored: :boolean},
     caps:        [:send],                          # default [action_name]
     modes:       [:cast],                          # default [:call]
     description: "Post a message into the session and fan it out to members"
   ```

5. Implement `state_slice/0` + `init_slice/1` (slice ownership stays; framework manages reads via `ctx[:read]`).
6. Implement `def handle_<action>(args, ctx)` for **every** declared action (compile-time check raises CompileError otherwise). Return `{:ok, result, [effect]}`:

   ```elixir
   def handle_send(%{message: msg}, ctx) do
     {:ok, %{stored: true},
      [
        {:set, :last_message_id, msg.id},
        {:notify, "session:#{ctx[:self_uri]}:events", {:chat_message, msg}},
        {:dispatch, %Ezagent.Cmd{target: recipient, action: :receive, args: %{message: msg}, ctx: %{caller: ctx[:self_uri]}}},
        {:emit, :message_sent, %{recipient: recipient}}
      ]}
   end
   ```

7. Register per-Kind in the plugin's `register_<X>_behaviors()`:
   `:ok = BehaviorRegistry.register(SomeKind, :action, YourBehavior)`. The new-contract Behavior is fully back-compat with the legacy `BehaviorRegistry` API — the macro auto-derives `actions/0` etc.
8. Actions still dispatched via `?action=<behavior_dot_form>.<action>` per SPEC v2 §5.2 (URI form unchanged); internally Router translates to `%Cmd{target, action}` and routes to your `handle_<action>/2`.

**Multi-action Behaviors and the action-axis limitation**: per docs/futures/todo.md "Capability struct lacks an action axis", `Capability` matches on kind+behavior+instance+workspace — NOT on action. Any holder of cap-on-Behavior holds all of the Behavior's actions. The new `caps: [list]` per-action declaration captures multi-cap intent (SPEC HIGH-7 closure) but the underlying `Capability.matches?/2` axes are unchanged. **Workaround until SPEC lands**: carve privileged actions into their own Behavior module (PR #356 pattern — `WorkspaceUserAdmin` for privileged `:create_user`, separate from generic `Workspace`).

**Result-dependent in-handler dispatch**: if you need the dispatch return value (e.g. `ReadMarker.mark` only after successful chat.receive cast), call `Ezagent.Router.dispatch/1` directly from inside the handler body — the `{:dispatch, _}` effect discards return values. See `Ezagent.ActionSet.Chat.handle_send/2` for the canonical example.

Reference: `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` (most complex new-contract Behavior, well-commented).

### Legacy — `@behaviour Ezagent.ActionSet` + `invoke/4` (HISTORICAL, do NOT use for new code)

Pre-2026-05-28 Behaviors implemented `@behaviour Ezagent.ActionSet` + module attribute `@interface` + `invoke(action, slice, args, ctx)` callback. Phase 3 (PR #464) deleted `LegacyBehaviorAdapter` and retired the `invoke/4` callback to `@optional_callbacks`. **No runtime path consults `invoke/4` post-Phase 3.** If you find a Behavior still using `invoke/4`, it's a Phase 2 migration leftover — open a PR migrating it to the new contract. The legacy callback declaration is kept in `Ezagent.ActionSet` purely to surface CompileError on stale references (rather than silent dispatch failure).

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
   defmodule Ezagent.ActionSet.ExternalAdapter.MyName.Allow do
     @behaviour Ezagent.ActionSet
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
       do: %{behavior_module: Ezagent.ActionSet.ExternalAdapter.MyName.Allow, description: "…"}
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

## How-to: check a Kind is alive / ensure it's started — from a plugin (task #95)

Plugins NEVER call `Ezagent.KindRegistry`/`Ezagent.SpawnRegistry` directly (architecture-invariants #22). Use the owner-gated facade `Ezagent.LocalRuntime`:

```elixir
# liveness probe (replaces `case KindRegistry.lookup(uri) do {:ok,_}->true; :error->false end`)
if Ezagent.LocalRuntime.kind_alive?(agent_uri), do: ...

# ensure started (replaces SpawnRegistry.spawn)
case Ezagent.LocalRuntime.ensure_started(agent_uri) do
  {:ok, _pid} -> :ok
  {:error, reason} -> ...   # incl. {:not_workspace_owner, ...} on a non-owner node
end

# need to know fresh-vs-already-running (replaces SpawnRegistry.spawn_detailed)
case Ezagent.LocalRuntime.ensure_started_detailed(agent_uri) do
  {:ok, :started, _pid} -> ...        # freshly spawned (do first-time setup, e.g. workspace bind)
  {:ok, :already_started, _pid} -> :ok
  {:error, reason} -> ...
end
```

Single-node these behave exactly like the old direct calls (the owner gate is a no-op when the local node owns the workspace); on a future multi-node deployment they return `false` / `{:error, {:not_workspace_owner, …}}` for a foreign-owned Kind instead of silently mis-reading the local registry. Do NOT add the agent's URI to any allowlist — only genuine read-only-pid probes / sidecar IPC stay allowlisted.
