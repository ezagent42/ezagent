defmodule Ezagent.World.ActionableErrorPresenter do
  @moduledoc """
  Viewer-aware projection for structured actionable errors.

  The persisted message keeps the producer's neutral error contract. This
  presenter adds the current viewer's repair layer, founder handoff, or durable
  Layer 3 registration number without mutating the message.
  """

  @doc "Project an actionable error for the current viewer."
  @spec project(Ezagent.Message.t(), map()) :: map() | nil
  def project(%Ezagent.Message{} = message, viewer_opts) when is_map(viewer_opts) do
    case Ezagent.Message.Body.actionable_error(message.body) do
      %{"code" => "agent.unclassified_failure"} = error ->
        project_registered_issue(error, message.id)

      %{"permission" => "agent.api_keys.put"} = error ->
        project_api_key_error(error, message.sender, viewer_opts)

      error ->
        error
    end
  end

  defp project_registered_issue(error, message_id) do
    case Ezagent.Message.ActionableErrorIssue.by_message_id(message_id) do
      %Ezagent.Message.ActionableErrorIssue{} = issue ->
        ticket = Ezagent.Message.ActionableErrorIssue.ticket(issue)

        error
        |> Map.put("layer", 3)
        |> Map.put("ticket", ticket)
        |> Map.put(
          "next_step",
          "此问题已自动登记（登记号 #{ticket}），团队会跟进处理。"
        )

      nil ->
        error
    end
  end

  defp project_api_key_error(
         error,
         %URI{} = agent_uri,
         %{caller_uri: %URI{} = caller, caller_caps: caps} = viewer_opts
       ) do
    if Ezagent.World.IdentityData.can_edit_api_keys?(agent_uri, caller, caps) do
      Map.put(error, "layer", 1)
    else
      project_admin_repair(error, Map.get(viewer_opts, :workspace_uri))
    end
  end

  defp project_api_key_error(error, _agent_uri, _viewer_opts), do: error

  defp project_admin_repair(error, %URI{scheme: "workspace"} = workspace_uri) do
    case Ezagent.Workspace.Store.get_by_name(workspace_uri.host) do
      %{created_by: %URI{} = founder_uri} ->
        display_name = Ezagent.EntityPresenter.display(URI.to_string(founder_uri))

        error
        |> Map.put("layer", 2)
        |> Map.put(
          "next_step",
          "请联系 workspace founder #{display_name}，由其检查 Agent 的凭据配置。"
        )
        |> Map.put("repair_owner", %{
          "uri" => URI.to_string(founder_uri),
          "display_name" => display_name
        })
        |> Map.put("action", %{
          "kind" => "notify_admin",
          "label" => "发送提醒给 #{display_name}"
        })

      _ ->
        error
        |> Map.put("layer", 3)
        |> Map.delete("action")
    end
  end

  defp project_admin_repair(error, _workspace_uri), do: error
end
