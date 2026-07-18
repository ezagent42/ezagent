defmodule Ezagent.Socialware.ManifestSeed do
  @moduledoc """
  Late boot-time socialware manifest scanner — ONE lane over the single
  deployment-level seed directory (sw-home lane, 2026-07-07; supersedes the
  early domain_session-priv-only scan).

  `scan_all!/1` runs once, AFTER every umbrella app has started (triggered
  from the last-booting transport app, `EzagentWeb.Application`), and sweeps
  the deployment-level seed directory — `system://socialware`
  (`$EZAGENT_HOME/<profile>/socialware/*/manifest.yaml`), resolved through
  `Ezagent.System.FsResolver` (never raw `Ezagent.Home`); silently skipped
  when the directory does not exist. Shipped flagships are seeded here from
  `ezagent_web/priv/socialware_seed/<name>/` by `Ezagent.Home.SocialwareSeed`
  (home.init + a boot fallback); this is the **canonical and only** socialware
  home (deploy-seed SPEC §4).

  Single-source contract: the deployment directory is the sole manifest
  source. The former app-priv `priv/socialware/<name>/manifest.yaml` authoring
  lane was retired by the deploy-seed migration (autoservice #1231, hello
  #1233) and is forbidden by the `socialware_priv_manifest_files` arch gate
  (#1246); its now-dead boot-scan branch was removed in #1227. A name
  published by more than one manifest under the deploy dir settles via the
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
  Sweep the single deployment-level manifest source through the governed
  import lane.

  No-op when `enabled?/0` is false (test default). Option (tests only):

    * `:deploy_dir` — override the deployment-level directory (default:
      `system://socialware` via `Ezagent.System.FsResolver`).

  Raises on the first failing manifest (fail-loud boot semantics).
  """
  @spec scan_all!(keyword()) :: :ok
  def scan_all!(opts \\ []) do
    if enabled?() do
      dir = deploy_dir(opts)
      if File.dir?(dir), do: scan_dir!(dir, source: "deploy")
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

  # The single manifest source: the deployment-level seed directory.
  defp deploy_dir(opts) do
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
  end

  defp import_manifest_path(path) do
    with :ok <- seed_sibling_recipes(path),
         {:ok, yaml} <- File.read(path) do
      case import_package(yaml) do
        {:ok, result} -> {:ok, Map.put(result, :path, path)}
        {:error, _} = error -> error
      end
    else
      {:error, reason} -> {:error, {nil, reason}}
    end
  end

  @doc """
  Content-based governed import of one socialware package — the same
  parse → resolve → conformance → `publish_or_upgrade` chain the boot scan
  runs, but fed YAML **bytes** instead of filesystem paths.

  This is the in-node entry point for the operator RPC lane
  (`mix ezagent.socialware.import_remote`, D5 2026-07-18): dev keeps
  boot-scan prod-only, and instead pushes manifest bytes into the RUNNING
  node over distributed Erlang — zero governance bypass, identical
  idempotency semantics (`:published` / `:upgraded` / `:exists`).

  `recipes_yaml` (optional) carries a sibling `recipes.yaml`'s bytes; its
  data-role recipes are seeded BEFORE the manifest publishes, mirroring
  `seed_sibling_recipes` on the boot path. Malformed recipes raise
  (fail-loud, same policy as boot); manifest-chain failures return
  `{:error, {name, reason}}`.
  """
  @spec import_package(binary(), binary() | nil) ::
          {:ok, %{name: String.t(), result: :published | :upgraded | :exists}}
          | {:error, {String.t() | nil, term()}}
  def import_package(manifest_yaml, recipes_yaml \\ nil) when is_binary(manifest_yaml) do
    if is_binary(recipes_yaml), do: seed_recipes_content!(recipes_yaml, "recipes.yaml (rpc)")

    case ManifestYaml.parse(manifest_yaml) do
      {:ok, attrs} ->
        case Map.get(attrs, "name") do
          name when is_binary(name) and name != "" ->
            ctx = ManifestYaml.operator_admin_ctx(name, Ezagent.URI.workspace(:system))

            case ManifestYaml.import(manifest_yaml, ctx) do
              {:ok, result} -> {:ok, %{name: name, result: result}}
              {:error, reason} -> {:error, {name, reason}}
            end

          other ->
            {:error, {nil, {:invalid_manifest_seed, other}}}
        end

      {:error, reason} ->
        {:error, {nil, reason}}
    end
  end

  # Seed the socialware package's own "brain" recipes BEFORE publishing its
  # manifest — a sibling `recipes.yaml` (same dir as `manifest.yaml`) carries the
  # data-role recipes (`%{name, skills, prompt}`) that the manifest's role slots
  # reference by name. Registering them first is what lets the manifest resolve
  # (`ManifestResolver` fails loud on an unknown recipe name-ref) + pass
  # conformance. This is how a socialware ships its OWN collaborator recipes
  # (kanban-assistant / dev-together) as SEED DATA instead of plugin code — the
  # plugin keeps only the board TOOL (`kanban-manager` behaviors).
  #
  # Absent `recipes.yaml` → `:ok` (most packages carry none). A malformed one
  # raises = fail-loud boot (same policy as a broken manifest).
  defp seed_sibling_recipes(manifest_path) do
    rp = Path.join(Path.dirname(manifest_path), "recipes.yaml")

    if File.exists?(rp) do
      case File.read(rp) do
        {:ok, yaml} -> seed_recipes_content!(yaml, rp)
        {:error, reason} -> raise "recipes.yaml seed failed at #{rp}: #{inspect(reason)}"
      end
    else
      :ok
    end
  end

  @doc """
  Seed data-role recipes from `recipes.yaml` **bytes** (fail-loud). Shared by
  the boot path (`seed_sibling_recipes`, origin = the file path) and the RPC
  import lane (`import_package/2`); raises on malformed content or a failed
  seed — same policy as a broken manifest.
  """
  @spec seed_recipes_content!(binary(), String.t()) :: :ok
  def seed_recipes_content!(yaml, origin) when is_binary(yaml) do
    case ManifestYaml.parse(yaml) do
      {:ok, %{"recipes" => list}} when is_list(list) ->
        Enum.each(list, &seed_one_recipe(&1, origin))
        :ok

      {:ok, other} ->
        raise "recipes.yaml at #{origin} must have a top-level `recipes:` list, got: #{inspect(other)}"

      {:error, reason} ->
        raise "recipes.yaml seed failed at #{origin}: #{inspect(reason)}"
    end
  end

  defp seed_one_recipe(%{"name" => name} = r, rp) when is_binary(name) and name != "" do
    recipe = %{
      name: name,
      skills: Map.get(r, "skills") || [],
      prompt: Map.get(r, "prompt") || "",
      behaviors: [],
      requested_caps: []
    }

    case Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise "recipes.yaml recipe #{inspect(name)} at #{rp} failed to seed: #{inspect(reason)}"
    end
  end

  defp seed_one_recipe(other, rp) do
    raise "recipes.yaml at #{rp} has an invalid recipe entry (needs a string `name`): #{inspect(other)}"
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
