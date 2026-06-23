defmodule Ezagent.ProtocolApi.Adapter do
  @moduledoc """
  Protocol API ExternalAdapter — `:request_scoped` (handoff §2.4).

  The binding is REQUEST-SCOPED: lives for one HTTP request. No Worker is spawned; OpenaiChatPlug owns the transport.
  
  
  
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "protocol_api"

  @impl true
  def display_name, do: "Protocol API"

  @impl true
  def description, do: "OpenAI/Anthropic-compatible inbound HTTP API."

  @impl true
  def cap_subject do
    %{
      behavior_module: nil,
      description: "P0 stub — API-key auth is external to the cap model"
    }
  end

  @impl true
  def adapter_kind, do: :request_scoped

  @impl true
  def binding_module, do: Ezagent.ProtocolApi.Binding

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(_event), do: :skip
end
