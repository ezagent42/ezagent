defmodule EzagentCore.MigrationGate do
  @moduledoc """
  Decides whether `Ecto.Migrator` should run pending migrations on
  application boot.

  Wired from `EzagentCore.Application` as
  `{Ecto.Migrator, ..., skip: EzagentCore.MigrationGate.skip?()}`.

  ## Run conditions (gate returns `false` → migrations run)

  Either of these triggers an auto-migrate on boot:
  - `RELEASE_NAME` env var set — the canonical signal that the app is
    starting as a Mix release (`bin/ezagent start` / `start_iex`).
  - `MIX_ENV=prod` — `MIX_ENV=prod mix phx.server` style deployments
    (the app.ezagent.chat Cloudflare-tunnel-fronted deploy uses this).

  ## Skip conditions (gate returns `true` → migrator is a no-op)

  - Dev (`MIX_ENV=dev` or unset) and test (`MIX_ENV=test`) — devs run
    `mix ecto.migrate` manually so a fresh migration is visible and
    deliberate. CI / ExUnit setups bring their own DB lifecycle.
  - Explicit override `EZAGENT_SKIP_MIGRATIONS=1` (also accepts `"true"`)
    — escape hatch for a one-off boot that should NOT apply a pending
    migration (e.g. troubleshooting, or rolling back code without
    rolling back the schema).

  The override is checked FIRST and unconditionally — useful for forcing
  a release boot to skip migrations when you intend to migrate out of
  band.

  ## Why not `Mix.env()`?

  In a Mix release, the `Mix` module is not loaded — `Mix.env/0` would
  raise. `MIX_ENV` env-var is the runtime-safe signal for both Mix
  releases (where it is set to "prod" at boot) and Mix tasks (where Mix
  itself sets it).
  """

  @doc """
  `true` if `Ecto.Migrator` should SKIP pending migrations on boot.

  See module doc for the env-var matrix.
  """
  @spec skip?() :: boolean()
  def skip? do
    if override_skip?() do
      true
    else
      not (release_mode?() or prod_mix_env?())
    end
  end

  defp override_skip? do
    String.downcase(System.get_env("EZAGENT_SKIP_MIGRATIONS", "")) in ["1", "true", "yes"]
  end

  defp release_mode?, do: System.get_env("RELEASE_NAME") not in [nil, ""]

  defp prod_mix_env?, do: System.get_env("MIX_ENV") == "prod"
end
