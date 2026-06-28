defmodule Ezagent.Socialware.DefinitionEditor do
  @moduledoc """
  P5 socialware definition authoring helpers.

  SessionTemplates now carry composition (`installs`) while team/routing/persona
  fields live on the installed socialware definitions. This module is the
  boundary used by session materialization and orchestrator tools to read and
  mutate that single source of truth.
  """

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ConfigObject, Definition, DefinitionRegistry, Installation}

  @doc """
  Validate a socialware definition at the shared authoring boundary.

  `complete: true` is used by the declarative form save, where the payload must
  be runnable on its own. Incremental orchestrator tools use the same structural
  normalization and may leave other sections to later tool calls.
  """
  @spec validate_definition(Definition.t() | map(), keyword()) ::
          {:ok, Definition.t()} | {:error, term()}
  def validate_definition(definition_or_attrs, opts \\ [])

  def validate_definition(%Definition{} = definition, opts) do
    if Keyword.get(opts, :complete, false) do
      validate_complete_definition(definition)
    else
      {:ok, definition}
    end
  end

  def validate_definition(attrs, opts) when is_map(attrs) do
    with {:ok, %Definition{} = definition} <- Definition.new(attrs) do
      validate_definition(definition, opts)
    end
  end

  def validate_definition(other, _opts), do: {:error, {:invalid_socialware_definition, other}}

  @doc "Validate and persist a form-authored socialware definition."
  @spec save_authored_definition(map() | Definition.t(), URI.t(), URI.t(), keyword()) ::
          {:ok, Definition.t(), ConfigObject.t()} | {:error, term()}
  def save_authored_definition(
        definition_or_attrs,
        %URI{} = workspace_uri,
        %URI{} = actor_uri,
        opts \\ []
      ) do
    with {:ok, %Definition{} = definition} <- validate_definition(definition_or_attrs, opts),
         {:ok, %ConfigObject{} = object} <-
           DefinitionRegistry.write_definition(definition,
             workspace_uri: workspace_uri,
             actor_uri: actor_uri
           ) do
      {:ok, definition, object}
    end
  end

  @doc "Return the merged socialware config installed by a SessionTemplate."
  @spec config_for_template(map(), URI.t() | String.t()) :: {:ok, map()} | {:error, term()}
  def config_for_template(template_content, workspace_uri) when is_map(template_content) do
    with {:ok, resolved} <-
           Installation.resolved_template_installs(template_content, workspace_uri) do
      config =
        Enum.reduce(resolved, empty_config(), fn {definition, _object, _install}, acc ->
          merge_definition(acc, definition)
        end)
        |> merge_legacy_template_fields(template_content)

      {:ok, config}
    end
  end

  @doc "Return members declared by the installed socialware definitions."
  @spec member_declarations_for_template(map(), URI.t() | String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def member_declarations_for_template(template_content, workspace_uri) do
    with {:ok, config} <- config_for_template(template_content, workspace_uri) do
      {:ok, config.members}
    end
  end

  @doc "Return the first installed orchestrator template URI, if one is declared."
  @spec orchestrator_template_uri_for_template(map(), URI.t() | String.t()) ::
          {:ok, URI.t() | nil} | {:error, term()}
  def orchestrator_template_uri_for_template(template_content, workspace_uri) do
    with {:ok, config} <- config_for_template(template_content, workspace_uri) do
      {:ok, config.orchestrator_template_uri}
    end
  end

  @doc "Update the primary installed definition for a live session and repoint its install."
  @spec update_primary_for_session(URI.t(), URI.t(), URI.t(), (Definition.t() ->
                                                                 map() | Definition.t())) ::
          {:ok, Definition.t(), ConfigObject.t()} | {:error, term()}
  def update_primary_for_session(
        %URI{scheme: "session"} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = actor_uri,
        updater
      )
      when is_function(updater, 1) do
    with {:ok, template_content} <- template_content_for_session(session_uri, workspace_uri),
         {:ok, install} <- primary_install(template_content),
         {:ok, definition, _object} <- lookup_definition(workspace_uri, install.ref),
         {:ok, next_definition} <- normalize_update(updater.(definition)),
         {:ok, object} <-
           DefinitionRegistry.write_definition(next_definition,
             workspace_uri: workspace_uri,
             actor_uri: actor_uri
           ),
         {:ok, _install_object} <-
           Installation.point_session_install(
             session_uri,
             workspace_uri,
             install,
             next_definition,
             object,
             actor_uri
           ) do
      {:ok, next_definition, object}
    end
  end

  @doc "Snapshot live session team/routing/persona into an installed definition."
  @spec snapshot_live_session(URI.t(), URI.t(), URI.t(), keyword()) ::
          {:ok, Definition.t(), ConfigObject.t()} | {:error, term()}
  def snapshot_live_session(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = actor_uri,
        opts \\ []
      ) do
    with {:ok, live} <- live_config(session_uri, workspace_uri),
         {:ok, template_content} <- template_content_for_session(session_uri, workspace_uri),
         {:ok, install} <- primary_install(template_content),
         {:ok, definition, _object} <- lookup_definition(workspace_uri, install.ref),
         name = Keyword.get(opts, :name, definition.name),
         next_definition = merge_live_config(%{definition | name: name}, live),
         {:ok, object} <-
           DefinitionRegistry.write_definition(next_definition,
             workspace_uri: workspace_uri,
             actor_uri: actor_uri
           ),
         install = %{install | ref: name},
         {:ok, _install_object} <-
           Installation.point_session_install(
             session_uri,
             workspace_uri,
             install,
             next_definition,
             object,
             actor_uri
           ) do
      {:ok, next_definition, object}
    end
  end

  @doc "Template content containing only composition and lineage fields."
  @spec composition_template_content(map(), URI.t() | nil, URI.t(), String.t() | nil) :: map()
  def composition_template_content(
        template_content,
        parent_uri,
        workspace_uri,
        install_ref \\ nil
      )
      when is_map(template_content) do
    installs =
      case install_ref do
        ref when is_binary(ref) and ref != "" -> [ref]
        _ -> Installation.installs_from_template(template_content)
      end

    %{
      description: map_get(template_content, :description, ""),
      default_workspace_uri: workspace_uri,
      parent_template_uri: parent_uri,
      installs: installs
    }
  end

  defp template_content_for_session(%URI{} = session_uri, workspace_uri) do
    wc = Session.read_template_working_copy(session_uri)

    with %URI{} = template_uri <- Map.get(wc, :session_template_uri),
         {:ok, _pid} <- Session.ensure_template_alive(template_uri),
         {:ok, content} when is_map(content) <- Session.read_template_content(template_uri) do
      {:ok, content}
    else
      nil ->
        {:ok, %{installs: Installation.default_installs(), default_workspace_uri: workspace_uri}}

      other ->
        {:error, {:session_template_not_readable, other}}
    end
  end

  defp primary_install(template_content) do
    with {:ok, installs} <- Installation.parsed_installs_from_template(template_content) do
      case Enum.find(installs, &(&1.ref != "chat")) || List.first(installs) do
        nil -> {:error, :no_socialware_install}
        install -> {:ok, install}
      end
    end
  end

  defp lookup_definition(workspace_uri, ref) do
    case DefinitionRegistry.lookup(workspace_uri, ref) do
      {:ok, definition, object} -> {:ok, definition, object}
      :error -> {:error, {:unknown_socialware_install, ref}}
    end
  end

  defp normalize_update(definition_or_attrs) do
    case validate_definition(definition_or_attrs) do
      {:ok, definition} -> {:ok, definition}
      {:error, reason} -> {:error, {:invalid_socialware_definition_update, reason}}
    end
  end

  defp validate_complete_definition(%Definition{} = definition) do
    cond do
      definition.bases == [] ->
        {:error, {:incomplete_socialware_definition, :bases}}

      definition.shape == [] ->
        {:error, {:incomplete_socialware_definition, :shape}}

      definition.members == [] ->
        {:error, {:incomplete_socialware_definition, :members}}

      definition.routing_rules == [] ->
        {:error, {:incomplete_socialware_definition, :routing_rules}}

      map_size(definition.prompt_templates) == 0 ->
        {:error, {:incomplete_socialware_definition, :prompt_templates}}

      map_size(definition.legends) == 0 ->
        {:error, {:incomplete_socialware_definition, :legends}}

      definition.adapters == [] ->
        {:error, {:incomplete_socialware_definition, :adapters}}

      true ->
        {:ok, definition}
    end
  end

  defp empty_config do
    %{
      members: [],
      routing_rules: [],
      prompt_templates: %{},
      legends: %{},
      orchestrator_template_uri: nil
    }
  end

  defp merge_definition(acc, %Definition{} = definition) do
    %{
      members: acc.members ++ definition.members,
      routing_rules: acc.routing_rules ++ definition.routing_rules,
      prompt_templates: Map.merge(acc.prompt_templates, definition.prompt_templates),
      legends: Map.merge(acc.legends, definition.legends),
      orchestrator_template_uri:
        acc.orchestrator_template_uri || definition.orchestrator_template_uri
    }
  end

  defp merge_legacy_template_fields(config, template_content) do
    legacy_members = list_field(template_content, :members)
    legacy_rules = list_field(template_content, :routing_rules)
    legacy_prompts = map_field(template_content, :prompt_templates)
    legacy_legends = map_field(template_content, :legends)
    legacy_orchestrator = uri_field(template_content, :orchestrator_template_uri)

    %{
      members: if(legacy_members == [], do: config.members, else: legacy_members),
      routing_rules: if(legacy_rules == [], do: config.routing_rules, else: legacy_rules),
      prompt_templates: Map.merge(config.prompt_templates, legacy_prompts),
      legends: Map.merge(config.legends, legacy_legends),
      orchestrator_template_uri: legacy_orchestrator || config.orchestrator_template_uri
    }
  end

  defp list_field(map, key) do
    case map_get(map, key, []) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp uri_field(map, key) do
    case map_get(map, key) do
      %URI{} = uri -> uri
      value when is_binary(value) and value != "" -> Ezagent.URI.new!(value)
      _ -> nil
    end
  end

  defp merge_live_config(%Definition{} = definition, live) do
    %{
      definition
      | members: live.members,
        routing_rules: live.routing_rules,
        prompt_templates: live.prompt_templates,
        legends: live.legends,
        orchestrator_template_uri:
          live.orchestrator_template_uri || definition.orchestrator_template_uri
    }
  end

  defp live_config(%URI{} = session_uri, %URI{} = workspace_uri) do
    slice = read_chat_slice(session_uri)

    {:ok,
     %{
       members: live_template_members(slice),
       prompt_templates: map_field(slice, :prompt_templates),
       legends: map_field(slice, :legends),
       routing_rules: live_rule_set_rules(session_uri, workspace_uri, slice),
       orchestrator_template_uri:
         map_get(slice, :orchestrator_template_uri) ||
           get_in(slice, [:template_working_copy, :orchestrator_template_uri])
     }}
  end

  defp live_template_members(slice) do
    slice
    |> map_field(:members)
    |> Enum.filter(fn {_uri, meta} -> map_get(meta, :in_session_template) == true end)
    |> Enum.map(fn {uri, meta} ->
      %{
        uri: uri,
        role_name: map_get(meta, :role_name),
        in_session_template: true,
        source_template_uri: map_get(meta, :source_template_uri)
      }
    end)
    |> Enum.sort_by(&inspect/1)
  end

  defp live_rule_set_rules(%URI{} = session_uri, %URI{} = _workspace_uri, slice) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
    session_str = URI.to_string(session_uri)
    uri_to_role = uri_to_role_map(slice)

    table
    |> safe_rule_list()
    |> Enum.filter(fn rule -> rule.created_by == session_str and not is_nil(rule.rule_set) end)
    |> Enum.flat_map(fn rule ->
      case Ezagent.Routing.Matcher.from_json(rule.matcher_data) do
        {:ok, _matcher} ->
          [
            %{
              matcher: rule.matcher_data,
              receivers: Enum.map(rule.receivers || [], &Map.get(uri_to_role, &1, &1)),
              rule_set: rule.rule_set,
              position: rule.position,
              prompt_template_ref: rule.prompt_template_ref
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn rule -> {rule.rule_set, rule.position} end)
  end

  defp uri_to_role_map(slice) do
    slice
    |> map_field(:members)
    |> Enum.flat_map(fn
      {%URI{} = uri, meta} ->
        case map_get(meta, :role_name) do
          role when is_binary(role) -> [{Ezagent.URI.stable_key(uri), role}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  defp read_chat_slice(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.Behavior.Session.state_slice(), %{})

        Map.get(chat_slice, :state, chat_slice)

      :error ->
        %{}
    end
  end

  defp safe_rule_list(table) do
    Ezagent.Routing.RuleStore.list(table)
  rescue
    _ -> []
  end

  defp map_field(map, key) do
    case map_get(map, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
