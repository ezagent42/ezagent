defmodule Ezagent.WorkspaceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Workspace, as: WK
  alias Ezagent.{Invocation, KindRegistry}

  setup do
    # Spawn workspaces under unique names so async tests don't collide.
    # async: false at module level guarantees serial execution within this
    # file (other test files can still run concurrently).
    :ok
  end

  describe "spawn_workspace/2" do
    test "starts a Kind and registers workspace://<name>" do
      name = "spawn-test-#{System.unique_integer([:positive])}"
      uri = WK.uri_for(name)

      assert {:ok, pid} = Ezagent.Workspace.spawn_workspace(name)
      assert is_pid(pid)
      assert {:ok, ^pid} = KindRegistry.lookup(uri)
    end

    test "second spawn at same URI returns {:error, {:already_started, pid}}" do
      name = "dup-test-#{System.unique_integer([:positive])}"

      {:ok, pid1} = Ezagent.Workspace.spawn_workspace(name)
      assert {:error, {:already_started, ^pid1}} = Ezagent.Workspace.spawn_workspace(name)
    end

    test "members in initial args are reachable via :list_members dispatch" do
      name = "members-test-#{System.unique_integer([:positive])}"
      uri = WK.uri_for(name)

      members = [
        Ezagent.URI.new!("entity://system/user/admin"),
        Ezagent.URI.new!("entity://team-alpha/agent/test_x")
      ]

      {:ok, _pid} = Ezagent.Workspace.spawn_workspace(name, %{members: members})

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=workspace.list_members")

      assert {:ok, %{members: listed}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{},
                 ctx: %{
                   caller: Ezagent.Entity.User.admin_uri(),
                   authenticated_principal: Ezagent.Entity.User.admin_uri(),
                   caps:
                     MapSet.new([signed_action_cap!(target, Ezagent.Entity.User.admin_uri())]),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert length(listed) == 2
    end
  end

  describe "instantiate via dispatch" do
    test ":instantiate returns one child per member" do
      name = "inst-test-#{System.unique_integer([:positive])}"
      uri = WK.uri_for(name)

      members = [
        Ezagent.URI.new!("entity://system/user/admin"),
        Ezagent.URI.new!("entity://team-alpha/agent/test_cc-builder")
      ]

      {:ok, _pid} = Ezagent.Workspace.spawn_workspace(name, %{members: members})

      target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=workspace.instantiate")

      assert {:ok, %{children: children}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{},
                 ctx: %{
                   caller: Ezagent.Entity.User.admin_uri(),
                   authenticated_principal: Ezagent.Entity.User.admin_uri(),
                   caps:
                     MapSet.new([signed_action_cap!(target, Ezagent.Entity.User.admin_uri())]),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert length(children) == 2
      assert Enum.all?(children, fn {:member, %URI{}} -> true end)
    end
  end

  describe "list_workspaces/0" do
    test "returns URIs for every live workspace://" do
      name1 = "list-a-#{System.unique_integer([:positive])}"
      name2 = "list-b-#{System.unique_integer([:positive])}"

      {:ok, _} = Ezagent.Workspace.spawn_workspace(name1)
      {:ok, _} = Ezagent.Workspace.spawn_workspace(name2)

      uris = Ezagent.Workspace.list_workspaces() |> Enum.map(&URI.to_string/1)

      assert "workspace://#{name1}" in uris
      assert "workspace://#{name2}" in uris
    end
  end

  describe "create/2 derivation provenance" do
    test "workspace ownership is committed with the durable workspace row" do
      name = "derivation-#{System.unique_integer([:positive])}"
      owner = Ezagent.URI.user(:system, :admin)
      workspace_uri = Ezagent.URI.workspace(name)

      assert {:ok, _pid} = Ezagent.Workspace.create(name, %{created_by: owner})
      assert workspace_uri in Ezagent.Provenance.DerivationEdges.descendants(owner)
    end
  end

  describe "add_member/2 — dispatch-first persistence (task #55 codex r2 CRIT-1)" do
    # Pre-fix: facade persisted via `Store.update_members/2` BEFORE
    # dispatching, so a Behavior-rejected cross-prefix member URI hit
    # `workspaces.member_uris` regardless of validator outcome. Post-fix:
    # dispatch runs FIRST through `:call`, the validator rejects, and the
    # facade exits with `{:error, ...}` WITHOUT touching the Store.

    test "Behavior validator rejection leaves DB row untouched" do
      name = "crit1-reject-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name, %{})

      # Snapshot the persisted member list before the rejected call.
      %{members: members_before} = Ezagent.Workspace.Store.get_by_name(name)

      # Cross-prefix violator — `entity://system/user/linyilun` inside
      # workspace `<name>` (whose own URI prefix is `<name>`).
      bad_uri = Ezagent.URI.new!("entity://system/user/linyilun")

      assert {:error, {:cross_workspace_member_not_permitted, ^bad_uri, _workspace_uri}} =
               Ezagent.Workspace.add_member(name, bad_uri)

      # DB must be untouched — the bad URI MUST NOT appear in the
      # persisted member list.
      %{members: members_after} = Ezagent.Workspace.Store.get_by_name(name)
      assert members_after == members_before

      refute Enum.any?(members_after, fn %URI{} = u ->
               URI.to_string(u) == URI.to_string(bad_uri)
             end)
    end

    test "happy-path same-prefix member IS persisted" do
      name = "crit1-accept-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name, %{})

      good_uri = Ezagent.URI.new!("entity://#{name}/user/alice")

      assert :ok = Ezagent.Workspace.add_member(name, good_uri)

      %{members: members_after} = Ezagent.Workspace.Store.get_by_name(name)

      assert Enum.any?(members_after, fn %URI{} = u ->
               URI.to_string(u) == URI.to_string(good_uri)
             end)
    end
  end

  describe "add_member/3 + remove_member/3 caller-ctx fail-closed (SPEC §7, codex HIGH)" do
    # The cap-checked `/3` variants must REJECT ambient-authority caller
    # shapes (`:system`, nil, atom, string, missing caps) BEFORE any
    # dispatch — so a programmatic caller that accidentally reaches `/3`
    # cannot slip past step 5.5 via Runtime's `default_holds_cap?(:system)`
    # all-caps bypass. Trusted ambient callers MUST use `/2`.

    test "add_member/3 with caller: :vm_internal is rejected (no membership change)" do
      name = "ctx-sys-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name, %{})
      member = Ezagent.URI.new!("entity://#{name}/user/mallory")

      before = Ezagent.Workspace.Store.get_by_name(name).members

      assert {:error, :invalid_caller_ctx} =
               Ezagent.Workspace.add_member(name, member, %{caller: :vm_internal, caps: []})

      assert Ezagent.Workspace.Store.get_by_name(name).members == before
    end

    test "add_member/3 / remove_member/3 reject malformed ctx shapes" do
      name = "ctx-bad-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name, %{})
      member = Ezagent.URI.new!("entity://#{name}/user/bob")

      for bad <- [
            %{caller: "entity://#{name}/user/x", caps: []},
            %{caller: nil, caps: []},
            %{caller: Ezagent.URI.new!("entity://#{name}/user/x"), caps: :nope},
            %{caps: []},
            %{}
          ] do
        assert {:error, :invalid_caller_ctx} =
                 Ezagent.Workspace.add_member(name, member, bad)

        assert {:error, :invalid_caller_ctx} =
                 Ezagent.Workspace.remove_member(name, member, bad)
      end
    end

    test "add_member/3 with a well-formed %URI{} caller + list caps passes the ctx guard" do
      # A concrete URI caller carrying (empty) list caps passes the ctx
      # guard and proceeds to the real cap-check (which then DENIES on
      # caps) — proving the guard admits the legitimate shape, not that
      # the dispatch authorizes.
      name = "ctx-ok-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name, %{})
      member = Ezagent.URI.new!("entity://#{name}/user/carol")
      caller = Ezagent.URI.new!("entity://#{name}/user/nonadmin")

      assert Ezagent.Workspace.add_member(name, member, %{
               caller: caller,
               authenticated_principal: caller,
               caps: []
             }) !=
               {:error, :invalid_caller_ctx}
    end
  end
end
