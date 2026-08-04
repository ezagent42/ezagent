# Codex Admission PTY View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Connect Codex` immediately enter a server-enumerated Terminal view while the provisional admission agent is authenticating.

**Architecture:** Extend the shared Terminal `SessionView` projection to recognize live PTYs owned by active admission candidates as well as joined members. After the existing authorization and related-target gates pass, World recomputes that caller-scoped projection and publishes it atomically with `active_view: "pty"`; React keeps enforcing the server-provided view list unchanged.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.1, ExUnit, React 19, TypeScript 6, Vitest 4.

## Global Constraints

- Preserve `Ezagent.UI.SessionViewRegistry.applicable_views/2` as the sole source of visible session views.
- Preserve the existing PTY Manage-cap read gate and session-related-target validation.
- Do not add a new terminal route, duplicate terminal component, or client-side permission bypass.
- Active admission candidates are only statuses `:authenticating` and `:materializing` with a canonical entity URI and a live `Ezagent.Domain.Pty` server.
- Use TDD: observe each production regression test fail for the expected missing behavior before changing production code.
- Run `mix precommit` after all focused checks pass.

---

## File Map

- Modify `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal_view.ex`: include active provisional admission candidates in Terminal applicability.
- Modify `apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs`: integration regression for a real Codex provisional PTY appearing in the registry projection before membership.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`: publish refreshed views in the same World state update that activates PTY.
- Modify `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`: LiveView regression for the atomic PTY state payload.
- Modify `apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx`: browser-rendering contract for an enumerated active PTY view.

### Task 1: Make an active admission PTY a Terminal SessionView

**Files:**
- Modify: `apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs`
- Modify: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal_view.ex`

**Interfaces:**
- Consumes: `AgentAdmission.list(session_uri) :: [admission()]`, `Ezagent.URI.parse/1`, and `Ezagent.Domain.Pty.alive?/1`.
- Produces: `TerminalView.applies_to?/1` returns `true` for either a joined live-PTY member or an active live-PTY provisional candidate.

- [ ] **Step 1: Write the failing Codex admission projection test**

In `credential_admission_bootstrap_test.exs`, immediately after the existing PTY liveness assertions, add:

```elixir
    assert EzagentDomainUi.Pty.TerminalView.applies_to?(session_uri)

    assert Enum.any?(
             Ezagent.World.ConversationData.session_views(session_uri, @owner_uri),
             &(&1["id"] == "pty" and &1["mode"] == "pty")
           )
```

Keep the existing assertion that `role_name_to_uri(...) == nil`; together they prove the Terminal view is available before membership.

- [ ] **Step 2: Run the regression and verify RED**

Run:

```bash
mix test apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs
```

Expected: FAIL at `TerminalView.applies_to?(session_uri)` because the provisional agent is not yet in `session.members`, while the preceding `Ezagent.Domain.Pty.alive?/1` assertion passes.

- [ ] **Step 3: Implement admission-aware applicability**

In `terminal_view.ex`, alias the admission module:

```elixir
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
```

Change the successful `Kind.read/3` branch to accept either source:

```elixir
      {:ok, %{members: members}} when is_map(members) ->
        Enum.any?(Map.keys(members), &pty_backed_member?/1) or
          active_admission_pty?(session_uri)
```

Add safe private helpers:

```elixir
  defp active_admission_pty?(session_uri) do
    session_uri
    |> AgentAdmission.list()
    |> Enum.any?(&active_admission_pty_row?/1)
  end

  defp active_admission_pty_row?(%{
         status: status,
         provisional_agent_uri: candidate
       })
       when status in [:authenticating, :materializing] and is_binary(candidate) do
    case Ezagent.URI.parse(candidate) do
      {:ok, %URI{scheme: "entity"} = uri} -> Ezagent.Domain.Pty.alive?(uri)
      _ -> false
    end
  end

  defp active_admission_pty_row?(_), do: false
```

Do not broaden accepted statuses and do not raise on malformed durable rows.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
mix test apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs
mix test apps/ezagent_domain_ui/test/ezagent_domain_ui/pty/terminal_view_test.exs
```

Expected: both files PASS with zero failures.

- [ ] **Step 5: Commit the projection fix**

```bash
git add apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal_view.ex \
  apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs
git diff --cached --check
git commit -m "fix(ui): expose active admission terminals"
```

### Task 2: Publish the PTY view and activation atomically

**Files:**
- Modify: `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx`

**Interfaces:**
- Consumes: `ConversationData.session_views(session_uri, caller_uri) :: [map()]` after the PTY is live.
- Produces: one `world:state` update containing `views`, `active_view`, `active_pty_agent_uri`, PTY status, and initial buffer.

- [ ] **Step 1: Write the failing LiveView payload test**

In `world_conversation_test.exs`, extend the `assert_push_event` in `"PR-4: switching to a member PTY records the active agent"`:

```elixir
    assert_push_event(view, "world:state", %{
      "views" => views,
      "active_view" => "pty",
      "active_pty_agent_uri" => ^agent,
      "agent_status" => %{
        "detail" => %{
          "cwd" => "/tmp",
          "exec_pid" => exec_pid,
          "os_pid" => os_pid
        }
      }
    })

    assert Enum.any?(views, &(&1["id"] == "pty" and &1["mode"] == "pty"))
```

- [ ] **Step 2: Run the LiveView regression and verify RED**

Run:

```bash
mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:827
```

Expected: FAIL because the pushed partial state has no `"views"` key.

- [ ] **Step 3: Publish refreshed views from the successful PTY path**

In `ConversationActions.switch_to_pty/3`, pass the session URI into the state builder:

```elixir
                push_pty_view(socket, session_uri, agent_uri)
```

Change the helper signature and add the caller-scoped projection:

```elixir
  defp push_pty_view(socket, %URI{} = session_uri, %URI{} = agent_uri) do
    caller = socket.assigns.current_entity_uri

    {:noreply,
     push_world_state(socket, %{
       "views" => ConversationData.session_views(session_uri, caller),
       "active_view" => "pty",
       "active_pty_agent_uri" => uri_string(agent_uri),
       "agent_uri" => uri_string(agent_uri),
       "agent_detail_path" =>
         "/identities/agents/#{URI.encode_www_form(URI.to_string(agent_uri))}",
       "agent_status" => jsonable(Ezagent.Domain.Agent.lifecycle_status(agent_uri)),
       "pty_alive" => Ezagent.Domain.Pty.alive?(agent_uri),
       "pty_phase" => pty_phase(agent_uri),
       "pty_initial_buffer" => pty_initial_buffer(agent_uri)
     })}
  end
```

- [ ] **Step 4: Verify the LiveView regression is GREEN**

Run:

```bash
mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:827
mix test apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs
mix test apps/ezagent_plugin_world/test/ezagent/world/view_cap_gate_regression_test.exs
```

Expected: all commands PASS with zero failures; the security and non-cap-gated PTY guard tests remain green.

- [ ] **Step 5: Add the existing React allowlist contract test**

Change the PTY mock in `Conversation.test.tsx` so its render is observable:

```tsx
vi.mock("./PtyTerminal", () => ({
  PtyTerminalSurface: () => <div data-world-test-pty-surface />,
}))
```

Add:

```tsx
describe("terminal view activation", () => {
  it("renders Terminal when the active PTY is present in server-enumerated views", () => {
    const html = renderConversation({
      ...state,
      active_view: "pty",
      active_pty_agent_uri: "entity://system/agent/codex-provisional",
      views: [
        ...state.views!,
        {id: "pty", label: "Terminal", icon: "terminal", mode: "pty"},
      ],
    })

    expect(html).toContain("data-world-test-pty-surface")
  })
})
```

This is contract coverage for unchanged React behavior; the Elixir test is the RED/GREEN regression for the production change.

- [ ] **Step 6: Run World asset checks**

Run:

```bash
pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx
pnpm --dir apps/ezagent_plugin_world/assets typecheck
```

Expected: Vitest reports the Conversation tests passing and TypeScript exits zero.

- [ ] **Step 7: Commit the atomic World update**

```bash
git add apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex \
  apps/ezagent_web/test/ezagent_web/world_conversation_test.exs \
  apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx
git diff --cached --check
git commit -m "fix(world): enter Codex admission terminal"
```

### Task 3: Verify and deploy the fix in the active worktree service

**Files:**
- Verify: all modified production and test files

**Interfaces:**
- Consumes: the completed projection and atomic state update from Tasks 1-2.
- Produces: verified code and a restarted service at `http://world.localhost:10042/`.

- [ ] **Step 1: Run focused regression suite together**

```bash
mix test \
  apps/ezagent_plugin_codex/test/integration/credential_admission_bootstrap_test.exs \
  apps/ezagent_domain_ui/test/ezagent_domain_ui/pty/terminal_view_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/view_cap_gate_regression_test.exs \
  apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
```

Expected: zero failures.

- [ ] **Step 2: Run the project-required full gate**

```bash
mix precommit
```

Expected: compile, formatting, umbrella tests, and auxiliary checks all exit zero. Fix only failures caused by this change; report unrelated pre-existing failures with exact evidence.

- [ ] **Step 3: Restart the worktree service**

Stop the currently running `./bin/dev` process, then restart from this worktree with:

```bash
PORT=10042 \
EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID=local-dev-v1 \
EZAGENT_PROVIDER_AUTH_KEYS_JSON='{"local-dev-v1":"WlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlo="}' \
./bin/dev
```

Do not set `HELLO_DEMO_SEED`; preserve the current database and active sessions.

- [ ] **Step 4: Run runtime acceptance on `hello-codex-1`**

Retry `Connect Codex` through the browser and verify:

- the admission row is `:authenticating` with a provisional entity URI;
- `Ezagent.Domain.Pty.alive?(candidate_uri)` is `true`;
- `ConversationData.session_views(session_uri, admin_uri)` contains `%{"id" => "pty", "mode" => "pty"}`;
- the same `world:state` event carries `views` and `active_view: "pty"`;
- the browser displays the xterm surface and a visible Terminal tab.

- [ ] **Step 5: Final repository review**

```bash
git status --short
git log -3 --oneline
git diff HEAD~2..HEAD --check
```

Expected: only the plan may remain uncommitted; implementation commits are the two scoped commits above, with no whitespace errors or unrelated changes.
