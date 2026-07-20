defmodule Ezagent.Socialware.MemberBackfillTest do
  @moduledoc """
  D1 join 补发 —— `Ezagent.Socialware.MemberBackfill.backfill/2`(唯一的
  「入会确认后补发」共享 caller-side helper)。

  盖 handoff DoD 的 helper 单测三件套:

    * 补发本体:confirmed 成员拿到 ① session declared views 的 render cap
      (granter = session owner 路,#1457)② 挂载表 `:operate`
      行的 person keys(`Mount.mount` 同路)。
    * 幂等:重复调用不重复发(cap 不翻倍、挂载行仍 1 行)。
    * `:read` 行不扩散;单行失败不牵连其余行、永不 raise;
      unconfirmed(anon)成员只拿 participation tier。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation, MemberBackfill}
  alias Ezagent.Socialware.{Mount, MountRow}

  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  # 最小 view read ActionSet(HelloRender 形状)—— kanban_render 的替身。
  defmodule MemberRender do
    @moduledoc false
    use Ezagent.Lifecycle
    @impl Ezagent.ActionSet
    def actions, do: [:member_render]
    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:member_render, "member view render"}]
    @impl Ezagent.ActionSet
    def dispatchable?, do: false
    @impl Ezagent.ActionSet
    def interface, do: %{}
    @impl Ezagent.ActionSet
    def required_caps,
      do: %{member_render: Ezagent.Capability.cap(:session, __MODULE__, :member_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  @workspace_uri Ezagent.URI.new!("workspace://system")
  @actor Ezagent.URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  # session 落 workspace://system —— 与 install 写入的 workspace 一致
  # (`installed_definitions/1` 按 session URI 推 workspace)。
  defp session_uri, do: Ezagent.URI.new!("session://system/default/backfill-#{uniq()}")

  # confirmed 用户(Users.create 路 confirmed:true)+ 拉起 Kind(grant 落 slice 需要)。
  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # unconfirmed(anon)用户。
  defp unconfirmed_user(prefix) do
    uri = URI.new!("entity://system/user/anon-#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create_read_only(uri)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp live_agent(name, owner, extra_behaviors \\ []) do
    uri = Ezagent.URI.new!("entity://composition/agent/#{name}-#{uniq()}")
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.URI.workspace("composition"))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  # 装一个带 view 的 socialware definition 到 session(anon_view_caps_test 同款)。
  defp install_view_definition(session_uri) do
    name = "backfill-view-#{uniq()}"

    {:ok, definition} =
      Definition.new(%{
        name: name,
        views: [MemberRender],
        visibility_policy: %{publish_policy: :auto, web_anon_access: false}
      })

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

  defp view_caps_of(member) do
    Enum.filter(Ezagent.Identity.list_caps_for(member), fn cap ->
      match?(%Ezagent.Capability{}, cap) and cap.kind == :session and
        cap.behavior == MemberRender
    end)
  end

  defp mount_caps_of(member, target) do
    Enum.filter(Ezagent.Identity.list_caps_for(member), fn cap ->
      match?(%Ezagent.Capability{}, cap) and cap.kind == :agent and
        cap.behavior == Target and cap.instance == Ezagent.URI.instance(target)
    end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  describe "backfill/2 — confirmed 成员的三段补发" do
    test "补发 declared-view render cap + 挂载表 :operate 行的 person keys" do
      owner = confirmed_user("owner")
      session = session_uri()
      _ = install_view_definition(session)

      # 既有挂载:owner 建的板(target),operate 行 grantee = 助手 agent。
      assistant = live_agent("assistant", owner)
      board = live_agent("board", owner, [Target])

      {:ok, _} =
        Mount.mount(session, board, assistant, Target, [:add_node, :get_tree], access: :operate)

      member = confirmed_user("member")
      assert :ok = MemberBackfill.backfill(session, member)

      # ① view render cap(tag configurer = member ⇒ granted_by = member)
      assert eventually(fn -> view_caps_of(member) != [] end),
             "member must be granted the declared-view render cap"

      [view_cap] = view_caps_of(member)
      assert view_cap.action == :member_render
      assert view_cap.instance == Ezagent.URI.instance(session)

      # ② mount operate keys:member 有自己的 operate 挂载行 + 两把 person keys
      row = MountRow.get(session, board, member, Target)
      assert %MountRow{access: "operate"} = row
      assert eventually(fn -> length(mount_caps_of(member, board)) == 2 end)

      # 钥匙 granter = 板 data_owner(#154)
      assert Enum.all?(
               mount_caps_of(member, board),
               &(URI.to_string(&1.granted_by) == URI.to_string(owner))
             )
    end

    test "幂等:重复调用不重复发(cap 不翻倍、挂载行仍 1 行)" do
      owner = confirmed_user("owner")
      session = session_uri()
      _ = install_view_definition(session)

      assistant = live_agent("assistant", owner)
      board = live_agent("board", owner, [Target])
      {:ok, _} = Mount.mount(session, board, assistant, Target, [:add_node], access: :operate)

      member = confirmed_user("member")
      assert :ok = MemberBackfill.backfill(session, member)
      assert eventually(fn -> view_caps_of(member) != [] end)
      assert eventually(fn -> mount_caps_of(member, board) != [] end)

      caps_before = Enum.count(Ezagent.Identity.list_caps_for(member))
      rows_before = length(MountRow.list_for_session(session))

      assert :ok = MemberBackfill.backfill(session, member)

      assert Enum.count(Ezagent.Identity.list_caps_for(member)) == caps_before,
             "a second backfill must not re-grant (cap churn)"

      assert length(MountRow.list_for_session(session)) == rows_before
      assert length(view_caps_of(member)) == 1
    end

    test ":read 行不扩散 —— 只读挂载不因入会升格" do
      owner = confirmed_user("owner")
      session = session_uri()

      viewer = live_agent("viewer", owner)
      shared = live_agent("shared-board", owner, [Target])
      {:ok, _} = Mount.mount(session, shared, viewer, Target, [:get_tree], access: :read)

      member = confirmed_user("member")
      assert :ok = MemberBackfill.backfill(session, member)

      assert MountRow.get(session, shared, member, Target) == nil,
             "a :read mount row must NOT spread to the new member"

      assert mount_caps_of(member, shared) == []
    end

    test "单行失败不牵连其余行、backfill 永不 raise" do
      owner = confirmed_user("owner")
      session = session_uri()

      assistant = live_agent("assistant", owner)
      good = live_agent("good-board", owner, [Target])
      {:ok, _} = Mount.mount(session, good, assistant, Target, [:add_node], access: :operate)

      # 直接落一条指向已消失宿主的 operate 行(remint 会 fail-closed)。
      {:ok, _} =
        MountRow.upsert(%{
          session_uri: session,
          target_uri: "entity://composition/agent/gone-#{uniq()}",
          grantee_uri: URI.to_string(assistant),
          behavior: Target,
          actions: [:add_node],
          access: :operate,
          granted_by: URI.to_string(owner),
          workspace_uri: "workspace://composition"
        })

      member = confirmed_user("member")
      assert :ok = MemberBackfill.backfill(session, member)

      # 好板照发,坏行只计 failed
      assert eventually(fn -> MountRow.get(session, good, member, Target) != nil end)

      assert {:ok, %{failed: 1, skipped: 1}} = Mount.backfill_member_mounts(session, member)
    end
  end

  describe "backfill/2 — 口径边界" do
    test "unconfirmed(anon)成员:只有 participation tier,无 view cap、无挂载钥匙" do
      owner = confirmed_user("owner")
      session = session_uri()
      _ = install_view_definition(session)

      assistant = live_agent("assistant", owner)
      board = live_agent("board", owner, [Target])
      {:ok, _} = Mount.mount(session, board, assistant, Target, [:add_node], access: :operate)

      anon = unconfirmed_user("viewer")
      assert :ok = MemberBackfill.backfill(session, anon)

      assert eventually(fn ->
               Enum.any?(Ezagent.Identity.list_caps_for(anon), fn cap ->
                 match?(%Ezagent.Capability{}, cap) and
                   cap.behavior == Ezagent.ActionSet.Publisher.SessionImpl and
                   cap.action == :subscribe_from
               end)
             end),
             "anon must still get the read-only participation tier"

      assert view_caps_of(anon) == []
      assert MountRow.get(session, board, anon, Target) == nil
    end

    test "agent 成员:整体 no-op(participation mount 对 agent 也是 no-op)" do
      owner = confirmed_user("owner")
      session = session_uri()
      agent = live_agent("member-agent", owner)

      caps_before = Enum.count(Ezagent.Identity.list_caps_for(agent))
      assert :ok = MemberBackfill.backfill(session, agent)
      assert Enum.count(Ezagent.Identity.list_caps_for(agent)) == caps_before
    end
  end
end
