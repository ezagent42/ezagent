defmodule EzagentPluginLoom.Fork do
  @moduledoc """
  Loom **fork**(消费侧):从一个 loom session 的 approved page 起一个新 loom session。

  不撞红线 #3(Turn 禁 `{:set,:surface}`):读源 session 的 approved surface tree → 新 session
  instantiate → 经**合法的 Turn**(open/compose/settle,result_refs 带 page)把源 tree seed 成
  新 session 的首版 surface。全经 Invocation.dispatch,不碰 domain。

  "发布/分享"在 loom 即 customer token + CustomerFeed 只读(已由 customer 入站端点覆盖);
  fork 是从只读发布物**派生可继续编辑/对话的新 session**。
  """

  alias Ezagent.{Invocation, SystemPrincipal}
  alias EzagentPluginLoom.Template.LoomSession

  @caller "system://loom-fork"

  @doc """
  从 `src_session_uri` fork 出名为 `new_name` 的新 loom session,operator = `operator_uri`。
  返回 `{:ok, new_session_uri}` | `{:error, reason}`。
  """
  @spec fork(URI.t(), String.t(), String.t()) :: {:ok, URI.t()} | {:error, term()}
  def fork(%URI{} = src_session_uri, new_name, operator_uri)
      when is_binary(new_name) and is_binary(operator_uri) do
    with {:ok, surface} <- Ezagent.Kind.get_slice(src_session_uri, :surface),
         tree when not is_nil(tree) <- approved_tree(surface),
         {:ok, ws} <- Ezagent.URI.workspace_name(src_session_uri),
         {:ok, [new_uri], _} <-
           LoomSession.instantiate(
             "loom-fork",
             %{
               "class" => "session.loom",
               "session_name" => new_name,
               "operator_uri" => operator_uri,
               # fork 自带源页,跳过 instantiate 的初始页 seed(避免和下面 seed_page 竞态)。
               "no_seed" => true
             },
             Ezagent.URI.workspace(ws)
           ),
         :ok <- seed_page(new_uri, tree) do
      copy_knowledge(src_session_uri, new_uri)
      {:ok, new_uri}
    else
      nil -> {:error, :no_approved_page}
      {:error, _} = error -> error
      other -> {:error, {:fork_failed, other}}
    end
  end

  defp copy_knowledge(src, dst) do
    case EzagentPluginLoom.Knowledge.get(src) do
      md when is_binary(md) and md != "" -> EzagentPluginLoom.Knowledge.put(dst, md)
      _ -> :ok
    end
  end

  defp approved_tree(%{approved: nil}), do: nil

  defp approved_tree(%{approved: version, versions: versions}) do
    case versions[version] do
      %{tree: tree} -> tree
      %{"tree" => tree} -> tree
      _ -> nil
    end
  end

  defp approved_tree(_), do: nil

  # 经合法 Turn 把 tree seed 成新 session 首版 surface(只 page、不发 chat,不触发编排)。
  defp seed_page(session_uri, tree) do
    with {:ok, %{turn_id: tid}} <-
           dispatch(session_uri, "turn.open", %{
             trigger: %{message_id: "fork-seed"},
             opened_at: System.system_time(:millisecond)
           }),
         {:ok, _} <-
           dispatch(session_uri, "turn.compose", %{
             turn_id: tid,
             result_refs: [%{kind: :page, tree: tree}]
           }),
         {:ok, _} <- dispatch(session_uri, "turn.settle", %{turn_id: tid}) do
      # settle → surface.approve 是异步 cast;fork 是同步操作,等 approved 落定再返回,
      # 保证生产里 customer fork 后立即能看到页面(有界等待,fork 是低频操作)。
      wait_approved(session_uri, 150)
    end
  end

  defp wait_approved(_uri, 0), do: {:error, :seed_timeout}

  defp wait_approved(uri, n) do
    case Ezagent.Kind.get_slice(uri, :surface) do
      {:ok, %{approved: a}} when not is_nil(a) -> :ok
      _ -> Process.sleep(20) && wait_approved(uri, n - 1)
    end
  end

  defp dispatch(session_uri, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: Ezagent.URI.new!(@caller),
        caps: SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
