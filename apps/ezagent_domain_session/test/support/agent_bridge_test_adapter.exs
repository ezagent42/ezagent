defmodule EzagentDomainInstanceMessage.AgentBridgeTestAdapter do
  @moduledoc false

  @behaviour Ezagent.AgentBridge.Adapter

  def ensure_registered do
    case Ezagent.AgentBridge.AdapterRegistry.lookup("cc") do
      {:ok, _adapter} -> :ok
      :error -> Ezagent.AgentBridge.AdapterRegistry.register("cc", __MODULE__)
    end
  end

  @impl true
  def flavor, do: "cc"

  @impl true
  def transport_class, do: :subprocess_ws

  @impl true
  def deliver(payload, channel_pid) when is_pid(channel_pid) do
    send(channel_pid, {:to_claude, %{"content" => payload.text, "meta" => payload.meta}})
    :ok
  end

  @impl true
  def handle_client_event(_event, _params, socket), do: {:reply, {:error, %{}}, socket}
end
