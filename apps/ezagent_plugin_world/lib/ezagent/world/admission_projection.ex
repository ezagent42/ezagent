defmodule Ezagent.World.AdmissionProjection do
  @moduledoc "Produces the non-secret agent-admission rows exposed to the World client."

  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission

  @doc "Returns non-secret credential-admission rows for a session shown in World."
  @spec list(URI.t()) :: [map()]
  def list(%URI{scheme: "session"} = session_uri) do
    session_uri
    |> AgentAdmission.list()
    |> Enum.map(&row/1)
  rescue
    _ -> []
  end

  def list(_session_uri), do: []

  defp row(admission) do
    %{
      "role_name" => Map.fetch!(admission, :role_name),
      "flavor" => Map.fetch!(admission, :flavor),
      "status" => admission |> Map.fetch!(:status) |> Atom.to_string(),
      "attempt_id" => Map.fetch!(admission, :attempt_id),
      "provisional_agent_uri" => Map.get(admission, :provisional_agent_uri),
      "failure_code" => failure_code(Map.get(admission, :failure_code)),
      "connection" => admission |> Map.fetch!(:connection) |> connection_descriptor()
    }
  end

  defp connection_descriptor({:pty, %{label: label}}) when is_binary(label),
    do: %{"kind" => "pty", "label" => label}

  defp connection_descriptor({:api_key, %{provider: provider, label: label}})
       when is_binary(provider) and is_binary(label),
       do: %{"kind" => "api_key", "provider" => provider, "label" => label}

  defp connection_descriptor(:not_required), do: %{"kind" => "not_required", "label" => "连接"}
  defp connection_descriptor(_connection), do: %{"kind" => "unsupported", "label" => "连接"}

  defp failure_code(nil), do: nil
  defp failure_code(code) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(_code), do: "connection_failed"
end
