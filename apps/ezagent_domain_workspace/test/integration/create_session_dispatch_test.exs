defmodule Ezagent.Integration.CreateSessionDispatchTest do
  @moduledoc """
  Acceptance tests for `Behavior.Workspace.:create_session`, dispatched via
  `Ezagent.Workspace.create_session/3`.

  Maps to the SPEC's Acceptance Criteria table:

    * C1: A dispatch via the `:create_session` action lands on
      `EzagentDomainInstanceMessage.SessionCreator.create_session/3` and returns the session URI
      shape the LV form produces. (We don't exercise the CLI surface
      because the auto-derived CLI is generated from `interface/0` —
      tested in `cli_lv_cap_parity_test.exs` for general parity.)
    * C2: CLI-side and LV-side return shapes are identical — invariant
      asserted structurally: the dispatched action returns the same
      session URI as a direct facade call would.
    * C3: Caller without `:create_session` cap → `{:error, :unauthorized}`
      from CapBAC step 5.5.

  These tests use the test-only facade DI so the workspace action's
  body can be exercised without booting the full chat-domain stack.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User

  # Fake session facade — record calls + return a deterministic shape.
  defmodule FakeSessionFacade do
    @moduledoc false

    def create_session(short_name, %URI{} = creator, opts) do
      Process.put({:fake_session_create, short_name},
        creator: creator,
        opts: opts
      )

      ws_uri = Keyword.fetch!(opts, :workspace_uri)
      template = Keyword.fetch!(opts, :template_name)

      session_uri =
        Ezagent.URI.session(ws_uri.host, template, short_name)

      _authority = Ezagent.Test.CapHelper.install_test_authority!(session_uri, :session)

      {:ok, session_uri, %{}}
    end
  end

  setup do
    ws_name = "create-session-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = Ezagent.URI.workspace(ws_name)

    admin_ctx = signed_workspace_ctx!(workspace_uri)

    Application.put_env(:ezagent_domain_workspace, :session_facade, FakeSessionFacade)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :session_facade)
    end)

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "C1 — dispatched :create_session reaches the facade" do
    test "happy path returns session_uri only in result map", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx,
      ws_name: ws_name
    } do
      short = "c1-#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               Workspace.create_session(
                 workspace_uri,
                 %{short_name: short, template_name: "default"},
                 admin_ctx
               )

      assert URI.to_string(result.session_uri) == "session://#{ws_name}/default/#{short}"
      refute Map.has_key?(result, :orchestrator_uri)
      refute Map.has_key?(result, :orchestrator_status)
      refute Map.has_key?(result, :orchestrator_error)
    end

    test "creator receives a session-scoped Manage cap after create", %{
      workspace_uri: workspace_uri,
      ws_name: ws_name
    } do
      creator_uri =
        Ezagent.URI.user(ws_name, "session-creator-#{System.unique_integer([:positive])}")

      create_cap =
        Ezagent.Capability.cap(
          :workspace,
          Ezagent.ActionSet.Workspace,
          :create_session,
          workspace_uri,
          workspace_uri
        )

      create_cap = signed_cap!(workspace_uri, creator_uri, create_cap)

      {:ok, _pid} =
        Ezagent.Kind.spawn(User, %{
          uri: creator_uri,
          initial_caps:
            MapSet.new([
              create_cap
            ])
        })

      short = "managed-session-#{System.unique_integer([:positive])}"

      assert {:ok, %{session_uri: session_uri}} =
               Workspace.create_session(
                 workspace_uri,
                 %{short_name: short, template_name: "default"},
                 %{
                   caller: creator_uri,
                   authenticated_principal: creator_uri,
                   caps: Ezagent.Identity.list_caps_for(creator_uri)
                 }
               )

      assert creator_has_manage_cap?(creator_uri, :session, session_uri, workspace_uri)
    end
  end

  describe "C1 — args coercion + validation" do
    test "missing short_name caught by InterfaceValidator", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # The dispatcher's InterfaceValidator (step 5.4 in Invocation.dispatch)
      # rejects with {:invalid_args, _} BEFORE the action body's own
      # `coerce_create_session_args/1` runs — both surfaces deny the
      # missing key, which is the desired behavior (defense in depth).
      assert {:error, {:invalid_args, [{[:short_name], :missing}]}} =
               Workspace.create_session(
                 workspace_uri,
                 %{template_name: "default"},
                 admin_ctx
               )
    end

    test "missing template_name caught by InterfaceValidator", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:invalid_args, [{[:template_name], :missing}]}} =
               Workspace.create_session(
                 workspace_uri,
                 %{short_name: "foo"},
                 admin_ctx
               )
    end

    test "empty short_name string returns :short_name_required from action body", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # An empty string passes the InterfaceValidator's `:string` type
      # check (it IS a binary), so the action body's
      # `coerce_create_session_args/1` rejects it.
      assert {:error, :short_name_required} =
               Workspace.create_session(
                 workspace_uri,
                 %{short_name: "", template_name: "default"},
                 admin_ctx
               )
    end
  end

  describe "C2 — CLI/LV parity (return shape invariant)" do
    test "result map has the documented session-only key", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      short = "c2-#{System.unique_integer([:positive])}"

      {:ok, result} =
        Workspace.create_session(
          workspace_uri,
          %{short_name: short, template_name: "default"},
          admin_ctx
        )

      actual_keys = MapSet.new(Map.keys(result))

      assert actual_keys == MapSet.new([:session_uri])
    end

    test "interface/0 returns spec for :create_session" do
      iface = Ezagent.ActionSet.Workspace.interface()
      assert is_map(iface[:create_session])
      assert iface[:create_session].modes == [:call]

      assert Map.keys(iface[:create_session].args) |> Enum.sort() ==
               [:short_name, :template_name] |> Enum.sort()
    end

    test "required_caps/0 entry uses MODULE reference (Invariant #2)" do
      caps = Ezagent.ActionSet.Workspace.required_caps()
      cap = Map.fetch!(caps, :create_session)

      assert %Ezagent.Capability{} = cap
      assert cap.kind == :workspace

      # Invariant #2: cap subject's `behavior` is the module reference,
      # NOT an atom shorthand.
      assert cap.behavior == Ezagent.ActionSet.Workspace
      refute is_atom(cap.behavior) and cap.behavior == :workspace
    end
  end

  describe "C3 — CapBAC step 5.5 enforces caller's :create_session cap" do
    test "caller without :create_session cap → {:error, :unauthorized}", %{
      workspace_uri: workspace_uri
    } do
      # Spawn a non-admin user with NO caps so step 5.5 denies the
      # workspace.create_session subject.
      bare_uri = URI.new!("entity://system/user/bare-c3-#{System.unique_integer([:positive])}")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: bare_uri, initial_caps: MapSet.new()})

      bare_ctx = %{caller: bare_uri, authenticated_principal: bare_uri, caps: MapSet.new()}

      assert {:error, :missing_cap} =
               Workspace.create_session(
                 workspace_uri,
                 %{short_name: "denied-c3", template_name: "default"},
                 bare_ctx
               )
    end
  end

  describe "session_facade DI" do
    test "missing facade module → {:error, {:session_facade_unavailable, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      Application.put_env(:ezagent_domain_workspace, :session_facade, NoSuchModule.Ever)

      assert {:error, {:session_facade_unavailable, NoSuchModule.Ever}} =
               Workspace.create_session(
                 workspace_uri,
                 %{short_name: "no-facade", template_name: "default"},
                 admin_ctx
               )
    end
  end

  # codex PR #408 review MED-2 — when a non-admin user is added to a
  # workspace via `Workspace.add_member/2`, they receive the
  # `Behavior.Workspace :create_session` cap automatically so they can
  # dispatch `workspace.create_session`. Per Allen's standing position
  # (`feedback_uuid_is_canonical_identifier` referenced indirectly via
  # "大部分用户不是 admin"), Gap C was meant to be available to members
  # — pre-fix the User Kind's `default_caps/1` only had a session-axis
  # wildcard, NOT a workspace-axis `:create_session` cap, so step 5.5
  # denied every non-admin caller.
  describe "codex PR #408 review MED-2 — add_member auto-grants :create_session cap" do
    test "a non-admin user added to a workspace can dispatch :create_session", %{
      workspace_uri: workspace_uri,
      ws_name: ws_name
    } do
      # Set up a non-admin user with NO caps initially.
      member_uri =
        URI.new!("entity://#{ws_name}/user/med2-#{System.unique_integer([:positive])}")

      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: member_uri, initial_caps: MapSet.new()})

      # Pre-add: dispatch denies (no :create_session cap)
      pre_ctx = %{
        caller: member_uri,
        authenticated_principal: member_uri,
        caps: MapSet.new()
      }

      assert {:error, :missing_cap} =
               Workspace.create_session(
                 workspace_uri,
                 %{
                   short_name: "pre-add-#{System.unique_integer([:positive])}",
                   template_name: "default"
                 },
                 pre_ctx
               )

      # Add as workspace member — the auto-grant fires.
      :ok = Workspace.add_member(ws_name, member_uri)

      # Read back the member's caps from the live User Kind (the grant
      # was dispatched via Invocation.dispatch → identity.grant_cap
      # which mutates the user's identity slice).
      Process.sleep(50)
      post_caps = Ezagent.Identity.list_caps_for(member_uri)

      # The :create_session cap on this workspace must be present.
      assert Enum.any?(post_caps, fn cap ->
               match?(%Ezagent.Capability{}, cap) and
                 cap.kind == :workspace and
                 cap.behavior == Ezagent.ActionSet.Workspace and
                 URI.to_string(cap.instance) == URI.to_string(workspace_uri)
             end),
             "expected :create_session cap, got #{inspect(post_caps)}"
    end

    test "codex round-2 MED-2 — dispatch-level :add_member also grants the cap (not just facade)",
         %{
           workspace_uri: workspace_uri,
           ws_name: ws_name,
           admin_ctx: admin_ctx
         } do
      # Round-1 fix only grafted the grant into the facade. Round-2 codex
      # observed: the production path is dispatch (`Invocation.dispatch`
      # → `Behavior.Workspace.invoke(:add_member, ...)`), and that path
      # was still missing the grant. This test exercises ONLY the
      # dispatch path (no facade call) and asserts the new member has
      # the cap afterwards.
      member_uri =
        URI.new!("entity://#{ws_name}/user/med2-disp-#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(User, %{uri: member_uri, initial_caps: MapSet.new()})

      # Dispatch :add_member under the authenticated admin authority used by
      # the trusted maintenance facade. Workspace has no Identity slice and
      # therefore cannot itself satisfy the holder-generation gate.
      target =
        URI.new!("#{URI.to_string(workspace_uri)}?action=workspace.add_member")

      result =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{member: member_uri},
          ctx: Map.put(admin_ctx, :reply, {:caller_inbox, self()})
        })

      assert match?(:ok, result) or match?({:ok, _}, result),
             "dispatch :add_member failed: #{inspect(result)}"

      # The grant fires inside invoke(:add_member, ...); the cap write
      # is itself a dispatched hop, so we allow a small inbox-delivery
      # window before reading caps back.
      Process.sleep(75)

      post_caps = Ezagent.Identity.list_caps_for(member_uri)

      assert Enum.any?(post_caps, fn cap ->
               match?(%Ezagent.Capability{}, cap) and
                 cap.kind == :workspace and
                 cap.behavior == Ezagent.ActionSet.Workspace and
                 URI.to_string(cap.instance) == URI.to_string(workspace_uri)
             end),
             "dispatch-level add_member must also auto-grant :create_session — got #{inspect(post_caps)}"
    end

    test "an agent member added to a workspace does NOT receive the cap (user-only grant)", %{
      ws_name: ws_name
    } do
      # Agents don't drive create_session — the grant is gated on
      # `entity://user/...` URI shape.
      agent_uri =
        URI.new!("entity://#{ws_name}/agent/cc_test-#{System.unique_integer([:positive])}")

      # Spawn the agent first so the lookup doesn't fail.
      _ = Ezagent.SpawnRegistry.spawn(agent_uri)

      :ok = Workspace.add_member(ws_name, agent_uri)

      Process.sleep(50)
      caps = Ezagent.Identity.list_caps_for(agent_uri)

      refute Enum.any?(caps, fn cap ->
               match?(%Ezagent.Capability{}, cap) and
                 cap.behavior == Ezagent.ActionSet.Workspace
             end),
             "agent member must NOT receive :create_session cap; got #{inspect(caps)}"
    end
  end

  defp creator_has_manage_cap?(creator_uri, kind, instance_uri, workspace_uri) do
    creator_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(fn
      %Ezagent.Capability{} = cap ->
        cap.kind == kind and
          cap.behavior == Ezagent.ActionSet.Manage and
          cap.action == :any and
          URI.to_string(cap.instance) == URI.to_string(instance_uri) and
          URI.to_string(cap.workspace_uri) == URI.to_string(workspace_uri) and
          URI.to_string(cap.granted_by) == URI.to_string(creator_uri) and
          URI.to_string(cap.grantee_uri) == URI.to_string(creator_uri) and
          is_binary(cap.signature) and byte_size(cap.signature) > 0

      _ ->
        false
    end)
  end
end
