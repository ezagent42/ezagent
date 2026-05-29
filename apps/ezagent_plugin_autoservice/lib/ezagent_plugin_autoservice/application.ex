defmodule EzagentPluginAutoservice.Application do
  @moduledoc """
  Autoservice plugin OTP application — the `Ezagent.Plugin` contract
  module for the customer-service vertical.

  ## What this plugin is

  A thin assembly layer on top of existing ezagent primitives that turns
  the platform into a multi-tenant customer-service product:

  - a tenant = a Workspace (e.g. `workspace://cinnox`)
  - per-customer Session with a fixed agent team:
    - **fast** agent — a curl-flavored agent (DeepSeek by default) that
      delivers the opening greeting and quick replies
    - **slow** agent (optional, env-gated) — a cc-flavored agent for
      deeper answers
  - **operator** — sees the workspace's customer sessions and can join
    any of them to talk to the customer directly
  - **admin** — workspace-wide management caps

  ## What this plugin does NOT invent

  Per P1 (plugin-isolation north star) + P8 (less invented, more
  assembled): it introduces no new URI scheme, no new Kind, no new
  Behavior. It reuses the curl + cc agent flavors, the Session/Chat
  primitives, `Ezagent.Routing.RuleStore`, and the existing
  password-login auth. The customer-service session is assembled by
  the `EzagentPluginAutoservice.CustomerSession` facade (idempotent
  reconciler), not by a bespoke Generator.

  ## Declarations

  This plugin declares only `plugin_info/0` — it ships no Kinds,
  Behaviors, Template Classes, or agent flavors. Its value is the
  facade + provisioning helpers + customer/operator LiveViews + the
  `mix ezagent.demo.seed_autoservice` task, all plain modules in this
  app. The customer/operator LiveView routes are declared by
  `ezagent_web`'s router (routes are host-owned, not plugin-injected).
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "autoservice",
      name: "Autoservice",
      description:
        "Multi-tenant customer-service vertical: per-customer sessions with a " <>
          "fast (curl/DeepSeek) + slow (cc) agent team, operator console, and " <>
          "workspace-scoped admin.",
      version: "0.1.0"
    }
  end
end
