defmodule EzagentPluginLiveview.Application do
  @moduledoc """
  Admin Web UI plugin OTP application — the `Ezagent.Plugin` contract
  module.

  ## Plugin authoring contract (PR-3)

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  §3 / §7 row 3 / §8 Q3 — Allen confirmed: the OTP `Application` module
  IS the plugin contract module) this module `use`s **both**
  `Application` (OTP plumbing) and `Ezagent.Plugin` (the declarative
  contract).

  `start/2` collapses to `Ezagent.Plugin.boot(__MODULE__)`; the
  framework's two-phase `boot/1` reads the declaration callbacks and
  performs every `*Registry` call. The `:ezagent_plugin_check` Mix
  compiler (wired into `mix.exs`) is the non-bypassable gate — after
  PR-3 the gate guards all five plugins.

  ## What this plugin declares

  This plugin **is** the web admin UI. It ships LiveView modules
  (workflow + admin surfaces) that `EzagentWeb`'s router references by
  atom — it ships no Kinds, no Behaviors, no agent flavors, no spawn
  fns, no Template Classes, and starts no processes of its own.
  Accordingly every optional `Ezagent.Plugin` callback keeps its
  `use Ezagent.Plugin` default: `behaviors/0 → []`, `kinds/0 → []`,
  `spawns/0 → []`, `template_classes/0 → []`, `agent_flavors/0 → []`,
  `routing_tables/0 → []`, `children/0 → []`, `after_boot/0 → :ok`.

  - `plugin_info/0` — identity for the `/plugins` catalog card.
  - `config_surface/0` — **`nil`** (the `use Ezagent.Plugin` default).
    This plugin IS the web UI; there is no separate config surface to
    open from the `/plugins` page (SPEC §6.1 — liveview has no config
    surface).

  Migrating liveview to the contract previously had no `Application`
  module at all (the app was a passive component library with no
  `mod:` key). The contract requires a plugin module + the
  `:ezagent_plugin` key so the `:ezagent_plugin_check` gate guards
  this app too; `boot/1`'s empty Phase-1 supervisor + `PluginRegistry`
  self-registration give the `/plugins` page a card for the web UI.
  """

  use Application
  use Ezagent.Plugin

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "liveview",
      name: "Admin Web UI",
      description: "The web admin UI you're currently using.",
      version: "0.1.0"
    }
  end

  # config_surface/0 keeps the `use Ezagent.Plugin` default `nil` — the
  # liveview plugin IS the web UI; it has no separate config surface
  # (SPEC §6.1).

  # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — Operating context (§4.1):
  # `system://lv-anon-mount` is used by LV mount paths when no
  # `current_entity_uri` is in session. Seeded here so the lazy callers
  # in `agent_extensions_live` / `agent_new_live` / `terminal_live` /
  # `agent_detail_live` find the principal alive on first mount.
  #
  # Test-env skip — the Sandbox boot-time DB write is racy and tests
  # that need the principal call `SystemPrincipal.ensure/1` in setup.
  @impl Ezagent.Plugin
  def after_boot do
    if Mix.env() == :test do
      :ok
    else
      ensure_lv_anon_mount()
    end
  end

  # PR-CC-2b (codex round-1 HIGH-1 fix) — wrap ensure/1 in try/catch
  # so EXITs from absent supervisors don't kill liveview plugin boot.
  defp ensure_lv_anon_mount do
    try do
      case Ezagent.SystemPrincipal.ensure(URI.parse("system://lv-anon-mount")) do
        :ok ->
          :ok

        {:error, reason} ->
          log_seed_failure(reason)
      end
    rescue
      e -> log_seed_failure(e)
    catch
      kind, reason -> log_seed_failure({kind, reason})
    end
  end

  defp log_seed_failure(reason) do
    require Logger

    Logger.warning(
      "EzagentPluginLiveview seed: ensure(system://lv-anon-mount) failed " <>
        "(#{inspect(reason)}); idempotent retry on next boot."
    )

    :ok
  end
end
