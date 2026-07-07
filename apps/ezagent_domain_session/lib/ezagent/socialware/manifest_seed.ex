defmodule Ezagent.Socialware.ManifestSeed do
  @moduledoc """
  Late boot-time socialware manifest scanner — ONE lane for every local
  manifest source (sw-home lane, 2026-07-07; supersedes the early
  domain_session-priv-only scan).

  `scan_all!/1` runs once, AFTER every umbrella app has started (triggered
  from the last-booting transport app, `EzagentWeb.Application`), and sweeps
  in deterministic order:

    1. the deployment-level seed directory — `system://socialware`
       (`$EZAGENT_HOME/<profile>/socialware/*/manifest.yaml`), resolved
       through `Ezagent.System.FsResolver` (never raw `Ezagent.Home`);
       silently skipped when the directory does not exist;
    2. every started OTP app's `priv/socialware/*/manifest.yaml`, apps
       sorted by name (apps without a priv dir are skipped).

  Plugin-author experience: drop a `manifest.yaml` under your app's
  `priv/socialware/<name>/` and it is collected — zero loader code. A name
  published by more than one source settles via the
  `ConfigGovernance.Socialware.publish_or_upgrade/2` idempotency
  (`:published` / `:upgraded` / `:exists`).

  Error layering:

    * broken manifest content (parse / resolve / conformance) → raise, boot
      fails LOUDLY — a deployment error should stop the node;
    * `uses` naming a plugin that is not installed → raise with a readable
      "requires plugin ... which is not installed" message instead of a deep
      resolver tuple.

  Remote config-repo ingestion still belongs to the registry follow-up.
  """

  require Logger

  alias Ezagent.Socialware.ManifestYaml

  @typedoc "One imported manifest: its path, definition name, and publish result."
  @type result :: %{path: Path.t(), name: String.t(), result: :published | :upgraded | :exists}

  @doc "Return true when boot manifest scanning is enabled for this runtime."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(
      :ezagent_domain_session,
      :socialware_manifest_boot_scan,
      default_enabled?()
    )
  end

  @doc """
  Sweep every local manifest source through the governed import lane.

  No-op when `enabled?/0` is false (test default). Options (tests only):

    * `:sources` — override the collected `[{source_label, dir}]` list;
    * `:deploy_dir` — override the deployment-level directory (default:
      `system://socialware` via `Ezagent.System.FsResolver`).

  Raises on the first failing manifest (fail-loud boot semantics).
  """
  @spec scan_all!(keyword()) :: :ok
  def scan_all!(opts \\ []) do
    if enabled?() do
      opts
      |> Keyword.get_lazy(:sources, fn -> default_sources(opts) end)
      |> Enum.each(fn {source, dir} -> _ = scan_dir!(dir, source: source) end)
    end

    :ok
  end

  @doc """
  Scan one directory whose children may contain `manifest.yaml` and import
  each through parse → resolve → conformance → governed publish.

  A missing/empty directory yields `[]` (the deploy dir is optional).
  Raises on the first failing manifest; `opts[:source]` labels the origin in
  logs and error messages.
  """
  @spec scan_dir!(Path.t(), keyword()) :: [result()]
  def scan_dir!(dir, opts \\ []) when is_binary(dir) do
    source = Keyword.get(opts, :source, dir)

    dir
    |> manifest_paths()
    |> Enum.map(fn path ->
      case import_manifest_path(path) do
        {:ok, %{name: name, result: outcome} = result} ->
          Logger.info("socialware manifest seed: #{name} (#{source}) → #{outcome}")
          result

        {:error, {name, reason}} ->
          raise seed_failure_message(source, path, name, reason)
      end
    end)
  end

  # Deterministic source order: deployment-level dir first, then every started
  # OTP app's priv/socialware, apps sorted by name.
  defp default_sources(opts) do
    deploy_sources(opts) ++ app_sources()
  end

  defp deploy_sources(opts) do
    dir =
      case Keyword.fetch(opts, :deploy_dir) do
        {:ok, override} ->
          # Tests inject an explicit dir — do NOT seed the real deployment home.
          override

        :error ->
          # Boot fallback (deploy-seed SPEC §4): CI/dev that never ran
          # `mix ezagent.home.init` still gets the shipped flagships into the
          # deployment dir. Idempotent FS copy (respects operator edits); runs
          # ahead of resolving + scanning the dir. `Ezagent.Home.SocialwareSeed`
          # lives in ezagent_core (domain_session → core dependency is valid).
          _ = Ezagent.Home.SocialwareSeed.seed!()
          # OI-3: node-global deployment artifact — resolved through the
          # hardened system:// seam, not raw Ezagent.Home.
          Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("socialware"))
      end

    if File.dir?(dir), do: [{"deploy", dir}], else: []
  end

  defp app_sources do
    Application.started_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
    |> Enum.sort()
    |> Enum.flat_map(fn app ->
      case :code.priv_dir(app) do
        {:error, :bad_name} ->
          []

        priv ->
          dir = Path.join(List.to_string(priv), "socialware")
          if File.dir?(dir), do: [{Atom.to_string(app), dir}], else: []
      end
    end)
  end

  defp import_manifest_path(path) do
    with {:ok, yaml} <- File.read(path),
         {:ok, attrs} <- ManifestYaml.parse(yaml) do
      case Map.get(attrs, "name") do
        name when is_binary(name) and name != "" ->
          ctx = ManifestYaml.operator_admin_ctx(name, Ezagent.URI.workspace(:system))

          case ManifestYaml.import(yaml, ctx) do
            {:ok, result} -> {:ok, %{path: path, name: name, result: result}}
            {:error, reason} -> {:error, {name, reason}}
          end

        other ->
          {:error, {nil, {:invalid_manifest_seed, other}}}
      end
    else
      {:error, reason} -> {:error, {nil, reason}}
    end
  end

  # `uses` unsatisfied gets a human-readable message (the late lane runs after
  # every plugin booted, so a missing plugin is a genuine deployment error —
  # still fail-loud, but say what is missing instead of a resolver tuple).
  defp seed_failure_message(source, path, name, {:missing_socialware_plugins, missing}) do
    {plugin_word, verb} = if length(missing) == 1, do: {"plugin", "is"}, else: {"plugins", "are"}
    slugs = Enum.map_join(missing, ", ", &inspect/1)

    "socialware manifest #{name} (#{source}: #{path}) requires #{plugin_word} " <>
      "#{slugs} which #{verb} not installed"
  end

  defp seed_failure_message(source, path, name, reason) do
    "socialware manifest seed failed for #{name || Path.basename(Path.dirname(path))} " <>
      "(#{source}: #{path}): #{inspect(reason)}"
  end

  defp manifest_paths(root) do
    root
    |> Path.join("*/manifest.yaml")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp default_enabled?, do: Application.get_env(:ezagent_core, :env) in [:dev, :prod]
end
