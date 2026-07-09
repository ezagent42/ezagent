defmodule Ezagent.ConfigGovernance.Agent do
  @moduledoc """
  Pure agent-subject policy helpers for `Ezagent.ActionSet.ConfigGovernance`.

  The ActionSet keeps Lifecycle ctx, sibling reads, dispatch/effect ownership,
  and sandbox materialization. Helpers here take plain data and return plain
  decisions.
  """

  @doc "ConfigGovernance actions are agent-subject only in v1."
  @spec assert_agent_subject(URI.t()) :: :ok | {:error, :non_agent_subject}
  def assert_agent_subject(self_uri) do
    case Ezagent.URI.type(self_uri) do
      {:ok, "agent"} -> :ok
      _ -> {:error, :non_agent_subject}
    end
  end

  @doc "Assert the CR subject is the dispatched-to agent."
  @spec assert_self_cr(struct(), URI.t()) :: :ok | {:error, :subject_not_self}
  def assert_self_cr(%{subject_uri: subject_uri}, self_uri) do
    if same_uri?(subject_uri, self_uri), do: :ok, else: {:error, :subject_not_self}
  end

  defp same_uri?(a, b), do: uri_string(a) == uri_string(b)
  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(other), do: other
end
