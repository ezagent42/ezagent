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

  The default instance `entity://system/agent/loom_agent` is spawned in
  Phase 3 (`after_boot/0`), AFTER Phase-2 `publish/1` registered
  `agent_flavors/0` so the resolver can map the flavor. This plugin's
  dep on `ezagent_domain_instance_message` makes OTP boot chat first, so the
  `entity://` SpawnRegistry dispatcher is published by the time this
  runs. Idempotent: re-spawning an already-alive Kind is a no-op.
  """

  use Application
  use Ezagent.Plugin

  # entity://system/agent/loom_agent — the default Loom instance. Built at runtime
  # via `default_uri/0` (NOT a compile-time module attr) so it uses the canonical
  # `Ezagent.URI.new!/1`; that needs the SchemeRegistry, which is up by the time
  # `after_boot/0` / `default_uri/0` run.
  @default_uri_str "entity://system/agent/loom_agent"

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
      url = System.get_env(var) || System.get_env(String.downcase(var))

      # An external HTTP(S)_PROXY URL is NOT an ezagent-scheme URI, so the canonical
      # `Ezagent.URI` helpers don't apply. Parse it with Erlang's `:uri_string` (avoids
      # stdlib `URI.parse/1`, which the uri-canonicalization invariant reserves for
      # ezagent-scheme URIs). Returns a map (host binary, port integer) or an error.
      parsed = is_binary(url) && :uri_string.parse(url)

      case parsed do
        %{host: host, port: port} when is_binary(host) and is_integer(port) ->
          :httpc.set_options([{opt, {{String.to_charlist(host), port}, no_proxy}}])
          require Logger
          Logger.info("EzagentPluginLoom: httpc #{opt} → #{host}:#{port}")

        _ ->
          :ok
      end
    end)

    :ok
  end

  # 2026-06-01 — view-switcher 的第 4 个 tab。`SessionViewRegistry` 是 ETS,
  # `init/0` 幂等;`register/1` 覆盖同 id。boot 顺序:domain_ui 是本 plugin
  # 的 dep,故 `Ezagent.UI.*` 一定先编译并 application_start,这里不需要
  # `Code.ensure_loaded?` 兜底。注册失败不能影响 plugin boot — try/rescue。
  defp register_session_views do
    # PR#2(loom-port):the plugin_check gate's forbidden registries are only the
    # core dispatch/routing ones (Adapter/Binding/Behavior/Spawn/Template/Plugin/
    # AgentFlavor/Routing) — `SessionViewRegistry` (UI) is NOT one of them, and
    # main's own admin_live mount registers views the same way. So loom registers
    # its admin session tabs here. `init/0` is idempotent (admin_live's mount
    # re-init doesn't wipe these); register failure must not abort plugin boot.
    try do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.PluginLoom.View.LoomSessionView)
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.PluginLoom.View.LoomDashboardView)
    rescue
      e ->
        require Logger
        Logger.warning("EzagentPluginLoom: SessionView register failed: #{inspect(e)}")
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
      # 2026-06-01 redesign — builderworker: AI page generator, dispatched by the
      # orchestrator with current source + user request, replies with a
      # <span type="page_update"> body.
      {Ezagent.Entity.LoomBuilderWorker, :receive, Ezagent.Behavior.LoomBuilderWorker},
      # 2026-06-10 — salespersonworker: preview-side AI (Salesperson chat + AiSpot),
      # @-only, DeepSeek-backed. Replaces the old direct-DeepSeek path.
      # 2026-06-12 — now the ORCHESTRATOR over the salesperson sub-workers below.
      {Ezagent.Entity.LoomSalespersonWorker, :receive, Ezagent.Behavior.LoomSalespersonWorker},
      # 2026-06-12 — salesperson sub-workers (chat/navigation/controls/content):
      # real worker Kinds the Salesperson orchestrator fans a turn out to.
      {Ezagent.Entity.LoomSalespersonSubWorker, :receive,
       Ezagent.Behavior.LoomSalespersonSubWorker},
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
      # 2026-06-01 redesign — builderworker Template Class (flavor declaration
      # satisfies the :ezagent_plugin_check gate).
      Ezagent.PluginLoom.Template.LoomBuilderWorker,
      # 2026-06-10 — salespersonworker Template Class (preview-side AI).
      Ezagent.PluginLoom.Template.LoomSalespersonWorker,
      # 2026-06-12 — salesperson sub-worker Template Class.
      Ezagent.PluginLoom.Template.LoomSalespersonSubWorker,
      # 2026-06-01 — team manager Template Class.
      Ezagent.PluginLoom.Template.LoomMetaAgent,
      # Session template: "create a loom session" auto-assembles the team
      # (orchestrator + 2 workers + builderworker + manager) instead of a bare session.
      Ezagent.PluginLoom.Template.LoomSession,
      # 2026-06-18 — loom-as-socialware-vertical (P0): spawns the unified
      # Entity.Session with the socialware behavior subset (Turn/Surface active).
      # Strangler entry, runs alongside the legacy session.loom; see
      # docs/loom-port/SOCIALWARE-VERTICAL.md.
      Ezagent.PluginLoom.Template.LoomVerticalSession
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
      # 2026-06-01 redesign — `entity://agent/<ws>/loombuilder_<name>` (AI page
      # generator worker; one per loom session, spawned by Team.ensure_team).
      %{
        flavor: "loombuilder",
        kind: Ezagent.Entity.LoomBuilderWorker,
        template_class: Ezagent.PluginLoom.Template.LoomBuilderWorker
      },
      # 2026-06-10 — `entity://agent/<ws>/loomsalesperson_<name>` (preview-side AI;
      # one per loom session, always spawned by Team.ensure_team).
      %{
        flavor: "loomsalesperson",
        kind: Ezagent.Entity.LoomSalespersonWorker,
        template_class: Ezagent.PluginLoom.Template.LoomSalespersonWorker
      },
      # 2026-06-12 — `entity://agent/<ws>/loomsalespersonsub_<sid>_<role>`.
      %{
        flavor: "loomsalespersonsub",
        kind: Ezagent.Entity.LoomSalespersonSubWorker,
        template_class: Ezagent.PluginLoom.Template.LoomSalespersonSubWorker
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

  # main resolves an agent's Kind from a flavor STORED in `AgentFlavorAttributes`
  # (in-memory ETS), NOT derived from the name as stitch did. That ETS is empty
  # after a restart, so existing loom agents (their snapshots persist) can't be
  # lazy-revived on the next dispatch → `{:no_kind_module_for_agent}`. Loom agents
  # store the flavor as their snapshot `kind_type` (loomorch / loombuilder / …), so
  # re-seed the flavor map from the durable snapshots at boot. Read-only; failure
  # must not abort boot.
  defp restore_agent_flavors do
    import Ecto.Query
    flavors = ~w(loom loomorch loomworker loombuilder loomsalesperson loomsalespersonsub loommeta)

    from(k in "kind_snapshots", where: k.kind_type in ^flavors, select: {k.uri, k.kind_type})
    |> EzagentCore.Repo.all()
    |> Enum.each(fn {uri_str, flavor} ->
      try do
        _ = Ezagent.AgentFlavorAttributes.put(Ezagent.URI.new!(uri_str), flavor)
      rescue
        _ -> :ok
      end
    end)

    :ok
  rescue
    e ->
      require Logger
      Logger.warning("EzagentPluginLoom: restore_agent_flavors failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Phase 3 post-register hook — seed the default Loom agent + restore agent flavors.

  `Ezagent.Plugin.boot/1` calls this AFTER Phase-2 `publish/1` has
  registered `agent_flavors/0`, so `Ezagent.AgentFlavorRegistry` maps
  the `"loom"` flavor → `Ezagent.Entity.Loom`. Idempotent. A genuine
  failure is logged, not raised — `after_boot/0` must not abort boot.
  """
  @impl Ezagent.Plugin
  def after_boot do
    # main's entity-spawn resolver needs the flavor STORED before a bare spawn.
    _ = Ezagent.AgentFlavorAttributes.put(default_uri(), "loom")
    _ = restore_agent_flavors()

    case Ezagent.SpawnRegistry.spawn(default_uri()) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "EzagentPluginLoom.after_boot/0: default loom agent spawn failed (#{inspect(reason)})"
        )

        :ok
    end

    # Plan B(loom-port):存模板/发布物 = **纯数据**,不再 boot 时合成 + 注册 Template Class
    # 模块(顺从 main 的 plugin「declare don't call」gate)。open/fork/derive 时由
    # `SavedClasses.instantiate_from_data/3` 直接实例化 session.loom。

    # 2026-06-02 — SDK v2 tools.把 `:tools` config 列表注册进 ETS 注册表。
    # 失败不阻塞 boot:某个工具模块挂了不该让整个 plugin 起不来。
    _ = EzagentPluginLoom.ToolRegistry.register_all()

    :ok
  end

  @doc "URI of the default Loom instance — seeded by `after_boot/0`."
  def default_uri, do: Ezagent.URI.new!(@default_uri_str)
end
