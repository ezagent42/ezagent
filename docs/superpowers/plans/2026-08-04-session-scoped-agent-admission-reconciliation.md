# Session-Scoped Agent Admission Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically join the original session-local provisional agent after PTY authentication, with session-scoped reconciliation and race-safe recovery controls.

**Architecture:** `AgentAdmission` gains a session-scoped reconciliation entry that reads only the requested session's active admission rows and completes authenticated candidates under the existing admission lock. The supervised sweeper invokes that entry before timeout handling, while World exposes the same operation for an immediate user-requested check and reopens the existing candidate PTY without calling `begin` again.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix LiveView 1.1, ExUnit, React 19, TypeScript 6, Vitest, Playwright.

## Global Constraints

- Reconciliation accepts one `session_uri` and reads only that session's `agent_admissions`.
- It never scans arbitrary agents, credential homes, or another session's candidates.
- `:missing` and `:unknown` credential states preserve the current attempt and candidate.
- Authenticated completion joins the same provisional agent and never publishes a reusable credential source.
- Completion, cancellation, and timeout serialize through the existing admission lock.
- Cancellation and timeout probe credentials once more before destructive cleanup.
- World remains transport/projection; React never reads credentials or infers authentication from PTY output.
- Use the existing `session.pty.open` action to reopen a candidate terminal.
- Add no dependencies.
- Preserve unrelated worktree changes.
- Run `mix precommit` after all implementation tasks and fix every failure caused by this change.

## File Structure

- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex`
  owns active-attempt credential probing, completion, cancellation, and timeout serialization.
- `apps/ezagent_domain_session/lib/ezagent/session/agent_admission_sweeper.ex`
  schedules per-session active reconciliation before expiry and joined-agent revalidation.
- `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`
  proves isolation, non-destructive pending outcomes, automatic completion, and races.
- `apps/ezagent_plugin_world/lib/ezagent/world/agent_admission_actions.ex`
  adapts an immediate session-scoped reconciliation request to LiveView state refresh.
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
  routes the new World dispatch action.
- `apps/ezagent_plugin_world/lib/ezagent/world/dispatch_contract.ex`
  admits the new action through the backend-owned allowlist.
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
  renders `Continue login` and `Check connection status` for an active PTY admission.
- World Elixir, Vitest, and Playwright tests lock the transport and UI behavior.

---

### Task 1: Add non-destructive session-scoped active reconciliation

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex`
- Test: `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`

**Interfaces:**
- Consumes: `AgentAdmission.list/1`, session owner capabilities, the provider frozen in each admission row, and `Ezagent.Domain.Agent.read_credential_status/3`.
- Produces: `AgentAdmission.reconcile/1 :: :ok | {:error, [{String.t(), String.t(), term()}]}`. Each failure tuple is `{role_name, attempt_id, reason}`; successful joins and pending candidates are observable through `AgentAdmission.list/1` and session membership.

- [ ] **Step 1: Write a failing test for automatic completion of the original candidate**

Add this test beside the existing candidate admission test:

```elixir
test "session reconciliation joins the authenticated original candidate", %{
  session_uri: session_uri,
  declarations: declarations
} do
  assert {:ok, _summary} =
           DefinitionAgents.materialize_definition_agents(
             session_uri,
             @workspace_uri,
             @owner_uri,
             declarations
           )

  caps = Ezagent.Identity.list_caps_for(@owner_uri)
  assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
  candidate_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
  Process.put({CredentialTemplate, :credential_status}, :authenticated)

  assert :ok = AgentAdmission.reconcile(session_uri)
  assert [%{status: :joined, provisional_agent_uri: candidate}] = AgentAdmission.list(session_uri)
  assert candidate == URI.to_string(candidate_uri)
  assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == candidate_uri
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: compilation fails because `AgentAdmission.reconcile/1` is undefined.

- [ ] **Step 3: Write failing tests for pending preservation and session isolation**

Use a second live session with copied declarations. Assert both `:missing` and `:unknown` preserve the exact row, and reconciling the first session does not touch an authenticated candidate in the second:

```elixir
before = hd(AgentAdmission.list(session_uri))
Process.put({CredentialTemplate, :credential_status}, :missing)
assert :ok = AgentAdmission.reconcile(session_uri)
assert AgentAdmission.list(session_uri) == [before]

Process.put({CredentialTemplate, :credential_status}, :unknown)
assert :ok = AgentAdmission.reconcile(session_uri)
assert AgentAdmission.list(session_uri) == [before]

other_session = live_session("reconcile-scope-#{System.unique_integer([:positive])}")
on_exit(fn -> terminate(other_session) end)
copy_declarations(other_session, declarations)
assert {:ok, %{status: :pending_auth}} =
         AgentAdmission.defer(other_session, Enum.find(declarations, &(&1.role_name == "llm")))
assert {:ok, other} = AgentAdmission.begin(other_session, "llm", @owner_uri, caps)
Process.put({CredentialTemplate, :credential_status}, :authenticated)

assert :ok = AgentAdmission.reconcile(session_uri)
assert [%{status: :authenticating, attempt_id: attempt}] = AgentAdmission.list(other_session)
assert attempt == other.attempt_id
```

- [ ] **Step 4: Implement `reconcile/1` and the locked attempt helper**

Add the public entry and keep the candidate list session-local:

```elixir
@doc "Reconcile every active credential admission owned by one session."
@spec reconcile(URI.t()) :: :ok | {:error, [{String.t(), String.t(), term()}]}
def reconcile(%URI{scheme: "session"} = session_uri) do
  failures =
    session_uri
    |> list()
    |> Enum.filter(&(&1.status in @active_statuses))
    |> Enum.reduce([], fn admission, failures ->
      case reconcile_attempt(session_uri, admission.role_name, admission.attempt_id) do
        :ok -> failures
        {:error, reason} -> [{admission.role_name, admission.attempt_id, reason} | failures]
      end
    end)

  case Enum.reverse(failures) do
    [] -> :ok
    failures -> {:error, failures}
  end
end
```

Implement `reconcile_attempt/3` using `State.with_lock/2`. Inside the lock, re-resolve the owner, declaration, revision, current attempt, candidate URI, and owner caps. Probe only that candidate. Map credential state exactly as follows:

```elixir
case credential_status.status do
  :authenticated ->
    case complete_authenticated(
           session_uri,
           owner_uri,
           caps,
           declaration,
           current,
           agent_uri,
           attempt_id
         ) do
      {:ok, _joined} -> :ok
      {:error, reason} -> {:error, reason}
    end

  status when status in [:missing, :unknown] ->
    :ok

  status ->
    {:error, {:unsupported_credential_status, status}}
end
```

Use `list_caps_for_materialization(owner_uri)` and the existing `actor_ctx/2`; do not call public `complete/4` while holding the lock.

- [ ] **Step 5: Run the focused domain tests and verify GREEN**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: all tests pass, including the new completion, pending-preservation, and cross-session isolation cases.

- [ ] **Step 6: Commit Task 1**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
git diff --cached --check
git commit -m "feat(session): reconcile active agent admissions"
```

---

### Task 2: Make cancellation and timeout race-safe

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex`
- Test: `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`

**Interfaces:**
- Consumes: the Task 1 locked credential-probe/completion helper and the existing `cancel/4`, `expire/2`, and `cleanup_provisional/6` paths.
- Produces: authenticated cancellation/timeout returns `{:ok, joined_admission}`; unauthenticated cancellation/timeout retains existing failed-row semantics.

- [ ] **Step 1: Write failing cancellation and timeout tests**

Create two independent sessions so each assertion owns one candidate:

```elixir
Process.put({CredentialTemplate, :credential_status}, :authenticated)

assert {:ok, %{status: :joined, provisional_agent_uri: candidate}} =
         AgentAdmission.cancel(
           cancel_session,
           "llm",
           cancelling.attempt_id,
           {@owner_uri, caps}
         )

assert candidate == cancelling.provisional_agent_uri
assert SessionBehavior.role_name_to_uri(members_of(cancel_session), "llm") ==
         Ezagent.URI.new!(candidate)

assert {:ok, %{status: :joined, provisional_agent_uri: expiring_candidate}} =
         AgentAdmission.expire(expire_session, expiring.attempt_id)

assert expiring_candidate == expiring.provisional_agent_uri
assert SessionBehavior.role_name_to_uri(members_of(expire_session), "llm") ==
         Ezagent.URI.new!(expiring_candidate)
```

Keep the existing cancellation/expiry test assertions proving `:missing` candidates become `connection_cancelled` or `connection_timed_out` and are retired.

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: authenticated cancellation and expiry return failed rows and remove membership instead of returning `joined`.

- [ ] **Step 3: Add a locked settle-or-retire helper**

Replace direct `cancel_current/5` calls from active cancellation and current-row expiry with a helper that receives the declaration:

```elixir
defp settle_or_cancel_current(
       session_uri,
       declaration,
       current,
       actor_uri,
       caps,
       failure_code
     ) do
  with {:ok, agent_uri} <- provisional_uri(current),
       {:ok, credential_status} <-
         Ezagent.Domain.Agent.read_credential_status(
           agent_uri,
           actor_ctx(actor_uri, caps),
           backend_profile: provider_of(declaration)
         ) do
    case credential_status.status do
      :authenticated ->
        complete_authenticated(
          session_uri,
          actor_uri,
          caps,
          declaration,
          current,
          agent_uri,
          current.attempt_id
        )

      status when status in [:missing, :unknown] ->
        cancel_current(session_uri, current, actor_uri, caps, failure_code)

      status ->
        {:error, {:unsupported_credential_status, status}}
    end
  end
end
```

Call it only after `cancellable_attempt/4` has revalidated the exact attempt under `State.with_lock/2`. Preserve idempotent handling of an already-failed row by returning it unchanged without probing.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: authenticated cancel/timeout joins the original candidate; unauthenticated cleanup, stale attempt, compensation, and retry tests remain green.

- [ ] **Step 5: Commit Task 2**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
git diff --cached --check
git commit -m "fix(session): settle authenticated admission races"
```

---

### Task 3: Reconcile active admissions before the sweeper expires them

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/agent_admission_sweeper.ex`
- Test: `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`

**Interfaces:**
- Consumes: `AgentAdmission.reconcile/1` from Task 1.
- Produces: every sweep reconciles each discovered session independently before evaluating that session's expired rows; `run_due/1` keeps its existing expiration-result return shape.

- [ ] **Step 1: Write a failing sweeper auto-completion test**

Use synchronous `run_due/1` so the credential test adapter reads the calling process dictionary:

```elixir
assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
candidate_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
Process.put({CredentialTemplate, :credential_status}, :authenticated)

assert AgentAdmissionSweeper.run_due(DateTime.utc_now()) == []
assert [%{status: :joined, provisional_agent_uri: candidate}] = AgentAdmission.list(session_uri)
assert candidate == URI.to_string(candidate_uri)
assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == candidate_uri
```

Add a deadline-race variant using `future = DateTime.add(DateTime.utc_now(), 1, :day)` and assert the authenticated attempt joins instead of becoming `connection_timed_out`.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: the ordinary sweep leaves the admission in `authenticating`; the future sweep expires it.

- [ ] **Step 3: Reorder per-session sweep work**

Introduce one per-session function and call it for every session:

```elixir
defp sweep_session(session_uri, now) do
  log_reconciliation_result(session_uri, AgentAdmission.reconcile(session_uri))
  expired = expire_due(session_uri, now)
  reconcile_due(session_uri)
  expired
end

defp run_due(now, sessions), do: Enum.flat_map(sessions, &sweep_session(&1, now))
```

Use a non-secret error log for aggregate failures:

```elixir
defp log_reconciliation_result(_session_uri, :ok), do: :ok

defp log_reconciliation_result(session_uri, {:error, failures}) do
  Enum.each(failures, fn {role_name, attempt_id, reason} ->
    Logger.error(
      "active agent admission #{attempt_id} for #{URI.to_string(session_uri)} " <>
        "role #{role_name} could not be reconciled: #{inspect(reason)}"
    )
  end)
end
```

Both public `run_due/1` and `handle_info(:sweep, state)` must use `run_due(now, sessions)` exactly once; remove the second standalone `Enum.each(sessions, &reconcile_due/1)` call to avoid duplicate joined revalidation.

- [ ] **Step 4: Run the domain session test file and verify GREEN**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: automatic and deadline-race tests pass; existing timeout and joined-credential revalidation tests remain green.

- [ ] **Step 5: Commit Task 3**

```bash
git add apps/ezagent_domain_session/lib/ezagent/session/agent_admission_sweeper.ex \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
git diff --cached --check
git commit -m "feat(session): auto-complete authenticated admissions"
```

---

### Task 4: Add World reconciliation and PTY recovery controls

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/agent_admission_actions.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/dispatch_contract.ex`
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx`
- Modify: `apps/ezagent_plugin_world/assets/e2e/fixtures/world.e2e.fixtures.json`
- Modify: `apps/ezagent_plugin_world/assets/e2e/world.spec.ts`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs`

**Interfaces:**
- Consumes: `AgentAdmission.reconcile/1`, `session.pty.open`, the existing `onOpenPty(sessionUri, agentUri)` callback, and `onAgentAdmissionAction(action, args)`.
- Produces: backend action `session.agent_admission.reconcile` with `{session_uri}` arguments; active PTY cards emit this action and reopen only their current `provisional_agent_uri`.

- [ ] **Step 1: Write failing backend routing tests**

Extend the dispatch contract assertion and bad-URI routing coverage:

```elixir
assert "session.agent_admission.reconcile" in
         Ezagent.World.DispatchContract.actions(:conversation)

assert {:noreply, out} =
         dispatch("session.agent_admission.reconcile", %{
           "session_uri" => "not-a-session-uri"
         })

assert out.assigns.last_dispatch_status == "error:bad_session_uri"
```

- [ ] **Step 2: Run the World routing test and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs
```

Expected: the action is absent from the contract or falls through to `error:unsupported_action`.

- [ ] **Step 3: Add the backend action and state refresh**

Add `session.agent_admission.reconcile` to the `:conversation` allowlist. Route it in `ConversationActions.handle_dispatch/3`:

```elixir
def handle_dispatch(
      socket,
      "session.agent_admission.reconcile",
      %{"session_uri" => sid}
    ) do
  Ezagent.World.AgentAdmissionActions.reconcile(socket, sid)
end
```

Add the adapter in `AgentAdmissionActions`:

```elixir
@doc "Immediately reconciles active admissions in the currently displayed session."
@spec reconcile(Phoenix.LiveView.Socket.t(), String.t()) ::
        {:noreply, Phoenix.LiveView.Socket.t()}
def reconcile(socket, sid) do
  with_current_session(socket, sid, fn session_uri ->
    case AgentAdmission.reconcile(session_uri) do
      :ok -> {:noreply, push_admission_state(socket, session_uri)}
      {:error, failures} ->
        socket
        |> push_admission_state(session_uri)
        |> error({:agent_admission_reconciliation_failed, failures})
    end
  end)
end
```

Keep `with_current_session/3` as the current-session authorization/binding check.

- [ ] **Step 4: Run backend routing and parity tests and verify GREEN**

Run:

```bash
mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/conversation_dispatch_parity_test.exs
```

Expected: both files pass and the new action is admitted by the single dispatch contract.

- [ ] **Step 5: Write failing PTY-card interaction coverage**

Add an active PTY admission to the conversation fixture. In `world.spec.ts`, click each recovery button and assert the exact event:

```typescript
await admission.getByRole("button", {name: "继续登录"}).click()
await expect.poll(() => lastEvent(page)).toEqual({
  event: "world:dispatch",
  payload: {
    action: "session.pty.open",
    args: {session_uri: conversationFixtureUri, agent: provisionalAgentUri},
  },
})

await page.evaluate(() => window.__WORLD_E2E__.clearEvents())
await admission.getByRole("button", {name: "检查连接状态"}).click()
await expect.poll(() => lastEvent(page)).toEqual({
  event: "world:dispatch",
  payload: {
    action: "session.agent_admission.reconcile",
    args: {session_uri: conversationFixtureUri},
  },
})
```

Also assert that neither click emits `session.agent_admission.begin`.

- [ ] **Step 6: Render the two controls against the existing candidate**

Add helpers in `Conversation.tsx`:

```typescript
const reconcileAdmissions = () => {
  if (!sessionUri) return
  onAgentAdmissionAction?.("session.agent_admission.reconcile", {session_uri: sessionUri})
}

const continueAdmissionLogin = (admission: AgentAdmission) => {
  if (!sessionUri || !admission.provisional_agent_uri) return
  onOpenPty(sessionUri, admission.provisional_agent_uri)
}
```

For active PTY admissions, render uniquely selectable buttons:

```tsx
{admission.connection.kind === "pty" && admission.provisional_agent_uri && (
  <>
    <Button
      type="button"
      size="sm"
      onClick={() => continueAdmissionLogin(admission)}
      data-world-agent-admission-continue
    >
      继续登录
    </Button>
    <Button
      type="button"
      size="sm"
      variant="secondary"
      onClick={reconcileAdmissions}
      data-world-agent-admission-check
    >
      检查连接状态
    </Button>
  </>
)}
```

Keep the existing API-key form unchanged. Keep Cancel beside the recovery controls.

- [ ] **Step 7: Run asset unit, type, lint, and E2E tests**

Run:

```bash
pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx
pnpm --dir apps/ezagent_plugin_world/assets typecheck
pnpm --dir apps/ezagent_plugin_world/assets lint
pnpm --dir apps/ezagent_plugin_world/assets test:e2e -- --grep "credential admission"
```

Expected: all commands exit 0; the PTY card emits `session.pty.open` and session-scoped reconciliation, never a second `begin`.

- [ ] **Step 8: Commit Task 4**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/agent_admission_actions.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/dispatch_contract.ex \
  apps/ezagent_plugin_world/assets/src/components/Conversation.tsx \
  apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx \
  apps/ezagent_plugin_world/assets/e2e/fixtures/world.e2e.fixtures.json \
  apps/ezagent_plugin_world/assets/e2e/world.spec.ts \
  apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs
git diff --cached --check
git commit -m "feat(world): recover active agent admissions"
```

---

### Task 5: Verify the complete login-to-membership journey

**Files:**
- Modify only files required to fix verification failures caused by Tasks 1-4.

**Interfaces:**
- Consumes: the complete domain, sweeper, World, and React behavior from Tasks 1-4.
- Produces: passing focused suites, passing project precommit, and runtime evidence that one login joins the original candidate.

- [ ] **Step 1: Run all focused regression suites together**

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/conversation_dispatch_parity_test.exs
pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx
pnpm --dir apps/ezagent_plugin_world/assets typecheck
pnpm --dir apps/ezagent_plugin_world/assets lint
```

Expected: every command exits 0.

- [ ] **Step 2: Run the repository gate required by `AGENTS.md`**

```bash
mise exec -- mix precommit
```

Expected: exit 0. Fix only failures attributable to this implementation; preserve unrelated user changes.

- [ ] **Step 3: Restart the worktree service and perform runtime acceptance**

Start the service at `http://world.localhost:10042/` using the worktree's existing runtime configuration. In a newly created Hello Codex session:

1. Record the provisional agent URI after the first `Connect Codex`.
2. Complete Codex login in that candidate's PTY.
3. Return to Conversation without clicking Cancel or Connect again.
4. Confirm the admission card disappears and the recorded URI appears as the `llm` member.
5. Confirm that opening its terminal does not show the login screen again.
6. Confirm no second provisional agent was created for the role.

- [ ] **Step 4: Inspect final scope and commit any verification-only correction**

```bash
git status --short
git diff --check
git diff --stat HEAD~4..HEAD
```

If Step 2 or Step 3 exposes a defect, return to the task that owns that file,
add a failing regression test there, apply the minimal correction, rerun that
task's checks, and use that task's exact staging list for a corrective commit.

Expected final status: only the user's pre-existing `.superpowers/sdd/task-1-report.md` and `.superpowers/sdd/task-2-report.md` modifications remain unstaged.
