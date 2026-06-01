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
  @spec ensure_team(URI.t()) ::
          {:ok, %{orchestrator: URI.t(), workers: [URI.t()]}} | {:error, term()}
  def ensure_team(%URI{scheme: "session"} = session_uri) do
    with {:ok, ws, sid} <- session_parts(session_uri) do
      orchestrator = URI.parse("entity://agent/#{ws}/loomorch_#{sid}")
      policy = URI.parse("entity://agent/#{ws}/loomworker_#{sid}_policy")
      company = URI.parse("entity://agent/#{ws}/loomworker_#{sid}_company")
      v0 = URI.parse("entity://agent/#{ws}/loomv0_#{sid}")
      members = [orchestrator, policy, company, v0]

      with :ok <- Enum.reduce_while(members, :ok, &spawn_step/2),
           :ok <- Enum.reduce_while(members, :ok, fn uri, _ -> join_step(session_uri, uri) end) do
        {:ok, %{orchestrator: orchestrator, workers: [policy, company, v0]}}
      end
    end
  end

  def ensure_team(_), do: {:error, :not_a_session_uri}

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
