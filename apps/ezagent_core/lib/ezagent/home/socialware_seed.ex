defmodule Ezagent.Home.SocialwareSeed do
  @moduledoc """
  Deploy-seed installer for shipped socialware packages (deploy-seed SPEC §4).

  Non-framework socialware (autoservice / kanban / dealscout + future installs)
  lives at the canonical deployment directory
  `$EZAGENT_HOME/<profile>/socialware/<name>/`. The flagships that ship in the
  release box are carried as source packages under
  `ezagent_web/priv/socialware_seed/<name>/`; this module copies each one into
  the deployment directory **idempotently** — a package dir that already exists
  is skipped, so operator hand-edits to a deployed copy are never clobbered.

  Purely filesystem work (no Repo, no dispatch): safe to call from the Category-A
  `mix ezagent.home.init` bootstrap AND from the boot fallback in
  `Ezagent.Socialware.ManifestSeed`, which resolves + publishes the seeded
  manifests through the governed import lane afterwards.

  Layer purity: `ezagent_core` MUST NOT depend on `ezagent_web`. The source app
  is referenced only as a RUNTIME atom via `:code.priv_dir/1` (code-path
  resolution, no compile dependency), mirroring the sanctioned atom use in
  `Mix.Tasks.Ezagent.Credential.Adopt`.
  """

  require Logger

  alias Ezagent.Home

  # The deploy/assembly app that packages the shipped socialware sources. Named
  # as a runtime atom only (no alias / compile dep on ezagent_web).
  @source_app :ezagent_web
  @source_rel "socialware_seed"

  @doc """
  Absolute path to the shipped socialware-seed source dir
  (`ezagent_web/priv/socialware_seed`), or `nil` when the app is not on the code
  path (e.g. a cc-less build) — the caller degrades gracefully.
  """
  @spec source_dir() :: Path.t() | nil
  def source_dir do
    case :code.priv_dir(@source_app) do
      {:error, :bad_name} -> nil
      priv -> Path.join(List.to_string(priv), @source_rel)
    end
  end

  @doc """
  Idempotently copy each `<name>/` package dir from the seed source into the
  deployment directory.

  Options (tests only):

    * `:source` — override the source dir (default: `source_dir/0`);
    * `:dest` — override the deployment dir (default:
      `Ezagent.Home.path("socialware")`).

  A missing source dir (nil or absent) is a silent no-op — a build without the
  seed packages simply installs nothing. Only directory children are seeded;
  a package whose dest already exists is skipped (`File.exists?`), respecting
  operator edits.
  """
  @spec seed!(keyword()) :: :ok
  def seed!(opts \\ []) do
    source = Keyword.get(opts, :source, source_dir())
    dest = Keyword.get(opts, :dest, Home.path("socialware"))

    if is_binary(source) and File.dir?(source) do
      File.mkdir_p!(dest)

      source
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.each(fn src -> seed_one(src, dest) end)
    end

    :ok
  end

  defp seed_one(src, dest) do
    name = Path.basename(src)
    target = Path.join(dest, name)

    unless File.exists?(target) do
      File.cp_r!(src, target)
      Logger.info("socialware deploy-seed: #{name} → #{target}")
    end
  end
end
