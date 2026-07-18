defmodule Ezagent.Socialware.InstallerViewCapsTest do
  @moduledoc """
  分层债 ⑤ —— session 安装 socialware 时,**installer/owner 也要拿到 declared views 的
  render cap**(否则装了 kanban 的 owner 看不到「看板」tab —— 门控 cap 只给匿名访客铸过,
  `Installation.anon_view_caps/1`)。

  `Installation.grant_installer_view_caps/2` 是通用修复(零业务字面):对 session 已安装
  的**每个** definition(不分 public/private —— installer 自己装的都能看)的 declared
  views,把 `cap(:session, view, action, <session>, <ws>)` 经 **Grant chokepoint**
  (#1457 后 rule 元组已删:granter=installer,admin 走 `{:admin,…}` 其余
  `{:held_by,…}`,先 `TargetAuthority.ensure/2` 落 per-Kind 授权)授给 installer。
  幂等:重跑不重复发。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}

  # 两个 cap-only view read ActionSet(HelloRender 形),各自唯一 render action ——
  # 与 anon_view_caps_test 同款靶,public / private 各一个。
  defmodule PublicRender do
    @moduledoc false
    use Ezagent.Lifecycle
    @impl Ezagent.ActionSet
    def actions, do: [:ivc_pub_render]
    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:ivc_pub_render, "public view render"}]
    @impl Ezagent.ActionSet
    def dispatchable?, do: false
    @impl Ezagent.ActionSet
    def interface, do: %{}
    @impl Ezagent.ActionSet
    def required_caps,
      do: %{ivc_pub_render: Ezagent.Capability.cap(:session, __MODULE__, :ivc_pub_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  defmodule PrivateRender do
    @moduledoc false
    use Ezagent.Lifecycle
    @impl Ezagent.ActionSet
    def actions, do: [:ivc_priv_render]
    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:ivc_priv_render, "private view render"}]
    @impl Ezagent.ActionSet
    def dispatchable?, do: false
    @impl Ezagent.ActionSet
    def interface, do: %{}
    @impl Ezagent.ActionSet
    def required_caps,
      do: %{ivc_priv_render: Ezagent.Capability.cap(:session, __MODULE__, :ivc_priv_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  @workspace_uri Ezagent.URI.new!("workspace://system")
  @actor Ezagent.URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  defp write_def(name, view_mod, anon_access?) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        views: [view_mod],
        visibility_policy: %{publish_policy: :auto, web_anon_access: anon_access?}
      })

    {:ok, _obj} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor
      )

    name
  end

  defp live_owner(name) do
    uri = Ezagent.URI.new!("entity://system/user/#{name}-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: uri, initial_caps: MapSet.new()})

    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp render_caps_of(owner, view_mod, action, session_uri) do
    instance = Ezagent.URI.instance(session_uri)

    owner
    |> Ezagent.Identity.list_caps_for()
    |> Enum.filter(fn cap ->
      cap.kind == :session and cap.behavior == view_mod and cap.action == action and
        cap.instance == instance
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

  test "installer 拿到全部已装 definition 的 view render cap(public + private),granted_by=installer,幂等" do
    n = uniq()
    session_uri = Ezagent.URI.session("system", "generic", "ivc-#{n}")
    owner = live_owner("ivc-owner")

    pub = write_def("ivc-pub-#{n}", PublicRender, true)
    priv = write_def("ivc-priv-#{n}", PrivateRender, false)

    :ok =
      Installation.install_template_installs(
        session_uri,
        @workspace_uri,
        %{installs: [pub, priv]},
        @actor
      )

    # 修复入口:安装后给 installer/owner 授 declared views 的 render cap
    assert :ok = Installation.grant_installer_view_caps(session_uri, owner)

    # installer 能看自己装的一切 view —— public 和 private 都拿到(区别于 anon 只拿 public)
    assert eventually(fn ->
             render_caps_of(owner, PublicRender, :ivc_pub_render, session_uri) != []
           end)

    assert eventually(fn ->
             render_caps_of(owner, PrivateRender, :ivc_priv_render, session_uri) != []
           end)

    # cap 形 = SessionView.authorize_view/3 检查的那把(concrete session instance + ws),
    # granted_by = installer(rule 的 configurer,#154 真实实体)
    [pub_cap] = render_caps_of(owner, PublicRender, :ivc_pub_render, session_uri)
    assert pub_cap.instance == Ezagent.URI.instance(session_uri)
    assert URI.to_string(pub_cap.granted_by) == URI.to_string(owner)

    # 幂等:重跑不重复发
    assert :ok = Installation.grant_installer_view_caps(session_uri, owner)
    assert length(render_caps_of(owner, PublicRender, :ivc_pub_render, session_uri)) == 1
    assert length(render_caps_of(owner, PrivateRender, :ivc_priv_render, session_uri)) == 1
  end

  test "无安装的 session / 非 session URI → :ok 无副作用" do
    owner = live_owner("ivc-noop-owner")
    empty_session = Ezagent.URI.session("system", "generic", "ivc-empty-#{uniq()}")

    assert :ok = Installation.grant_installer_view_caps(empty_session, owner)
    assert :ok = Installation.grant_installer_view_caps(@workspace_uri, owner)

    assert render_caps_of(owner, PublicRender, :ivc_pub_render, empty_session) == []
  end
end
