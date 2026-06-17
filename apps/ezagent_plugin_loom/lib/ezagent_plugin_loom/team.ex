defmodule EzagentPluginLoom.Team do
  @moduledoc """
  loom session 的 **agent team 装配** —— 给 session 起一队 loom 编排控制器作为
  socialware Session Member,使其出现在 admin Members 面板。

  每个成员:`Kind.spawn(Ezagent.Entity.LoomAgent, …)`(活 Kind,join 的前提)→
  `session.join`(role_name 携带角色)。角色由 URI 名前缀携带(同 loom-stitch):

  - `loomorch_<sid>`   编排器(控制器)
  - `loomv0_<sid>`     v0 页面生成
  - `loomworker_<sid>_<key>`  主题 worker(从 `WorkerConfig` 取,缺省 2 个通用)
  - `loommeta_<sid>`   团队管家(@ 改 roster)
  - `loomstitch_<sid>` 预览侧 Stitch 编排
  - `loomstitchsub_<sid>_<role>`  Stitch 4 子角色(chat/navigation/controls/content)

  编排逻辑在 `EzagentPluginLoom.OrchestratorServer`(控制器,loom 内部);LLM 走
  `EzagentPluginLoom.LLM`(已对接 socialware/ezagent)。本模块只负责"成员装配"。
  幂等:同 URI 重复 spawn → `{:error, {:already_started, _}}` 视为已在;join 幂等。
  """

  require Logger

  alias Ezagent.{Invocation, Kind, SystemPrincipal}
  alias Ezagent.Entity.LoomAgent
  alias EzagentPluginLoom.WorkerConfig

  @default_worker_keys ["general", "details"]

  @doc "给 session 装配整队 loom agent Member。返回 `{:ok, %{members: [URI.t()]}}`。"
  @spec ensure_team(URI.t()) :: {:ok, %{members: [URI.t()]}} | {:error, term()}
  def ensure_team(%URI{scheme: "session"} = session_uri) do
    with {:ok, ws, sid} <- ws_sid(session_uri) do
      members =
        session_uri
        |> member_specs(ws, sid)
        |> Enum.map(fn {uri, role} ->
          _ = spawn_member(uri, role)
          _ = join_member(session_uri, uri, role)
          uri
        end)

      {:ok, %{members: members}}
    end
  end

  def ensure_team(_), do: {:error, :not_a_session_uri}

  # {member_uri, role} 列表。
  defp member_specs(session_uri, ws, sid) do
    worker_keys = worker_keys(session_uri)

    [
      {agent(ws, "loomorch_#{sid}"), "orchestrator"},
      {agent(ws, "loomv0_#{sid}"), "v0"},
      {agent(ws, "loommeta_#{sid}"), "meta"},
      {agent(ws, "loomstitch_#{sid}"), "stitch"}
    ] ++
      Enum.map(worker_keys, fn key ->
        {agent(ws, "loomworker_#{sid}_#{key}"), "worker:#{key}"}
      end) ++
      Enum.map(stitch_sub_roles(), fn role ->
        {agent(ws, "loomstitchsub_#{sid}_#{role}"), "stitch:#{role}"}
      end)
  end

  defp worker_keys(session_uri) do
    case WorkerConfig.list(session_uri) do
      [] ->
        @default_worker_keys

      workers when is_list(workers) ->
        workers
        |> Enum.map(&(&1["key"] || &1[:key]))
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> case do
          [] -> @default_worker_keys
          keys -> keys
        end
    end
  end

  defp stitch_sub_roles do
    EzagentPluginLoom.StitchExperts.role_keys()
  rescue
    _ -> []
  end

  defp agent(ws, name), do: Ezagent.URI.agent(ws, name)

  defp spawn_member(%URI{} = uri, role) do
    Kind.spawn(LoomAgent, %{uri: uri, behaviors: [Ezagent.Behavior.LoomAgent], role: role})
  rescue
    e ->
      Logger.warning("loom Team.spawn_member #{URI.to_string(uri)} failed: #{inspect(e)}")
      :error
  catch
    :exit, _ -> :error
  end

  defp join_member(session_uri, %URI{} = member_uri, role) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: member_uri, role_name: role, in_session_template: true},
      ctx: %{
        caller: SystemPrincipal.uri("template-materialize"),
        caps: "template-materialize" |> SystemPrincipal.uri() |> SystemPrincipal.caps(),
        reply: {:caller_inbox, self()}
      }
    })
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp ws_sid(%URI{scheme: "session", host: ws, path: "/loom/" <> name})
       when is_binary(ws) and is_binary(name) and name != "" do
    {:ok, ws, name}
  end

  defp ws_sid(_), do: {:error, :not_a_loom_session}
end
