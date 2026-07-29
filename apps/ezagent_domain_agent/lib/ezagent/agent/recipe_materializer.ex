defmodule Ezagent.Agent.RecipeMaterializer do
  @moduledoc """
  Shared recipe × flavor agent materialization helpers.

  A recipe owns sandbox content; flavor owns how that content is loaded. This
  module is the domain-agent boundary that turns that pair into AgentTemplate
  content and spawns it through the existing `Agent.spawn_from_template_content/5`
  path. Session/socialware callers add their own wrapper concerns after this
  core step, such as joining a session and landing the recipe caps.
  """

  alias Ezagent.Agent.DefaultAgentSeed
  alias Ezagent.Agent.Recipe
  alias Ezagent.Agent.RecipeBehaviorFold
  alias Ezagent.Entity.Agent.TemplateSpawn.Rollback
  alias Ezagent.Identity.RecipeCapBinding

  @type build_opts :: %{
          required(:recipe_name) => String.t(),
          required(:role_name) => String.t(),
          required(:flavor) => String.t(),
          required(:agent_uri) => URI.t(),
          optional(:description) => String.t(),
          optional(:provider) => String.t()
        }

  @type spawn_opts :: %{
          required(:recipe) => map(),
          required(:recipe_name) => String.t(),
          required(:role_name) => String.t(),
          required(:flavor) => String.t(),
          required(:agent_uri) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:owner_uri) => URI.t(),
          required(:caller) => URI.t(),
          required(:caps) => Enumerable.t(),
          optional(:description) => String.t(),
          optional(:provider) => String.t(),
          optional(:source_template_uri) => URI.t(),
          optional(:template_content) => map(),
          optional(:template_content_overrides) => map()
        }

  @doc """
  Build AgentTemplate content for a recipe under a concrete flavor.

  The recipe remains flavor-free. `flavor` is supplied by the materializing
  socialware/session declaration, and `role_name` is the durable role marker for
  the materialized agent.
  """
  @spec template_content(map(), build_opts()) :: {:ok, map()} | {:error, term()}
  def template_content(
        recipe,
        %{flavor: flavor, role_name: role_name, agent_uri: %URI{} = uri} = opts
      )
      when is_map(recipe) and is_binary(flavor) and is_binary(role_name) do
    recipe_name = Map.get(opts, :recipe_name, role_name)
    description = Map.get(opts, :description, "agent materialized from recipe")
    project_cwd = recipe_project_cwd(recipe, recipe_name)

    with {:ok, template_class} <- template_class_for(flavor) do
      base =
        %{
          name: role_name,
          description: description,
          flavor: flavor,
          project_cwd: project_cwd,
          config_dir: config_dir_ref(template_class, uri),
          role: recipe_name,
          default_caps: [],
          created_by: nil,
          created_at: DateTime.utc_now()
        }

      {:ok,
       base
       |> Map.merge(recipe_config_for_flavor(recipe, flavor))
       |> maybe_put(:desired_skills, recipe_field(recipe, :skills), &non_empty_list?/1)
       |> maybe_put(:plugins, recipe_field(recipe, :plugins), &non_empty_list?/1)
       |> maybe_put(:prompt, recipe_field(recipe, :prompt), &is_binary/1)
       |> maybe_put(:script, recipe_field(recipe, :script), &is_binary/1)
       |> maybe_put(:provider, Map.get(opts, :provider), &is_binary/1)}
    end
  end

  def template_content(_recipe, opts), do: {:error, {:invalid_recipe_materializer_opts, opts}}

  @doc """
  Spawn a live agent from a recipe/flavor pair and record launch attributes.
  """
  @spec create_agent_from_recipe(spawn_opts()) ::
          {:ok, {:created, Rollback.fresh_receipt()} | :already_present} | {:error, term()}
  def create_agent_from_recipe(
        %{
          recipe: recipe,
          recipe_name: recipe_name,
          role_name: role_name,
          flavor: flavor,
          agent_uri: %URI{} = agent_uri,
          workspace_uri: %URI{} = workspace_uri,
          owner_uri: %URI{} = owner_uri,
          caller: %URI{} = caller
        } = opts
      )
      when is_map(recipe) and is_binary(recipe_name) and is_binary(role_name) and
             is_binary(flavor) do
    with {:ok, %Recipe{} = recipe} <- normalize_recipe(recipe),
         {:ok, materialized} <- RecipeBehaviorFold.fold(recipe, flavor),
         {:ok, content} <- materializer_content(%{opts | recipe: recipe}),
         :ok <- ensure_project_cwd(content),
         {:ok, outcome} <-
           spawn_from_content(
             content,
             agent_uri,
             owner_uri,
             workspace_uri,
             caller,
             Map.get(opts, :caps, []),
             Map.get(
               opts,
               :source_template_uri,
               Ezagent.URI.template(:system, :agent, recipe_name)
             ),
             Map.fetch!(materialized, :behaviors)
           ),
         :ok <- record_launch_attributes(agent_uri, recipe_name, recipe) do
      {:ok, outcome}
    end
  end

  def create_agent_from_recipe(opts), do: {:error, {:invalid_recipe_materializer_opts, opts}}

  # A recipe's project_cwd is where interactive flavors start their PTY. The
  # role defaults intentionally point at a per-role directory under ~/.ezagent;
  # create it before spawning so a fresh Codex/CC login terminal cannot exit
  # immediately because its working directory does not exist.
  @doc false
  @spec ensure_project_cwd(map()) :: :ok | {:error, term()}
  def ensure_project_cwd(content) when is_map(content) do
    case Map.get(content, :project_cwd) || Map.get(content, "project_cwd") do
      cwd when is_binary(cwd) and cwd != "" ->
        case File.mkdir_p(cwd) do
          :ok -> :ok
          {:error, reason} -> {:error, {:project_cwd_create_failed, cwd, reason}}
        end

      _ ->
        {:error, :missing_project_cwd}
    end
  end

  @doc false
  @spec spawn_from_template_content(map(), URI.t(), URI.t(), URI.t(), keyword()) ::
          {:ok, {:created, Rollback.fresh_receipt()} | :already_present} | {:error, term()}
  def spawn_from_template_content(
        content,
        %URI{} = agent_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri,
        opts
      )
      when is_map(content) and is_list(opts) do
    caller = Keyword.get(opts, :caller, owner_uri)
    caps = Keyword.get(opts, :caps, [])

    source_template_uri =
      Keyword.get(
        opts,
        :source_template_uri,
        Ezagent.URI.template(:system, :agent, content_role(content))
      )

    with {:ok, outcome} <-
           spawn_from_content(
             content,
             agent_uri,
             owner_uri,
             workspace_uri,
             caller,
             caps,
             source_template_uri,
             Keyword.get(opts, :behavior_overlay, [])
           ),
         :ok <- record_launch_attributes(agent_uri, content_role(content), content) do
      {:ok, outcome}
    end
  end

  def spawn_from_template_content(_content, _agent_uri, _owner_uri, _workspace_uri, _opts),
    do: {:error, :invalid_template_content_spawn}

  @doc """
  Retire a fresh recipe materialization using the opaque receipt returned by
  `create_agent_from_recipe/1`.

  A positive binding version is tombstoned before spawn ownership is released,
  so a concurrent newer binding prevents compensation from terminating its
  agent. `nil` is accepted only for the pre-binding failure path and is checked
  against the absence of an active binding.
  """
  @spec rollback_fresh_agent(Rollback.fresh_receipt(), nil | pos_integer()) ::
          {:ok, :retired} | {:error, term()}
  def rollback_fresh_agent(receipt, binding_version)
      when is_nil(binding_version) or
             (is_integer(binding_version) and binding_version > 0) do
    with {:ok, agent_uri} <- Rollback.instance_uri(receipt),
         :ok <- rollback_recipe_binding(agent_uri, binding_version),
         {:ok, :retired} <- Rollback.fresh_spawn(receipt) do
      {:ok, :retired}
    end
  end

  def rollback_fresh_agent(_receipt, _binding_version),
    do: {:error, :invalid_fresh_agent_rollback}

  @doc false
  @spec materializer_content(map()) :: {:ok, map()} | {:error, term()}
  def materializer_content(%{template_content: content}) when is_map(content), do: {:ok, content}

  def materializer_content(opts) when is_map(opts) do
    with {:ok, content} <-
           template_content(Map.fetch!(opts, :recipe), %{
             recipe_name: Map.fetch!(opts, :recipe_name),
             role_name: Map.fetch!(opts, :role_name),
             flavor: Map.fetch!(opts, :flavor),
             agent_uri: Map.fetch!(opts, :agent_uri),
             description: Map.get(opts, :description, "agent materialized from recipe"),
             provider: Map.get(opts, :provider)
           }) do
      case Map.get(opts, :template_content_overrides, %{}) do
        overrides when is_map(overrides) ->
          {:ok, Map.merge(content, config_for_flavor(overrides, Map.fetch!(opts, :flavor)))}

        other ->
          {:error, {:invalid_template_content_overrides, other}}
      end
    end
  end

  def materializer_content(_opts), do: {:error, :invalid_template_content_materializer_opts}

  defp spawn_from_content(
         content,
         agent_uri,
         owner_uri,
         workspace_uri,
         caller,
         caps,
         source_template_uri,
         behavior_overlay
       ) do
    opts = [
      caller: caller,
      caps: caps,
      source_template_uri: source_template_uri,
      behavior_overlay: behavior_overlay
    ]

    case Ezagent.Entity.Agent.spawn_from_template_content(
           content,
           agent_uri,
           owner_uri,
           workspace_uri,
           opts
         ) do
      {:ok, %{fresh?: true, rollback_receipt: receipt}} -> {:ok, {:created, receipt}}
      {:ok, %{fresh?: true}} -> {:error, :fresh_spawn_receipt_missing}
      {:ok, %{fresh?: false}} -> {:ok, :already_present}
      {:ok, %{}} -> {:ok, :already_present}
      {:error, _} = err -> err
    end
  end

  defp rollback_recipe_binding(agent_uri, nil) do
    case RecipeCapBinding.fetch(agent_uri) do
      :not_found -> :ok
      {:ok, binding} -> {:error, {:unexpected_active_recipe_binding, binding.version}}
    end
  end

  defp rollback_recipe_binding(agent_uri, version) do
    case RecipeCapBinding.tombstone_if_version(agent_uri, version) do
      :ok ->
        :ok

      {:error, :version_mismatch} ->
        case RecipeCapBinding.fetch(agent_uri) do
          :not_found -> :ok
          {:ok, binding} -> {:error, {:recipe_binding_version_changed, version, binding.version}}
        end
    end
  end

  defp normalize_recipe(%Recipe{} = recipe), do: {:ok, recipe}
  defp normalize_recipe(recipe) when is_map(recipe), do: Recipe.new(recipe)
  defp normalize_recipe(recipe), do: {:error, {:invalid_recipe, recipe}}

  # Records BUILD PROVENANCE (the recipe name) on the agent — never a session
  # role. Session role_name is set on the (entity × session) membership edge by
  # the caller's faceted `session.join` (Gate B).
  defp record_launch_attributes(%URI{} = agent_uri, recipe_name, recipe_or_content) do
    :ok = Ezagent.Agent.RecipeAttributes.put(agent_uri, recipe_name)

    case passive_value(recipe_or_content) do
      value when is_boolean(value) -> Ezagent.AgentPassiveAttributes.put(agent_uri, value)
      _ -> :ok
    end
  end

  defp template_class_for(flavor), do: Ezagent.AgentFlavorRegistry.template_class_for(flavor)

  defp config_dir_ref(template_class, %URI{} = agent_uri) do
    if config_dir_flavor?(template_class) do
      Ezagent.Sandbox.ConfigDir.path(
        agent_uri,
        Ezagent.Kind.Template.namespace_of(template_class)
      )
    end
  end

  defp config_dir_flavor?(template_class) do
    function_exported?(template_class, :config_dir_namespace, 0) or
      Ezagent.Agent.CredentialAdapter.credentialled?(template_class)
  end

  defp recipe_project_cwd(recipe, role) do
    case config_get(recipe_config(recipe), :project_cwd) do
      cwd when is_binary(cwd) -> cwd
      _ -> DefaultAgentSeed.default_project_cwd(role)
    end
  end

  defp recipe_config(recipe), do: recipe_field(recipe, :config) || %{}

  # The Hello recipe's provider/model fields describe its curl implementation.
  # A session may materialize that same recipe under another flavor, where
  # passing DeepSeek's model into Codex/CC would override the account default
  # (and can be rejected by the CLI). Keep the recipe's transport defaults only
  # for curl; other flavors add their own explicit template data separately.
  defp recipe_config_for_flavor(recipe, flavor),
    do: config_for_flavor(recipe_config(recipe), flavor)

  defp config_for_flavor(config, "curl"), do: config

  defp config_for_flavor(config, _flavor) do
    Map.drop(config, [:provider, "provider", :api_url, "api_url", :model, "model"])
  end

  defp recipe_field(recipe, key) when is_atom(key) do
    case Map.fetch(recipe, key) do
      {:ok, value} -> value
      :error -> Map.get(recipe, Atom.to_string(key))
    end
  end

  defp config_get(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end

  defp config_get(_config, _key), do: nil

  defp passive_value(%{passive: passive}) when is_boolean(passive), do: passive
  defp passive_value(%{"passive" => passive}) when is_boolean(passive), do: passive
  defp passive_value(_), do: false

  defp content_role(content) do
    case Map.get(content, :role) || Map.get(content, "role") || Map.get(content, :name) ||
           Map.get(content, "name") do
      role when is_binary(role) and role != "" -> role
      _ -> "agent"
    end
  end

  defp maybe_put(map, key, value, valid?) do
    if valid?.(value), do: Map.put(map, key, value), else: map
  end

  defp non_empty_list?(value), do: is_list(value) and value != []
end
