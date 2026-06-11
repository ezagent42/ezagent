defmodule EzagentPluginAutoservice.Application do
  @moduledoc """
  Autoservice plugin OTP application — the `Ezagent.Plugin` contract
  module for the customer-service vertical.

  ## What this plugin is

  A thin assembly layer on top of existing ezagent primitives that turns
  the platform into a multi-tenant customer-service product:

  - a tenant = a Workspace (e.g. `workspace://cinnox`)
  - per-customer Session with socialware Turn semantics
  - **operator** — sees the workspace's customer sessions and can join
    any of them to talk to the customer directly

  ## Declarations

  This plugin declares only `plugin_info/0` — it ships no Kinds,
  Behaviors, Template Classes, or agent flavors. Its value is the
  TurnDriver + ChatUI + lifecycle orchestration assembled from existing
  socialware, instance_message, and agent primitives.
  """

  use Application
  use Ezagent.Plugin

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract -----------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "autoservice",
      name: "Autoservice",
      description:
        "Multi-tenant customer-service vertical: per-customer sessions with " <>
          "socialware turn semantics, operator console, and workspace-scoped admin.",
      version: "0.1.0"
    }
  end
end
