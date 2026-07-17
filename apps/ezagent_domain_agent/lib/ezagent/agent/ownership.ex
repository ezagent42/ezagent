defmodule Ezagent.Agent.Ownership do
  @moduledoc false

  @doc false
  def workspace_match?(%URI{} = agent_uri, %URI{} = workspace_uri) do
    case {Ezagent.URI.type(agent_uri), Ezagent.URI.workspace_name(agent_uri)} do
      {{:ok, "agent"}, {:ok, workspace}} -> workspace == workspace_uri.host
      _ -> false
    end
  end

  def workspace_match?(_agent_uri, _workspace_uri), do: false
end
