defmodule Ezagent.Agent.DefaultRecipeSeed do
  @moduledoc """
  `DefaultRecipeSeed` — the GENERIC, non-plugin seeder for the cc-headless default
  role-agents `pm-coordinator` + `dev-together` (Phase 3 ③ refactor 2026-06-30).

  It is the single unified entry that replaces the two old plugin-scoped seeds
  (kanban's `after_boot → PmCoordinatorSeed.seed()` for pm, and the deleted
  `ezagent_plugin_dev_together`'s `after_boot → DevTogetherSeed.seed()` for dev).

  ## Two halves run at two different boot points (the timing matters)

  A default role-agent needs BOTH a recipe ConfigObject (flavor-agnostic config)
  AND a `cc × <role>` AgentTemplate (which needs the **cc flavor's spawn fn**).
  These two are published at different boot stages, so the seed is split:

    1. **recipe-seed** (`seed_all/0`) — runs from `EzagentDomainAgent.Application.start/2`
       (the domain-agent boot's latest point — Repo + ConfigStore are up).
       `RecipeRegistry.seed_role_if_absent/1` writes the role config into the
       system-ws ConfigStore. The recipe carries STRING behavior names; it needs
       NO module loaded and NO flavor spawn fn — pure config, safe this early.

    2. **template-seed** (`seed_templates_all/0`) — runs from the **cc plugin's
       `after_boot`** (`EzagentPluginCc.Application.after_boot`, AFTER
       `Workspace.Loader.load_all/0` publishes the cc flavor + its template spawn
       fn). `DefaultAgentSeed.seed/1` writes the `cc × <role>` AgentTemplate. This
       MUST run after the cc flavor is published — at domain_agent `start/2` the
       cc spawn fn is not yet registered (`{:no_spawn_fn, "template"}`). It mirrors
       the existing cc-orchestrator AgentTemplate seed already in cc `after_boot`.

  Parallel seeders: core's `Ezagent.Plugin.RoleSeedHook` (per-plugin `roles/0`,
  still seeds `kanban-manager`) + the identity domain's admin/smtp boot seed.

  ## `:test` skip + boot-safe (same discipline as RoleSeedHook / identity seed)

  Both halves are SKIPPED in `:test` (a boot-time DB write would contend with the
  per-test Ecto sandbox); tests drive `do_seed_all/0` / `do_seed_templates_all/0`
  inside their own sandbox. Outside `:test` both are BOOT-SAFE: any one role's
  failure downgrades to a `Logger.warning` + telemetry and NEVER crashes boot.
  """

  require Logger

  alias Ezagent.Agent.{DefaultAgentSeed, DefaultRecipes, RecipeRegistry}

  @telemetry_root [:ezagent, :agent, :default_recipe_seed]

  # ── recipe-seed half (domain_agent start/2; flavor-agnostic config) ────────────

  @doc """
  Seed every `DefaultRecipes.all/0` role's recipe ConfigObject (config only — no
  flavor spawn fn needed). CALLER is `EzagentDomainAgent.Application.start/2`.
  Skipped in `:test`; always returns `:ok` (boot-safe).
  """
  @spec seed_all() :: :ok
  def seed_all do
    if test_env?(), do: :ok, else: do_seed_all()
  end

  @doc """
  The un-gated recipe-seed worker (public so a test can drive it inside its own
  Ecto sandbox). Boot-safe: a soft failure on any one recipe is logged +
  telemetered, never raised; always returns `:ok`.
  """
  @spec do_seed_all() :: :ok
  def do_seed_all do
    Enum.each(specs(), fn %{role: role, recipe: recipe} -> seed_recipe(role, recipe) end)
    :ok
  end

  # ── template-seed half (cc plugin after_boot; cc-flavor AgentTemplate) ─────────

  @doc """
  Seed every `DefaultRecipes.all/0` role's `cc × <role>` AgentTemplate. MUST run
  AFTER the cc flavor + template spawn fn are published — CALLER is the cc plugin's
  `after_boot` (alongside the cc-orchestrator AgentTemplate seed). Skipped in
  `:test`; always returns `:ok` (boot-safe).
  """
  @spec seed_templates_all() :: :ok
  def seed_templates_all do
    if test_env?(), do: :ok, else: do_seed_templates_all()
  end

  @doc """
  The un-gated template-seed worker (public so a test can drive it inside its own
  Ecto sandbox + with the cc flavor published). Boot-safe; always returns `:ok`.
  """
  @spec do_seed_templates_all() :: :ok
  def do_seed_templates_all do
    Enum.each(specs(), &seed_template/1)
    :ok
  end

  # ── workers ────────────────────────────────────────────────────────────────

  # Write the role config into the system-ws ConfigStore. Boot-safe: a collision
  # (a pre-existing DB seeded with a divergent body) or any error is a warning +
  # telemetry, not a boot crash.
  defp seed_recipe(role, recipe) do
    case RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _seeded_or_exists} ->
        :ok

      {:error, reason} ->
        soft_fail(role, :recipe_seed_failed, reason, "recipe-seed")
    end
  rescue
    e -> soft_fail(role, :recipe_seed_failed, e, "recipe-seed raised")
  end

  # Write the `cc × <role>` AgentTemplate. Boot-safe: a missing cc spawn fn (if
  # somehow called too early) or any error is a warning + telemetry, not a crash.
  defp seed_template(%{role: role, recipe: recipe, description: description, project_cwd: project_cwd}) do
    # `DefaultAgentSeed.seed/1` is itself boot-safe (logs + `:ok` on a soft
    # failure, e.g. a too-early `{:no_spawn_fn}`); we just rescue any hard raise.
    _ =
      DefaultAgentSeed.seed(%{
        role_name: role,
        description: description,
        recipe: recipe,
        project_cwd: project_cwd,
        telemetry_prefix: @telemetry_root ++ [String.to_atom(role)]
      })

    :ok
  rescue
    e -> soft_fail(role, :template_seed_failed, e, "template-seed raised")
  end

  defp soft_fail(role, event, reason, what) do
    Logger.warning("DefaultRecipeSeed: #{what} for #{role} failed: #{inspect(reason)} (boot-safe)")

    :telemetry.execute(
      @telemetry_root ++ [String.to_atom(role), event],
      %{count: 1},
      %{reason: reason}
    )

    :ok
  end

  # The per-role seed inputs (recipe + description + project_cwd) come from
  # DefaultRecipes so the constants live in ONE place (shared with the kanban
  # board-scoping materialize).
  defp specs do
    [
      %{
        role: "pm-coordinator",
        recipe: DefaultRecipes.pm_coordinator_recipe(),
        description: DefaultRecipes.pm_description(),
        project_cwd: DefaultRecipes.pm_project_cwd()
      },
      %{
        role: "dev-together",
        recipe: DefaultRecipes.dev_together_recipe(),
        description: DefaultRecipes.dev_description(),
        project_cwd: DefaultRecipes.dev_project_cwd()
      }
    ]
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end
end
