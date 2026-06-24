defmodule EzagentPluginCc.CcHeadlessBridgeAdapter do
  @moduledoc """
  BridgeAdapter for the `"cc-headless"` flavor.

  `cc-headless` is an in-process synchronous transport: Agent receive calls
  this adapter, this adapter calls the supervised Python SDK sidecar, and the
  returned result is re-dispatched to `Ezagent.Behavior.CcHeadlessAgent`'s
  `:sync_result` action for persistence and session reply.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  alias Ezagent.AgentBridge.Payload

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc-headless"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :in_process_sync

  @impl Ezagent.AgentBridge.Adapter
  def deliver(%Payload{} = payload, nil) do
    with {:ok, agent_uri} <- agent_uri_from_payload(payload) do
      EzagentPluginCc.SdkSidecar.query(agent_uri, payload.text || "",
        session_id: session_id_from_payload(payload)
      )
    end
  end

  @impl Ezagent.AgentBridge.Adapter
  def handle_client_event(_event, _params, socket),
    do: {:reply, {:error, %{reason: "unsupported"}}, socket}

  @impl Ezagent.AgentBridge.Adapter
  def socket_path, do: "/cc_headless_socket"

  @impl Ezagent.AgentBridge.Adapter
  def channel_topic_prefix, do: "cc-headless"

  @impl Ezagent.AgentBridge.Adapter
  def join_info(_params, _socket), do: %{}

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

  defp session_id_from_payload(%Payload{meta: meta, session_uri: %URI{} = session_uri})
       when is_map(meta) do
    Map.get(meta, "claude_session_id") || Ezagent.URI.stable_key(session_uri)
  end

  defp session_id_from_payload(%Payload{meta: meta}) when is_map(meta) do
    Map.get(meta, "claude_session_id")
  end

  defp session_id_from_payload(_), do: nil
end
