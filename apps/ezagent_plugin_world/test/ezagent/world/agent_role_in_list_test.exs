defmodule Ezagent.World.AgentRoleInListTest.RoleProbeBehavior do
  @moduledoc false
  # Inline RF-5a-style probe Behavior (a real, Entity.Agent-UNDECLARED Behavior),
  # local to this test so it does not depend on ezagent_domain_workspace's
  # test-support `RoleTestBehavior` (which is not visible across apps). The role
  # recipe loads it per-instance; we only care that the agent ends up carrying a
  # durable role NAME resolvable via `UriQuery.resolve(:role, _)`.
  use Ezagent.Lifecycle, state_slice: :role_probe

  action(:ping,
    args: %{},
    returns: %{pong: :boolean},
    caps: [:ping],
    modes: [:call],
    description: "test-only probe role behavior"
  )

  def required_caps do
    %{ping: Ezagent.Capability.cap(:agent, __MODULE__, :ping)}
  end

  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{pinged: false}}

  def handle_ping(_args, _ctx), do: {:ok, %{pong: true}, [{:set, :pinged, true}]}
end

defmodule Ezagent.World.AgentRoleInListTest do
  @moduledoc """
  Layer-2 降级（2026-06-27）的后端验收门：**板 = agent**，在 Identities/agents
  列表里**按 role 过滤**就能筛出看板（`role:kanban-manager`），不再占左栏一级 nav。

  正确的隔离轴是 **role**（不是 flavor —— github-gateway 也是 native flavor，flavor
  隔离不出看板）。本测试证明 `IdentityData.list_entities/2` 通用地：

    1. 把每个带 role 的 agent 的 role NAME surface 到行（`row["role"]`）——经 sanctioned
       读路 `UriQuery.resolve(:role, uri)`（与 `flavor_for/2` 同构），不硬编码 kanban；
    2. `role:<role>` 过滤子句命中该 role 的 agent（照 `agent:<flavor>` chip 先例）；
    3. 一个**无 role** 的 agent（curl）行 `role` 为 `nil`，且不被 `role:` 过滤命中。

  通用 by-role：用一个内联注册的 throwaway native flavor + role（不依赖 kanban 插件）
  复刻 `kanban-manager` 形态，证明机制对任意带 role 的 agent 都成立。

  复用 `create_role_agent_test.exs`（RF-5a）的 native-flavor + role 注册 + 直起 spawn
  pattern；断言点搬到 world 读模型 `IdentityData.list_entities/2`。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.World.AgentRoleInListTest.RoleProbeBehavior
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias Ezagent.World.IdentityData

  @flavor "role-in-list-native"
  @role_name "role-in-list-manager"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "role-in-list-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    # A `native`-style direct-spawn flavor (unified Agent Kind, fail-closed CapMint
    # granting exactly the recipe's requested caps), inline so this test does not
    # depend on the kanban/native plugins. Mirrors create_role_agent_test.exs.
    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: @role_name,
        passive: true,
        behaviors: [RoleProbeBehavior],
        requested_caps: [%{behavior: RoleProbeBehavior, action: :ping}]
      })

    RecipeRegistry.flush_cache()

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  @tag :integration
  test "a role agent surfaces row[\"role\"] and is filtered by role:<role> (Layer-2 degrade)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      role_name = "role-agent-#{System.unique_integer([:positive])}"
      roleless_name = "roleless-agent-#{System.unique_integer([:positive])}"

      # A native agent carrying @role_name (the kanban-manager analogue).
      assert {:ok, %{agent_uri: role_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: role_name, role: @role_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      # A roleless agent (same registered native flavor, but NO role arg —
      # RF-5a: absent role → materialized nil → base behaviors only). `curl` is
      # not registered in this minimal bootstrap, so reuse @flavor.
      assert {:ok, %{agent_uri: roleless_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: roleless_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      role_uri_str = URI.to_string(role_uri)
      roleless_uri_str = URI.to_string(roleless_uri)

      # (1) The role NAME is surfaced on the agent row (generic, not kanban-specific).
      all_rows = IdentityData.list_entities(workspace_uri, "agents")
      role_row = Enum.find(all_rows, &(&1["uri"] == role_uri_str))
      roleless_row = Enum.find(all_rows, &(&1["uri"] == roleless_uri_str))

      assert role_row, "role agent absent from list_entities/agents"
      assert roleless_row, "roleless agent absent from list_entities/agents"

      assert role_row["role"] == @role_name,
             "row did not surface the agent's role NAME: #{inspect(role_row["role"])}"

      # (3) A roleless agent carries a nil role (key present so the chip layer is
      # uniform), and is NOT matched by any role: filter.
      assert Map.has_key?(roleless_row, "role")
      assert roleless_row["role"] == nil

      # (2) `role:<role>` filters to exactly the role agent (照 agent:<flavor> chip).
      role_filtered =
        IdentityData.list_entities(workspace_uri, "role:#{@role_name}")
        |> Enum.map(& &1["uri"])

      assert role_uri_str in role_filtered,
             "role:#{@role_name} did not include the role agent"

      refute roleless_uri_str in role_filtered,
             "role:#{@role_name} leaked a roleless agent"

      # A different role filter excludes our agent (no false-positive matching).
      other_filtered =
        IdentityData.list_entities(workspace_uri, "role:some-other-role")
        |> Enum.map(& &1["uri"])

      refute role_uri_str in other_filtered,
             "role:some-other-role wrongly matched the #{@role_name} agent"

      # The role agent still appears under the plain "agents" filter (degrade does
      # not hide it — it is just an agent, filterable by role).
      assert role_uri_str in Enum.map(all_rows, & &1["uri"]),
             "role agent must remain in the plain agents list (#{ws_name})"
    end)
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
