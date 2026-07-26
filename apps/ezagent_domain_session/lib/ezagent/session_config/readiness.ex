defmodule Ezagent.Session.Config.Readiness do
  @moduledoc false

  alias Ezagent.Session.Config.Operation

  @spec check(Operation.t(), URI.t()) :: :ok | {:error, {:gate_failed, :readiness, term()}}
  @doc false
  def check(%Operation{target_scope: :workspace}, %URI{scheme: "workspace"}), do: :ok

  def check(%Operation{target_scope: :session}, %URI{scheme: "session"} = session_uri) do
    # V5 A1c — liveness leg by URI through the resolver seam (was
    # `KindRegistry.lookup/1`); the pid never enters domain code.
    case {Ezagent.ReadyGate.status(session_uri), Ezagent.Runtime.Resolver.alive?(session_uri)} do
      {:ready, true} -> :ok
      {status, _live?} -> {:error, {:gate_failed, :readiness, status}}
    end
  end
end
