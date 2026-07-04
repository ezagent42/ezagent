defmodule EzagentPluginPy.BridgeAdapter do
  @moduledoc """
  Py flavor AgentBridge adapter — the `:in_process_sync` TRANSPORT (P4b).

  ## Why this exists (own-Kind retirement)

  P4b folds `py` onto the UNIFIED `Ezagent.Entity.Agent` Kind (curl precedent).
  On `Entity.Agent` the `:receive` action is owned by the flavor-blind base
  `Ezagent.ActionSet.Agent.Receive`, which hands the message to
  `Ezagent.AgentBridge.deliver` → this per-flavor adapter. So py can no longer
  own `:receive`; its chat→script→reply splits, exactly like curl, into:

    * the **TRANSPORT** half — THIS adapter. It does ONLY the in-process
      `Ezagent.Domain.Python` `"receive"` round-trip and RETURNS the result.
      It PERSISTS NOTHING and emits NO effects.

    * the **STATE** half — `Ezagent.ActionSet.PyAgent` on `Entity.Agent`: the
      `:sync_result` action persists `last_*` + replies into the session; plus
      `:reset` / `:configure` and the `activate/2` subprocess self-heal.

  ## Transport class — `:in_process_sync`

  No WebSocket, no Channel. `AgentBridge.deliver` routes the
  `:in_process_sync` class straight here and hands `nil` for the channel ref.
  `deliver/2` calls the agent's per-agent Domain.Python subprocess
  SYNCHRONOUSLY (the subprocess is kept alive by `Behavior.PyAgent.activate/2`;
  Domain.Python is keyed by the agent URI) and returns `{:ok, %{text: ...}}` /
  `{:ok, :silent}` / `{:error, reason}` — which `agent.receive` re-dispatches
  to `Behavior.PyAgent`'s `:sync_result` action.

  ## No self-call deadlock

  The adapter runs INSIDE the agent Kind's dispatch process. It does NOT read
  the agent's live slice (`Kind.get_slice/2` would be a `GenServer.call(self)`
  deadlock). The Domain.Python handle is the agent URI (carried in the
  payload); the per-call timeout uses the flavor default (`:configure` tunes
  the durable value, applied by the Behavior — not needed for the transport).
  """

  @behaviour Ezagent.AgentBridge.Adapter

  require Logger

  alias Ezagent.AgentBridge.Payload
  alias Ezagent.Domain.Python

  @default_timeout_ms 10_000

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "py"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :in_process_sync

  @impl Ezagent.AgentBridge.Adapter
  def deliver(%Payload{} = payload, nil) do
    with {:ok, agent_uri} <- agent_uri_from_payload(payload) do
      params = %{
        "text" => payload.text || "",
        "from" => uri_string(payload.sender_uri),
        "session" => uri_string(payload.session_uri)
      }

      run_receive(agent_uri, @default_timeout_ms, params)
    end
  end

  # Call the operator script's `receive` handler on the per-agent Domain.Python
  # subprocess (keyed by the agent URI). A raising handler surfaces as a
  # structured JSON-RPC error (captured by the Behavior into last_error).
  defp run_receive(handle, timeout, params) do
    case Python.call(handle, "receive", params, timeout) do
      {:ok, nil} -> {:ok, :silent}
      {:ok, %{"text" => t}} when is_binary(t) -> {:ok, %{text: t}}
      {:ok, other} -> {:error, {:bad_python_result, other}}
      {:error, %{"code" => code, "message" => message}} -> {:error, {:python_error, code, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  # agent_uri travels in the payload meta (set by the receive delivery path),
  # falling back to the session-derived target if absent.
  defp agent_uri_from_payload(%Payload{meta: meta}) when is_map(meta) do
    case Map.get(meta, "agent_uri") do
      uri_str when is_binary(uri_str) and uri_str != "" ->
        {:ok, Ezagent.URI.new!(uri_str)}

      _ ->
        {:error, :no_agent_uri_in_payload}
    end
  rescue
    ArgumentError -> {:error, :malformed_agent_uri}
  end

  defp agent_uri_from_payload(_), do: {:error, :no_agent_uri_in_payload}

  defp uri_string(%URI{} = u), do: URI.to_string(u)
  defp uri_string(s) when is_binary(s), do: s
  defp uri_string(_), do: ""
end
