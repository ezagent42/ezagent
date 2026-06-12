defmodule EzagentPluginAutoservice.RolesTest do
  @moduledoc """
  Tests for EzagentPluginAutoservice.Roles — CapBAC role bundles.

  Covers:
  1. Each bundle/2 returns the correct caps with correct field shapes.
  2. After ensure_customer, list_caps_for(customer_uri) includes customer role caps.
  3. After ensure_operator, list_caps_for(operator_uri) includes operator role caps.
  4. After ensure_admin, list_caps_for(admin_uri) includes tenant_admin role caps.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.Identity
  alias EzagentPluginAutoservice.{Assembly, Roles}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ws(tid), do: Ezagent.URI.workspace(tid)

  defp unique_tid, do: "roles-test-#{System.unique_integer([:positive])}"

  defp caps_include_exact?(caps_mapset, kind, behavior, action) do
    Enum.any?(caps_mapset, fn cap ->
      cap.kind == kind and
        (cap.behavior == behavior or cap.behavior == :any) and
        (cap.action == action or cap.action == :any) and
        match?(%Capability{}, cap)
    end)
  end

  # ---------------------------------------------------------------------------
  # Unit tests: bundle/2 shape correctness
  # ---------------------------------------------------------------------------

  describe "Roles.bundle(:master_admin, ws)" do
    test "returns 3 caps with :any workspace_uri" do
      ws = ws("ignored-ws")
      caps = Roles.bundle(:master_admin, ws)
      assert length(caps) == 3
      assert Enum.all?(caps, fn cap -> cap.workspace_uri == :any end)
      assert Enum.all?(caps, fn cap -> match?(%Capability{}, cap) end)
      assert caps_include_exact?(MapSet.new(caps), :workspace, :any, :any)
      assert caps_include_exact?(MapSet.new(caps), :content, :any, :write)
      assert caps_include_exact?(MapSet.new(caps), :user, :any, :create)
    end

    test "each cap has granted_by = admin_uri and a recent granted_at" do
      ws = ws("ignored-ws")
      caps = Roles.bundle(:master_admin, ws)
      admin_uri = User.admin_uri()
      before = DateTime.utc_now()

      Enum.each(caps, fn cap ->
        assert cap.granted_by == admin_uri
        assert DateTime.compare(cap.granted_at, before) in [:lt, :eq]
      end)
    end
  end

  describe "Roles.bundle(:tenant_admin, ws)" do
    test "returns 3 ws-scoped caps" do
      ws = ws("tenant-admin-ws-1")
      caps = Roles.bundle(:tenant_admin, ws)
      assert length(caps) == 3
      assert Enum.all?(caps, fn cap -> cap.workspace_uri == ws end)
      assert Enum.all?(caps, fn cap -> match?(%Capability{}, cap) end)
    end

    test "includes workspace:any, content:write, user:create_user" do
      ws = ws("tenant-admin-ws-2")
      caps_ms = MapSet.new(Roles.bundle(:tenant_admin, ws))
      assert caps_include_exact?(caps_ms, :workspace, Ezagent.Behavior.Workspace, :any)
      assert caps_include_exact?(caps_ms, :content, :any, :write)

      assert caps_include_exact?(
               caps_ms,
               :user,
               Ezagent.Behavior.WorkspaceUserAdmin,
               :create_user
             )
    end

    test "instance is the workspace URI (not :any)" do
      ws = ws("tenant-admin-ws-3")
      caps = Roles.bundle(:tenant_admin, ws)
      assert Enum.all?(caps, fn cap -> cap.instance == ws end)
    end
  end

  describe "Roles.bundle(:operator, ws)" do
    test "returns 5 caps (3 spec + 2 orchestrator extension)" do
      ws = ws("op-ws-1")
      caps = Roles.bundle(:operator, ws)
      # 3 spec caps + 2 orchestrator dispatch caps
      assert length(caps) == 5
      assert Enum.all?(caps, fn cap -> cap.workspace_uri == ws end)
    end

    test "includes session:join, turn:claim, turn:settle" do
      ws = ws("op-ws-2")
      caps_ms = MapSet.new(Roles.bundle(:operator, ws))
      assert caps_include_exact?(caps_ms, :session, :any, :join)
      assert caps_include_exact?(caps_ms, :turn, Ezagent.Behavior.Turn, :claim)
      assert caps_include_exact?(caps_ms, :turn, Ezagent.Behavior.Turn, :settle)
    end

    test "includes cs_orchestrator:operator_claim and operator_settle (SPEC extension)" do
      ws = ws("op-ws-3")
      caps_ms = MapSet.new(Roles.bundle(:operator, ws))

      assert caps_include_exact?(
               caps_ms,
               :cs_orchestrator,
               Ezagent.Behavior.CsOrchestrator,
               :operator_claim
             )

      assert caps_include_exact?(
               caps_ms,
               :cs_orchestrator,
               Ezagent.Behavior.CsOrchestrator,
               :operator_settle
             )
    end
  end

  describe "Roles.bundle(:customer, ws)" do
    test "returns 2 ws-scoped caps" do
      ws = ws("cust-ws-1")
      caps = Roles.bundle(:customer, ws)
      assert length(caps) == 2
      assert Enum.all?(caps, fn cap -> cap.workspace_uri == ws end)
    end

    test "includes session:send and session:receive" do
      ws = ws("cust-ws-2")
      caps_ms = MapSet.new(Roles.bundle(:customer, ws))
      assert caps_include_exact?(caps_ms, :session, :any, :send)
      assert caps_include_exact?(caps_ms, :session, :any, :receive)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tests: caps granted via Assembly are queryable via Identity
  # ---------------------------------------------------------------------------

  describe "ensure_customer grants customer role caps" do
    test "Identity.list_caps_for(customer_uri) includes session:send and session:receive", %{} do
      tid = unique_tid()

      ctx = %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
      }

      assert {:ok, %{customer_uri: customer_uri}} =
               Assembly.provision_session(tid, "alice", ctx, create_agents: false)

      caps = Identity.list_caps_for(customer_uri)
      ws = ws(tid)

      assert caps_include_exact?(caps, :session, :any, :send),
             "expected session:send cap after ensure_customer; caps: #{inspect(MapSet.to_list(caps))}"

      assert caps_include_exact?(caps, :session, :any, :receive),
             "expected session:receive cap after ensure_customer; caps: #{inspect(MapSet.to_list(caps))}"

      # All customer caps must be ws-scoped (not :any workspace)
      customer_caps =
        caps
        |> Enum.filter(fn cap -> cap.kind == :session end)

      assert Enum.all?(customer_caps, fn cap ->
               cap.workspace_uri == ws or cap.workspace_uri == :any
             end),
             "expected all session caps to be scoped to #{URI.to_string(ws)}; " <>
               "got: #{inspect(Enum.map(customer_caps, & &1.workspace_uri))}"
    end
  end

  describe "ensure_operator grants operator role caps" do
    test "Identity.list_caps_for(operator_uri) includes operator caps", %{} do
      tid = unique_tid()

      ctx = %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
      }

      # Provision a customer first (workspace must exist)
      assert {:ok, _} = Assembly.provision_session(tid, "alice", ctx, create_agents: false)

      assert {:ok, operator_uri} = Assembly.ensure_operator(tid, "bob")
      caps = Identity.list_caps_for(operator_uri)
      ws = ws(tid)

      assert caps_include_exact?(caps, :session, :any, :join),
             "expected session:join cap; caps: #{inspect(MapSet.to_list(caps))}"

      assert caps_include_exact?(caps, :turn, Ezagent.Behavior.Turn, :claim),
             "expected turn:claim cap; caps: #{inspect(MapSet.to_list(caps))}"

      assert caps_include_exact?(caps, :turn, Ezagent.Behavior.Turn, :settle),
             "expected turn:settle cap; caps: #{inspect(MapSet.to_list(caps))}"

      assert caps_include_exact?(
               caps,
               :cs_orchestrator,
               Ezagent.Behavior.CsOrchestrator,
               :operator_claim
             ),
             "expected cs_orchestrator:operator_claim cap; caps: #{inspect(MapSet.to_list(caps))}"

      # All operator caps must be scoped to the operator's workspace
      operator_role_caps =
        caps
        |> Enum.filter(fn cap ->
          cap.kind in [:session, :turn, :cs_orchestrator] and
            cap.workspace_uri != :any
        end)

      assert Enum.all?(operator_role_caps, fn cap -> cap.workspace_uri == ws end),
             "expected all role caps to be ws-scoped; " <>
               "got: #{inspect(Enum.map(operator_role_caps, & &1.workspace_uri))}"
    end
  end

  describe "ensure_admin grants tenant_admin role caps" do
    test "Identity.list_caps_for(admin_uri) includes tenant_admin caps", %{} do
      tid = unique_tid()

      ctx = %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
      }

      # Provision a customer first (workspace must exist)
      assert {:ok, _} = Assembly.provision_session(tid, "alice", ctx, create_agents: false)

      assert {:ok, admin_uri} = Assembly.ensure_admin(tid, "carol")
      caps = Identity.list_caps_for(admin_uri)
      ws = ws(tid)

      assert caps_include_exact?(caps, :workspace, Ezagent.Behavior.Workspace, :any),
             "expected workspace:any cap; caps: #{inspect(MapSet.to_list(caps))}"

      assert caps_include_exact?(caps, :content, :any, :write),
             "expected content:write cap; caps: #{inspect(MapSet.to_list(caps))}"

      assert caps_include_exact?(
               caps,
               :user,
               Ezagent.Behavior.WorkspaceUserAdmin,
               :create_user
             ),
             "expected user:create_user cap; caps: #{inspect(MapSet.to_list(caps))}"

      # All tenant_admin caps must be scoped to the admin's workspace
      admin_role_caps =
        caps
        |> Enum.filter(fn cap ->
          cap.kind in [:workspace, :content, :user] and
            cap.workspace_uri != :any
        end)

      assert Enum.all?(admin_role_caps, fn cap -> cap.workspace_uri == ws end),
             "expected all tenant_admin caps to be ws-scoped to #{URI.to_string(ws)}; " <>
               "got: #{inspect(Enum.map(admin_role_caps, & &1.workspace_uri))}"
    end
  end
end
