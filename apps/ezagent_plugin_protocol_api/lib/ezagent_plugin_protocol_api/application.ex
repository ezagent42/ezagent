defmodule EzagentPluginProtocolApi.Application do
  @moduledoc """
  Protocol API plugin — exposes OpenAI/Anthropic-compatible inbound HTTP APIs.

  ## Plugin contract

  `use`s both `Application` (OTP plumbing) and `Ezagent.Plugin` (declarative
  contract). Registration is declarative — `Ezagent.Plugin.boot/1` reads the
  callbacks below and performs every `*Registry` call.
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.ProtocolApi.Adapter
  alias Ezagent.ProtocolApi.Binding

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "protocol_api",
      name: "Protocol API",
      description: "OpenAI/Anthropic-compatible inbound HTTP API. Phase 0: /v1/chat/completions.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters, do: [{Adapter, Binding}]

  @impl Ezagent.Plugin
  def config_surface, do: nil

  @impl Ezagent.Plugin
  def children, do: []
end
