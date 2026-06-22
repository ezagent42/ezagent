defmodule EzagentPluginProtocolApi.Application do
  @moduledoc """
  Protocol API plugin — exposes OpenAI/Anthropic-compatible inbound HTTP APIs.

  ## Plugin contract

  `use`s both `Application` (OTP plumbing) and `Ezagent.Plugin` (declarative
  contract). Registration is declarative — `Ezagent.Plugin.boot/1` reads the
  callbacks below and performs every `*Registry` call.

  ## What this plugin declares (P0)

  - `adapters/0` — `Ezagent.ProtocolApi.Adapter` as bare `:push` adapter
    (no-op binding; real transport is the HTTP response in `OpenaiChatPlug`).
    P1 will introduce the request-scoped binding variant.
  - `config_surface/0` — nil (API-key management UI deferred to P1).
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.ProtocolApi.Adapter

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
  def adapters, do: [Adapter]

  @impl Ezagent.Plugin
  def config_surface, do: nil

  @impl Ezagent.Plugin
  def children, do: []
end
