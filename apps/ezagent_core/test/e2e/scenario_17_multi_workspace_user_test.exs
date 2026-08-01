defmodule EzagentCore.E2E.Scenario17MultiWorkspaceUserTest do
  @moduledoc """
  Scenario 17 — User with caps in multiple workspaces (catalog Category 6).

  This is the **scenario-level** composition that the catalog's ✅ bar
  asks for: it walks the multi-workspace-user journey end-to-end through
  the real `Invocation.dispatch` authz pipeline, rather than asserting
  the individual predicates in isolation. The building-block invariants
  are already unit-covered elsewhere; this test ties them into the user
  journey and pins the parts those units do NOT reach:

  - `cap_based_workspace_visibility_invariant_test` (INV-2) covers a
    user member of ONE workspace. This test covers a user member of TWO
    tenant workspaces simultaneously — the actual "multi-workspace user"
    visibility set.
  - `promote_to_system_grants_cross_workspace_test` stops at the
    `Capability.cross_workspace?/2` PREDICATE. This test proves the
    predicate translates into a real `Invocation.dispatch` SUCCEEDING
    cross-workspace into TWO different tenant workspaces (the production
    authz path: step 5.5 cap matcher + step 5.6 workspace isolation).
  - `cross_workspace_isolation_test` proves the cross-workspace DENIAL
    using an `:any` cap for the positive case. This test uses the
    realistic shape — system membership + per-workspace target-scoped
    caps — and exercises grant → act-in-both → revoke → denied.

  ## The authz model this journey exercises (Kind.Runtime §5)

  - **5.5 (cap matcher)** substitutes the TARGET workspace into the
    required cap, so the caller must hold a cap whose `workspace_uri`
    matches the target workspace (or `:any`).
  - **5.6 (workspace isolation)** denies when caller's home workspace
    differs from the target's, UNLESS some cap is cross-workspace
    (`workspace_uri: :any`) OR the caller is a `workspace://system`
    member (`Capability.cross_workspace?/2` membership bypass).

  So a non-system user holding a per-workspace cap can act ONLY in their
  home workspace; system membership is what lets the same per-workspace
  caps act across workspaces. That is the multi-workspace-user contract.

  ## Out of scope (genuine remaining gaps — need a SPEC, not a test)

  - **Default-workspace-selection at login** (scenario steps 2 + 10):
    which workspace a multi-workspace user lands in after password vs.
    magic-link login is implementation-defined today; the scenario doc
    flags this as needing a SPEC. Not asserted here.
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules
  # (Workspace / SpawnRegistry / WorkspaceRegistry); resolves only in
  # the umbrella. Excluded from `cd apps/ezagent_core && mix test`.
  @moduletag :umbrella_only

  alias Ezagent.{Invocation, Message, SpawnRegistry, WorkspaceRegistry, Workspace}

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(Ezagent.Entity.User.admin_uri()) =>
        MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    # System workspace row must exist for the membership-based
    # cross-workspace bypass (mirrors promote_to_system test setup).
    case Workspace.Store.get_by_name("system") do
      nil -> {:ok, _} = Workspace.Store.create("system", %{})
      _ -> :ok
    end

    :ok
  end

  # A `session.send` cap scoped to a concrete workspace (NOT `:any`),
  # mirroring `User.default_caps/1`'s shape. Passes step 5.5 only for a
  # target in `workspace_uri`.
  defp session_cap_for(%URI{} = session_uri, %URI{} = grantee) do
    signed_action_cap!(Ezagent.URI.with_action(session_uri, :session, :send), grantee)
  end

  defp send_invocation(%URI{} = session_uri, %URI{} = caller_uri, caps) do
    by_holder =
      Application.get_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{})

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      Map.put(by_holder, Ezagent.URI.stable_key(caller_uri), caps)
    )

    msg = Message.new(caller_uri, %{text: "hello", attachments: []})

    %Invocation{
      origin: :trusted_internal,
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
      mode: :call,
      args: %{message: msg},
      ctx: %{
        caller: caller_uri,
        authenticated_principal: caller_uri,
        caps: caps,
        reply: :ignore
      }
    }
  end

  # "Passed the authz gate" — both step-5.5 (cap) and step-5.6
  # (workspace isolation) cleared. Downstream stages (Chat.send DB
  # INSERT) may race the Ecto sandbox; that is orthogonal to the authz
  # decision, so we assert the absence of BOTH denial atoms rather than
  # `{:ok, ...}` (same robustness pattern as cross_workspace_isolation_test).
  defp assert_passed_gate(result, context) do
    refute match?({:error, :unauthorized}, result),
           "#{context}: denied at step 5.5 (cap matcher). Got: #{inspect(result)}"

    refute match?({:error, :cross_workspace_denied}, result),
           "#{context}: denied at step 5.6 (workspace isolation). Got: #{inspect(result)}"
  end

  defp add_to_system(%URI{} = user_uri) do
    %{members: existing} = Workspace.Store.get_by_name("system")
    {:ok, _} = Workspace.Store.update_members("system", Enum.uniq([user_uri | existing]))
    :ok
  end

  defp remove_from_system(%URI{} = user_uri) do
    %{members: existing} = Workspace.Store.get_by_name("system")
    target = URI.to_string(user_uri)
    remaining = Enum.reject(existing, fn m -> URI.to_string(m) == target end)
    {:ok, _} = Workspace.Store.update_members("system", remaining)
    :ok
  end

  defp setup_two_tenant_workspaces do
    suffix = uniq("ws17")
    alpha_name = "alpha-#{suffix}"
    beta_name = "beta-#{suffix}"

    alpha_ws = URI.new!("workspace://#{alpha_name}")
    beta_ws = URI.new!("workspace://#{beta_name}")

    {:ok, _} = Workspace.spawn_workspace(alpha_name)
    {:ok, _} = Workspace.spawn_workspace(beta_name)

    # `spawn_workspace/1` brings up the Workspace Kind but does not
    # necessarily persist the Store row that `update_members/2` reads;
    # ensure it (idempotent — mirrors the visibility/promote tests).
    for name <- [alpha_name, beta_name] do
      case Workspace.Store.get_by_name(name) do
        nil -> {:ok, _} = Workspace.Store.create(name, %{})
        _ -> :ok
      end
    end

    # SPEC v3 §3.6 — 3-segment session URIs carry workspace as the
    # second segment.
    alpha_session = URI.new!("session://#{alpha_name}/default/main")
    beta_session = URI.new!("session://#{beta_name}/default/main")

    {:ok, _} = SpawnRegistry.spawn(alpha_session)
    {:ok, _} = SpawnRegistry.spawn(beta_session)

    :ok = WorkspaceRegistry.bind(alpha_session, alpha_ws)
    :ok = WorkspaceRegistry.bind(beta_session, beta_ws)

    %{
      alpha_name: alpha_name,
      beta_name: beta_name,
      alpha_ws: alpha_ws,
      beta_ws: beta_ws,
      alpha_session: alpha_session,
      beta_session: beta_session
    }
  end

  describe "multi-workspace visibility (scenario 17 step 3 — dropdown)" do
    test "a user who is a member of TWO tenant workspaces sees exactly those two (not system)" do
      ctx = setup_two_tenant_workspaces()

      # U's home URI is alpha, but membership is what drives visibility.
      u = URI.new!("entity://#{ctx.alpha_name}/user/#{uniq("u")}")
      {:ok, _row} = Ezagent.Users.create(u, nil, [])
      {:ok, _} = SpawnRegistry.spawn(u)
      {:ok, _} = Workspace.Store.update_members(ctx.alpha_name, [u])
      {:ok, _} = Workspace.Store.update_members(ctx.beta_name, [u])

      current_caps = Ezagent.IdentityCaps.load(u)

      by_holder =
        Application.get_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{})

      Application.put_env(
        :ezagent_core,
        EzagentCore.Test.CapAuthorityLoaderStub,
        Map.put(by_holder, Ezagent.URI.stable_key(u), MapSet.new(current_caps))
      )

      visible =
        u
        |> Workspace.list_workspaces_for(current_caps)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert ctx.alpha_name in visible and ctx.beta_name in visible,
             "multi-workspace user must see BOTH workspaces they are a member of; " <>
               "got #{inspect(visible)} with caps #{inspect(current_caps)}"

      refute "system" in visible,
             "a non-system, non-admin multi-workspace user must NOT see workspace://system (INV-7); got #{inspect(visible)}"
    end
  end

  describe "multi-workspace dispatch authority (scenario 17 steps 4-8)" do
    test "system member dispatches successfully into BOTH tenant workspaces with per-workspace caps" do
      ctx = setup_two_tenant_workspaces()

      u = URI.new!("entity://#{ctx.alpha_name}/user/#{uniq("sysmember")}")
      {:ok, _} = SpawnRegistry.spawn(u)

      # Promotion to system membership is what confers cross-workspace
      # authority (membership IS the cap — no new cap rows).
      :ok = add_to_system(u)

      # Per-workspace target-scoped caps satisfy step 5.5 for each
      # target; system membership satisfies step 5.6 for the
      # cross-workspace (beta) dispatch.
      caps =
        MapSet.new([
          session_cap_for(ctx.alpha_session, u),
          session_cap_for(ctx.beta_session, u)
        ])

      # alpha is U's home workspace — intra-workspace (5.6 trivially OK).
      assert_passed_gate(
        Invocation.dispatch(send_invocation(ctx.alpha_session, u, caps)),
        "system member dispatching into home workspace (alpha)"
      )

      # beta is a DIFFERENT workspace — cross-workspace; only passes
      # because U is a system member (5.6 membership bypass) AND holds a
      # beta-scoped cap (5.5).
      assert_passed_gate(
        Invocation.dispatch(send_invocation(ctx.beta_session, u, caps)),
        "system member dispatching cross-workspace into beta"
      )
    end

    test "non-system user with a foreign-workspace cap is denied cross-workspace (control)" do
      ctx = setup_two_tenant_workspaces()

      # Home is alpha; holds a beta-scoped cap (so step 5.5 passes for a
      # beta target), but is NOT a system member and the cap is not
      # `:any`, so step 5.6 must deny.
      u = URI.new!("entity://#{ctx.alpha_name}/user/#{uniq("tenant")}")
      caps = MapSet.new([session_cap_for(ctx.beta_session, u)])

      assert {:error, :cross_workspace_denied} =
               Invocation.dispatch(send_invocation(ctx.beta_session, u, caps)),
             "a non-system tenant user must NOT act cross-workspace even with a " <>
               "target-scoped cap — only system membership or an :any cap grants that"
    end
  end

  describe "revoking system membership revokes cross-workspace dispatch (scenario 17 failure mode)" do
    test "after removal from system, the same cross-workspace dispatch is denied again" do
      ctx = setup_two_tenant_workspaces()

      u = URI.new!("entity://#{ctx.alpha_name}/user/#{uniq("revoke")}")
      {:ok, _} = SpawnRegistry.spawn(u)
      caps = MapSet.new([session_cap_for(ctx.beta_session, u)])

      # Granted: system member → cross-workspace dispatch passes the gate.
      :ok = add_to_system(u)

      assert_passed_gate(
        Invocation.dispatch(send_invocation(ctx.beta_session, u, caps)),
        "system member before revoke (cross-workspace into beta)"
      )

      # Revoked: membership gone → the cross-workspace bypass disappears.
      :ok = remove_from_system(u)

      assert {:error, :cross_workspace_denied} =
               Invocation.dispatch(send_invocation(ctx.beta_session, u, caps)),
             "after removal from system membership, the cross-workspace dispatch " <>
               "that previously passed must fail with :cross_workspace_denied — " <>
               "proving membership (not some ambient state) was the authorizer"
    end
  end
end
