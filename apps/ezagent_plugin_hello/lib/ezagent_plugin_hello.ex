defmodule EzagentPluginHello do
  @moduledoc """
  Top-level helpers for the hello plugin.

  Owns the SINGLE source of truth for the **hello home workspace** — the
  workspace the 官网 instance (`session://<home>/hello/ezagent-official`), its
  DeepSeek credential bridge, and the `/hello/<name>` short-URL serve side all
  read. Before this module each side pinned its own literal (`"system"` on the
  seed/bridge side, `"demo"` in the controller default, `"system"` in
  `config.exs`) — a split-brain where two sources disagreed on one truth.
  """

  @doc """
  The hello home workspace name (default `"ezagent"`).

  The ONE read point every hello-home consumer must use — the boot 官网 seed
  (`OfficialSiteSeed`/`FusionSeed`), the #185 credential bridge destination
  (`CredentialBridge`), and the `/hello/<name>` serve side
  (`EzagentWeb.Socialware.ChatFeedController`). Read at RUNTIME (never a
  compile-time attribute) so a per-lane override
  (`config :ezagent_plugin_hello, :home_workspace, ...`) takes effect without a
  recompile, and so no caller ever passes the workspace as an argument (the
  credential path stays non-caller-redirectable, #185).
  """
  @spec home_workspace() :: String.t()
  def home_workspace do
    Application.get_env(:ezagent_plugin_hello, :home_workspace, "ezagent")
  end
end
