defmodule EzagentPluginProtocolApi.Application do
  @moduledoc """
  LLM Protocol API plugin — exposes OpenAI/Anthropic-compatible inbound HTTP APIs.

  Display name: **LLM Protocol API** (gaga's #96 evaluation). The OTP app and
  slug stay `ezagent_plugin_protocol_api` / `protocol_api` — only the
  human-facing name and module taxonomy change.

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
      name: "LLM Protocol API",
      description:
        "Inbound OpenAI/Anthropic-compatible API for calling ezagent agents. Implemented: OpenAI /v1/chat/completions.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters, do: [{Adapter, Binding}]

  @impl Ezagent.Plugin
  def config_surface, do: nil

  @impl Ezagent.Plugin
  def children, do: []

  @impl Ezagent.Plugin
  def after_boot do
    Ezagent.ProtocolApi.PendingReplyStore.init()
    :ok
  end
end
