defmodule EzagentDomainInstanceMessage.SessionCreator.TemplateTeam do
  @moduledoc false

  alias Ezagent.Socialware.DefinitionEditor
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @spec materialize_template_team(URI.t(), URI.t(), URI.t(), map()) :: :ok | {:error, term()}
  def materialize_template_team(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        template_content
      )
      when is_map(template_content) do
    with {:ok, socialware_config} <-
           DefinitionEditor.config_for_template(template_content, workspace_uri) do
      declared_roles = declared_role_names(socialware_config)

      with :ok <- install_template_prompt_templates(session_uri, socialware_config),
           :ok <- install_template_legends(session_uri, socialware_config),
           {:ok, _rule_ids} <-
             install_template_rule_sets(
               session_uri,
               workspace_uri,
               socialware_config,
               declared_roles
             ),
           # P1 — materialize the installed socialware Definitions' agent role
           # slots (`%{recipe, role_name, flavor}`) as spawned session members with recipe
           # caps. Runs on BOTH the fresh-create and repair paths (idempotent).
           :ok <-
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               workspace_uri,
               granted_by,
               socialware_config
               |> Map.get(:roles, [])
               |> Enum.filter(&(&1.fill == :agent))
             ) do
        :ok
      end
    end
  end

  def materialize_template_team(_session, _ws, _granted_by, _content), do: :ok

  @spec provision_declared_member(URI.t(), URI.t(), URI.t(), map()) ::
          {:ok, URI.t(), map()} | {:error, term()}
  def provision_declared_member(
        %URI{} = session_uri,
        %URI{} = _workspace_uri,
        %URI{} = _granted_by,
        declaration
      )
      when is_map(declaration) do
    role_name = member_field(declaration, :role_name)

    case member_field(declaration, :fill) do
      :human ->
        {:error, {:human_role_slot_requires_runtime_assignment, role_name, session_uri}}

      "human" ->
        {:error, {:human_role_slot_requires_runtime_assignment, role_name, session_uri}}

      :agent ->
        {:error, {:agent_role_slot_materialized_at_session_create, role_name, session_uri}}

      "agent" ->
        {:error, {:agent_role_slot_materialized_at_session_create, role_name, session_uri}}

      _ ->
        {:error, {:invalid_role_slot_declaration, declaration}}
    end
  end

  @doc false
  def spawned_member_instance_name_public(
        flavor,
        %URI{} = source_template_uri,
        role_name,
        %URI{} = session_uri
      ),
      do: spawned_member_instance_name(flavor, source_template_uri, role_name, session_uri)

  defp spawned_member_instance_name(
         flavor,
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri
       )
       when is_binary(flavor) do
    slot =
      if is_binary(role_name) and role_name != "" do
        "#{role_name}-#{source_template_hash(source_template_uri)}"
      else
        source_template_uri.path
        |> to_string()
        |> String.split("/", trim: true)
        |> List.last() || "member"
      end

    Ezagent.Entity.Agent.session_instance_name(slot, session_discriminator(session_uri))
  end

  defp source_template_hash(%URI{} = source_template_uri) do
    :crypto.hash(:sha256, URI.to_string(source_template_uri))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc false
  def session_discriminator(%URI{} = session_uri) do
    :crypto.hash(:sha256, URI.to_string(session_uri))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp install_template_prompt_templates(%URI{} = session_uri, template_content) do
    case template_map_field(template_content, :prompt_templates) do
      pts when map_size(pts) == 0 ->
        :ok

      pts ->
        case Ezagent.ActionSet.Session.system_set_prompt_templates(session_uri, pts) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:install_prompt_templates_failed, reason}}
        end
    end
  end

  defp install_template_legends(%URI{} = session_uri, template_content) do
    case template_map_field(template_content, :legends) do
      legends when map_size(legends) == 0 ->
        :ok

      legends ->
        case Ezagent.ActionSet.Session.system_set_legends(session_uri, legends) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:install_legends_failed, reason}}
        end
    end
  end

  defp install_template_rule_sets(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         template_content,
         declared_roles
       )
       when is_list(declared_roles) do
    rules = template_routing_rules_of(template_content)

    if rules == [] do
      {:ok, []}
    else
      table = Ezagent.Routing.Resolver.default_routing_table()

      result =
        Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, inserted_ids} ->
          case install_one_rule(table, session_uri, workspace_uri, declared_roles, rule) do
            {:ok, :exists} ->
              {:cont, {:ok, inserted_ids}}

            {:ok, {:inserted, id}} ->
              {:cont, {:ok, [id | inserted_ids]}}

            {:error, reason} ->
              delete_rule_rows(inserted_ids)
              {:halt, {:error, {:install_rule_failed, rule, reason}}}
          end
        end)

      with {:ok, inserted_ids} <- result do
        :ok = Ezagent.Routing.RuleStore.load_into_registry(table)
        {:ok, inserted_ids}
      end
    end
  end

  defp install_one_rule(table, %URI{} = session_uri, %URI{} = workspace_uri, declared_roles, rule)
       when is_map(rule) and is_list(declared_roles) do
    matcher = Map.get(rule, :matcher) || Map.get(rule, "matcher")
    rule_set = Map.get(rule, :rule_set) || Map.get(rule, "rule_set")
    position = Map.get(rule, :position) || Map.get(rule, "position") || 0

    case Ezagent.Routing.RuleStore.find_by_identity(table, session_uri, rule_set, position) do
      %Ezagent.Routing.RuleStore{} ->
        {:ok, :exists}

      nil ->
        with {:ok, matcher} <- normalize_rule_matcher(matcher),
             {:ok, receivers} <-
               resolve_rule_receivers(
                 Map.get(rule, :receivers) || Map.get(rule, "receivers") || [],
                 declared_roles
               ) do
          add_result =
            Ezagent.Routing.RuleStore.add(
              table,
              matcher,
              receivers,
              session_uri,
              source: Ezagent.Routing.RuleStore.system_default_source(),
              workspace_uri: workspace_uri,
              rule_set: rule_set,
              position: position,
              prompt_template_ref:
                Map.get(rule, :prompt_template_ref) || Map.get(rule, "prompt_template_ref")
            )

          case add_result do
            {:ok, %Ezagent.Routing.RuleStore{id: id}} -> {:ok, {:inserted, id}}
            {:error, _} = err -> err
          end
        end
    end
  end

  defp normalize_rule_matcher(matcher) when is_tuple(matcher), do: {:ok, matcher}

  defp normalize_rule_matcher(matcher_json) when is_map(matcher_json) do
    Ezagent.Routing.Matcher.from_json(matcher_json)
  end

  defp normalize_rule_matcher(other), do: {:error, {:invalid_rule_matcher, other}}

  defp delete_rule_rows(ids) when is_list(ids) do
    Enum.each(ids, fn id ->
      safe(fn -> Ezagent.Routing.RuleStore.delete(id, force: true) end)
    end)

    :ok
  end

  defp resolve_rule_receivers(receivers, declared_roles) when is_list(receivers) do
    Enum.reduce_while(receivers, {:ok, []}, fn receiver, {:ok, acc} ->
      case resolve_one_receiver(receiver, declared_roles) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_one_receiver({:role, role}, declared_roles) when is_binary(role) do
    if role in declared_roles do
      {:ok, Ezagent.Routing.Receiver.role(role)}
    else
      {:error, {:unknown_rule_receiver, role}}
    end
  end

  defp resolve_one_receiver(r, declared_roles) when is_binary(r) do
    if r in declared_roles do
      {:ok, Ezagent.Routing.Receiver.role(r)}
    else
      {:error, {:unknown_rule_receiver, r}}
    end
  end

  defp resolve_one_receiver(other, _declared_roles),
    do: {:error, {:unknown_rule_receiver, other}}

  defp declared_role_names(content) when is_map(content) do
    content
    |> template_roles_of()
    |> Enum.map(&member_field(&1, :role_name))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp template_roles_of(content) when is_map(content) do
    case Map.get(content, :roles) || Map.get(content, "roles") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp template_routing_rules_of(content) when is_map(content) do
    case Map.get(content, :routing_rules) || Map.get(content, "routing_rules") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp template_map_field(content, key) when is_map(content) do
    case Map.get(content, key) || Map.get(content, Atom.to_string(key)) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp member_field(member, key) when is_map(member) do
    Map.get(member, key) || Map.get(member, Atom.to_string(key))
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
