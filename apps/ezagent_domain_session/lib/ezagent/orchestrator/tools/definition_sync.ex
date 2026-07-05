defmodule Ezagent.Orchestrator.Tools.DefinitionSync do
  @moduledoc false

  alias Ezagent.Socialware.DefinitionEditor

  @spec member(URI.t(), URI.t(), URI.t(), URI.t(), map()) :: :ok | {:error, term()}
  def member(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = caller,
        %URI{} = member_uri,
        facets
      ) do
    with :ok <- ensure_user_member_uri(member_uri),
         {:ok, role_name} <- role_name_from_facets(facets) do
      DefinitionEditor.update_primary_for_session(
        session_uri,
        workspace_uri,
        caller,
        fn definition ->
          slot = %{role_name: role_name, fill: :human}

          roles =
            definition.roles
            |> Enum.reject(&(map_get(&1, :role_name) == role_name))
            |> Kernel.++([slot])

          %{definition | roles: roles}
        end
      )
      |> ok_unit()
    end
  end

  @spec rule(URI.t(), URI.t(), URI.t(), map(), String.t() | URI.t(), keyword()) ::
          :ok | {:error, term()}
  def rule(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = caller,
        matcher_json,
        receiver,
        opts
      ) do
    rule = %{
      matcher: matcher_json,
      receivers: [receiver_value(receiver)],
      rule_set: Keyword.get(opts, :rule_set),
      position: Keyword.get(opts, :position, 0),
      prompt_template_ref: Keyword.get(opts, :prompt_template_ref)
    }

    DefinitionEditor.update_primary_for_session(
      session_uri,
      workspace_uri,
      caller,
      fn definition ->
        rules =
          definition.routing_rules
          |> Enum.reject(fn existing ->
            map_get(existing, :rule_set) == rule.rule_set and
              map_get(existing, :position) == rule.position
          end)
          |> Kernel.++([rule])

        %{definition | routing_rules: rules}
      end
    )
    |> ok_unit()
  end

  @spec prompt_template(URI.t(), URI.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def prompt_template(%URI{} = session_uri, %URI{} = caller, name, template) do
    workspace_uri = Ezagent.URI.workspace_of(session_uri)

    DefinitionEditor.update_primary_for_session(
      session_uri,
      workspace_uri,
      caller,
      fn definition ->
        %{definition | prompt_templates: Map.put(definition.prompt_templates, name, template)}
      end
    )
    |> ok_unit()
  end

  @spec legend(URI.t(), URI.t(), String.t(), [String.t()], String.t(), boolean()) ::
          :ok | {:error, term()}
  def legend(
        %URI{} = session_uri,
        %URI{} = caller,
        legend_name,
        member_role_names,
        bound_rule_set,
        fold
      ) do
    workspace_uri = Ezagent.URI.workspace_of(session_uri)

    entry = %{
      member_set: Enum.map(member_role_names, &to_string/1),
      bound_rule_set: bound_rule_set,
      fold: fold
    }

    DefinitionEditor.update_primary_for_session(
      session_uri,
      workspace_uri,
      caller,
      fn definition ->
        %{definition | legends: Map.put(definition.legends, legend_name, entry)}
      end
    )
    |> ok_unit()
  end

  defp ok_unit({:ok, _, _}), do: :ok
  defp ok_unit({:error, _} = err), do: err

  defp receiver_value(%URI{} = uri), do: Ezagent.URI.stable_key(uri)
  defp receiver_value(other), do: other

  defp ensure_user_member_uri(%URI{} = uri) do
    if Ezagent.URI.type?(uri, :user) do
      :ok
    else
      {:error, {:socialware_member_uri_not_human, uri}}
    end
  end

  defp role_name_from_facets(facets) do
    case Map.get(facets, :role_name) || Map.get(facets, "role_name") do
      role_name when is_binary(role_name) and role_name != "" -> {:ok, role_name}
      other -> {:error, {:missing_socialware_member_role_name, other}}
    end
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
