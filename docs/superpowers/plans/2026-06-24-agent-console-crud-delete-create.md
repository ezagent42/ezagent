# Agent Console CRUD — Delete + Create-hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Pass `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` to every subagent that touches Elixir.

**Goal:** Add the **Delete** verb (the missing D) and harden **Create/Read** to the demonstrable anti-demo bar, on the existing #905 `world` agent surface. **Update (edit config) is DEFERRED** — it is blocked on @黄佳佳's config-read contract answer and not in this plan.

**Architecture:** Extend the #905 React island + LiveView dispatch. Each mutation routes through an existing cap-checked domain primitive via `Ezagent.Invocation.dispatch/1` (never a synthesized cap, never a direct GenServer poke), mirroring the `dispatch_agent_create` + `push_agent_create_error` no-silent-drop template. The bound-session delete gate composes two existing reads (`KindRegistry.list_all/0` + `Orchestrator.session_member_uris/1`) into a session-domain helper.

**Tech Stack:** Elixir/OTP (ezagent umbrella), Phoenix LiveView (`world_live.ex`), React/TSX island (`Identities.tsx` + `main.tsx`), shadcn-shaped components, ExUnit. Tests run with `POSTGRES_PORT=5432`.

## Global Constraints

- **Additive only.** No new top-level route family, no nav redesign. Touch only the world identities/agents surface + ONE session-domain read helper.
- **Dispatch-only between Kinds (Invariant #1 / P14).** Delete dispatches `Manage.:delete` through `Ezagent.Invocation.dispatch/1`. No `PubSub.broadcast`, no direct GenServer call.
- **Per-mutation real cap (no-unowned-caps).** Delete is authorized by the operator's held `current_caps` (the creator manage-cap `cap(:any, Manage, :any, instance)`). Never synthesize a cap. `ctx.caps` is the authorizer.
- **No silent drops (Invariant #9).** Every failure path (cap denial, bound-session, bad URI) surfaces an operator-facing message via the same `world:state` re-push the create-error path uses. Returning `:ok` while nothing happened is a defect.
- **DoD is pinned to backend state, not rendered UI.** Delete is done only when `KindRegistry.lookup/1` returns not-found after the action; Create's regression test asserts the URI is in `list_entities`. A row vanishing / a form rendering is NOT proof.
- **Bound-session helper placement is pending @黄佳佳** (discussion item #3). This plan puts it in the session domain (per P9: "reads session data → session domain"); it is a read-only composition of existing primitives, reversible if 黄佳佳 prefers another home. Flag it in the PR; do not block on it.
- **Update/edit-config is OUT of this plan** (deferred to 黄佳佳's config-read contract). Do not add an edit form, an `agents.update` clause, or any `apply_config_delta` wiring here.
- shadcn token classes already defined at the top of `Identities.tsx` — reuse them; do not introduce a new style system.
- Register the world in-flight row (`docs/guide/world-coordination.md` §5) as Task 0.

---

### Task 0: Register world in-flight work + branch hygiene

**Files:**
- Modify: `docs/guide/world-coordination.md` (§5 in-flight registry — add one row)

- [ ] **Step 1:** Append a row to the §5 in-flight registry: branch `feat/agent-console-crud`, owner (this task), surface "identities/agents CRUD — Delete + Create-hardening", status in-flight.
- [ ] **Step 2:** Commit. `git add docs/guide/world-coordination.md && git commit -m "docs(world): register agent-console-crud in-flight"`

---

### Task 1: Read/live-status verification (no production code)

This is the Phase-1 "verify, fix only if broken" gate. Recon confirmed `agent_detail` already reads live status (`Domain.Agent.lifecycle_status/1` + `AgentBridge.Registry`); the `unknown` seen in #905 stills was a genuinely not-running agent (`:not_found`), not a placeholder bug.

**Files:** none (verification only; evidence captured at execution time).

- [ ] **Step 1:** With a LIVE agent (one present in `KindRegistry`), open its detail page and confirm Phase shows a live value (e.g. `alive`/`registered`), not literal `unknown`. Capture an agent-browser screenshot as evidence.
- [ ] **Step 2:** If (and only if) a live agent shows literal `unknown`, STOP and escalate — that would be a real bug needing a separate fix task. Otherwise record "live-status verified, no code change" in the ledger.

---

### Task 2: Create anti-stub regression test (the C demonstrable gate)

The create path already works (`dispatch_agent_create` → `Workspace.create_agent/3`). What #904 lacked was a structural test that **fails if create is stubbed**. Add a test asserting a created agent appears in `list_entities/2`.

**Files:**
- Test: `apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.World.IdentityData.list_entities(workspace_uri, "agents")` → `[%{"uri" => ..., ...}]`; `Ezagent.Workspace.create_agent/3`.

- [ ] **Step 1: Write the failing test.** Create an agent (flavor `echo`, fresh name) via the same path the dispatch uses (`Ezagent.Workspace.create_agent/3` with a caller ctx holding workspace-create authority), then assert its URI string is present in `IdentityData.list_entities(workspace_uri, "agents") |> Enum.map(& &1["uri"])`. (Follow `ezagent-developer` test setup; use the workspace/admin caps fixtures already used by world tests.)
- [ ] **Step 2: Run it — confirm it passes** (create already works), proving the gate is wired to real state. If it fails, the create→list path is broken — fix before proceeding. Run: `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_create_appears_in_list_test.exs`
- [ ] **Step 3:** Add a second assertion in the same file: a `cc` create with empty `cwd` returns `{:error, :cwd_required_for_cc}` (the failure path is real, no silent success).
- [ ] **Step 4: Commit.** `feat(world): anti-stub regression — created agent appears in agents list`

---

### Task 3: Session-domain helper — `agent_bound_to_live_session?/1`

The delete gate must block deleting an agent that is a member of any live session. No single primitive answers "is this agent in ANY live session?"; compose the two that exist.

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex` (add public fn near `session_member_uris/1`, line ~496)
- Test: `apps/ezagent_domain_session/test/ezagent/entity/session/orchestrator_bound_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.KindRegistry.list_all/0` (returns `[{uri_str, pid}]`), `session_member_uris/1` (`%URI{} -> [URI.t()]`), `Ezagent.URI.parse/1`.
- Produces: `agent_bound_to_live_session?(%URI{}) :: boolean` — true iff the agent URI is a member of at least one live `session://` Kind.

- [ ] **Step 1: Write the failing test.** Spawn a live session, add an agent URI as a member; assert `agent_bound_to_live_session?(agent_uri) == true`; assert a non-member agent URI returns `false`; assert with no live sessions it returns `false`. (Use existing session+orchestrator test fixtures in this app.)
- [ ] **Step 2: Run — verify it fails** (function undefined). `POSTGRES_PORT=5432 mix test apps/ezagent_domain_session/test/ezagent/entity/session/orchestrator_bound_test.exs`
- [ ] **Step 3: Implement.**

```elixir
@doc """
True iff `agent_uri` is a member of at least one LIVE session.

Composition of two existing reads (no new storage): enumerate live
`session://` Kinds from the registry, union their members. Placement in the
session domain follows P9 (reads session data → session domain); pending
@黄佳佳 confirm (discussion item #3, reversible). O(N sessions × M members) —
acceptable for the current scale; index later if it shows up in profiling.
"""
@spec agent_bound_to_live_session?(URI.t()) :: boolean()
def agent_bound_to_live_session?(%URI{} = agent_uri) do
  agent_str = URI.to_string(agent_uri)

  Ezagent.KindRegistry.list_all()
  |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "session://") end)
  |> Enum.any?(fn {session_uri_str, _pid} ->
    case Ezagent.URI.parse(session_uri_str) do
      {:ok, session_uri} ->
        session_uri
        |> session_member_uris()
        |> Enum.any?(fn m -> to_string(m) == agent_str end)

      _ ->
        false
    end
  end)
end
```

- [ ] **Step 4: Run — verify it passes.** Same command as Step 2.
- [ ] **Step 5: Commit.** `feat(session): agent_bound_to_live_session? — compose registry + members (delete gate)`

---

### Task 4: world dispatch — `agents.delete` clause + gate + no-silent-drop error

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` (add a `handle_event` clause near line 209; add `dispatch_agent_delete/2` + `push_agent_action_error/2` near the create helpers, line ~367-425)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/agent_delete_dispatch_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.Invocation.dispatch/1`, `Ezagent.URI.with_action/3`, `Ezagent.Entity.Session.Orchestrator.agent_bound_to_live_session?/1` (Task 3), `Ezagent.KindRegistry.lookup/1`, `parse_agent_uri/1` (already in this module), the `state_for_route/3` + `push_event("world:state", state)` re-push used by `push_agent_create_error`.

- [ ] **Step 1: Write the failing test.** Three cases, asserting BACKEND state (not just status string):
  - **happy:** create a live `echo` agent (not in any session), dispatch `agents.delete` with the operator's manage-cap in `current_caps`; assert dispatch returns ok AND `wait_until(fn -> Ezagent.KindRegistry.lookup(agent_uri_str) == :error end)` (destroy is async/detached — poll, don't assume immediate).
  - **cap denial:** dispatch delete with empty caps; assert no destroy happened (`KindRegistry.lookup` still found) AND `last_dispatch_status` starts with `"error:"`.
  - **bound:** make the agent a member of a live session; dispatch delete; assert the agent is STILL alive (not destroyed) AND the error surfaces.
- [ ] **Step 2: Run — verify it fails** (no `agents.delete` clause). `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_delete_dispatch_test.exs`
- [ ] **Step 3: Add the handle_event clause** (near line 209, after the `agents.create` clause):

```elixir
def handle_event(
      "world:dispatch",
      %{"action" => "agents.delete", "args" => %{"agent_uri" => agent_uri_str}},
      socket
    ) do
  dispatch_agent_delete(socket, agent_uri_str)
end
```

- [ ] **Step 4: Add the dispatch helper + error push** (near the create helpers):

```elixir
defp dispatch_agent_delete(socket, agent_uri_str) when is_binary(agent_uri_str) do
  caller = socket.assigns.current_entity_uri
  caps = Map.get(socket.assigns, :current_caps, MapSet.new())

  with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
       false <- Ezagent.Entity.Session.Orchestrator.agent_bound_to_live_session?(agent_uri),
       target = Ezagent.URI.with_action(agent_uri, :manage, :delete),
       {:ok, %{deleted: true}} <-
         Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
         }) do
    {:noreply,
     socket
     |> assign(:last_dispatch_status, "ok")
     |> push_navigate(to: "/identities/agents")}
  else
    true ->
      {:noreply, push_agent_action_error(socket, :agent_bound_to_live_session)}

    :error ->
      {:noreply, push_agent_action_error(socket, :invalid_agent_uri)}

    {:error, reason} ->
      {:noreply, push_agent_action_error(socket, reason)}
  end
end

defp dispatch_agent_delete(socket, _), do: {:noreply, push_agent_action_error(socket, :invalid_agent)}

# No silent drop: re-push the agents list state with an operator-facing error
# via the same world:state channel the route uses (mirrors push_agent_create_error).
defp push_agent_action_error(socket, reason) do
  route = Ezagent.World.Routes.route_for(%{}, "/identities/agents")
  layout = socket.assigns.world_state["layout"]
  state = state_for_route(route, socket, layout)
  state = Map.put(state, "action_error", action_error_message(reason))

  socket
  |> assign(:world_state, state)
  |> assign(:world_state_json, Jason.encode!(state))
  |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")
  |> push_event("world:state", state)
end

defp action_error_message(:agent_bound_to_live_session),
  do: "该 agent 正在某个对话中，先把它从对话移出再删除"

defp action_error_message(:cap_denied), do: "没有删除权限（需要 manage 权限）"
defp action_error_message(reason), do: "删除失败：#{reason_to_string(reason)}"
```

  (Note: if `Invocation.dispatch` returns the cap-denial as a specific reason atom, map it in `action_error_message`. Confirm the exact `{:error, reason}` shape from `Manage`/the cap chokepoint during Step 1's failing run and align the clause — do NOT invent a reason atom; use what the runtime returns.)
- [ ] **Step 5: Run — verify it passes.** Same command as Step 2.
- [ ] **Step 6: Commit.** `feat(world): agents.delete dispatch — manage-cap + bound-session gate + no-silent-drop`

---

### Task 5: React — Delete button + confirm + list-side error, wired through main.tsx

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` (Delete button + confirm on `AgentDetail` ~283; surface `action_error` on `AgentsTable` ~187; thread an `onDeleteAgent` prop through `IdentitiesSurface` ~106)
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx` (add `onDeleteAgent` to the context interface ~406, the wiring object ~192, and the `IdentitiesSurface` render ~490)

**Interfaces:**
- Consumes: the `world:dispatch` pushEvent channel; `onDeleteAgent(agentUri: string)` mirrors `onCreateAgent`.

- [ ] **Step 1: Add the dispatch wiring in `main.tsx`.** After the `onCreateAgent` block (line ~192):

```tsx
onDeleteAgent: (agentUri: string) => {
  pushEvent?.("world:dispatch", {
    action: "agents.delete",
    args: {agent_uri: agentUri},
  })
},
```

  Add `onDeleteAgent: (agentUri: string) => void` to the context interface (~406), and pass `onDeleteAgent={context.onDeleteAgent}` to the `IdentitiesSurface` render (~490).
- [ ] **Step 2: Thread the prop through `Identities.tsx`.** Extend `Props` (line 87) and `IdentitiesSurface` (106) with `onDeleteAgent?: (agentUri: string) => void`; pass it to `<AgentDetail .../>` (line 110).
- [ ] **Step 3: Add the Delete affordance to `AgentDetail`.** After the read-only config note (line 318-320), add a destructive button that opens a confirm step (a simple two-click confirm via local `React.useState` is sufficient — no new dialog dependency):

```tsx
function AgentDetail({state, onDeleteAgent}: {state: IdentitiesState; onDeleteAgent?: (agentUri: string) => void}) {
  const [confirming, setConfirming] = React.useState(false)
  // ... existing rows/grantedCaps ...
  // append after the read-only config <p>:
  //   <div className="border-t border-border pt-3">
  //     {!confirming && <Button variant? onClick={() => setConfirming(true)}>Delete agent</Button>}
  //     {confirming && (
  //       <div className="flex items-center gap-2">
  //         <span className="text-sm text-destructive">确认删除该 agent？此操作不可撤销。</span>
  //         <Button onClick={() => state.agent_uri && onDeleteAgent?.(state.agent_uri)}>确认删除</Button>
  //         <Button onClick={() => setConfirming(false)}>取消</Button>
  //       </div>
  //     )}
  //   </div>
}
```

  Use the existing `Button` primitive + `text-destructive` token for the destructive styling (match the create-error styling already in the file). Keep it shadcn-shaped.
- [ ] **Step 4: Surface `action_error` on `AgentsTable`.** Render `state.action_error` (set by `push_agent_action_error`) as a `role="alert"` banner above the table, mirroring the `create_error` banner in `AgentNewForm` (line 350-354). Add `action_error?: string` to `IdentitiesState` (line 84 area).
- [ ] **Step 5: Build the island + typecheck.** Run the world assets build/typecheck the way this project runs it (`pnpm`, per `ezagent-developer` conventions — check `apps/ezagent_plugin_world/assets/package.json` for the exact script; do NOT assume). Fix any TS errors. Report the exact command + output.
- [ ] **Step 6: Commit.** `feat(world): Delete button + confirm on agent detail; list-side action error`

---

### Task 6: E2E demonstrable evidence (the anti-demo DoD)

**Files:** none (evidence captured + written to a notes file).

- [ ] **Step 1:** Run the app; create a fresh `echo` agent; from its detail page click Delete → confirm. Capture: (a) agent-browser screenshot of `/identities/agents` WITHOUT the deleted agent, (b) a backend confirmation that `KindRegistry.lookup(agent_uri)` returns not-found (iex or a `mix ezagent` listing).
- [ ] **Step 2:** Capture the cap-denial path (a caller without manage-cap) showing the surfaced error (no silent success).
- [ ] **Step 3:** Capture the bound-session block (agent in a live session → Delete shows the "先移出对话" message, agent still present).
- [ ] **Step 4:** Write the evidence to `docs/superpowers/notes/2026-06-24-agent-delete-e2e-evidence.md` (screenshots + the backend-lookup output). Commit.

---

## Self-Review

- **Spec coverage:** Delete (Task 3-6), Create-hardening (Task 2), Read/live-status verify (Task 1), in-flight registry (Task 0), anti-stub regression tests (Task 2 create-in-list, Task 4 delete→lookup-not-found), demonstrable evidence (Task 6). Update is explicitly deferred per the locked blocker — out of scope, noted.
- **No-placeholder:** dispatch clause, helper, error push, React wiring all shown as concrete code; the two "confirm the runtime's exact shape" notes (cap-denial reason atom; assets build command) are deliberate verification points, not placeholders — the implementer confirms against the running code rather than the plan inventing a value.
- **Type consistency:** `onDeleteAgent(agentUri: string)` consistent across main.tsx + Identities.tsx; `action_error` key consistent between `push_agent_action_error` (server) and `AgentsTable` (client); `agent_bound_to_live_session?/1` consistent between Task 3 (def) and Task 4 (call).
- **DoD pinned to backend:** Task 4 polls `KindRegistry.lookup` (not row-vanish); Task 2 asserts `list_entities`; Task 6 captures backend lookup. Matches the anti-demo guardrail.
