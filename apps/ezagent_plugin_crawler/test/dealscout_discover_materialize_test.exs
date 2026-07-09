defmodule EzagentPluginCrawler.DealscoutDiscoverMaterializeTest do
  @moduledoc """
  段3（2026-07-10）物化冒烟：dealscout 的 discover 槽换 py 车道后（D1——
  cc-headless 物化必崩是平台 gap，绕开不修），证明**同一份 shipped manifest
  的 discover 槽走真实 install 物化车道能物化不崩**。

  两层：

  1. **resolve 级（无 uv 前置）**——shipped manifest 的 discover 槽 resolve 出
     `dealscout-discover × py`；recipe 从 RecipeRegistry read-through 解析出
     script-carrying recipe；`py` flavor 真实注册在 AgentFlavorRegistry（不是
     假设）。
  2. **物化级（`:uv`，真 subprocess）**——用 install 车道的同一入口
     `EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents
     .materialize_definition_agents/4` 物化 resolve 出的 discover 槽本体：
     spawn（RecipeMaterializer，recipe script → config_dir `agent.py`）→
     faceted join（role_name "discover"）→ grant（空 recipe 铸 0 cap）。再经
     `Ezagent.Domain.Python.call/4` 直打 `receive` 证 script 的真实契约在跑
     （网络可用 → 回复带更新信号 + 线索；网络不可用 → fail-honest 降级回复、
     不带信号——两者都证明 script 真在执行，断言接受二者）。

  跟 `definition_agents_materialize_test.exs`（domain_session，stub flavor）
  的差异：这里 flavor 是**真 py**（subprocess 真起），slot 数据来自**shipped
  manifest 本体**（不是手搓 map）——这正是旧 e2e 里 cc-headless 必崩的那一步。

  差什么（如实说）：完整 install（Installation.install → 全 slot + requires
  递归 + orchestrator MCP context）没在这里跑——page 槽的 ALT 与 orchestrator
  的 cc 车道不属于本段验收；会话内 @discover → receive → 回复 → routing 命中
  page 的全链是段5 真浏览器 e2e 的活。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Domain.Python
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{Definition, ManifestResolver, ShippedManifest}
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @manifest_relpath "dealscout/manifest.yaml"
  @workspace_uri URI.new!("workspace://system")
  @owner_uri URI.new!("entity://system/user/admin")

  setup do
    # 与 dealscout_manifest_publish_test 同一环境公式 + plugin_py（注册真
    # `py` flavor + Template.PyAgent + Domain.Python）。
    for app <- [
          :ezagent_domain_session,
          :ezagent_domain_socialware,
          :ezagent_plugin_hello,
          :ezagent_plugin_crawler,
          :ezagent_plugin_py
        ] do
      {:ok, _} = Elixir.Application.ensure_all_started(app)
    end

    # `RoleSeedHook` skips in :test — seed 两家 recipe（含 script-carrying 的
    # dealscout-discover，走 seed_role_if_absent 的 trusted-code 通道）。
    recipes = EzagentPluginCrawler.Recipes.all() ++ EzagentPluginHello.Application.roles()

    Enum.each(recipes, fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()
    :ok
  end

  defp discover_slot! do
    assert {:ok, %Definition{} = definition} =
             @manifest_relpath |> ShippedManifest.load!() |> ManifestResolver.resolve()

    slot = Enum.find(definition.roles, &(&1.fill == :agent and &1.role_name == "discover"))
    assert slot, "the shipped manifest must declare the discover agent slot"
    slot
  end

  describe "resolve 级（无 uv）" do
    test "shipped manifest 的 discover 槽 = dealscout-discover × py；recipe 解析出 script；py flavor 真实注册" do
      slot = discover_slot!()
      assert slot.recipe == "dealscout-discover"
      assert slot.flavor == "py"

      # recipe read-through 解析（install 车道 lookup 的同一入口），script 在场
      # 且信号已注入（占位符残留会在 script 启动时 fail-loud）。
      assert {:ok, %Ezagent.Agent.Recipe{script: script}} =
               RecipeRegistry.lookup(URI.to_string(@workspace_uri), slot.recipe)

      assert is_binary(script) and script =~ Ezagent.ActionSet.Crawler.update_signal()
      refute script =~ EzagentPluginCrawler.Recipes.update_signal_placeholder()

      # `py` flavor 是真注册的物化车道（AgentFlavorRegistry），不是 manifest
      # 里的一个悬空字符串。
      assert {:ok, flavor_spec} = Ezagent.AgentFlavorRegistry.lookup("py")
      assert flavor_spec.kind == Ezagent.Entity.Agent
    end
  end

  describe "物化级（uv — 真 py subprocess）" do
    setup do
      case System.find_executable("uv") do
        nil -> {:skip, "uv not on PATH"}
        _ -> :ok
      end
    end

    @tag :uv
    @tag timeout: 240_000
    test "manifest 的 discover 槽经 DefinitionAgents 物化不崩：join + script 安装 + subprocess 真跑" do
      slot = discover_slot!()
      n = System.unique_integer([:positive])

      session_uri = Ezagent.URI.session("system", "generic", "dealscout-discover-smoke-#{n}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.behaviors()})

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
      on_exit(fn -> terminate(session_uri) end)

      # 旧 e2e 在这步（cc-headless 物化）必崩；py 车道要走通。
      assert :ok =
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 @owner_uri,
                 [slot]
               )

      members = read_members(session_uri)

      agent_uri =
        Ezagent.ActionSet.Session.Members.role_name_to_uri(members, "discover") ||
          flunk("discover member must be joined with its role_name facet")

      on_exit(fn ->
        _ = Python.stop(agent_uri)
        terminate(agent_uri)
      end)

      # flavor 落盘为 py；recipe script 装进 config_dir 的 agent.py 且带信号。
      assert {:ok, "py"} = Ezagent.AgentFlavorAttributes.get(agent_uri)
      installed = Path.join(Ezagent.Sandbox.ConfigDir.path(agent_uri, "py"), "agent.py")
      assert File.exists?(installed)
      assert File.read!(installed) =~ Ezagent.ActionSet.Crawler.update_signal()

      # script 的真实契约在跑：receive → 文本回复。网络可用 → 带更新信号的
      # 线索报告；网络不可用 → fail-honest 降级（明说"未发更新信号"）。
      # 两者都证明 subprocess 起来了且 script 按契约应答（物化不崩的实证）。
      assert {:ok, %{"text" => text}} =
               Python.call(
                 agent_uri,
                 "receive",
                 %{
                   "text" => "@discover 帮我看看有什么新线索",
                   "from" => URI.to_string(@owner_uri),
                   "session" => URI.to_string(session_uri)
                 },
                 120_000
               )

      assert is_binary(text) and text != ""

      assert text =~ Ezagent.ActionSet.Crawler.update_signal() or text =~ "未发更新信号",
             "the reply must be the script's real contract (signal-carrying leads " <>
               "or the fail-honest degraded line), got: #{inspect(text)}"
    end
  end

  defp terminate(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end

  # 照 definition_agents_materialize_test 的读法：members 住 session Kind 的
  # `:session` slice。
  defp read_members(%URI{} = session_uri) do
    slice_module = Ezagent.ActionSet.Session.state_slice()

    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(slice_module, %{})

        Map.get(Map.get(chat_slice, :state, chat_slice), :members, %{})

      :error ->
        %{}
    end
  end
end
