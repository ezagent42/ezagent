defmodule Ezagent.Agent.RoleSeedHook do
  @moduledoc """
  Domain-agent implementation of core's role-seed hook (role-as-data, SPEC §4).

  Seeds a `roles/0` recipe as a role ConfigObject via
  `Ezagent.Agent.RecipeRegistry.seed_role_if_absent/1` (atomic seed-once-if-no-pointer →
  idempotent + override-safe). The role store lives here (read-through over
  `Ezagent.Socialware.ConfigStore`), so the seed — a boot-time DB write — also
  lives here.

  ## `:test` skip (the DB-writer decides)

  Like the identity admin/smtp seeds, the boot-time DB write is SKIPPED in
  `:test`: a write at plugin boot contends with the per-test Ecto sandbox (the
  seed runs outside any test's checked-out connection). Tests seed explicitly
  via `RecipeRegistry.seed_role_if_absent/1` inside their own sandbox. Core's
  `Ezagent.Plugin.RoleSeedHook` seam is pure dispatch and knows nothing about
  the env — the skip is here, at the writer.
  """

  @behaviour Ezagent.Plugin.RoleSeedHook

  @impl true
  def seed_role(recipe) when is_map(recipe) do
    if test_env?() do
      :ok
    else
      case Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe) do
        {:ok, _seeded_or_exists} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end
end
