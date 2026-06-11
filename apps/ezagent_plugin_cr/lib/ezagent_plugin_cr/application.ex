defmodule EzagentPluginCr.Application do
  @moduledoc """
  CR (change-request) plugin OTP application — the `Ezagent.Plugin` contract module.

  ## Plugin authoring contract (SPEC §3.2)

  Implements `use Application` (OTP plumbing) and `use Ezagent.Plugin`
  (declarative contract). `start/2` delegates to `Ezagent.Plugin.boot/1`
  which handles the two-phase boot: Phase 1 starts children, Phase 2
  publishes declarations, Phase 3 runs `after_boot/0`.

  ## What this plugin provides

  CR publishing — tenant sandbox→release change requests.

  This plugin owns the tenant publishing flow of AutoService v2: tenant
  admins edit `sandbox/`; publishing copies the full sandbox to
  `release/v<N>/` and atomically flips the `_current` symlink (Task B2).
  This plugin owns NO Kinds or Behaviors — it is a pure store + workflow
  coordinator backed by `Ezagent.Socialware.ConfigStore`.
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
      slug: "cr",
      name: "CR",
      description: "CR publishing — tenant sandbox→release change requests.",
      version: "0.1.0"
    }
  end
end
