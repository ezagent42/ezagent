defmodule Ezagent.Home.SocialwareSeed do
  @moduledoc """
  Deploy-seed installer for shipped socialware packages (deploy-seed SPEC §4).

  Non-framework socialware (autoservice / kanban / dealscout + future installs)
  lives at the canonical deployment directory
  `$EZAGENT_HOME/<profile>/socialware/<name>/`. Flagships that ship in the
  release box are carried as source packages under any app's
  `priv/socialware_seed/<name>/`; this module enumerates EVERY loaded OTP app,
  collects those source dirs, and copies each package into the deployment
  directory **idempotently** — a package dir that already exists is skipped, so
  operator hand-edits to a deployed copy are never clobbered.

  Purely filesystem work (no Repo, no dispatch): safe to call from the Category-A
  `mix ezagent.home.init` bootstrap AND from the boot fallback in
  `Ezagent.Socialware.ManifestSeed`, which resolves + publishes the seeded
  manifests through the governed import lane afterwards.

  Layer-clean: `ezagent_core` names NO higher-layer app. Sources are discovered
  generically by scanning every loaded OTP app's `priv/socialware_seed` — so
  whichever app ships a package (today `ezagent_web`) is found without a
  hardcoded reference.
  """

  require Logger

  @source_rel "socialware_seed"

  @doc """
  All shipped socialware-seed source dirs: every loaded OTP app's
  `priv/socialware_seed` that exists on disk. Empty when none ship packages.
  Works at bootstrap (apps loaded, not necessarily started) and at boot.
  """
  @spec source_dirs() :: [Path.t()]
  def source_dirs do
    for {app, _desc, _vsn} <- Application.loaded_applications(),
        priv = safe_priv_dir(app),
        priv != nil,
        dir = Path.join(priv, @source_rel),
        File.dir?(dir) do
      dir
    end
  end

  defp safe_priv_dir(app) do
    case :code.priv_dir(app) do
      {:error, :bad_name} -> nil
      priv -> List.to_string(priv)
    end
  end

  @doc """
  Idempotently copy each `<name>/` package dir from every seed source into the
  deployment directory.

  Options (tests only):

    * `:source` — override with a single source dir (skips enumeration);
    * `:dest` — override the deployment dir (default: the `system://socialware`
      deploy dir resolved via `Ezagent.System.FsResolver`).

  Only directory children are seeded; a package whose dest already exists is
  skipped (`File.exists?`), respecting operator edits.
  """
  @spec seed!(keyword()) :: :ok
  def seed!(opts \\ []) do
    dest =
      Keyword.get_lazy(opts, :dest, fn ->
        # Resolve the node-global deploy dir through the sanctioned system://
        # seam (Ezagent.System.FsResolver), NOT raw Ezagent.Home — same
        # chokepoint ManifestSeed.deploy_dir uses, so seed dest == scan dir.
        Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("socialware"))
      end)

    sources =
      case Keyword.get(opts, :source) do
        nil -> source_dirs()
        src when is_binary(src) -> [src]
      end

    for source <- sources, File.dir?(source) do
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
