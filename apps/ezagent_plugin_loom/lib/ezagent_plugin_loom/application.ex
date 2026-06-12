defmodule EzagentPluginLoom.Application do
  @moduledoc """
  Loom plugin OTP application — the `Ezagent.Plugin` contract module.

  Loom is a fixed-reply test bot flavor: every `loom_*` agent always
  answers "你好！我是测试机器人！". Modeled on the Echo plugin, minus the
  PTY opt-in.

  ## Plugin authoring contract

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`)
  this module `use`s **both** `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot/1`; the framework's two-phase boot reads the
  declaration callbacks below and performs every `*Registry` call — the
  plugin author never touches a registry API. The `:ezagent_plugin_check`
  Mix compiler (wired into `mix.exs`) is the non-bypassable gate.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.Loom, :say|:receive}` →
    `Ezagent.Behavior.Loom`. `:say` is the programmatic-invoke action;
    `:receive` is the chat fan-out hook (without it the Loom agent
    silently drops chat messages).
  - `template_classes/0` — the `loom.agent` Template Class (minimal,
    pure-spawn; exists to satisfy the flavor declaration + gate).
  - `agent_flavors/0` — flavor `"loom"` → `{Ezagent.Entity.Loom,
    Ezagent.PluginLoom.Template.LoomAgent}`. Consumed by
    `Ezagent.AgentFlavorRegistry` so the New-agent form + `entity://`
    SpawnRegistry resolver map the `loom` prefix to this Kind.
  - `config_surface/0` — `:flavor` surface for the `/plugins` page.

  ## Default instance seeding — `after_boot/0`

  The default instance `entity://agent/system/loom_agent` is spawned in
  Phase 3 (`after_boot/0`), AFTER Phase-2 `publish/1` registered
  `agent_flavors/0` so the resolver can map the flavor. This plugin's
  dep on `ezagent_domain_instance_message` makes OTP boot chat first, so the
  `entity://` SpawnRegistry dispatcher is published by the time this
  runs. Idempotent: re-spawning an already-alive Kind is a no-op.
  """

  use Application
  use Ezagent.Plugin

  @default_uri URI.parse("entity://agent/system/loom_agent")

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args) do
    configure_httpc_proxy()
    result = Ezagent.Plugin.boot(__MODULE__)
    register_session_views()
    result
  end

  # 2026-06-11 — `:httpc` 不读 HTTPS_PROXY/HTTP_PROXY 环境变量。开发机走 Clash
  # fake-ip 模式时,`api.deepseek.com` 解析成不可路由的假 IP(198.18.x.x),只能经
  # 代理隧道出网。boot 时若检测到 proxy env,就显式配进 httpc 默认 profile,让
  # `DeepSeek` / `FetchProxy`(都用 httpc)走代理。无 proxy env(如 prod)则不动,安全。
  defp configure_httpc_proxy do
    no_proxy =
      (System.get_env("no_proxy") || System.get_env("NO_PROXY") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.to_charlist()))
      |> then(fn list -> [~c"localhost", ~c"127.0.0.1" | list] end)

    [{:proxy, "HTTP_PROXY"}, {:https_proxy, "HTTPS_PROXY"}]
    |> Enum.each(fn {opt, var} ->
      with url when is_binary(url) <-
             System.get_env(var) || System.get_env(String.downcase(var)),
           %URI{host: host, port: port} when is_binary(host) and is_integer(port) <-
             URI.parse(url) do
        :httpc.set_options([{opt, {{String.to_charlist(host), port}, no_proxy}}])

        require Logger
        Logger.info("EzagentPluginLoom: httpc #{opt} → #{host}:#{port}")
      else
        _ -> :ok
      end
    end)

    :ok
  end

  # 2026-06-01 — view-switcher 的第 4 个 tab。`SessionViewRegistry` 是 ETS,
  # `init/0` 幂等;`register/1` 覆盖同 id。boot 顺序:domain_ui 是本 plugin
  # 的 dep,故 `Ezagent.UI.*` 一定先编译并 application_start,这里不需要
  # `Code.ensure_loaded?` 兜底。注册失败不能影响 plugin boot — try/rescue。
  defp register_session_views do
    try do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.PluginLoom.View.LoomSessionView)
      # 2026-06-12 — loom session 的 Dashboard tab(token/分享/素材/团队统计)。
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.PluginLoom.View.LoomDashboardView)
    rescue
      e ->
        require Logger
        Logger.warning("EzagentPluginLoom: LoomSessionView register failed: #{inspect(e)}")
        :ok
    end
  end

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "loom",
      name: "Loom",
      description: "Fixed-reply test bot — always answers 你好！我是测试机器人！",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Loom, :say, Ezagent.Behavior.Loom},
      {Ezagent.Entity.Loom, :receive, Ezagent.Behavior.Loom},
      # loom v0.2 G-E — worker agent: chat fan-out hook that produces a
      # DeepSeek content fragment for an orchestrator subtask.
      {Ezagent.Entity.LoomWorker, :receive, Ezagent.Behavior.LoomWorker},
      # loom v0.2 G-D — orchestrator agent: decompose → fan out →
      # aggregate → compose, all on the session's chat fan-out hook.
      {Ezagent.Entity.LoomOrchestrator, :receive, Ezagent.Behavior.LoomOrchestrator},
      # 2026-06-01 redesign — v0worker: AI page generator, dispatched by the
      # orchestrator with current source + user request, replies with a
      # <span type="page_update"> body.
      {Ezagent.Entity.LoomV0Worker, :receive, Ezagent.Behavior.LoomV0Worker},
      # 2026-06-10 — stitchworker: preview-side AI (Stitch chat + AiSpot),
      # @-only, DeepSeek-backed. Replaces the old direct-DeepSeek path.
      # 2026-06-12 — now the ORCHESTRATOR over the stitch sub-workers below.
      {Ezagent.Entity.LoomStitchWorker, :receive, Ezagent.Behavior.LoomStitchWorker},
      # 2026-06-12 — stitch sub-workers (chat/navigation/controls/content):
      # real worker Kinds the Stitch orchestrator fans a turn out to.
      {Ezagent.Entity.LoomStitchSubWorker, :receive, Ezagent.Behavior.LoomStitchSubWorker},
      # 2026-06-01 — team manager: @-mention-driven add/remove worker agent.
      # Uses DeepSeek NL parsing → spawn/terminate Kind + chat.join/leave.
      {Ezagent.Entity.LoomMetaAgent, :receive, Ezagent.Behavior.LoomMetaAgent}
    ]
  end

  @impl Ezagent.Plugin
  def template_classes,
    do: [
      Ezagent.PluginLoom.Template.LoomAgent,
      Ezagent.PluginLoom.Template.LoomWorker,
      Ezagent.PluginLoom.Template.LoomOrchestrator,
      # 2026-06-01 redesign — v0worker Template Class (flavor declaration
      # satisfies the :ezagent_plugin_check gate).
      Ezagent.PluginLoom.Template.LoomV0Worker,
      # 2026-06-10 — stitchworker Template Class (preview-side AI).
      Ezagent.PluginLoom.Template.LoomStitchWorker,
      # 2026-06-12 — stitch sub-worker Template Class.
      Ezagent.PluginLoom.Template.LoomStitchSubWorker,
      # 2026-06-01 — team manager Template Class.
      Ezagent.PluginLoom.Template.LoomMetaAgent,
      # Session template: "create a loom session" auto-assembles the team
      # (orchestrator + 2 workers + v0worker + manager) instead of a bare session.
      Ezagent.PluginLoom.Template.LoomSession
    ]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "loom",
        kind: Ezagent.Entity.Loom,
        template_class: Ezagent.PluginLoom.Template.LoomAgent
      },
      # loom v0.2 G-E — `entity://agent/<ws>/loomworker_<name>`.
      %{
        flavor: "loomworker",
        kind: Ezagent.Entity.LoomWorker,
        template_class: Ezagent.PluginLoom.Template.LoomWorker
      },
      # loom v0.2 G-D — `entity://agent/<ws>/loomorch_<name>`.
      %{
        flavor: "loomorch",
        kind: Ezagent.Entity.LoomOrchestrator,
        template_class: Ezagent.PluginLoom.Template.LoomOrchestrator
      },
      # 2026-06-01 redesign — `entity://agent/<ws>/loomv0_<name>` (AI page
      # generator worker; one per loom session, spawned by Team.ensure_team).
      %{
        flavor: "loomv0",
        kind: Ezagent.Entity.LoomV0Worker,
        template_class: Ezagent.PluginLoom.Template.LoomV0Worker
      },
      # 2026-06-10 — `entity://agent/<ws>/loomstitch_<name>` (preview-side AI;
      # one per loom session, always spawned by Team.ensure_team).
      %{
        flavor: "loomstitch",
        kind: Ezagent.Entity.LoomStitchWorker,
        template_class: Ezagent.PluginLoom.Template.LoomStitchWorker
      },
      # 2026-06-12 — `entity://agent/<ws>/loomstitchsub_<sid>_<role>`.
      %{
        flavor: "loomstitchsub",
        kind: Ezagent.Entity.LoomStitchSubWorker,
        template_class: Ezagent.PluginLoom.Template.LoomStitchSubWorker
      },
      # 2026-06-01 — `entity://agent/<ws>/loommeta_<name>` (team manager;
      # one per loom session, spawned by Team.ensure_team).
      %{
        flavor: "loommeta",
        kind: Ezagent.Entity.LoomMetaAgent,
        template_class: Ezagent.PluginLoom.Template.LoomMetaAgent
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "loom", label: "Loom Agents"}
  end

  @doc """
  Phase 3 post-register hook — seed the default Loom agent.

  `Ezagent.Plugin.boot/1` calls this AFTER Phase-2 `publish/1` has
  registered `agent_flavors/0`, so `Ezagent.AgentFlavorRegistry` maps
  the `"loom"` flavor → `Ezagent.Entity.Loom`. Idempotent. A genuine
  failure is logged, not raised — `after_boot/0` must not abort boot.
  """
  @impl Ezagent.Plugin
  def after_boot do
    case Ezagent.SpawnRegistry.spawn(@default_uri) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "EzagentPluginLoom.after_boot/0: default loom agent spawn failed (#{inspect(reason)})"
        )

        :ok
    end

    # 2026-06-01 — Class-level "save as template":每个保存项都是一个 runtime
    # 生成的 Template Class 模块,跟 `session.loom` 同级。`register_all_from_disk`
    # 读 `~/.ezagent/<profile>/loom_saved_classes.json`,逐个 `Module.create` +
    # `TemplateRegistry.register`。Phase 3 的 after_boot 比 Phase 2 publish 晚,
    # 所以 TemplateRegistry 已就绪。
    Ezagent.PluginLoom.SavedClasses.register_all_from_disk()

    # 2026-06-02 — SDK v2 tools.把 `:tools` config 列表注册进 ETS 注册表。
    # 失败不阻塞 boot:某个工具模块挂了不该让整个 plugin 起不来。
    _ = EzagentPluginLoom.ToolRegistry.register_all()

    :ok
  end

  @doc "URI of the default Loom instance — seeded by `after_boot/0`."
  def default_uri, do: @default_uri
end
