defmodule EzagentPluginGithub.GithubRoleTest do
  @moduledoc """
  github-gateway role recipe + `roles/0` 注册（RF-4，github-as-role 范式，对齐
  kanban-manager / np）。单一组合 gate（`Recipe.new(recipe)` 携判别字段成功）一次抓三点：

    * behaviors == [Ezagent.Behavior.Github]（网关 behavior，8 动作经此解析）；
    * requested_caps 是 cap-template MAP `%{behavior:, action:}`（非裸 atom，不带 kind）；
    * passive: true 流过 `Recipe.new/1`。

  role-as-data (SPEC §3/§4)：RecipeRegistry 是 `Ezagent.Agent.RecipeRegistry`（read-through
  over ConfigStore，在 `ezagent_domain_agent`）——boot SEED recipe 进 ConfigStore、`lookup`
  读穿解析。本测试走 `seed_role_if_absent → flush_cache → lookup` 复刻 boot 注册回环
  （对齐 `ezagent_plugin_py` 的 `np_role_test.exs`）。
  """
  # DataCase（非裸 ExUnit.Case）：seed→lookup 是 DB 写读（ConfigStore 持久化在 Repo），
  # 需 Ecto SQL Sandbox 的连接所有权 setup,否则 CI 高负载下 seed 的 DB 写撞
  # `DBConnection.ConnectionError owner exited`（#997 家族 sandbox 竞态）。对齐 np_role_test。
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Behavior.Github
  alias Ezagent.Agent.Recipe
  alias EzagentPluginGithub.Application, as: GithubApp

  @recipe_name "github-gateway"

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  test "github-gateway recipe 在 roles/0 里" do
    assert GithubApp.github_gateway_recipe() in GithubApp.roles()
  end

  test "RF-4 boot 注册 —— roles/0 → RecipeRegistry seed → lookup round-trip" do
    Enum.each(GithubApp.roles(), fn recipe ->
      # 全 umbrella 里 plugin boot（或前序 test）已把 recipe 种进 ConfigStore（pointer
      # 已存在）→ `seed_role_if_absent` 的 seed-once 守卫返 `{:error, {:role_seed_collision,
      # _}}`（"已在"的预期态）；隔离 test 环境则 `{:ok, _}`。两种都让 role 落进 ConfigStore
      # ——round-trip 由下面的 `lookup`（解析回带判别字段的正确 Role）权威验证。
      case RecipeRegistry.seed_role_if_absent(recipe) do
        {:ok, _} -> :ok
        {:error, {:role_seed_collision, _}} -> :ok
      end
    end)

    :ok = RecipeRegistry.flush_cache()

    assert {:ok, %Recipe{name: @recipe_name, behaviors: [Github], passive: true}} =
             RecipeRegistry.lookup(@recipe_name)
  end

  test "Recipe.new/1 接受 recipe 携判别字段（组合 gate）" do
    recipe = GithubApp.github_gateway_recipe()

    assert {:ok, %Recipe{} = role} = Recipe.new(recipe)

    assert role.behaviors == [Github]
    assert role.passive == true
    assert role.name == @recipe_name

    actions = Github.actions()
    assert length(actions) == 8
    assert length(role.requested_caps) == 8

    assert Enum.all?(role.requested_caps, fn cap ->
             is_map(cap) and cap.behavior == Github and cap.action in actions and
               not Map.has_key?(cap, :kind)
           end)

    assert MapSet.new(role.requested_caps, & &1.action) == MapSet.new(actions)
  end

  test "gateway_uri/0 = entity://system/agent/github_gateway" do
    assert URI.to_string(GithubApp.gateway_uri()) == "entity://system/agent/github_gateway"
  end
end
