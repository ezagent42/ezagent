# hello → 标准 socialware substrate + 框架 routing table (B'-direct) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (+ `ezagent-socialware` for Task 3-6) — without them it writes stale Elixir and violates invariants.

**Goal:** Migrate `ezagent_plugin_hello` off its bespoke imperative team-build onto the standard socialware substrate — a declarative `Definition.roles` team materialized by the framework, inbound delivered via the framework routing table, per-message decision + orchestrator→member handoff kept in the orchestrator's Elixir — and close the human-only + loop-safety gaps.

**Architecture:** hello's session already is a `public_view` versioned `SessionTemplate` whose sole chat member is a `hello.orchestrator` role × `"hello"` flavor agent; builder/concierge are identity-only agents the orchestrator drives directly via `Generator`/`TurnDriver` (admin-genesis chokepoint). B'-direct makes the TEAM declarative (`Definition.roles`, materialized by `TemplateTeam.materialize_template_team`), addresses members by `role_name` (not the `orch_`/`hello_`/`concierge_` URI convention), moves `HelloOrchestrator` onto the flavor's `instance_behaviors` (Definition.roles drops `recipe.behaviors`), formalizes inbound→orchestrator as a `Definition.routing_rules` entry, and adds a loop/multi-agent guard. The orchestrator→member hop stays in-process (NOT the routing table — the default rule's `$session_users` would leak the internal relay to public feeds).

**Tech Stack:** Elixir/OTP, `use Ezagent.Lifecycle` behaviors, `Ezagent.Socialware.Definition`, `Ezagent.Routing` (RuleStore/Resolver/Receiver), ExUnit (`EzagentCore.DataCase`).

**Spec:** `docs/superpowers/specs/2026-07-06-hello-socialware-substrate-and-routing-table-design.md`

## Global Constraints

- **No core/domain changes.** Everything lands in `apps/ezagent_plugin_hello` + (Task 5) the hello-specific web channel. Do NOT touch `orchestrator.ex:94`, `definition.ex`, `template_team.ex`, `resolver.ex`, or any `ezagent_core`/`ezagent_domain_*` module. If a task seems to need one, STOP and flag it (grill culture — pause → Allen).
- **Principle 1:** agent type = role × flavor on `Ezagent.Entity.Agent`; never a new Kind.
- **CjkLiteralGate:** no Han characters in `apps/ezagent_plugin_hello/lib/**/*.ex` string literals (comments/moduledocs are fine).
- **P14 dispatch-only:** cross-Kind only via `Ezagent.Router.dispatch/1` / `Ezagent.Invocation.dispatch/1`; never `PubSub.broadcast` to an inbound topic.
- **Definition field is `roles`, NOT `agents`** — `%{role_name, fill: :agent, recipe, flavor}`. Passing `agents:`/`members:` → `{:retired_socialware_definition_field, _}` (`definition.ex:313-321`).
- **`Definition.roles` materialize drops `recipe.behaviors`** (`recipe_materializer.ex:68-74`) — a member's active behavior MUST come from its flavor's `instance_behaviors`.
- **Never commit `config/dev.exs`.** Commit messages end `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Gate:** each task ends green on `mix precommit` scoped to the touched app (`mix cmd --app ezagent_plugin_hello mix test` + `mix format --check-formatted`); the full `mix precommit` + `mix ezagent.check_invariants` is the final Task 7 gate.
- **Test env note:** boot-seeded roles/definitions are NOT visible in the `DataCase` sandbox — tests must seed roles/definitions in `setup` (see existing `test/integration/hello_page_e2e_test.exs`).

---

## File Structure

- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex` — MODIFY: add the loop/multi-agent guard (`route/3` gains a "should route?" predicate). Owns routing policy.
- `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_orchestrator.ex` — MODIFY: pass the managed-member set to the guard; fix the moduledoc's now-true loop claim.
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex` — MODIFY: `"hello"` flavor gains `instance_behaviors` incl. `HelloOrchestrator`.
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex` — MODIFY: declarative team in `seed_hello_definition` (`roles` + inbound `routing_rules`); create path materializes the team via the standard path; member addressing by `role_name` (new `member_uri_by_role/2`); retire the imperative `ensure_orchestrator`/`ensure_session_*` convention spawns.
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/members.ex` — CREATE: `role_uri/2` helper resolving a session member URI by `role_name` (replaces the `orch_`/`hello_`/`concierge_` convention helpers).
- `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex` — MODIFY: address the orchestrator by `role_name` (or drop the mention and rely on the inbound routing rule) instead of the `orch_<name>` convention.
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex` — MODIFY: migration re-points existing hello sessions to the versioned template + declarative team.
- Tests under `apps/ezagent_plugin_hello/test/` — one per task.

---

## Task 1: Loop + multi-agent guard in the orchestrator router

Isolated, highest-value, no substrate change. The current `Router.route/3` acts on EVERY delivered message (the moduledoc claims "only USER-sender messages" but the code has no such check) — a latent loop, and it rejects nothing so it also can't distinguish external agents. Add a guard: **ignore messages whose sender is the orchestrator itself or one of its own builder/concierge members; route everything else** (users → owner-check+intent; external agents → non-owner → concierge).

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_orchestrator.ex:53-64`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs`

**Interfaces:**
- Consumes: `EzagentPluginHello.App.builder_uri/1`, `App.concierge_uri/1`, `App.orchestrator_uri/1` (current convention helpers — still present until Task 5).
- Produces: `Router.should_route?(session_uri, sender)  :: boolean` (pure-ish; reads only the three self/member URIs), and `Router.route/3` early-returns `:ignored` when `should_route?` is false.

- [ ] **Step 1: Write the failing test**

Add to `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs`:

```elixir
describe "should_route?/2 (loop + multi-agent guard)" do
  setup do
    session = Ezagent.URI.session("system", :hello, "guard-demo")
    %{session: session}
  end

  test "ignores the orchestrator's own outbound", %{session: session} do
    self_uri = EzagentPluginHello.App.orchestrator_uri(session)
    refute EzagentPluginHello.Router.should_route?(session, self_uri)
  end

  test "ignores its own builder member", %{session: session} do
    refute EzagentPluginHello.Router.should_route?(session, EzagentPluginHello.App.builder_uri(session))
  end

  test "ignores its own concierge member", %{session: session} do
    refute EzagentPluginHello.Router.should_route?(session, EzagentPluginHello.App.concierge_uri(session))
  end

  test "routes a user message", %{session: session} do
    user = Ezagent.URI.user("system", "admin")
    assert EzagentPluginHello.Router.should_route?(session, user)
  end

  test "routes an EXTERNAL agent message (multi-agent, not human-only)", %{session: session} do
    external = Ezagent.URI.entity("system", :agent, "some-other-agent")
    assert EzagentPluginHello.Router.should_route?(session, external)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/router_test.exs -o "should_route"`
Expected: FAIL — `should_route?/2` undefined.

- [ ] **Step 3: Implement the guard**

In `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex`, add `should_route?/2` and gate `route/3` on it:

```elixir
  @doc """
  Loop + multi-agent guard. Route a message UNLESS its sender is the
  orchestrator itself or one of its own managed members (builder / concierge) —
  those are the orchestrator's OWN workers, whose output must never re-route
  (loop). Every other sender — a user OR an external agent — IS routed, which is
  how the orchestrator accepts more than human messages.
  """
  @spec should_route?(URI.t(), URI.t()) :: boolean()
  def should_route?(%URI{} = session_uri, %URI{} = sender) do
    own =
      MapSet.new([
        URI.to_string(App.orchestrator_uri(session_uri)),
        URI.to_string(App.builder_uri(session_uri)),
        URI.to_string(App.concierge_uri(session_uri))
      ])

    not MapSet.member?(own, URI.to_string(sender))
  end
```

And wrap the body of `route/3` (`router.ex:30-42`) so it no-ops when the guard fails:

```elixir
  def route(%URI{} = session_uri, user_text, %URI{} = sender) when is_binary(user_text) do
    if should_route?(session_uri, sender) do
      Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
        case decide(owner?(session_uri, sender), user_text) do
          :builder ->
            _ = App.ensure_session_builder(session_uri)
            Generator.generate(session_uri, user_text)

          :concierge ->
            _ = App.ensure_session_concierge(session_uri)
            Generator.concierge_answer(session_uri, user_text, App.concierge_uri(session_uri))
        end
      end)
    else
      :ignored
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/router_test.exs`
Expected: PASS.

- [ ] **Step 5: Correct the orchestrator moduledoc claim (now true)**

In `hello_orchestrator.ex`, the moduledoc currently says loop-safety comes from `Agent.Receive` dropping own outbound + "the Router only acts on USER-sender messages." Replace that sentence with the accurate mechanism:

```elixir
  Loop-safe + multi-agent by construction: `Agent.Receive` drops the agent's own
  outbound before delivery, and `EzagentPluginHello.Router.should_route?/2`
  additionally ignores any message whose sender is the orchestrator itself or one
  of its own builder/concierge members — so the orchestrator routes every OTHER
  sender (users AND external agents) without ever re-routing its own workers.
```

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex \
        apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_orchestrator.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs
git commit -m "fix(hello): loop + multi-agent guard in the orchestrator router

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Move `HelloOrchestrator` onto the `"hello"` flavor's `instance_behaviors`

The declarative team (Task 4) materializes the orchestrator via `Definition.roles`, which drops `recipe.behaviors`. So the orchestrator's `:hello_sync_result` action must be in the FLAVOR's instance behavior set, not only the role recipe. Add `instance_behaviors` to the `"hello"` flavor. (Union with the recipe path is harmless while both coexist during Tasks 2-4.)

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:95-106`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Entity.Agent.base_behaviors/0`, `Ezagent.ActionSet.HelloOrchestrator`.
- Produces: the `"hello"` flavor decl now carries `instance_behaviors: (-> [module()])` returning `base ++ [HelloOrchestrator]`.

- [ ] **Step 1: Write the failing test**

Add to `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`:

```elixir
test "hello flavor instance_behaviors includes HelloOrchestrator" do
  [decl] = EzagentPluginHello.Application.agent_flavors()
  assert decl.flavor == "hello"
  assert is_function(decl.instance_behaviors, 0)
  assert Ezagent.ActionSet.HelloOrchestrator in decl.instance_behaviors.()
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/registration_test.exs -o "instance_behaviors"`
Expected: FAIL — no `:instance_behaviors` key (current decl omits it → `decl.instance_behaviors` is `nil`/KeyError).

- [ ] **Step 3: Add `instance_behaviors` to the hello flavor**

In `application.ex`, update the `agent_flavors/0` decl:

```elixir
  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "hello",
        kind: Ezagent.Entity.Agent,
        instance_behaviors: fn ->
          Ezagent.Entity.Agent.base_behaviors() ++ [Ezagent.ActionSet.HelloOrchestrator]
        end,
        template_class: EzagentPluginHello.Template.HelloAgent,
        bridge_adapter: EzagentPluginHello.BridgeAdapter,
        cap_policy: &EzagentPluginNative.CapPolicy.for_recipe/1
      }
    ]
  end
```

(If `Ezagent.Entity.Agent.base_behaviors/0` is not the exact name, first `grep -n "def base_behaviors" apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` — the py flavor uses `AgentKind.base_behaviors()` where `AgentKind = Ezagent.Entity.Agent`, confirmed in `apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:108`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/registration_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs
git commit -m "feat(hello): carry HelloOrchestrator on the hello flavor instance_behaviors

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Declare the team + inbound routing rule in the hello Definition

Replace the empty `roles: []` / `routing_rules: []` in `seed_hello_definition/2` with the declared team (orchestrator × `"hello"`, builder × `"native"`, concierge × `"native"`) and an inbound `{:always} → {:role, "orchestrator"}` rule. This is SHAPE-only at seed time; recipe existence + materialization are validated at session-create (Task 4).

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:237-260` (`seed_hello_definition/2`)
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Socialware.Definition.new/1` (validates `roles`/`routing_rules`), the role recipe names `"hello.orchestrator"`/`"hello.builder"`/`"hello.concierge"` (`Application.roles/0`).
- Produces: the seeded hello Definition map now has `roles: [3 slots]` + `routing_rules: [1 map]`; `Definition.new/1` returns `{:ok, %Definition{}}` for it.

- [ ] **Step 1: Write the failing test**

Add to `registration_test.exs`:

```elixir
test "hello Definition declares the orchestrator/builder/concierge roles + inbound rule" do
  attrs = EzagentPluginHello.App.hello_definition_attrs("hello-demo")
  {:ok, defn} = Ezagent.Socialware.Definition.new(attrs)

  role_names = Enum.map(defn.roles, & &1.role_name) |> Enum.sort()
  assert role_names == ["builder", "concierge", "orchestrator"]
  assert Enum.all?(defn.roles, &(&1.fill == :agent))
  assert Enum.find(defn.roles, &(&1.role_name == "orchestrator")).flavor == "hello"

  assert [rule] = defn.routing_rules
  assert (rule[:receivers] || rule["receivers"]) == ["orchestrator"]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/registration_test.exs -o "declares the orchestrator"`
Expected: FAIL — `hello_definition_attrs/1` undefined.

- [ ] **Step 3: Extract the Definition attrs + declare the team**

In `app.ex`, extract the Definition map into a public `hello_definition_attrs/1` (so it is testable) and have `seed_hello_definition/2` seed it:

```elixir
  @doc "The hello socialware Definition attrs for a given socialware name (testable)."
  @spec hello_definition_attrs(String.t()) :: map()
  def hello_definition_attrs(name) when is_binary(name) do
    %{
      name: name,
      bases: [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Publisher.SessionImpl
      ],
      shape: [
        Ezagent.ActionSet.Turn,
        Ezagent.ActionSet.Surface
      ],
      roles: [
        %{role_name: "orchestrator", fill: :agent, recipe: "hello.orchestrator", flavor: "hello"},
        %{role_name: "builder", fill: :agent, recipe: "hello.builder", flavor: "native"},
        %{role_name: "concierge", fill: :agent, recipe: "hello.concierge", flavor: "native"}
      ],
      routing_rules: [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => ["orchestrator"],
          "rule_set" => "default",
          "position" => 0
        }
      ],
      prompt_templates: %{},
      legends: %{},
      adapters: [%{adapter_id: "external_feed", role: :customer, config: %{}}],
      visibility_policy: %{publish_policy: :auto, web_anon_access: true},
      owner_policy: %{type: :installer}
    }
  end

  defp seed_hello_definition(ws, name) do
    DefinitionRegistry.seed_definition_if_absent(
      hello_definition_attrs(name),
      workspace_uri: Ezagent.URI.workspace(ws),
      actor_uri: User.admin_uri()
    )
  end
```

Note: `routing_rules` entries use string keys (`"matcher"`/`"receivers"`) — that is the shape `install_one_rule/5` reads (`Map.get(rule, :matcher) || Map.get(rule, "matcher")`, `template_team.ex`) and `Matcher.from_json/1` parses `%{"type" => "always"}`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/registration_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs
git commit -m "feat(hello): declare orchestrator/builder/concierge team + inbound rule in the Definition

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Materialize the declared team via the standard path (retire imperative spawn)

Switch `ensure_app/3` so the session's team comes from `Definition.roles` materialization (the framework `TemplateTeam.materialize_template_team` path, which spawns+joins each `fill: :agent` role and grants recipe caps) instead of the imperative `ensure_orchestrator` + on-demand `ensure_session_*`. Members now get PLANNED URIs with a `role_name` facet — so introduce `EzagentPluginHello.Members.role_uri/2` to resolve a member by role, replacing the `orch_`/`hello_`/`concierge_` convention.

> **Read first (10 min, do not skip):** `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex:8-52` (the materialize entry) and how `Installation.install_template_installs/4` (already called at `app.ex:76`) relates to it. Confirm whether installing the hello Definition triggers `materialize_template_team`, or whether `ensure_app` must call it explicitly after `system_set_working_copy`. The socialware standard create path (`Ezagent.Workspace.create_session/3`, `workspace.ex:818`; `SessionCreator.create_session/3`, `session_creator.ex:125`) runs it; hello's `Ezagent.Kind.spawn(Session, …)` path may not. Implement whichever wiring the code actually requires — do NOT modify `template_team.ex` itself (core/domain).

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/members.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex` (retire `ensure_orchestrator`/`ensure_session_orchestrator`/`ensure_session_builder`/`ensure_session_concierge`/`create_role_agent`/`join_as`; call the standard team materialization)
- Test: `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs` (extend the existing E2E setup)

**Interfaces:**
- Consumes: `Ezagent.Behavior.Session.Members.role_name_to_uri/2` (`members.ex:83-86`) or `Ezagent.Kind.get_slice(session_uri, :members)`; the materialization entry confirmed in the read step.
- Produces:
  - `EzagentPluginHello.Members.role_uri(session_uri, role_name :: String.t()) :: {:ok, URI.t()} | :error` — resolves a joined member's URI by its `role_name` facet.
  - `App.ensure_app/3` returns `{:ok, session_uri, orchestrator_uri}` where `orchestrator_uri` is resolved via `Members.role_uri(session_uri, "orchestrator")` (NOT the `orch_` convention).

- [ ] **Step 1: Write the failing test (member resolution by role)**

Create `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/members_test.exs`. Use the existing E2E setup pattern (seed roles + Definition in `setup` — copy from `test/integration/hello_page_e2e_test.exs`). Then:

```elixir
test "role_uri resolves a joined member by role_name", %{ws: ws} do
  {:ok, session_uri, orch_uri} = EzagentPluginHello.App.ensure_app(ws, "members-demo", defer_orchestrator: false)

  assert {:ok, ^orch_uri} = EzagentPluginHello.Members.role_uri(session_uri, "orchestrator")
  assert {:ok, %URI{}} = EzagentPluginHello.Members.role_uri(session_uri, "builder")
  assert {:ok, %URI{}} = EzagentPluginHello.Members.role_uri(session_uri, "concierge")
  assert :error = EzagentPluginHello.Members.role_uri(session_uri, "nope")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/members_test.exs`
Expected: FAIL — `EzagentPluginHello.Members` undefined (and, pre-Step-3, `ensure_app` does not join builder/concierge as members).

- [ ] **Step 3: Implement `Members.role_uri/2`**

```elixir
defmodule EzagentPluginHello.Members do
  @moduledoc """
  Resolve a hello session member URI by its `role_name` facet. Replaces the old
  `orch_`/`hello_`/`concierge_` URI-prefix convention now that members are
  spawned by the framework `Definition.roles` materialization with PLANNED URIs.
  """

  @spec role_uri(URI.t(), String.t()) :: {:ok, URI.t()} | :error
  def role_uri(%URI{} = session_uri, role_name) when is_binary(role_name) do
    case Ezagent.Kind.get_slice(session_uri, :members) do
      {:ok, members} when is_map(members) ->
        case Ezagent.Behavior.Session.Members.role_name_to_uri(members, role_name) do
          %URI{} = uri -> {:ok, uri}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
```

(In the read step, confirm the members-slice key + that `Ezagent.Behavior.Session.Members` is the accessible module name in this build — `grep -rn "def role_name_to_uri" apps/`. If the members slice is not readable via `get_slice/2`, use the same read path `existing_member_for_role/2` uses in `definition_agents.ex:353-373`.)

- [ ] **Step 4: Rewire `ensure_app/3` to materialize the declared team**

Per the read-step finding, replace the imperative `ensure_orchestrator(...)` tail of `ensure_app/3` with the standard team materialization, and resolve the orchestrator URI by role. Delete `ensure_orchestrator/4`, `ensure_session_orchestrator/1`, `ensure_session_builder/1`, `ensure_session_concierge/1`, `create_role_agent/4`, `join_as/3`, and the `orchestrator_uri/1`/`builder_uri/1`/`concierge_uri/1` convention helpers (callers switch to `Members.role_uri/2` in this task + Task 5). The `ensure_app/3` tail becomes:

```elixir
      # Team is DECLARED in the hello Definition (roles: orchestrator/builder/
      # concierge) and materialized by the framework standard path — no imperative
      # per-role spawn. <wire per the read-step finding: either it already ran via
      # install_template_installs, or call the confirmed materialize entry here.>
      {:ok, orch_uri} = EzagentPluginHello.Members.role_uri(session_uri, "orchestrator")
      {:ok, session_uri, orch_uri}
```

Also update `Router.route/3` (Task 1) + `Router`'s `App.concierge_uri`/`ensure_session_*` calls to use `Members.role_uri/2` (builder/concierge are now always-materialized members, so `ensure_session_*` is gone):

```elixir
        :builder ->
          Generator.generate(session_uri, user_text)

        :concierge ->
          {:ok, concierge_uri} = EzagentPluginHello.Members.role_uri(session_uri, "concierge")
          Generator.concierge_answer(session_uri, user_text, concierge_uri)
```

And update `Router.should_route?/2` to build its "own members" set from `Members.role_uri/2` instead of the deleted convention helpers.

- [ ] **Step 5: Run the member + E2E tests**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/members_test.exs test/integration/hello_page_e2e_test.exs`
Expected: PASS (E2E may need its setup updated to seed the three roles + Definition — do so).

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/members.ex \
        apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex \
        apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/members_test.exs \
        apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs
git commit -m "feat(hello): materialize the team via Definition.roles; resolve members by role_name

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Address the orchestrator by role from the web channel

The web `SessionFeedChannel.dispatch_post/3` mentions `orchestrator_uri(session_uri)` computed as `orch_<name>` (`session_feed_channel.ex:352-379`). With planned URIs that convention is dead. Switch it to resolve the orchestrator by `role_name` (via `EzagentPluginHello.Members.role_uri/2`), keeping `Message.sender = principal` so the downstream owner-check + `from_user?` semantics hold.

> **Read first:** `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:279-379` (the `maybe_adapter_post/4` → `dispatch_post/3` path + `orchestrator_uri/1`/`hello_agent_uri/2`). Confirm this channel is hello-specific (safe to depend on `EzagentPluginHello.Members`) — it is under `ezagent_web` socialware and already references the `orch_` hello convention, so it already couples to hello.

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex:352-379`
- Test: `apps/ezagent_plugin_hello/test/integration/hello_orchestrator_delivery_test.exs` (extend — it already covers orchestrator delivery)

**Interfaces:**
- Consumes: `EzagentPluginHello.Members.role_uri/2` (Task 4).
- Produces: `dispatch_post/3` mentions the role-resolved orchestrator URI; `sender` stays `principal`.

- [ ] **Step 1: Write the failing test**

Extend `hello_orchestrator_delivery_test.exs` to assert a posted user message reaches the role-materialized orchestrator (not a convention URI). Copy the delivery-assertion pattern already in that file; key assertion:

```elixir
{:ok, orch_uri} = EzagentPluginHello.Members.role_uri(session_uri, "orchestrator")
# after dispatch_post, assert the orchestrator (orch_uri) received the message
# via the existing delivery-capture mechanism in this test file.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/integration/hello_orchestrator_delivery_test.exs`
Expected: FAIL — orchestrator now has a planned URI; the web's `orch_<name>` mention targets a non-existent agent, so delivery misses.

- [ ] **Step 3: Resolve the orchestrator by role in the channel**

Replace `dispatch_post/3`'s convention mention + `orchestrator_uri/1`/`hello_agent_uri/2` helpers:

```elixir
  defp dispatch_post(session_uri, %URI{} = principal, text) do
    mentions =
      case EzagentPluginHello.Members.role_uri(session_uri, "orchestrator") do
        {:ok, orch_uri} -> [orch_uri]
        :error -> []
      end

    msg = Ezagent.Message.new(principal, %{text: text, attachments: []}, mentions: mentions)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :send),
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: principal, reply: :ignore}
    })
  end
```

(The inbound `Definition.routing_rules` `{:always} → {:role,"orchestrator"}` from Task 3 is the belt to this mention's suspenders: even with `mentions: []`, the rule delivers to the orchestrator.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix cmd --app ezagent_plugin_hello mix test test/integration/hello_orchestrator_delivery_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex \
        apps/ezagent_plugin_hello/test/integration/hello_orchestrator_delivery_test.exs
git commit -m "feat(hello): address the orchestrator by role_name from the web channel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Migration of existing hello sessions + versioning/migrate wiring

Existing live hello sessions (e.g. `session://system/hello/v3`) were built the old imperative way (single `orch_<name>` member, no declarative team). Update `migrate.ex` to re-point each to the versioned template + declarative team, and document/verify `migrate_session`.

> **Read first:** `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex` (current `migrate_all/0`/`migrate_one`), and `Ezagent.Orchestrator.Tools.Migration.migrate_session/2` (the framework re-pin, resumable ledger). Decide per session: rebuild vs `migrate_session` to the new versioned template. Do NOT drive the live node with raw RPC (`No hacks against the live node` — operate via a `mix ezagent.*` task / sanctioned dispatch).

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/migrate_test.exs` (create)

**Interfaces:**
- Consumes: `App.ensure_app/3` (idempotent, now declarative), `EzagentPluginHello.Members.role_uri/2`, `Ezagent.Orchestrator.Tools.Migration.migrate_session/2`.
- Produces: `Migrate.migrate_all/0` brings every existing hello session to the declarative team (idempotent), resolvable via `Members.role_uri/2`.

- [ ] **Step 1: Write the failing test**

Create `migrate_test.exs`: seed roles+Definition, spawn a pre-B' session shape (single orchestrator member with a convention-style URI, or an old snapshot), run `Migrate.migrate_all/0`, assert afterward `Members.role_uri(session, "builder")` and `"concierge"` resolve (declarative team present).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/migrate_test.exs`
Expected: FAIL — migration does not yet materialize the declarative team.

- [ ] **Step 3: Implement the migration**

Per the read-step decision, implement `migrate_one` to (idempotently) ensure the declarative team + versioned-template binding for each session (reuse `ensure_app/3`'s materialization path or `migrate_session/2`). Keep it idempotent (re-run safe).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/migrate_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/migrate_test.exs
git commit -m "feat(hello): migrate existing sessions to the declarative team + versioned template

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Full-suite gate + e2e acceptance

**Files:**
- Modify (if needed): any test setup revealed by the full suite.
- Test: the whole `ezagent_plugin_hello` suite + invariants.

- [ ] **Step 1: Run the hello suite**

Run: `mix cmd --app ezagent_plugin_hello mix test`
Expected: PASS. Fix any setup regressions (roles/Definition seeding in `setup`).

- [ ] **Step 2: Format + full precommit**

Run: `mix format apps/ezagent_plugin_hello/lib/**/*.ex apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex && mix precommit`
Expected: PASS (compile --warnings-as-errors + format + full test).

- [ ] **Step 3: Invariants**

Run: `mix ezagent.check_invariants`
Expected: PASS. (Watch: CjkLiteralGate on hello `.ex` string literals; no `PubSub.broadcast` to inbound; plugin does not import core internals.)

- [ ] **Step 4: E2E acceptance (per spec §验收)**

Manually or via the E2E test, confirm on a live/isolated stack:
1. owner "改标题" → page updates via builder→TurnDriver (Surface put_version).
2. visitor same message → concierge read-only reply, **page unchanged**.
3. external agent message → orchestrator routes it (not human-only rejected).
4. no loop — builder/concierge output does not re-route (guard).
5. `migrate_session` re-points an existing session to the new versioned template.

- [ ] **Step 5: Final commit (if any fixups)**

```bash
git add -A -- apps/ezagent_plugin_hello apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex
git commit -m "test(hello): green full suite + invariants for B'-direct substrate migration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Definition.roles declarative team → Task 3 (declare) + Task 4 (materialize). ✅
- HelloOrchestrator on flavor instance_behaviors → Task 2. ✅
- Inbound via routing table → Task 3 (rule) + Task 5 (web addresses by role). ✅
- orchestrator→member direct handoff (NOT table) → unchanged; Task 1/4 keep the in-process `Generator` path. ✅
- Loop + multi-agent guard → Task 1. ✅
- builder/concierge identity-only, no new flavor → Task 3/4 (native flavor, dormant behaviors). ✅
- Versioning/migrate + live migration → Task 6. ✅
- No core changes → Global Constraints + Task 4/6 read-first "do not modify core" notes. ✅
- Gate (precommit + invariants) → Task 7. ✅

**Known front-loaded discovery (honest):** Tasks 4 and 6 begin with a mandated read step because the exact wiring of the standard team-materialization into hello's `Kind.spawn` create path, and the rebuild-vs-`migrate_session` choice, depend on internal APIs (`template_team.ex`, `Migration.migrate_session/2`) whose exact composition must be confirmed against the live code before writing the final glue — writing that glue blind would fabricate. Each read step names the exact file:line and forbids editing core.

**Type consistency:** `Members.role_uri/2 :: {:ok, URI.t()} | :error` used consistently in Tasks 4/5/6; `Router.should_route?/2 :: boolean()` in Task 1/4; Definition `roles` slots `%{role_name, fill: :agent, recipe, flavor}` in Task 3 match `role_slot/1` (`definition.ex:249-309`).
