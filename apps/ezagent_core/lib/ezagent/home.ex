defmodule Ezagent.Home do
  @moduledoc """
  EZAGENT_HOME runtime persistence helpers — Phase 5 PR 1.

  Resolves the active home + profile + credential paths from environment
  with sensible fallbacks documented in `docs/phase-specs/phase5/EZAGENT_HOME.md`.

  Read-only here; mutation lives in `Mix.Tasks.Ezagent.Home.Init` and
  `Mix.Tasks.Ezagent.Home.ImportFromEsrdDev` so library code never creates
  state on a sleeping operator's machine.
  """

  @default_home "~/.ezagent"
  @default_profile "default"

  @doc "Absolute path to the active EZAGENT_HOME (env: `EZAGENT_HOME`)."
  def home do
    System.get_env("EZAGENT_HOME", @default_home) |> Path.expand()
  end

  @doc "Active profile name (env: `EZAGENT_PROFILE`)."
  def profile, do: System.get_env("EZAGENT_PROFILE", @default_profile)

  @doc "Absolute path to the active profile directory."
  def profile_dir, do: Path.join(home(), profile())

  @doc "Path to a sub-directory under the profile (e.g. `:credentials`, `:db`)."
  def path(component) when is_atom(component),
    do: Path.join(profile_dir(), Atom.to_string(component))

  def path(component) when is_binary(component),
    do: Path.join(profile_dir(), component)

  @doc """
  Read a YAML credentials file under `credentials/`.

  Returns `{:ok, map}`, `{:error, :not_found}`, or `{:error, reason}`.
  Credentials missing is a normal startup state — the caller decides
  whether to degrade or raise (per memory `feedback_let_it_crash_no_workarounds`,
  prefer raise at the actual boundary; a missing Feishu cred means
  the Feishu plugin should refuse to start, not silently no-op).
  """
  def read_credentials(name) when is_binary(name) do
    file = Path.join(path(:credentials), "#{name}.yaml")

    case File.read(file) do
      {:ok, body} ->
        case YamlElixir.read_from_string(body) do
          {:ok, parsed} -> {:ok, parsed}
          err -> err
        end

      {:error, :enoent} ->
        {:error, :not_found}

      err ->
        err
    end
  end

  @doc "True iff the profile dir + skeleton sub-dirs exist."
  def initialized? do
    File.dir?(profile_dir()) and File.dir?(path(:credentials)) and File.dir?(path(:db))
  end

  @doc """
  List of profile sub-directories the init task creates.

  `:socialware` is the canonical deployment home for non-framework socialware
  (deploy-seed SPEC §4); `Ezagent.Home.SocialwareSeed` seeds shipped packages
  into it at init time.
  """
  def skeleton_dirs, do: [:credentials, :db, :snapshots, :logs, :plugins, :socialware]
end
