defmodule EzagentPluginKanban.MemberBackfillKanbanRenderTest do
  @moduledoc """
  D3 供给半件（声明侧）acceptance —— 用 **真 kanban socialware**（deploy-seed
  manifest，非替身 ActionSet）证全链：

    manifest `views: [kanban_render]`
      → `ManifestResolver.resolve` 出 `Definition.views == [KanbanRender]`
      → 装到 session 后 `Installation.declared_view_actions/1` 枚举到
        `{KanbanRender, :kanban_render}`
      → 新成员入会（`MemberBackfill.backfill/2`，join/receive 各入口共用的
        补发 funnel）即持 `{Session, :kanban_render}` cap
      → `SessionView.authorize_view/3` 放行（tab 恒显 + 列表能渲染的权限半边）。

  零 domain 改动 —— domain 侧机制（declared_view_actions + MemberBackfill，
  main #1462/#1466）原样消费 kanban 的声明；本测试锁的是 **kanban 声明写全**
  这半件（声明缺了任何一环，本测试红）。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{DefinitionRegistry, Installation, ManifestResolver, MemberBackfill}
  alias Ezagent.Socialware.ShippedManifest
  alias Ezagent.ActionSet.KanbanRender

  @manifest_relpath "kanban/manifest.yaml"
  @workspace_uri Ezagent.URI.new!("workspace://system")
  @actor Ezagent.URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  # session 落 workspace://system —— install 写入与 `installed_definitions/1`
  # 按 session URI 推 workspace 一致（member_backfill_test 同款）。
  defp session_uri, do: Ezagent.URI.new!("session://system/default/kanban-d3-#{uniq()}")

  # confirmed 用户 + 拉起 Kind（grant 落 slice 需要）。
  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # 装真 kanban socialware：deploy-seed manifest（per-run 唯一名，测试隔离 seam）
  # → ManifestResolver（fail-closed authoring boundary）→ 注册 → 装到 session。
  defp install_kanban(session_uri) do
    name = "kanban-d3-#{uniq()}"
    attrs = ShippedManifest.load!(@manifest_relpath, name: name)
    assert {:ok, definition} = ManifestResolver.resolve(attrs)

    # 声明侧半件的核心断言 ①：manifest 的 "kanban_render" 名引经注册的
    # BoardView 解析回 view read ActionSet 本尊。
    assert definition.views == [KanbanRender]

    {:ok, _obj} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor
      )

    :ok =
      Installation.install_template_installs(
        session_uri,
        @workspace_uri,
        %{installs: [name]},
        @actor
      )

    name
  end

  defp kanban_render_caps_of(member) do
    Enum.filter(Ezagent.Identity.list_caps_for(member), fn cap ->
      match?(%Ezagent.Capability{}, cap) and cap.kind == :session and
        cap.behavior == KanbanRender and cap.action == :kanban_render
    end)
  end

  test "装了 kanban 的 session：declared_view_actions 枚举到 kanban_render" do
    session = session_uri()
    install_kanban(session)

    # 声明侧半件核心断言 ②：domain 的枚举点（installation.ex declared_view_actions）
    # 看得到 kanban 的 render 动作 —— MemberBackfill 入会补发消费的就是这份枚举。
    assert {KanbanRender, :kanban_render} in Installation.declared_view_actions(session)
  end

  test "新成员入会（MemberBackfill.backfill）即持 kanban_render，authorize_view 放行" do
    session = session_uri()
    install_kanban(session)

    member = confirmed_user("kanban-d3-member")
    assert kanban_render_caps_of(member) == []

    assert :ok = MemberBackfill.backfill(session, member)

    # 入会即持 render cap（D3 供给半件生效面）。
    assert [%Ezagent.Capability{action: :kanban_render} | _] = kanban_render_caps_of(member)

    # 权限半边闭环：SessionView 的 cap 门对该成员放行（tab 恒显之外，
    # 板列表投影对成员可渲染）。
    assert Ezagent.UI.SessionView.authorize_view(EzagentPluginKanban.BoardView, member, session)

    # 幂等：重复 backfill 不重复发（cap 不翻倍）。
    held = length(kanban_render_caps_of(member))
    assert :ok = MemberBackfill.backfill(session, member)
    assert length(kanban_render_caps_of(member)) == held
  end
end
