defmodule Ezagent.World.PluginPageRegistryTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.PluginPageRegistry

  # 迁移前 WorldLive `@kanban_actions` 的逐字拷贝（2026-07-09 快照）——注册表的
  # 动作细白名单必须与它逐一等价（行为零变化的锁）。改动这份名单 = 改动 world
  # 的 dispatch 准入面，必须是显式决策，不是注册表重构的副作用。
  # T6.4（显式决策）：`kanban.share_board` 加入 dispatch 准入白名单（分享看板动作）。
  # ⑲（显式决策 2026-07-16）：`kanban.delete_board` 加入白名单（板主人删板）。
  # 这份 verbatim 锁存在正是为了强制「改白名单 = 显式决策」，故随白名单一并更新。
  @legacy_kanban_actions ~w(kanban.add_node kanban.rename_node kanban.move_node kanban.remove_node kanban.set_stage kanban.claim_node kanban.unclaim_node kanban.set_status kanban.attach_artifact kanban.detach_artifact kanban.set_metric kanban.create kanban.sync_miro kanban.save_miro_creds kanban.select_board kanban.drop_subtree kanban.set_board_config kanban.attach_upload kanban.register_pr kanban.attach_code_file kanban.share_board kanban.delete_board)

  describe "pages/0 shape" do
    test "every page carries the full registration shape" do
      pages = PluginPageRegistry.pages()
      refute Enum.empty?(pages)

      for page <- pages do
        assert is_binary(page.key) and page.key != ""
        assert {route_path, :index} = page.route
        assert is_binary(route_path)
        assert {detail_path, :detail} = page.detail_route
        assert is_binary(detail_path)
        assert %{label: label, path: nav_path} = page.nav
        assert is_binary(label) and is_binary(nav_path)
        assert is_atom(page.data_builder)
        assert is_list(page.renderer_families) and page.renderer_families != []

        assert Enum.all?(
                 page.renderer_families,
                 &match?({type, title} when is_binary(type) and is_binary(title), &1)
               )

        assert is_list(page.action_prefixes) and page.action_prefixes != []
        assert is_list(page.actions) and page.actions != []
        assert is_atom(page.actions_module)

        # 细白名单里的每个动作必须被至少一个声明的前缀覆盖（前缀是准入粗筛，
        # 名单才是细白名单——两层必须自洽）。
        for action <- page.actions do
          assert Enum.any?(page.action_prefixes, &String.starts_with?(action, &1)),
                 "action #{action} not covered by any prefix of page #{page.key}"
        end
      end
    end

    test "kanban is registered as the first plugin page entry" do
      assert [%{key: "kanban"} = page | _] = PluginPageRegistry.pages()
      assert page.route == {"/plugins/kanban", :index}
      assert page.detail_route == {"/plugins/kanban/:id", :detail}
      assert page.nav == %{label: "看板", path: "/plugins/kanban"}
      assert page.data_builder == EzagentPluginKanban.WorldData
      assert page.renderer_families == [{"kanban", "看板"}]
      assert page.action_prefixes == ["kanban."]
      assert page.actions_module == EzagentPluginKanban.WorldActions
    end
  end

  describe "by_key/1" do
    test "returns the registered page" do
      assert %{key: "kanban"} = PluginPageRegistry.by_key("kanban")
    end

    test "fail-closed: unregistered or malformed keys return nil" do
      assert PluginPageRegistry.by_key("feishu_bindings") == nil
      assert PluginPageRegistry.by_key("") == nil
      assert PluginPageRegistry.by_key(nil) == nil
      assert PluginPageRegistry.by_key(:kanban) == nil
    end
  end

  describe "by_route/1" do
    test "index route resolves with empty params" do
      assert {%{key: "kanban"}, params} = PluginPageRegistry.by_route("/plugins/kanban")
      assert params == %{}
    end

    test "detail route resolves with the raw (still-encoded) segment" do
      encoded = URI.encode_www_form("entity://acme/agent/kanban-mgr-1")

      assert {%{key: "kanban"}, %{"id" => ^encoded}} =
               PluginPageRegistry.by_route("/plugins/kanban/#{encoded}")
    end

    test "fail-closed: non-registered or malformed paths return nil" do
      # 尾斜线 / 空 segment / 多余 segment 语义与原 `[^/]+` 正则逐一等价
      assert PluginPageRegistry.by_route("/plugins/kanban/") == nil
      assert PluginPageRegistry.by_route("/plugins/kanban/a/b") == nil
      assert PluginPageRegistry.by_route("/plugins") == nil
      assert PluginPageRegistry.by_route("/plugins/kb") == nil
      assert PluginPageRegistry.by_route("/plugins/kanbanx") == nil
      assert PluginPageRegistry.by_route("/") == nil
      assert PluginPageRegistry.by_route(nil) == nil
    end
  end

  describe "by_action/1 (dispatch admission)" do
    test "every whitelisted action resolves to its page" do
      page = PluginPageRegistry.by_key("kanban")

      for action <- page.actions do
        assert %{key: "kanban", actions_module: EzagentPluginKanban.WorldActions} =
                 PluginPageRegistry.by_action(action)
      end
    end

    test "fail-closed: prefix hit alone is NOT enough — the action must be whitelisted" do
      # `kanban.` 前缀命中但不在细白名单 → 拒绝（前缀不是放行面）
      assert PluginPageRegistry.by_action("kanban.drop_table") == nil
      assert PluginPageRegistry.by_action("kanban.") == nil
    end

    test "fail-closed: unrelated or malformed actions return nil" do
      assert PluginPageRegistry.by_action("chat.send") == nil
      assert PluginPageRegistry.by_action("kanba.add_node") == nil
      assert PluginPageRegistry.by_action("") == nil
      assert PluginPageRegistry.by_action(nil) == nil
    end
  end

  describe "kanban action whitelist equivalence (行为零变化锁)" do
    test "registry whitelist is verbatim the legacy WorldLive @kanban_actions list" do
      assert PluginPageRegistry.by_key("kanban").actions == @legacy_kanban_actions
    end

    test "registry whitelist equals the set of actions WorldActions declares handlers for" do
      # 从 WorldActions 编译产物（abstract code）导出 handle_dispatch/3 的字面
      # action 子句集合——白名单必须与实际声明逐一等价，不多（放行无处理器的
      # 动作）也不少（注册表悄悄砍掉可用动作）。
      declared = declared_actions(EzagentPluginKanban.WorldActions)
      registry = MapSet.new(PluginPageRegistry.by_key("kanban").actions)

      assert MapSet.equal?(registry, declared),
             "registry-only: #{inspect(MapSet.difference(registry, declared) |> Enum.sort())}; " <>
               "declared-only: #{inspect(MapSet.difference(declared, registry) |> Enum.sort())}"
    end
  end

  defp declared_actions(module) do
    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(:code.which(module), [:abstract_code])

    for {:function, _, :handle_dispatch, 3, clauses} <- forms,
        {:clause, _, [_socket, action_arg, _args], _guards, _body} <- clauses,
        action = literal_binary(action_arg),
        is_binary(action),
        into: MapSet.new(),
        do: action
  end

  # `"kanban.add_node"` 这类字面 binary 在 abstract code 里是单 string 元素的
  # bin;catch-all 子句的 `_action` 变量返回 nil 被上面过滤掉。
  defp literal_binary({:bin, _, [{:bin_element, _, {:string, _, chars}, :default, :default}]}),
    do: List.to_string(chars)

  defp literal_binary(_), do: nil
end
