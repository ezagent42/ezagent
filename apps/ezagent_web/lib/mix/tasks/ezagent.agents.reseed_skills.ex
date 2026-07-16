defmodule Mix.Tasks.Ezagent.Agents.ReseedSkills do
  @shortdoc "Reconcile per-agent skill homes with current recipe + seed"
  @moduledoc """
  Reconcile each durable agent's `<config_dir>/skills/` subtree to align with the
  current recipe declarations + shipped skill seed.

  ## Usage

      mix ezagent.agents.reseed_skills [--all] [--agent <uri>] [--dry-run]

  Options:
    - `--all` — reconcile ALL durable agents (default when no `--agent`).
    - `--agent <uri>` — reconcile only the given agent.
    - `--dry-run` — compute the diff but do NOT write anything.

  ## Behavior

  - **Only touches `<config_dir>/skills/` subtree** — never renames the home,
    never touches markers or credentials.
  - Per-ref **staging + rename** atomic replace (mirrors `SkillSeed`).
  - **Overwrite** per-agent copies that diverged from the seed (hash 3-way
    compare with telemetry).
  - **Keep** unresolvable refs (recipe no longer declares them) + telemetry;
    v1 does not auto-delete.
  - **CLAUDE.md hint** is idempotently appended when recipe skills include
    the orchestrator skill ref.

  This is the manual trigger for the same reconcile that runs automatically
  in the boot lane (`SkillSeed.boot!/1` → `SkillReconcile.reconcile_all/1`).

  ## Prerequisites

  The node must be booted (`mix phx.server` or equivalent) — the task needs
  `SkillRegistry` ready, `RecipeRegistry` populated, and the Ecto repo running.
  """

  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(argv) do
    {opts, _} =
      OptionParser.parse!(argv,
        strict: [all: :boolean, agent: :string, dry_run: :boolean]
      )

    unless Keyword.get(opts, :all) or Keyword.has_key?(opts, :agent) do
      Mix.shell().error("""
      Specify --all to reconcile all agents, or --agent <uri> for a single agent.

      Usage: mix ezagent.agents.reseed_skills [--all] [--agent <uri>] [--dry-run]
      """)

      System.halt(1)
    end

    unless Ezagent.SkillRegistry.ready?() do
      Mix.shell().error(
        "SkillRegistry is not ready. Ensure the node is booted " <>
          "(SkillSeed.boot! must have run)."
      )

      System.halt(1)
    end

    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      Mix.shell().info("[dry-run] Computing diff without writing...")
    end

    reconcile_opts =
      [
        fail_soft: true,
        dry_run: dry_run?
      ] ++ build_filter_opt(opts)

    {:ok, stats} =
      try do
        Ezagent.Home.SkillReconcile.reconcile_all(reconcile_opts)
      rescue
        e ->
          Mix.shell().error("Reconcile sweep aborted: #{Exception.message(e)}")
          System.halt(1)
      end

    Mix.shell().info("""
    Reseed complete: reconciled=#{stats.reconciled} skipped=#{stats.skipped} errors=#{stats.errors}
    """)

    if stats.errors > 0 do
      System.halt(1)
    end
  end

  defp build_filter_opt(opts) do
    case Keyword.get(opts, :agent) do
      nil -> []
      uri -> [filter_agent_uri: uri]
    end
  end
end
