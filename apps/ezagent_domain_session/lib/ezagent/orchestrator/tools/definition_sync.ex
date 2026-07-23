defmodule Ezagent.Orchestrator.Tools.DefinitionSync do
  @moduledoc false

  alias Ezagent.Socialware.DefinitionEditor

  @doc false
  @spec await_member_projection(URI.t(), URI.t(), non_neg_integer()) ::
          :ok | {:error, :membership_projection_timeout}
  def await_member_projection(session_uri, member_uri, attempts \\ 200)

  def await_member_projection(_session_uri, _member_uri, 0),
    do: {:error, :membership_projection_timeout}

  def await_member_projection(session_uri, member_uri, attempts) do
    if member_uri in Ezagent.Session.Participants.list_participants(session_uri) do
      :ok
    else
      Process.sleep(10)
      await_member_projection(session_uri, member_uri, attempts - 1)
    end
  end

  @spec member(URI.t(), URI.t(), URI.t(), URI.t(), map(), keyword()) :: :ok | {:error, term()}
  def member(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = caller,
        %URI{} = member_uri,
        facets,
        opts \\ []
      ) do
    with {:ok, role_name} <- role_name_from_facets(facets),
         {:ok, slot} <- role_slot_for_member(member_uri, role_name, facets) do
      DefinitionEditor.update_primary_for_session(
        session_uri,
        workspace_uri,
        caller,
        fn definition ->
          roles =
            definition.roles
            |> Enum.reject(&(map_get(&1, :role_name) == role_name))
            |> Kernel.++([slot])

          %{definition | roles: roles}
        end,
        # SECURITY (#165): thread caller caps so a `:public` primary def edit is
        # admin-authorized by the domain gate rather than blanket-blocked.
        caps: Keyword.get(opts, :caps, [])
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
      end,
      caps: Keyword.get(opts, :caps, [])
    )
    |> ok_unit()
  end

  @spec prompt_template(URI.t(), URI.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def prompt_template(%URI{} = session_uri, %URI{} = caller, name, template, opts \\ []) do
    workspace_uri = Ezagent.URI.workspace_of(session_uri)

    DefinitionEditor.update_primary_for_session(
      session_uri,
      workspace_uri,
      caller,
      fn definition ->
        %{definition | prompt_templates: Map.put(definition.prompt_templates, name, template)}
      end,
      caps: Keyword.get(opts, :caps, [])
    )
    |> ok_unit()
  end

  @spec legend(URI.t(), URI.t(), String.t(), [String.t()], String.t(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def legend(
        %URI{} = session_uri,
        %URI{} = caller,
        legend_name,
        member_role_names,
        bound_rule_set,
        fold,
        opts \\ []
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
      end,
      caps: Keyword.get(opts, :caps, [])
    )
    |> ok_unit()
  end

  defp ok_unit({:ok, _, _}), do: :ok
  defp ok_unit({:error, _} = err), do: err

  defp receiver_value(%URI{} = uri), do: Ezagent.URI.stable_key(uri)
  defp receiver_value(other), do: other

  defp role_slot_for_member(%URI{} = uri, role_name, facets) do
    if Ezagent.URI.type?(uri, :user) do
      {:ok, %{role_name: role_name, fill: :human}}
    else
      agent_role_slot(uri, role_name, facets)
    end
  end

  defp agent_role_slot(%URI{} = uri, role_name, facets) do
    cond do
      not Ezagent.URI.type?(uri, :agent) ->
        {:error, {:socialware_member_uri_not_participant, uri}}

      match?(%URI{}, map_get(facets, :source_template_uri)) ->
        source_template_uri = map_get(facets, :source_template_uri)

        {:ok,
         %{
           role_name: role_name,
           fill: :agent,
           recipe: Ezagent.URI.name!(source_template_uri),
           flavor: source_template_flavor(source_template_uri)
         }}

      true ->
        {:error, {:socialware_agent_member_missing_source_template_uri, uri}}
    end
  end

  defp source_template_flavor(%URI{} = source_template_uri) do
    template_name = Ezagent.URI.name!(source_template_uri)
    [flavor | _] = String.split(template_name, "-", parts: 2)

    case flavor do
      flavor when is_binary(flavor) and flavor != "" -> flavor
      _ -> "cc"
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
