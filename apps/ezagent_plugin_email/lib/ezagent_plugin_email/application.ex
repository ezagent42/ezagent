defmodule EzagentPluginEmail.Application do
  @moduledoc """
  Email plugin OTP application + `Ezagent.Plugin` contract module (task #88,
  CLI-only). It owns the ezagent.chat email capability — `Ezagent.Email`
  send (Swoosh SMTP) / receive (CF Email Worker pull over `:httpc`) — exposed
  through a `mix ezagent.email` CLI. It registers no kinds/behaviors/adapters/
  surfaces; the plugin body is just `plugin_info/0`. A future UI consumer can
  call `Ezagent.Email` without changes here.
  """
  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "email",
      name: "Email",
      description: "Admin CLI for ezagent.chat email send/receive.",
      version: "0.1.0"
    }
  end
end
