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

  @doc "Parse a SessionTemplate's install declarations into canonical install specs."
  @spec parsed_installs_from_template(map()) :: {:ok, [install_spec()]} | {:error, term()}
  def parsed_installs_from_template(content) when is_map(content),
    do: parse_installs(installs_from_template(content))

  def parsed_installs_from_template(_content), do: parse_installs(@default_installs)

  @doc "Resolve a SessionTemplate's install declarations to definitions and ConfigObjects."
  @spec resolved_template_installs(map(), URI.t() | String.t()) ::
          {:ok, [{Definition.t(), ConfigObject.t(), install_spec()}]} | {:error, term()}
  def resolved_template_installs(content, workspace_uri) when is_map(content) do
    with {:ok, installs} <- parsed_installs_from_template(content),
         {:ok, definitions} <- resolve_definitions(installs, workspace_uri) do
      {:ok, definitions}
    end
  end

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

  @doc "Repoint all per-session install records to the definitions named by a template."
  @spec repoint_template_installs(URI.t(), URI.t() | String.t(), map(), URI.t() | String.t()) ::
          :ok | {:error, term()}
  def repoint_template_installs(
        %URI{scheme: "session"} = session_uri,
        workspace_uri,
        content,
        actor_uri
      ) do
    with {:ok, definitions} <- resolved_template_installs(content, workspace_uri) do
      Enum.reduce_while(definitions, :ok, fn {definition, object, install}, :ok ->
        case point_session_install(
               session_uri,
               workspace_uri,
               install,
               definition,
               object,
               actor_uri
             ) do
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

  @doc """
  T2-2b — the view read-caps an anonymous visitor is minted with for
  `session_uri`: for every PUBLIC installed definition
  (`visibility_policy.web_anon_access == true`), one `<sw>_render` cap per action
  of each of the definition's declared `views` ActionSets.

  This is the fine-grained half of the two-layer gate: openness
  (`web_anon_access`) decides whether an anon is minted at all; these caps decide
  which VIEWS that anon can see. A view of a NON-public installed definition
  (e.g. kanban-private in a hello-public session) contributes NO cap, so the anon
  cannot render it (`SessionView.authorize_view/3` denies).

  The cap shape is exactly what `SessionView.render_needed_caps/2` checks
  (`cap(:session, view_actionset, action, <session>, <ws>)`), so the mint and the
  gate agree by construction. `granted_by` = the session owner (the configurer of
  the public_view rule), falling back to the admin entity — Decision #154's named
  granter, never a `system://` principal. JSON-serializable (concrete instance) so
  it lands in the anon's `caps_json`.
  """
  @spec anon_view_caps(URI.t()) :: [Ezagent.Capability.t()]
  def anon_view_caps(%URI{scheme: "session"} = session_uri) do
    granter = anon_view_granter(session_uri)
    instance = Ezagent.URI.instance(session_uri)
    workspace = Ezagent.Capability.workspace_of(session_uri)

    session_uri
    |> installed_definitions()
    |> Enum.filter(fn %Definition{visibility_policy: policy} ->
      Map.get(policy, :web_anon_access, false) == true
    end)
    |> Enum.flat_map(fn %Definition{views: views} -> views end)
    |> Enum.uniq()
    |> Enum.flat_map(&view_render_caps(&1, instance, workspace, granter))
  end

  def anon_view_caps(_), do: []

  defp view_render_caps(view_module, instance, workspace, granter) when is_atom(view_module) do
    for action <- view_actions(view_module) do
      %Ezagent.Capability{
        Ezagent.Capability.cap(:session, view_module, action, instance, workspace)
        | granted_by: granter,
          granted_at: DateTime.utc_now()
      }
    end
  end

  defp view_actions(view_module) do
    if Code.ensure_loaded?(view_module) and function_exported?(view_module, :actions, 0) do
      view_module.actions()
    else
      []
    end
  rescue
    _ -> []
  end

  defp anon_view_granter(%URI{} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} -> owner
      _ -> Ezagent.Entity.User.admin_uri()
    end
  end

  @doc "Return the effective publish policy for a session's installed socialwares."
  @spec publish_policy(URI.t()) :: :auto | :supervised
  def publish_policy(%URI{scheme: "session"} = session_uri) do
    if Enum.any?(installed_definitions(session_uri), &supervised?/1) do
      :supervised
    else
      :auto
    end
  end

  def publish_policy(_), do: :auto

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

  def installed?(_session_uri, _ref), do: false

  @doc "Repoint one session install record to a newer socialware definition object."
  @spec point_session_install(
          URI.t(),
          URI.t() | String.t(),
          install_spec(),
          Definition.t(),
          ConfigObject.t(),
          URI.t() | String.t()
        ) :: {:ok, ConfigObject.t()} | {:error, term()}
  def point_session_install(
        %URI{scheme: "session"} = session_uri,
        workspace_uri,
        install,
        %Definition{} = definition,
        %ConfigObject{} = object,
        actor_uri
      )
      when is_map(install) do
    ref = install.ref

    with {:ok, %{object: %ConfigObject{} = install_object}} <-
           ConfigStore.write_and_point(%{
             layer: @install_layer,
             workspace_uri: workspace_uri,
             subject_uri: session_uri,
             key: install_key(ref),
             body: install_body(ref, install.config, definition, object),
             actor_uri: actor_uri,
             source_turn_id: unique_source_turn_id("socialware-install", session_uri, ref)
           }) do
      {:ok, install_object}
    end
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

  defp supervised?(%Definition{visibility_policy: policy}) do
    Map.get(policy, :publish_policy, :auto) == :supervised
  end

  defp seed_install(session_uri, workspace_uri, definition, object, install, actor_uri) do
    ref = install.ref

    ConfigStore.seed_object_if_no_pointer(%{
      layer: @install_layer,
      workspace_uri: workspace_uri,
      subject_uri: session_uri,
      key: install_key(ref),
      body: install_body(ref, install.config, definition, object),
      actor_uri: actor_uri,
      source_turn_id: "socialware-install:#{URI.to_string(session_uri)}:#{ref}",
      collision_tag:
        {:socialware_install_collision, URI.to_string(session_uri), ref, definition.name}
    })
  end

  defp install_body(ref, config, %Definition{} = _definition, %ConfigObject{} = object) do
    %{
      ref: ref,
      seed_config: config,
      definition_subject_uri: object.subject_uri,
      definition_config_id: object.id
    }
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

  defp unique_source_turn_id(prefix, %URI{} = session_uri, ref) do
    "#{prefix}:#{URI.to_string(session_uri)}:#{ref}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
