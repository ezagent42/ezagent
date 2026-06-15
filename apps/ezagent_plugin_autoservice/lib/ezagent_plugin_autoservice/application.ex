defmodule EzagentPluginAutoservice.Application do
  @moduledoc """
  Autoservice plugin OTP application — the `Ezagent.Plugin` contract
  module for the customer-service vertical.

  ## What this plugin is

  A thin assembly layer on top of existing ezagent primitives + the
  content plugin APIs that turns the platform into a multi-tenant
  customer-service product:

  - a tenant = a Workspace (e.g. `workspace://cinnox`)
  - per-customer Session with a fixed agent team:
    - **fast** agent — a curl-flavored agent (DeepSeek by default) that
      delivers the opening greeting and quick ACK replies
    - **slow** agent (optional) — a cc-flavored agent for deeper answers
  - **operator** — sees the workspace's customer sessions and can join
    any of them to talk to the customer directly
  - **admin** — workspace-wide management caps

  ## Content plugin integration (v0.2)

  This version removes all CINNOX hardcoding and uses the content plugin APIs:
  - `EzagentPluginContent.Tenant.TenantRuntime` for path management + materialization
  - `EzagentPluginContent.Soul.SoulRenderer` for CLAUDE.md generation
  - `EzagentPluginContent.Kb.KbMcpProvider` for MCP configuration
  - Fast agent prompt/model/endpoint read from `priv/skeleton/config/`

  ## What this plugin does NOT invent

  It introduces no new URI scheme, no new Kind, no new Behavior. It reuses
  the curl + cc agent flavors, the Session/Chat primitives, routing rules,
  and the existing password-login auth.
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
          "workspace-scoped admin. Uses content plugin APIs for tenant-aware " <>
          "prompts, souls, skills, and KB.",
      version: "0.3.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Session, :process_message, Ezagent.Behavior.CsOrchestrator},
      {Ezagent.Entity.Session, :operator_claim, Ezagent.Behavior.CsOrchestrator},
      {Ezagent.Entity.Session, :operator_settle, Ezagent.Behavior.CsOrchestrator}
    ]
  end
end
