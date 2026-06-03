defmodule EzagentCore.Invariants.CrossWorkspaceIsolationTest do
  @moduledoc """
  Phase 9 PR-4 (SPEC v3 §5) invariant — cross-workspace dispatch is
  denied unless the caller holds a cross-workspace cap
  (`workspace_uri: :any`).

  This is the gate test per memory
  `feedback_completion_requires_invariant_test`: PR-4 is "done" iff
  this test passes AND would fail if `Ezagent.Kind.Runtime`'s step
  5.6 (workspace isolation) were removed. Specifically, if any of:

  - `workspace_isolation_check/2` deleted from the `with` chain
  - the `:cross_workspace_denied` atom replaced with `:unauthorized`
  - the cross-workspace cap predicate (`Capability.cross_workspace?/1`)
    flipped to `true` for non-`:any` workspace_uri
  - `Ezagent.Capability.workspace_of/1` returns `:any` for a concrete
    entity URI (would let everything through)

  then one or more of the assertions below would fail.

  ## Setup

  Two workspaces (`tenant-beta-*` + `team-alpha-*`), one user per workspace.
  Default user gets the standard `User.default_caps/1` (session.* in
  its own workspace). Both spawned via `SpawnRegistry.spawn/1` so
  they're alive in `KindRegistry`. A session is spawned in each
  workspace and bound via `WorkspaceRegistry.bind/2` (invariant 4).

  ## Test sequence (5 assertions)

  1. Intra-workspace dispatch (default → default session) succeeds
     — positive control; ensures the cap structurally matches.
  2. Cross-workspace dispatch WITHOUT the cross-workspace cap fails
     with `{:error, :cross_workspace_denied}` (NOT `:unauthorized` —
     invariant 9).
  3. Grant the user a cross-workspace cap (`workspace_uri: :any`);
     same dispatch now succeeds — the cap bypasses isolation.
  4. Revoke the cross-workspace cap; dispatch fails again with
     `:cross_workspace_denied`.
  5. The bootstrap admin (holding `User.admin_caps/0` which has
     `workspace_uri: :any` by construction) bypasses isolation by
     default — verifies the admin escape hatch still works.

  See `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md`
  §5 + §9 PR-4 row.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation, Message, SpawnRegistry, WorkspaceRegistry}
  alias Ezagent.Entity.User

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Build a `chat.send` invocation from `caller` to `session_uri` with
  # the supplied caps MapSet. Mode `:call` so cap denial / isolation
  # denial bubble back synchronously (the production inbound transport
  # uses the same override per Decision #134).
  defp send_invocation(session_uri, caller_uri, caps) do
    msg = Message.new(caller_uri, %{text: "hello", attachments: []})

    %Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=chat.send"),
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: caller_uri, caps: caps, reply: :ignore}
    }
  end

  # Construct the workspace-scoped session.send cap for a given
  # workspace. This mirrors the cap shape `User.default_caps/1` mints
  # but bound to a specific workspace + explicit instance:`:any` so
  # we can plug in either workspace's session URI.
  #
  # IMPORTANT: PR-3's matcher already rejects this cap for a target in
  # a DIFFERENT workspace at step 5.5 (workspace dimension on the cap
  # matcher). So step 5.6 (caller↔target workspace check) only fires
  # when caller HOLDS a cap that matches the TARGET workspace yet the
  # caller's own workspace differs. The natural shape is "admin in
  # workspace A explicitly granted me a cap scoped to workspace B" —
  # then 5.5 passes but 5.6 should deny unless I also hold a
  # cross-workspace cap.
  defp session_cap_for(workspace_uri) do
    %Capability{
      kind: :session,
      behavior: :any,
      instance: :any,
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: ~U[2026-05-21 00:00:00Z]
    }
  end

  # Cross-workspace cap — same shape as default_caps but
  # `workspace_uri: :any`. This is the structural cross-workspace
  # marker per SPEC v3 §5.1.
  defp cross_workspace_cap do
    %Capability{
      kind: :session,
      behavior: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: User.admin_uri(),
      granted_at: ~U[2026-05-21 00:00:00Z]
    }
  end

  defp setup_scenario do
    suffix = unique("xws")

    # Two non-system tenant workspaces. The test deliberately avoids
    # `workspace://system` because system-workspace members hold
    # cross-workspace authority by membership (SPEC v3 §13.1 + invariant
    # 13) — the very property under test here would short-circuit.
    # Both `tenant-beta` and `team-alpha` are plain tenant names.
    tenant_beta_name = "tenant-beta-#{suffix}"
    tenant_beta_uri = URI.new!("workspace://#{tenant_beta_name}")

    team_alpha_name = "team-alpha-#{suffix}"
    team_alpha_uri = URI.new!("workspace://#{team_alpha_name}")

    {:ok, _} = Ezagent.Workspace.spawn_workspace(tenant_beta_name)
    {:ok, _} = Ezagent.Workspace.spawn_workspace(team_alpha_name)

    # Two sessions, one per workspace. Use SpawnRegistry to follow the
    # plugin-isolation contract (Loader / Session.spawn_from_template
    # both go through this).
    # SPEC v3 §3.6 (Phase 9 PR-7) — 3-segment session URIs carry
    # workspace as the second path segment. The first segment is the
    # template; we use `default` here since these test sessions don't
    # spawn from a template class.
    default_session_uri = URI.new!("session://default/#{tenant_beta_name}/#{suffix}-main")

    team_alpha_session_uri =
      URI.new!("session://default/#{team_alpha_name}/#{suffix}-main")

    {:ok, _} = SpawnRegistry.spawn(default_session_uri)
    {:ok, _} = SpawnRegistry.spawn(team_alpha_session_uri)

    default_workspace_uri = tenant_beta_uri
    :ok = WorkspaceRegistry.bind(default_session_uri, default_workspace_uri)
    :ok = WorkspaceRegistry.bind(team_alpha_session_uri, team_alpha_uri)

    # tenant-beta user. We don't actually need to spawn the User
    # Kind for this test — dispatch reads caller URI as identity and
    # caps from ctx — but spawning so the URI is a "real" entity in
    # case future invariants assert principal existence.
    default_user_name = unique("user-default")
    default_user_uri = URI.new!("entity://user/#{tenant_beta_name}/#{default_user_name}")
    {:ok, _} = SpawnRegistry.spawn(default_user_uri)

    # team-alpha user — spawn after the workspace exists so its
    # workspace_uri derivation in any future hook works.
    team_alpha_user_name = unique("user-alpha")

    team_alpha_user_uri =
      URI.new!("entity://user/#{team_alpha_name}/#{team_alpha_user_name}")

    {:ok, _} = SpawnRegistry.spawn(team_alpha_user_uri)

    %{
      default_workspace_uri: default_workspace_uri,
      team_alpha_workspace_uri: team_alpha_uri,
      default_session_uri: default_session_uri,
      team_alpha_session_uri: team_alpha_session_uri,
      default_user_uri: default_user_uri,
      team_alpha_user_uri: team_alpha_user_uri
    }
  end

  describe "cross-workspace dispatch policy (SPEC v3 §5)" do
    test "intra-workspace dispatch passes step 5.5 + 5.6 (positive control)" do
      ctx = setup_scenario()

      caps = MapSet.new([session_cap_for(ctx.default_workspace_uri)])

      inv = send_invocation(ctx.default_session_uri, ctx.default_user_uri, caps)

      # Intra-workspace; both caller and target are in workspace://default.
      # The PR-4 gate question is: does the dispatch get PAST step 5.5
      # (CapBAC) and step 5.6 (workspace isolation)? Downstream stages
      # (Chat.send DB INSERT) may race the Ecto sandbox under parallel
      # load — that's orthogonal to the workspace check. So we accept
      # ANY result OTHER than :unauthorized or :cross_workspace_denied
      # as proof that both 5.5 and 5.6 cleared.
      result = Invocation.dispatch(inv)

      refute match?({:error, :unauthorized}, result),
             "intra-workspace dispatch denied at step 5.5 (cap matcher) — " <>
               "the test's session_cap_for/1 cap doesn't structurally match. " <>
               "Got: #{inspect(result)}"

      refute match?({:error, :cross_workspace_denied}, result),
             "intra-workspace dispatch denied at step 5.6 (workspace " <>
               "isolation) — caller default + target default should never " <>
               "trigger isolation. Got: #{inspect(result)}"
    end

    test "cross-workspace dispatch WITHOUT cross-workspace cap → :cross_workspace_denied" do
      ctx = setup_scenario()

      # Caller in workspace://default, target session in workspace://team-alpha.
      # The cap is scoped to TARGET's workspace (team-alpha) — this is the
      # "admin in workspace-default granted me a team-alpha cap" pattern,
      # so step 5.5 (cap matcher) PASSES (cap.workspace matches needed
      # team-alpha). Step 5.6 then fires the caller↔target check: caller
      # is in default, target is in team-alpha, and no cap has
      # workspace_uri: :any. Expected: :cross_workspace_denied.
      caps = MapSet.new([session_cap_for(ctx.team_alpha_workspace_uri)])

      inv = send_invocation(ctx.team_alpha_session_uri, ctx.default_user_uri, caps)

      assert {:error, :cross_workspace_denied} = Invocation.dispatch(inv),
             "PR-4 step 5.6 must deny cross-workspace dispatch when the caller " <>
               "doesn't hold a cross-workspace cap. If this returns :unauthorized, " <>
               "either (a) the cap matcher denied at 5.5 first (rebuild the cap " <>
               "with workspace_uri matching the TARGET workspace) or (b) step 5.6 " <>
               "was removed. If this returns :ok, step 5.6 isn't running."
    end

    test "cross-workspace dispatch WITH cross-workspace cap → passes step 5.6" do
      ctx = setup_scenario()

      # Add the cross-workspace cap (workspace_uri: :any). The cap's
      # :any workspace passes both step 5.5 (matches any needed workspace)
      # AND step 5.6 (cross_workspace? returns true → bypass). The
      # team-alpha-scoped cap from above isn't strictly needed, but we
      # keep it to mirror the "caller has 2 caps, one of them is the
      # cross-workspace one" case.
      caps =
        MapSet.new([
          session_cap_for(ctx.team_alpha_workspace_uri),
          cross_workspace_cap()
        ])

      inv = send_invocation(ctx.team_alpha_session_uri, ctx.default_user_uri, caps)

      result = Invocation.dispatch(inv)

      refute match?({:error, :cross_workspace_denied}, result),
             "cross-workspace cap (workspace_uri: :any) must let step 5.6 " <>
               "pass even when caller's workspace differs from target's. " <>
               "Got #{inspect(result)} — Capability.cross_workspace?/1 likely " <>
               "stopped recognizing :any as the bypass marker."

      refute match?({:error, :unauthorized}, result),
             "cross-workspace cap + target-scoped cap must satisfy step 5.5 " <>
               "too. Got #{inspect(result)}."
    end

    test "revoke cross-workspace cap → dispatch fails again with :cross_workspace_denied" do
      ctx = setup_scenario()

      cross_cap = cross_workspace_cap()
      target_scoped_cap = session_cap_for(ctx.team_alpha_workspace_uri)

      # Grant: dispatch passes 5.6.
      caps_with = MapSet.new([target_scoped_cap, cross_cap])

      inv_with =
        send_invocation(ctx.team_alpha_session_uri, ctx.default_user_uri, caps_with)

      result_with = Invocation.dispatch(inv_with)

      refute match?({:error, :cross_workspace_denied}, result_with),
             "grant path: cross-workspace cap failed to bypass step 5.6; " <>
               "got #{inspect(result_with)}"

      # Revoke: dispatch fails again. Capability.revoke/2 returns
      # {:ok, new_caps} for non-admin-invariant caps. After revoke the
      # caller still has the team-alpha-scoped cap (so 5.5 still
      # passes) but no longer has the cross-workspace cap (so 5.6
      # fires).
      assert {:ok, caps_without} = Capability.revoke(caps_with, cross_cap)

      inv_without =
        send_invocation(ctx.team_alpha_session_uri, ctx.default_user_uri, caps_without)

      assert {:error, :cross_workspace_denied} = Invocation.dispatch(inv_without),
             "after revoke, cross-workspace dispatch must fail again with " <>
               ":cross_workspace_denied — proves the cap is what was authorizing " <>
               "the bypass (not some other ambient state)."
    end

    test "bootstrap admin (admin_caps/0) bypasses workspace isolation by default" do
      ctx = setup_scenario()

      # admin_caps/0 returns a MapSet with one cap that has
      # workspace_uri: :any — the structural cross-workspace admin
      # invariant per SPEC v3 §4.4. Admin dispatching into any
      # workspace must pass step 5.6 without any additional grant.
      inv =
        send_invocation(ctx.team_alpha_session_uri, User.admin_uri(), Ezagent.SystemPrincipal.caps("system://bootstrap"))

      result = Invocation.dispatch(inv)

      refute match?({:error, :cross_workspace_denied}, result),
             "admin's bootstrap cap must bypass workspace isolation; " <>
               "got #{inspect(result)}. If this fails, either admin_caps/0 " <>
               "lost workspace_uri: :any, or cross_workspace?/1 stopped " <>
               "treating :any as the bypass marker — both are SPEC v3 §4.4 " <>
               "regressions."

      refute match?({:error, :unauthorized}, result),
             "admin's all-:any cap must satisfy step 5.5 too. Got #{inspect(result)}."
    end

    test ":cross_workspace_denied is a DISTINCT atom from :unauthorized (invariant 9)" do
      ctx = setup_scenario()

      # An empty caps set — step 5.5 (CapBAC) fails BEFORE step 5.6
      # gets a chance to run. This must return :unauthorized, NOT
      # :cross_workspace_denied — the two are different failure modes
      # and inbound transports surface them with different reaction
      # emojis (THUMBSDOWN vs NO) per Phase 9 PR-4 inbound dispatcher.
      empty_caps = MapSet.new()

      inv =
        send_invocation(ctx.team_alpha_session_uri, ctx.default_user_uri, empty_caps)

      assert {:error, :unauthorized} = Invocation.dispatch(inv),
             "empty caps → step 5.5 cap denial → :unauthorized. " <>
               "If this returns :cross_workspace_denied, step 5.6 has " <>
               "incorrectly run before step 5.5 (broken `with` ordering) " <>
               "or the two atoms have been collapsed."
    end
  end
end
