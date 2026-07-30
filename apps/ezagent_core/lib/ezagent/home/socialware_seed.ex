defmodule Ezagent.Home.SocialwareSeed do
  @moduledoc """
  Deploy-seed installer for shipped socialware packages (deploy-seed SPEC §4).

  Non-framework socialware (autoservice / kanban / dealscout + future installs)
  lives at the canonical deployment directory
  `$EZAGENT_HOME/<profile>/socialware/<name>/`. Flagships that ship in the
  release box are carried as source packages under any app's
  `priv/socialware_seed/<name>/`; this module enumerates EVERY loaded OTP app,
  collects those source dirs, and reconciles each package into the deployment
  directory **idempotently at FILE granularity** — a file that already exists
  at dest is never touched (operator hand-edits to a deployed copy are never
  clobbered), but a file present in the source and MISSING at dest is copied
  in on every seed! call, even into an already-deployed package dir.

  File-level (not directory-level) reconciliation is what #206 required:
  `EZAGENT_HOME` is a **persistent** volume (prod/canary bind-mount `/data`)
  that survives a DB reset, so a package dir materialized by an earlier
  deploy stays on disk forever. When a shipped package later grows a new
  sibling file — e.g. kanban's `recipes.yaml`, added in 2e46164d3 after its
  `manifest.yaml` first shipped in cd7f5a599 — a dir-level `File.exists?`
  skip would permanently freeze every already-deployed copy at its
  first-seed file set, silently starving `Ezagent.Socialware.ManifestSeed`'s
  `seed_sibling_recipes` of a file it now expects and failing loud on
  `{:unknown_agent_recipe, _}` at every subsequent boot — no amount of
  re-running seed! (or resetting the DB) would ever add the missing file
  without an operator manually deleting the stale package dir first. File-
  level reconciliation self-heals this on the very next boot: no manual
  home wipe needed.

  Caveat: "never touched" cuts both ways. If an operator deliberately
  DELETES a single file from an already-deployed package (rather than
  editing it), the next seed! cannot tell that apart from "this dest simply
  predates the file's existence in source" — it re-adds the file. Only a
  content EDIT survives untouched; a content-level CHANGE shipped in a later
  release of a builtin file also does not overwrite an existing (even
  unedited) copy — see the module tests for both boundaries.

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
  Idempotently reconcile each `<name>/` package dir from every seed source
  into the deployment directory, at file granularity.

  Options (tests only):

    * `:source` — override with a single source dir (skips enumeration);
    * `:dest` — override the deployment dir (default: the `system://socialware`
      deploy dir resolved via `Ezagent.System.FsResolver`).

  Only top-level directory children of a source are seeded (stray files
  ignored). Within a package dir, every file present in source is copied to
  dest UNLESS it already exists there — recursively, so a file already
  deployed (including one an operator hand-edited) is NEVER overwritten, but
  a file the source has gained since the package was first deployed (a new
  sibling file added to an already-materialized package dir) reaches an
  existing deployment on the very next call.
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
      |> Enum.each(fn src -> seed_one(src, Path.join(dest, Path.basename(src))) end)
    end

    :ok
  end

  # Recursively reconcile `src` into `target` (a package dir, or a subdir of
  # one): each source file is copied to dest only if it is missing there;
  # each source subdir is walked the same way. A file that already exists at
  # dest — whatever its content — is never touched, at any depth.
  defp seed_one(src, target) do
    File.mkdir_p!(target)

    src
    |> File.ls!()
    |> Enum.each(fn entry ->
      s = Path.join(src, entry)
      d = Path.join(target, entry)

      cond do
        File.dir?(s) ->
          seed_one(s, d)

        File.exists?(d) ->
          :ok

        true ->
          File.cp!(s, d)
          Logger.info("socialware deploy-seed: #{d}")
      end
    end)
  end
end
