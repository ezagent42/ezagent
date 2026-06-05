defmodule EzagentPluginLoom.Team do
  @moduledoc """
  Loom team assembler (loom v0.2, G-F — lightweight path).

  Given an EXISTING `session://<ws>/<sid>`, `ensure_team/1` spawns the
  fixed demo team and joins it to the session:

  - orchestrator `entity://agent/<ws>/loomorch_<sid>`
  - worker `entity://agent/<ws>/loomworker_<sid>_policy` (政策侧)
  - worker `entity://agent/<ws>/loomworker_<sid>_company` (企业侧)
  - v0worker `entity://agent/<ws>/loomv0_<sid>` (页面生成,2026-06-01)

  This is the **B path** chosen for the demo (no SessionTemplate /
  AgentTemplate records). The orchestrator discovers its roster at
  runtime from the session members (`LoomOrchestrator.discover_workers/1`)
  and each worker reads its theme off its own URI name
  (`LoomWorker.theme_for/1`), so NO spawn-time config injection is
  needed.

  No custom routing rules are installed: the default mention-gated
  `system_default` rule (`{:always} → [$session_users, $mentions]`,
  `EzagentDomainChat.DefaultRules`) already delivers each message only
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
    # 2026-06-01 — 可变 worker 数组。`opts[:worker_themes]` 是字符串列表,
    # 每个 theme 对应一个 `loomworker_<sid>_<theme>` URI;默认 `["policy",
    # "company"]` 保留原行为。saved template 实例化时 LoomSession 从
    # saved_state.workers 里抽 theme 列表传进来,实现"模板带 worker spec"。
    worker_themes = Keyword.get(opts, :worker_themes, ["policy", "company"])
    # 2026-06-05 — 可关 v0。只有最初的 session.loom 有 v0(页面创作);发布物 fork
    # 出的 session `include_v0: false`,base 冻结、只能叠 user_schema ops,不能重写源码。
    include_v0? = Keyword.get(opts, :include_v0, true)

    with {:ok, ws, sid} <- session_parts(session_uri) do
      # 2026-06-01 — 用 `Ezagent.URI.new!`(走 `URI.new`,canonical 形:无
      # `authority` 字段)代替 deprecated `URI.parse/1`(留 `authority: "agent"`)。
      # canonicalize_uris/1 在 snapshot load 时把 chat.members 的 key 全 rewrite
      # 到 canonical;若这里再用 URI.parse 加非 canonical key,Map.put 视为
      # 两个不同 key → 同一 agent 出现两条成员行(2026-06-01 demo6 双倍 bug)。
      orchestrator = Ezagent.URI.new!("entity://agent/#{ws}/loomorch_#{sid}")

      workers =
        Enum.map(worker_themes, fn theme ->
          Ezagent.URI.new!("entity://agent/#{ws}/loomworker_#{sid}_#{theme}")
        end)

      v0_members =
        if include_v0?,
          do: [Ezagent.URI.new!("entity://agent/#{ws}/loomv0_#{sid}")],
          else: []

      # 2026-06-01 — team manager,接收 @ 的自然语言加 / 删 worker 指令。
      # 默认每个 loom session 都有。Behavior 是 mention-gated,不 @ 不动。
      meta = Ezagent.URI.new!("entity://agent/#{ws}/loommeta_#{sid}")

      members = [orchestrator | workers] ++ v0_members ++ [meta]

      with :ok <- Enum.reduce_while(members, :ok, &spawn_step/2),
           :ok <- Enum.reduce_while(members, :ok, fn uri, _ -> join_step(session_uri, uri) end) do
        {:ok, %{orchestrator: orchestrator, workers: workers ++ v0_members ++ [meta]}}
      end
    end
  end

  def ensure_team(_, _), do: {:error, :not_a_session_uri}

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
