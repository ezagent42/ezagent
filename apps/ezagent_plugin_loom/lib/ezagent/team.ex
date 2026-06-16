defmodule EzagentPluginLoom.Team do
  @moduledoc """
  Loom team assembler (loom v0.2, G-F — lightweight path).

  Given an EXISTING `session://<ws>/<sid>`, `ensure_team/1` spawns the
  fixed demo team and joins it to the session:

  - orchestrator `entity://agent/<ws>/loomorch_<sid>`
  - worker `entity://agent/<ws>/loomworker_<sid>_policy` (政策侧)
  - worker `entity://agent/<ws>/loomworker_<sid>_company` (企业侧)
  - builderworker `entity://agent/<ws>/loombuilder_<sid>` (页面生成,2026-06-01)

  This is the **B path** chosen for the demo (no SessionTemplate /
  AgentTemplate records). The orchestrator discovers its roster at
  runtime from the session members (`LoomOrchestrator.discover_workers/1`)
  and each worker reads its theme off its own URI name
  (`LoomWorker.theme_for/1`), so NO spawn-time config injection is
  needed.

  No custom routing rules are installed: the default mention-gated
  `system_default` rule (`{:always} → [$session_users, $mentions]`,
  `EzagentDomainInstanceMessage.DefaultRules`) already delivers each message only
  to its `@mention`ed agent + the session's User members — so worker↔
  worker cross-talk is structurally impossible as long as every message
  @mentions its recipient (which the orchestrator + workers do). The
  PRD's "override $session_members fan-out" was based on a stale premise
  (the default is mention-gated, not broadcast).

  Idempotent reconciler: a re-run spawns nothing new (already-alive
  agents) and the join short-circuits (Chat `:join` online+pid match).
  The tmp_user is joined separately by the bootstrap (G-C).
  """

  require Logger

  alias Ezagent.Invocation

  @doc """
  Ensure the team is alive + joined to `session_uri`. Returns
  `{:ok, %{orchestrator: URI.t(), workers: [URI.t()]}}` or `{:error, _}`.
  """
  @spec ensure_team(URI.t(), keyword()) ::
          {:ok, %{orchestrator: URI.t(), workers: [URI.t()]}} | {:error, term()}
  def ensure_team(session_uri, opts \\ [])

  def ensure_team(%URI{scheme: "session"} = session_uri, opts) do
    # 2026-06-15 — 可配置 worker(per-session)。worker 的真相源是
    # `Ezagent.PluginLoom.WorkerConfig`(旁路 JSON + 默认 2 个通用 worker)。
    #
    # - 不传 `opts[:worker_themes]`(普通新建 session)→ 从 WorkerConfig 取(首次落地
    #   2 个通用 worker 默认值),每个 worker **带配置 spawn**(role=desc / system_prompt)。
    # - 传 `opts[:worker_themes]`(saved-template 路径,LoomSession 从 saved_state.workers
    #   抽 theme 列表)→ 保留原行为:bare theme URI,prompt 由 LoomSession.pre_spawn 注入。
    saved_themes = Keyword.get(opts, :worker_themes)
    # 2026-06-05 — 可关 v0。只有最初的 session.loom 有 v0(页面创作);发布物 fork
    # 出的 session `include_builder: false`,base 冻结、只能叠 user_schema ops,不能重写源码。
    include_builder? = Keyword.get(opts, :include_builder, true)

    with {:ok, ws, sid} <- session_parts(session_uri) do
      # 2026-06-12 — session 初始化即建好素材库根目录(目录即库;v0/Claude Code 用 cwd+Read 读)。
      _ = Ezagent.PluginLoom.Materials.ensure_dir(ws, sid)

      # 2026-06-01 — 用 `Ezagent.URI.new!`(走 `URI.new`,canonical 形:无
      # `authority` 字段)代替 deprecated `URI.parse/1`(留 `authority: "agent"`)。
      # canonicalize_uris/1 在 snapshot load 时把 chat.members 的 key 全 rewrite
      # 到 canonical;若这里再用 URI.parse 加非 canonical key,Map.put 视为
      # 两个不同 key → 同一 agent 出现两条成员行(2026-06-01 demo6 双倍 bug)。
      orchestrator = Ezagent.URI.new!("entity://agent/#{ws}/loomorch_#{sid}")

      # worker_specs:%{uri, role, prompt};role/prompt=nil → bare spawn(saved 路径)。
      worker_specs = resolve_worker_specs(ws, sid, saved_themes)
      workers = Enum.map(worker_specs, & &1.uri)

      builder_members =
        if include_builder?,
          do: [Ezagent.URI.new!("entity://agent/#{ws}/loombuilder_#{sid}")],
          else: []

      # 2026-06-10 — preview-side AI orchestrator(Salesperson chat + AiSpot)。和 v0 平级、
      # @-only,不受 include_builder 门控:发布物 / fork 出的无-v0 会话也要有 Salesperson。
      # 2026-06-12 — Salesperson 现在是 orchestrator,外加一组固定的 sub-worker
      # (chat/navigation/controls/content),每个 loom session 创建即全量自带。
      salesperson_members =
        [Ezagent.URI.new!("entity://agent/#{ws}/loomsalesperson_#{sid}")] ++
          Enum.map(EzagentPluginLoom.SalespersonExperts.role_keys(), fn role ->
            Ezagent.URI.new!("entity://agent/#{ws}/loomsalespersonsub_#{sid}_#{role}")
          end)

      # 2026-06-01 — team manager,接收 @ 的自然语言加 / 删 worker 指令。
      # 默认每个 loom session 都有。Behavior 是 mention-gated,不 @ 不动。
      meta = Ezagent.URI.new!("entity://agent/#{ws}/loommeta_#{sid}")

      # workers 走带配置 spawn(default 路径)/ bare spawn(saved 路径);
      # 其余成员(orchestrator / v0 / salesperson / meta)走 SpawnRegistry bare spawn。
      others = [orchestrator | builder_members] ++ salesperson_members ++ [meta]
      members = [orchestrator | workers] ++ builder_members ++ salesperson_members ++ [meta]

      with :ok <- Enum.reduce_while(worker_specs, :ok, &spawn_worker_step/2),
           :ok <- Enum.reduce_while(others, :ok, &spawn_step/2),
           :ok <- Enum.reduce_while(members, :ok, fn uri, _ -> join_step(session_uri, uri) end) do
        {:ok,
         %{orchestrator: orchestrator, workers: workers ++ builder_members ++ salesperson_members ++ [meta]}}
      end
    end
  end

  def ensure_team(_, _), do: {:error, :not_a_session_uri}

  # worker 列表解析的优先级:
  #   1. 已存的 WorkerConfig(用户配过 / 之前 seed 过)→ **权威**,带配置 spawn(跨重启一致)。
  #   2. saved 模板首次实例化(传了 theme 列表、还没存配置)→ bare URI,prompt 由
  #      LoomSession.pre_spawn 注入(zuatu 等)。首次 GET /workers 会把它们导入 WorkerConfig。
  #   3. 普通新建(都没有)→ WorkerConfig.get_or_seed,落地默认 2 个通用 worker。
  defp resolve_worker_specs(ws, sid, saved_themes) do
    cond do
      is_list(stored = Ezagent.PluginLoom.WorkerConfig.stored(ws, sid)) and stored != [] ->
        Enum.map(stored, &config_spec(ws, sid, &1))

      is_list(saved_themes) and saved_themes != [] ->
        Enum.map(saved_themes, fn theme ->
          %{
            uri: Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{theme}"),
            role: nil,
            prompt: nil
          }
        end)

      true ->
        Ezagent.PluginLoom.WorkerConfig.get_or_seed(ws, sid)
        |> Enum.map(&config_spec(ws, sid, &1))
    end
  end

  defp config_spec(ws, sid, w) do
    %{
      uri: Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{w["key"]}"),
      role: w["desc"],
      prompt: w["prompt"]
    }
  end

  # bare spawn(saved 路径:prompt 由 LoomSession.pre_spawn 注入,这里幂等短路)。
  defp spawn_worker_step(%{uri: uri, role: nil}, _acc), do: spawn_step(uri, :ok)

  # 带配置 spawn(default 路径):role=desc / system_prompt 注入 :loom_worker slice。
  defp spawn_worker_step(%{uri: uri, role: role, prompt: prompt}, _acc) do
    case Ezagent.Kind.spawn(Ezagent.Entity.LoomWorker, %{
           uri: uri,
           role: role,
           system_prompt: prompt
         }) do
      {:ok, _} -> {:cont, :ok}
      {:error, {:already_started, _}} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:spawn_failed, URI.to_string(uri), reason}}}
    end
  end

  # `session://<template>/<workspace>/<short_name>` (SPEC v3 — 3-segment
  # authority) → {workspace, short_name}. Agents live in <workspace>;
  # their names carry <short_name> for per-session uniqueness + the worker
  # theme suffix (`_policy` / `_company`).
  defp session_parts(%URI{path: path} = uri) when is_binary(path) do
    case path |> String.trim_leading("/") |> String.split("/") do
      [ws, sid | _] when ws != "" and sid != "" -> {:ok, ws, sid}
      _ -> {:error, {:bad_session_uri, URI.to_string(uri)}}
    end
  end

  defp session_parts(uri), do: {:error, {:bad_session_uri, URI.to_string(uri)}}

  defp spawn_step(%URI{} = uri, _acc) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} -> {:cont, :ok}
      {:error, {:already_started, _pid}} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:spawn_failed, URI.to_string(uri), reason}}}
    end
  end

  # Join under `system://session-internal` — the Catalog principal that
  # holds `cap(:any, Chat, :any)` (same principal the Generator's
  # `auto_join_session_members` uses). `:call` so a CapBAC / missing-member
  # failure is observable (no silent swallow).
  defp join_step(%URI{} = session_uri, %URI{} = member_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: Ezagent.SystemPrincipal.uri("session-internal"),
          caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
          reply: {:caller_inbox, self()}
        }
      })

    case result do
      :ok -> {:cont, :ok}
      {:ok, _} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:join_failed, URI.to_string(member_uri), reason}}}
    end
  end
end
