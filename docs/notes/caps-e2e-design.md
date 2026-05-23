# Capabilities — why they feel invisible + e2e test design

**Author:** session 2026-05-23 (responding to Allen "我其实没有太感受到当前 caps 有什么作用")
**Status:** analysis + concrete test designs
**Predecessors:** SKILL P15 (cap shape), CapabilityRegistry PR #264, Presence cap-gate PR #265

## 1. Where caps actually fire today

Two production code paths check capabilities:

### 1.1 `Ezagent.Invocation.dispatch/1` step 5.5

`apps/ezagent_core/lib/ezagent/kind/runtime.ex` — every Behavior action invocation goes through `authz_check/4`:

```elixir
defp authz_check(kind_module, action, target, ctx) do
  needed = Ezagent.Capability.cap_for_action(kind_module, action, target)
  caps = Map.get(ctx, :caps, MapSet.new())

  granted? =
    Enum.any?(caps, fn cap ->
      Ezagent.Capability.matches?(cap, needed)
    end)

  # → emit [:ezagent, :authz, :granted] or [:ezagent, :authz, :denied]
  # → return :ok | {:error, :unauthorized}
end
```

This is THE central cap gate. Every `chat.send`, `lifecycle.terminate`, `template.write`, `routing.add_rule`, …  hits it.

Followed by §5.6 workspace-isolation check (`:cross_workspace_denied` if cross-workspace cap missing).

### 1.2 `Ezagent.Presence.subscribe/2` (PR #265)

The cap-only sentinel path. `subscribe/2` calls `CapabilityRegistry.needed_for(kind, :online, uri)` and matches against `ctx.caps`. Raises `Ezagent.Capability.Unauthorized`.

### 1.3 What's NOT cap-gated (yet)

- Most LV mounts (LiveAuth only checks "is logged in", not "has cap to view this surface")
- `/admin/caps`, `/admin/templates`, `/admin/settings` — gated by per-LV `@is_admin?` mount-check, NOT by CapBAC. A non-admin who hits these gets a flash redirect, but the gate is module-level (boolean), not cap-shaped.
- `Ezagent.Users.create/3`, `Ezagent.Users.set_password/2`, … — facade-level operations that don't dispatch. No cap check.

## 2. Why caps feel invisible to Allen

**Three reasons, root-cause first:**

### Reason 1 — Admin holds a superset cap

`Ezagent.Entity.User.admin_caps/0` returns:

```elixir
%Ezagent.Capability{
  kind: :any,
  behavior: :any,
  instance: :any,
  workspace_uri: :any,
  ...
}
```

This matches EVERY needed cap shape. `Capability.matches?/2` returns `true` 100% of the time. Admin sees the system as if there's no auth gate.

### Reason 2 — Most production paths run as admin

- The `:user_uri => "entity://user/system/admin"` session is THE default in dev tests, LiveView default conn (`@is_admin?` true)
- Chat fan-out runs under `ctx.caps = admin_caps()` (see `Chat.dispatch_receive/3`) — Session is acting on behalf of the system-routed message
- Most LV test fixtures use `Phoenix.ConnTest.build_conn() |> init_test_session(%{"current_entity_uri" => admin_uri})`

So even when caps ARE checked, the caller has admin and the check passes silently.

### Reason 3 — Successful cap checks emit no UI signal

Granted caps emit `[:ezagent, :authz, :granted]` telemetry, but nothing in the UI renders this. The user just sees their action succeed (with no indication that a cap check happened). Denial DOES emit a clear `{:error, :unauthorized}` and (for Feishu inbound) a thumbs-down react with a message — but admin never sees denial.

## 3. What WOULD make caps visible

Three orthogonal directions; pick any/all per priority:

### A. Tests with non-admin users that PROVE cap denial

The strongest "caps are real" signal is a green test suite where:
- A user with NO caps tries an action → asserts `{:error, :unauthorized}`
- A user with a workspace-narrow cap tries to act cross-workspace → asserts `{:error, :cross_workspace_denied}`
- A user with a kind-narrow cap tries to act on the wrong Kind → asserts `:unauthorized`

`apps/ezagent_core/test/integration/routing_cap_test.exs` already does this for routing-rule mutations. We have invariants for cap-shape (`cap_has_workspace_test.exs`) and cross-workspace (`cross_workspace_isolation_test.exs`). But for Allen's day-to-day "create user X, X tries to do thing Y, gets denied", there's no clean reference e2e.

→ **Design 1 below: a single comprehensive `caps_denial_e2e_test.exs`.**

### B. Operator surface that shows live cap traffic

A `/admin/audit/authz` LV that subscribes to `[:ezagent, :authz, :granted]` + `:denied` telemetry and streams a live feed of (`who, what, target, result`). Admin can SEE every cap check fire. Makes the invariant tangible.

→ **Design 2 below: live authz audit LV.**

### C. Per-LV cap-shaped gates (replace `@is_admin?` boolean checks)

Today `/admin/settings` etc. check `socket.assigns.is_admin?`. A user with a workspace-scoped admin cap (e.g. `{kind: :workspace, behavior: Workspace, instance: :within_workspace, workspace_uri: ws}`) gets denied even though they ARE workspace admin for `ws`. Replacing the boolean with `Capability.matches?` opens the door to per-workspace admin roles.

→ **Out of scope for this analysis** — bigger architectural shift. Filed as future.

## 4. Design 1 — `caps_denial_e2e_test.exs`

Single integration test that walks through 5 denial scenarios, with each scenario producing a clear assertion failure if cap enforcement breaks. Runs in `apps/ezagent_core/test/integration/`. Pattern:

```elixir
defmodule Ezagent.Integration.CapsDenialE2ETest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation, Message, Users}

  defp setup_non_admin_user(handle, caps \\ []) do
    uri = "entity://user/default/" <> handle
    {:ok, _} = Users.create(uri, nil, caps)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(URI.parse(uri))
    {URI.parse(uri), MapSet.new(caps)}
  end

  defp dispatch_as(caller_uri, caps, target, args) do
    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: caller_uri, caps: caps, reply: :inline}
    })
  end

  describe "scenario 1: empty-caps user cannot chat.send" do
    test "denial fires with :unauthorized" do
      {bob_uri, bob_caps} = setup_non_admin_user("bob_empty", [])
      session_uri = create_session_and_join_admin()

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")
      msg = Message.new(bob_uri, %{text: "hi", attachments: []}, mentions: [])

      assert {:error, :unauthorized} =
               dispatch_as(bob_uri, bob_caps, target, %{message: msg})
    end
  end

  describe "scenario 2: user with workspace-narrow cap can chat.send in own workspace only" do
    test "permitted in own workspace, denied cross-workspace" do
      alpha_ws = URI.parse("workspace://alpha")
      beta_ws = URI.parse("workspace://beta")

      cap_alpha = %Capability{
        kind: :session, behavior: :any, instance: :any,
        workspace_uri: alpha_ws,
        granted_by: Ezagent.Entity.User.admin_uri(),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      {alice_uri, _} = setup_non_admin_user("alice_alpha", [cap_alpha])

      # Alice in alpha — granted
      alpha_session = create_session_in_ws(alpha_ws)
      assert :ok = dispatch_chat_send(alice_uri, MapSet.new([cap_alpha]), alpha_session, "hi alpha")

      # Alice in beta — denied (workspace_uri mismatch)
      beta_session = create_session_in_ws(beta_ws)
      assert {:error, :unauthorized} =
               dispatch_chat_send(alice_uri, MapSet.new([cap_alpha]), beta_session, "hi beta")
    end
  end

  describe "scenario 3: cap-only Presence subscribe path" do
    test "user without :online cap on target raises Unauthorized" do
      {bob_uri, bob_caps} = setup_non_admin_user("bob_no_presence", [])

      assert_raise Ezagent.Capability.Unauthorized, fn ->
        Ezagent.Presence.subscribe(bob_uri, %{caps: bob_caps})
      end
    end

    test "user with the right :online cap succeeds" do
      target_user = URI.parse("entity://user/default/observed_target")
      {:ok, _} = Users.create(URI.to_string(target_user), nil, [])

      cap_online = %Capability{
        kind: :user, behavior: Ezagent.Behavior.Presence, instance: :any,
        workspace_uri: URI.parse("workspace://default"),
        granted_by: Ezagent.Entity.User.admin_uri(),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      {watcher_uri, _} = setup_non_admin_user("watcher", [cap_online])
      assert :ok = Ezagent.Presence.subscribe(target_user, %{caps: MapSet.new([cap_online])})
    end
  end

  describe "scenario 4: lifecycle.terminate cap denial" do
    test "non-orchestrator cannot terminate someone else's agent" do
      # Spawn an agent owned by orchestrator A
      # User B (no cap) tries to terminate it via lifecycle.terminate
      # → :unauthorized
    end
  end

  describe "scenario 5: cross-workspace cap requirement" do
    test "user with workspace://alpha cap cannot act on workspace://beta target" do
      # Already tested via routing_cap_test pattern; replicated here
      # for a fast single-file reference example
    end
  end
end
```

**Why this single file:** today the cap-coverage exists but is scattered across `cross_workspace_isolation_test`, `routing_cap_test`, `entities_have_workspace_test`, plus invariant tests. None of them produce a clear "5 scenarios, 5 denials" report a human can read in 30 seconds.

This file becomes the reference exhibit for "yes, caps actually gate behavior". When Allen says "show me caps work", we point at this test.

## 5. Design 2 — live authz audit LV

`/admin/audit/authz` consumes the existing telemetry:

```elixir
:telemetry.attach(
  "authz-feed-#{inspect(self())}",
  [:ezagent, :authz, :granted],
  &__MODULE__.on_authz_event/4,
  nil
)

:telemetry.attach(
  "authz-feed-deny-#{inspect(self())}",
  [:ezagent, :authz, :denied],
  &__MODULE__.on_authz_event/4,
  nil
)

def on_authz_event(_event, _measurements, meta, _config) do
  send(self(), {:authz_event, meta})
end
```

Renders a streaming table:

```
TIME    │ CALLER                         │ ACTION                                 │ TARGET        │ RESULT
─────── ┼ ────────────────────────────── ┼ ─────────────────────────────────────── ┼ ───────────── ┼ ──────
14:32:17 │ entity://user/default/admin   │ Ezagent.Behavior.Chat#send             │ session://... │ GRANTED
14:32:18 │ entity://user/default/bob     │ Ezagent.Behavior.Chat#send             │ session://... │ DENIED
14:32:18 │ entity://user/default/alice   │ Ezagent.Behavior.Workspace#add_member  │ workspace://… │ GRANTED
```

A single-PR ~150 LOC addition. Makes the cap system viscerally visible.

## 6. Recommended order

1. **Ship Design 1** first — concrete test that proves cap behavior is real (~1 PR, ~200 LOC test). Allen runs `mix test apps/ezagent_core/test/integration/caps_denial_e2e_test.exs` and sees 5 green denial-scenarios.
2. **Ship Design 2** second if the visceral-visibility is still wanted — operator surface (~1 PR, ~150 LOC LV).
3. **Defer Design C** (per-LV cap gates) — architectural change requiring per-page audit + workspace-admin role design first.

Today's session (2026-05-23) will ship Design 1 as the immediate response to Allen's concern; Designs 2/3 are queued.

## 7. Quick demonstration Allen can run RIGHT NOW

Three iex commands that show caps gating in action without writing a test:

```elixir
# In iex -S mix (test env):

# Set up bob (no caps)
bob_uri = URI.parse("entity://user/default/bob_demo")
{:ok, _} = Ezagent.Users.create("entity://user/default/bob_demo", nil, [])
{:ok, _pid} = Ezagent.SpawnRegistry.spawn(bob_uri)

# Bob tries to send a chat — DENIED
{:ok, session_uri} = EzagentDomainChat.create_session("caps_demo", Ezagent.Entity.User.admin_uri())

msg = Ezagent.Message.new(bob_uri, %{text: "hello", attachments: []}, mentions: [])
target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

Ezagent.Invocation.dispatch(%Ezagent.Invocation{
  target: target, mode: :call, args: %{message: msg},
  ctx: %{caller: bob_uri, caps: MapSet.new(), reply: :inline}
})
# → {:error, :unauthorized}

# Now grant bob a session cap + retry
cap = %Ezagent.Capability{
  kind: :session, behavior: :any, instance: :any,
  workspace_uri: URI.parse("workspace://default"),
  granted_by: Ezagent.Entity.User.admin_uri(),
  granted_at: ~U[2026-01-01 00:00:00Z]
}

Ezagent.Invocation.dispatch(%Ezagent.Invocation{
  target: target, mode: :call, args: %{message: msg},
  ctx: %{caller: bob_uri, caps: MapSet.new([cap]), reply: :inline}
})
# → {:ok, ...} — granted!
```

Two dispatches, same caller, only difference is `ctx.caps`. The first denied, the second granted. Caps are real.
