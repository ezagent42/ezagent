defmodule EzagentPluginContent.Application do
  @moduledoc """
  Content plugin OTP application — the `Ezagent.Plugin` contract module.

  ## Plugin authoring contract (SPEC §3.2)

  Implements `use Application` (OTP plumbing) and `use Ezagent.Plugin`
  (declarative contract). `start/2` delegates to `Ezagent.Plugin.boot/1`
  which handles the two-phase boot: Phase 1 starts children, Phase 2
  publishes declarations, Phase 3 runs `after_boot/0`.

  ## What this plugin provides

  Content supply for AutoService v2 tenants: soul files, skill packages,
  KB databases, flow chunks, references, and agent configuration. All
  content access goes through `EzagentPluginContent.TenantPaths` which
  resolves the correct sandbox/release directory for each tenant.

  This plugin owns NO Kinds, Behaviors, or agent flavors — it is a
  pure filesystem-content provider. Later tasks add SoulRenderer,
  SkillIndexer, and provision_context.
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
      slug: "content",
      name: "Content",
      description: "Tenant content supply: souls, skills, KB, agent config.",
      version: "0.1.0"
    }
  end
end
