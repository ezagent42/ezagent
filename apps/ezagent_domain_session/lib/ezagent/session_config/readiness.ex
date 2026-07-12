defmodule Ezagent.Session.Config.Readiness do
  @moduledoc false

  alias Ezagent.Session.Config.Operation

  @spec check(Operation.t(), URI.t()) :: :ok | {:error, {:gate_failed, :readiness, term()}}
  @doc false
  def check(%Operation{target_scope: :workspace}, %URI{scheme: "workspace"}), do: :ok

  def check(%Operation{target_scope: :session}, %URI{scheme: "session"} = session_uri) do
    case {Ezagent.ReadyGate.status(session_uri), Ezagent.KindRegistry.lookup(session_uri)} do
      {:ready, {:ok, _pid}} -> :ok
      {status, _lookup} -> {:error, {:gate_failed, :readiness, status}}
    end
  end
end
