defmodule Ezagent.World.ConversationPtyRefresh do
  @moduledoc """
  Reconciles transient conversation PTY selection with a rebuilt projection.

  A caller-capability refresh rebuilds durable conversation state, which does
  not contain the currently selected terminal. The selection is preserved only
  while its target is live, session-related, and still readable by the caller.
  """

  @pty_state_keys ~w(
    active_view
    active_pty_agent_uri
    agent_uri
    agent_detail_path
    agent_status
    pty_alive
    pty_phase
    pty_initial_buffer
  )
  @active_admission_statuses ~w(authenticating materializing)

  @doc """
  Carries a valid active PTY selection into a refreshed conversation state.

  If the terminal is no longer live, session-related, or readable by the
  caller, the returned state explicitly clears the PTY selection.
  """
  @spec reconcile(map(), map(), URI.t(), term()) :: map()
  def reconcile(
        %{"component" => "conversation", "views" => views} = refreshed_state,
        %{
          "component" => "conversation",
          "active_view" => "pty",
          "agent_uri" => agent_uri_string
        } = current_state,
        %URI{} = caller,
        caps
      )
      when is_binary(agent_uri_string) do
    with {:ok, %URI{} = agent_uri} <-
           Ezagent.World.ConversationActions.parse_agent_uri(agent_uri_string),
         true <- live_target_in_projection?(refreshed_state, agent_uri_string, agent_uri),
         true <- Ezagent.Domain.Pty.Access.may_read?(caller, agent_uri, caps) do
      Map.merge(refreshed_state, Map.take(current_state, @pty_state_keys))
    else
      _ -> Map.merge(refreshed_state, cleared_pty_state(views))
    end
  end

  def reconcile(refreshed_state, _current_state, _caller, _caps), do: refreshed_state

  defp live_target_in_projection?(state, agent_uri_string, agent_uri) do
    Ezagent.Domain.Pty.alive?(agent_uri) and
      (Enum.any?(Map.get(state, "members", []), fn member ->
         Map.get(member, "kind") == "agent" and Map.get(member, "uri") == agent_uri_string
       end) or
         Enum.any?(Map.get(state, "agent_admissions", []), fn admission ->
           Map.get(admission, "status") in @active_admission_statuses and
             Map.get(admission, "provisional_agent_uri") == agent_uri_string
         end))
  end

  defp cleared_pty_state(views) do
    %{
      "views" => views,
      "active_view" => fallback_view(views),
      "active_pty_agent_uri" => nil,
      "agent_uri" => nil,
      "agent_detail_path" => nil,
      "agent_status" => nil,
      "pty_alive" => false,
      "pty_phase" => "dead",
      "pty_initial_buffer" => ""
    }
  end

  @doc false
  def fallback_view(views) do
    Enum.find_value(views, fn view ->
      if Map.get(view, "id") == "conversation", do: "conversation"
    end) || Enum.find_value(views, &Map.get(&1, "id"))
  end
end
