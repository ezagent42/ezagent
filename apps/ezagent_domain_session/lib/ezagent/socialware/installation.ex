defmodule Ezagent.Socialware.Installation do
  @moduledoc """
  Session ↔ socialware install relation.

  A SessionTemplate's `installs` field names ConfigStore-backed socialware
  definitions. Materialization writes a per-session ConfigObject record and
  threads the definitions' behavior union into the Session's `:kind_base`.
  """

  alias Ezagent.Socialware.{ConfigObject, ConfigStore, Definition, DefinitionRegistry}

  @default_installs ["chat"]
  @install_layer "session"
  @install_key_prefix "install:"

  @type install_spec :: %{ref: String.t(), config: map()}

  @doc "Default socialware refs for legacy SessionTemplates with no installs field."
  @spec default_installs() :: [String.t()]
  def default_installs, do: @default_installs

  @doc "Read the raw installs list from SessionTemplate content, defaulting to chat."
  @spec installs_from_template(map()) :: [term()]
  def installs_from_template(content) when is_map(content) do
    case Map.get(content, :installs) || Map.get(content, "installs") do
      installs when is_list(installs) -> installs
      _ -> @default_installs
    end
  end

  def installs_from_template(_), do: @default_installs

  @doc "Resolve a SessionTemplate's installs into the Session host behavior set."
  @spec behavior_set_for_template(map(), URI.t() | String.t()) ::
          {:ok, [module()]} | {:error, term()}
  def behavior_set_for_template(content, workspace_uri) when is_map(content) do
    with {:ok, installs} <- parse_installs(installs_from_template(content)),
         {:ok, definitions} <- resolve_definitions(installs, workspace_uri) do
      definitions
      |> Enum.flat_map(fn {definition, _object, _install} -> Definition.behaviors(definition) end)
      |> Enum.uniq()
      |> case do
        [] -> {:error, :empty_install_behavior_set}
        behaviors -> {:ok, behaviors}
      end
    end
  end

  def behavior_set_for_template(_content, workspace_uri),
    do: behavior_set_for_template(%{}, workspace_uri)

  @doc "Materialize per-session install records for a SessionTemplate's installs."
  @spec install_template_installs(URI.t(), URI.t() | String.t(), map(), URI.t() | String.t()) ::
          :ok | {:error, term()}
  def install_template_installs(
        %URI{scheme: "session"} = session_uri,
        workspace_uri,
        content,
        actor_uri
      ) do
    with {:ok, installs} <- parse_installs(installs_from_template(content)),
         {:ok, definitions} <- resolve_definitions(installs, workspace_uri) do
      Enum.reduce_while(definitions, :ok, fn {definition, object, install}, :ok ->
        case seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc "True when any installed socialware definition allows anonymous web access."
  @spec web_anon_access?(URI.t()) :: boolean()
  def web_anon_access?(%URI{scheme: "session"} = session_uri) do
    session_uri
    |> installed_definitions()
    |> Enum.any?(fn %Definition{visibility_policy: policy} ->
      Map.get(policy, :web_anon_access, false) == true
    end)
  end

  def web_anon_access?(_), do: false

  @doc "Return true when `session_uri` has a current install record for `ref`."
  @spec installed?(URI.t(), String.t()) :: boolean()
  def installed?(%URI{scheme: "session"} = session_uri, ref) when is_binary(ref) do
    workspace = Ezagent.URI.workspace_of(session_uri)
    key = install_key(ref)

    match?(
      {:ok, %ConfigObject{}},
      ConfigStore.resolve(@install_layer, workspace, session_uri, key)
    )
  end

  @doc "Return the exact socialware definitions currently installed on a session."
  @spec installed_definitions(URI.t()) :: [Definition.t()]
  def installed_definitions(%URI{scheme: "session"} = session_uri) do
    workspace = Ezagent.URI.workspace_of(session_uri)

    session_uri
    |> ConfigStore.list_keys_for_subject()
    |> Enum.filter(&String.starts_with?(&1, @install_key_prefix))
    |> Enum.flat_map(fn key ->
      case ConfigStore.resolve(@install_layer, workspace, session_uri, key) do
        {:ok, %ConfigObject{} = install_object} ->
          install_object
          |> installed_definition()
          |> List.wrap()

        :none ->
          []
      end
    end)
  end

  def installed_definitions(_), do: []

  defp installed_definition(%ConfigObject{body: body}) do
    with config_id when is_binary(config_id) <- Map.get(body, "definition_config_id"),
         {:ok, %ConfigObject{} = object} <- ConfigStore.fetch_object(config_id),
         {:ok, %Definition{} = definition} <- Definition.new(object.body) do
      definition
    else
      _ -> nil
    end
  end

  defp seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
    ref = install.ref

    ConfigStore.seed_object_if_no_pointer(%{
      layer: @install_layer,
      workspace_uri: workspace_uri,
      subject_uri: session_uri,
      key: install_key(ref),
      body: %{
        ref: ref,
        seed_config: install.config,
        definition_subject_uri: object.subject_uri,
        definition_config_id: object.id
      },
      actor_uri: actor_uri,
      source_turn_id: "socialware-install:#{URI.to_string(session_uri)}:#{ref}",
      collision_tag:
        {:socialware_install_collision, URI.to_string(session_uri), ref, definition.name}
    })
  end

  defp resolve_definitions(installs, workspace_uri) do
    Enum.reduce_while(installs, {:ok, []}, fn install, {:ok, acc} ->
      case DefinitionRegistry.lookup(workspace_uri, install.ref) do
        {:ok, definition, object} -> {:cont, {:ok, [{definition, object, install} | acc]}}
        :error -> {:halt, {:error, {:unknown_socialware_install, install.ref}}}
      end
    end)
    |> case do
      {:ok, defs} -> {:ok, Enum.reverse(defs)}
      error -> error
    end
  end

  defp parse_installs(installs) when is_list(installs) do
    Enum.reduce_while(installs, {:ok, []}, fn install, {:ok, acc} ->
      case parse_install(install) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_install(ref) when is_binary(ref) and ref != "",
    do: {:ok, %{ref: ref, config: %{}}}

  defp parse_install(ref) when is_atom(ref) and not is_nil(ref) and not is_boolean(ref),
    do: {:ok, %{ref: Atom.to_string(ref), config: %{}}}

  defp parse_install({ref, config}) when is_map(config) do
    with {:ok, parsed} <- parse_install(ref) do
      {:ok, %{parsed | config: config}}
    end
  end

  defp parse_install(install) when is_map(install) do
    ref =
      Map.get(install, :ref) || Map.get(install, "ref") || Map.get(install, :name) ||
        Map.get(install, "name")

    config = Map.get(install, :config) || Map.get(install, "config") || %{}

    with {:ok, parsed} <- parse_install(ref),
         true <- is_map(config) do
      {:ok, %{parsed | config: config}}
    else
      _ -> {:error, {:invalid_socialware_install, install}}
    end
  end

  defp parse_install(other), do: {:error, {:invalid_socialware_install, other}}

  defp install_key(ref), do: @install_key_prefix <> ref
end
