defmodule Ezagent.Integration.CreateSessionDispatchTest do
  @moduledoc """
  Acceptance tests for SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap C — `Behavior.Workspace.:create_session` action, dispatched via
  `Ezagent.Workspace.create_session/3`.

  Maps to the SPEC's Acceptance Criteria table:

    * C1: A dispatch via the `:create_session` action lands on
      `EzagentDomainChat.create_session/3` and returns the session URI
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
        URI.new!("session://#{template}/#{ws_uri.host}/#{short_name}")

      orch_uri =
        URI.new!("entity://agent/#{ws_uri.host}/cc_orchestrator-#{short_name}")

      {:ok, session_uri,
       %{
         orchestrator_uri: orch_uri,
         orchestrator_status: :ready,
         orchestrator_error: nil
       }}
    end
  end

  setup do
    ws_name = "create-session-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }

    Application.put_env(:ezagent_domain_workspace, :session_facade, FakeSessionFacade)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :session_facade)
    end)

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "C1 — dispatched :create_session reaches the facade" do
    test "happy path returns session_uri + orchestrator_uri in result map", %{
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

      assert URI.to_string(result.session_uri) == "session://default/#{ws_name}/#{short}"

      assert URI.to_string(result.orchestrator_uri) ==
               "entity://agent/#{ws_name}/cc_orchestrator-#{short}"

      assert result.orchestrator_status == :ready
      assert is_nil(result.orchestrator_error)
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
    test "result map has the 4 documented keys", %{
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

      expected_keys =
        MapSet.new([:session_uri, :orchestrator_uri, :orchestrator_status, :orchestrator_error])

      actual_keys = MapSet.new(Map.keys(result))

      assert MapSet.subset?(expected_keys, actual_keys),
             "expected result keys to include #{inspect(expected_keys)}, got #{inspect(actual_keys)}"
    end

    test "interface/0 returns spec for :create_session" do
      iface = Ezagent.Behavior.Workspace.interface()
      assert is_map(iface[:create_session])
      assert iface[:create_session].modes == [:call]

      assert Map.keys(iface[:create_session].args) |> Enum.sort() ==
               [:short_name, :template_name] |> Enum.sort()
    end

    test "required_caps/0 entry uses MODULE reference (Invariant #2)" do
      caps = Ezagent.Behavior.Workspace.required_caps()
      cap = Map.fetch!(caps, :create_session)

      assert %Ezagent.Capability{} = cap
      assert cap.kind == :workspace

      # Invariant #2: cap subject's `behavior` is the module reference,
      # NOT an atom shorthand.
      assert cap.behavior == Ezagent.Behavior.Workspace
      refute is_atom(cap.behavior) and cap.behavior == :workspace
    end
  end

  describe "C3 — CapBAC step 5.5 enforces caller's :create_session cap" do
    test "caller without :create_session cap → {:error, :unauthorized}", %{
      workspace_uri: workspace_uri
    } do
      # Spawn a non-admin user with NO caps so step 5.5 denies the
      # workspace.create_session subject.
      bare_uri = URI.new!("entity://user/system/bare-c3-#{System.unique_integer([:positive])}")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: bare_uri, initial_caps: MapSet.new()})

      bare_ctx = %{caller: bare_uri, caps: MapSet.new()}

      assert {:error, :unauthorized} =
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
end
