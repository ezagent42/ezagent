# World PTY JSON Runtime-Value Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent `session.pty.open` from terminating the World LiveView when a running PTY lifecycle status contains an `exec_pid` PID.

**Architecture:** Keep native runtime values inside the domain and normalize them only at the World JSON projection boundary. Exercise the public LiveView hook with a real, erlexec-backed short-lived PTY so the regression test observes the same nested PID shape as Canary; then change only the existing `jsonable/1` fallback to stringify non-JSON runtime terms.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.1, ExUnit/`Phoenix.LiveViewTest`, `Ezagent.Domain.Pty`, erlexec, Jason.

## Global Constraints

- Preserve dispatch, CapBAC, Kind lifecycle, agent readiness, and PTY process behavior.
- Use only the existing erlexec-backed `Ezagent.Domain.Pty` facade for the test child process.
- Keep current atom normalization unchanged, including the existing string projection of booleans and `nil`.
- Do not modify or deploy Canary, restart services, clean the test session, or address unrelated crash loops.
- Follow red-green-refactor and observe the focused test fail before changing production code.
- Run repository `mix precommit` after all local changes.

---

## File map

- Modify `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`:
  public LiveView regression setup, assertions, and bounded PTY readiness helper.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`:
  one-line final fallback normalization at the existing World JSON boundary.
- Modify `docs/e2e/2026-07-13/agent-callable-canary/README.md`:
  distinguish the locally verified repair from the still-unmodified Canary deployment.
- Modify `docs/e2e/2026-07-13/agent-callable-canary/05-pty-and-bridge-join.log`:
  append the local regression test and deployment-pending disposition.

### Task 1: Reproduce and fix PID serialization through `session.pty.open`

**Files:**
- Modify: `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:798`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:1183`

**Interfaces:**
- Consumes: `Ezagent.Kind.spawn/2`, `Ezagent.Domain.Pty.start/2`,
  `Ezagent.Domain.Pty.status/1`, `Ezagent.Domain.Pty.stop/1`,
  `Ezagent.Kind.terminate/1`, and the existing `world:dispatch` hook.
- Produces: unchanged `session.pty.open` payload shape, except nested runtime-only
  values such as `agent_status.detail.exec_pid` are readable strings.

- [ ] **Step 1: Strengthen the existing PTY LiveView test with a real PID**

Replace the fixed, non-running agent setup in
`"PR-4: switching to a member PTY records the active agent"` with:

```elixir
agent_uri =
  Ezagent.URI.new!(
    "entity://system/agent/world-pr4-pty-#{System.unique_integer([:positive])}"
  )

agent = URI.to_string(agent_uri)

{:ok, _agent_pid} =
  Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, initial_caps: MapSet.new()})

{:ok, _pty_pid} =
  Ezagent.Domain.Pty.start(agent_uri, %{
    cwd: "/tmp",
    cmd_override: ["/bin/sleep", "60"],
    test_mode: false,
    auto_prompts: []
  })

on_exit(fn ->
  :ok = Ezagent.Domain.Pty.stop(agent_uri)
  :ok = Ezagent.Kind.terminate(agent_uri)
end)

assert is_pid(wait_for_pty_exec_pid(agent_uri))
```

After the existing `render_hook/3`, extend its push-event assertion to cover
the serialized lifecycle detail:

```elixir
assert_push_event(view, "world:state", %{
  "active_view" => "pty",
  "active_pty_agent_uri" => ^agent,
  "agent_status" => %{
    "detail" => %{"exec_pid" => exec_pid}
  }
})

assert is_binary(exec_pid)
assert String.starts_with?(exec_pid, "#PID<")
assert Process.alive?(view.pid)
```

Add this bounded helper near the existing private wait helpers:

```elixir
defp wait_for_pty_exec_pid(agent_uri, attempts \\ 100)

defp wait_for_pty_exec_pid(agent_uri, 0) do
  flunk("PTY never exposed exec_pid for #{URI.to_string(agent_uri)}")
end

defp wait_for_pty_exec_pid(agent_uri, attempts) do
  case Ezagent.Domain.Pty.status(agent_uri) do
    %{exec_pid: exec_pid} when is_pid(exec_pid) ->
      exec_pid

    _ ->
      Process.sleep(20)
      wait_for_pty_exec_pid(agent_uri, attempts - 1)
  end
end
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:798
```

Expected result: FAIL when `render_hook/3` drives `session.pty.open`; the
LiveView terminates with `Protocol.UndefinedError` because Jason cannot encode
the nested PID. The test setup must reach the PID assertion first; a failure to
spawn `/bin/sleep` is a setup error and must be corrected before proceeding.

- [ ] **Step 3: Implement the minimal World-boundary fallback**

In `ConversationActions.jsonable/1`, change only the final branch:

```elixir
      true ->
        inspect(value)
```

Do not reorder the URI/date/struct/map/list/atom branches and do not change
`push_world_state/2` or `Domain.Agent.lifecycle_status/1`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:798
```

Expected result: one passing test; the pushed nested `exec_pid` is a string and
the LiveView remains alive.

- [ ] **Step 5: Run the surrounding test file and format touched code**

Run:

```bash
mix format apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex \
  apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
```

Expected result: formatter makes no unrelated changes and the full World
conversation test file passes without orphaning `/bin/sleep`.

- [ ] **Step 6: Review and commit the code fix**

Run:

```bash
git diff --check
git diff -- apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex \
  apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
git add apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex \
  apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
git diff --cached --check
git commit -m "fix(world): serialize PTY runtime status values"
```

Expected result: one Conventional Commit containing only the regression test,
its bounded process cleanup, and the one-branch production fix.

### Task 2: Record local disposition and run repository gates

**Files:**
- Modify: `docs/e2e/2026-07-13/agent-callable-canary/README.md`
- Modify: `docs/e2e/2026-07-13/agent-callable-canary/05-pty-and-bridge-join.log`

**Interfaces:**
- Consumes: the passing focused and full-file test results from Task 1.
- Produces: an evidence record that clearly separates local verification from
  deployment and a final clean branch ready for review.

- [ ] **Step 1: Update the evidence status without claiming deployment**

Change the README status to:

```markdown
Status: **CORE CALL PATH PASS; PTY FIX VERIFIED LOCALLY, DEPLOYMENT PENDING**
```

In the Terminal-tab result, preserve the Canary failure description and append:

```markdown
The PID normalization repair now has a public LiveView regression test and
passes locally. Canary remains unchanged, so the deployed Terminal result stays
FAIL until an explicitly authorized deployment and recheck.
```

Append this section to `05-pty-and-bridge-join.log`:

```text
LOCAL REPAIR DISPOSITION
  A public session.pty.open LiveView regression now starts a real erlexec-backed
  PTY, observes its exec_pid, and verifies that World state projects the PID as
  a readable string without terminating the LiveView.
  Focused test: PASS
  Full World conversation test file: PASS
  Canary deployment/revalidation: PENDING EXPLICIT AUTHORIZATION
```

- [ ] **Step 2: Run the required repository gate**

Run:

```bash
mix precommit
```

Expected result: exit status 0 with formatter, compile, and configured test/
quality gates passing. Fix only failures caused by this branch; report unrelated
pre-existing failures with their exact command and output.

- [ ] **Step 3: Re-run sensitive-data and diff checks**

Run:

```bash
rg -n -i '(esr_(ml|pat)_[A-Za-z0-9_-]+|authorization:|bearer [A-Za-z0-9._-]+|api[_-]?key\s*[:=]\s*[^ <]|cookie\s*[:=]\s*[^ <]|token=[A-Za-z0-9_-]+)' \
  docs/e2e/2026-07-13/agent-callable-canary || true
git diff --check
git status --short
```

Expected result: no credential value; the known prose heading
`Authorization:` may match and is not a secret.

- [ ] **Step 4: Commit the local verification disposition**

Run:

```bash
git add docs/e2e/2026-07-13/agent-callable-canary/README.md \
  docs/e2e/2026-07-13/agent-callable-canary/05-pty-and-bridge-join.log
git diff --cached --check
git commit -m "docs(e2e): record local PTY serialization repair"
```

Expected result: a documentation-only Conventional Commit that does not claim
Canary was modified or revalidated.

- [ ] **Step 5: Final branch review**

Run:

```bash
git status --short --branch
git log --oneline --decorate -5
```

Expected result: clean worktree. Report the evidence commit, design/plan commit,
code-fix commit, documentation disposition commit, test results, and the exact
remaining authorization needed for Canary deploy/revalidation.
