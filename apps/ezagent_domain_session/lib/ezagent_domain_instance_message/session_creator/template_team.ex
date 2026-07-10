defmodule EzagentDomainInstanceMessage.SessionCreator.TemplateTeam do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.DefinitionEditor
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @doc """
  Install the template's CONFIG into the session: prompt templates, legends and
  routing rule sets. Spawns nothing.

  This is the ONLY part of the old `materialize_template_team/4` the rev6 create
  contract permits (`SessionCreator` moduledoc step 4 — "record the template
  declaration and install template prompts/legends/rules"). Agent role slots are
  materialized by `materialize_definition_agents/4`, which runs as its OWN
  transaction AFTER create returns.
  """
  @spec materialize_template_config(URI.t(), URI.t(), map()) :: :ok | {:error, term()}
  def materialize_template_config(%URI{} = session_uri, %URI{} = workspace_uri, template_content)
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
             ) do
        :ok
      end
    end
  end

  def materialize_template_config(_session, _ws, _content), do: :ok

  @doc """
  Materialize the installed socialware Definitions' agent role slots
  (`%{recipe, role_name, flavor}`) as spawned session members with recipe caps.

  **This is an AGENT transaction and MUST NOT run inside the session-create
  transaction** (rev6 / #912; regressed by #1140 + #1223). Callers: the post-create
  socialware-install step, `repair_orchestrator/1`, and the plugin app-instantiate
  paths. Idempotent — a role already joined is skipped.
  """
  @spec materialize_definition_agents(URI.t(), URI.t(), URI.t(), map()) ::
          {:ok, DefinitionAgents.summary()} | {:error, term()}
  def materialize_definition_agents(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        template_content
      )
      when is_map(template_content) do
    with {:ok, socialware_config} <-
           DefinitionEditor.config_for_template(template_content, workspace_uri) do
      DefinitionAgents.materialize_definition_agents(
        session_uri,
        workspace_uri,
        granted_by,
        socialware_config
        |> Map.get(:roles, [])
        |> Enum.filter(&agent_role_slot?/1)
      )
    end
  end

  def materialize_definition_agents(_session, _ws, _granted_by, _content),
    do: {:ok, %{satisfied: [], skipped: []}}

  @doc """
  Config + agents in one call. Used by the REPAIR path and by plugin
  app-instantiate flows that create and populate a session as one operator
  action. **Never call this from `SessionCreator.create_session/3`** — the arch
  gate `session_create_no_agent_spawn_test` enforces that.
  """
  @spec materialize_template_team(URI.t(), URI.t(), URI.t(), map()) :: :ok | {:error, term()}
  def materialize_template_team(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        template_content
      )
      when is_map(template_content) do
    # The repair + plugin app-instantiate lanes. Skip records are written to the
    # session working copy (same as `install_session_socialware/1`) so the UI can
    # surface unfilled role slots regardless of which lane created the session.
    with :ok <- materialize_template_config(session_uri, workspace_uri, template_content),
         {:ok, summary} <-
           materialize_definition_agents(session_uri, workspace_uri, granted_by, template_content),
         :ok <- record_unfilled_slots(session_uri, summary.skipped) do
      :ok
    end
  end

  def materialize_template_team(_session, _ws, _granted_by, _content), do: :ok

  # Write on EVERY materialize — even an empty list clears a stale record left by
  # a previous install whose orchestrator had no credentials.
  defp record_unfilled_slots(session_uri, skipped) when is_list(skipped) do
    EzagentDomainInstanceMessage.SessionCreator.record_unfilled_role_slots(session_uri, skipped)
  end

  @doc """
  Keep only the `fill: :agent` role slots of a declaration list (the durable
  `member_declarations` recorded at create, or a resolved socialware config's
  `roles`). Human slots and legacy member declarations are left out.
  """
  @spec agent_role_slots([map()]) :: [map()]
  def agent_role_slots(roles) when is_list(roles), do: Enum.filter(roles, &agent_role_slot?/1)
  def agent_role_slots(_), do: []

  defp agent_role_slot?(%{} = role) do
    (Map.get(role, :fill) || Map.get(role, "fill")) in [:agent, "agent"]
  end

  defp agent_role_slot?(_role), do: false

  @spec provision_declared_member(URI.t(), URI.t(), URI.t(), map()) ::
          {:ok, URI.t(), map()} | {:error, term()}
  def provision_declared_member(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
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
        source_template_uri = member_uri_field(declaration, :source_template_uri)

        with {:ok, %URI{} = member_uri, _fresh?} <-
               ensure_legacy_member_present(
                 declaration,
                 workspace_uri,
                 granted_by,
                 source_template_uri,
                 role_name,
                 session_uri
               ) do
          facets =
            %{in_session_template: true}
            |> maybe_put(:role_name, role_name)
            |> maybe_put(:source_template_uri, source_template_uri)

          {:ok, member_uri, facets}
        end
    end
  end

  defp ensure_legacy_member_present(
         _member,
         %URI{} = workspace_uri,
         %URI{} = granted_by,
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri
       ) do
    with {:ok, content, flavor} <- source_template_content_and_flavor(source_template_uri) do
      instance_name =
        spawned_member_instance_name(flavor, source_template_uri, role_name, session_uri)

      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
      agent_uri = Ezagent.URI.agent(workspace_name, instance_name)

      case Ezagent.Entity.Agent.spawn_from_template_content(
             content,
             agent_uri,
             granted_by,
             workspace_uri,
             caller: granted_by,
             caps:
               EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(
                 granted_by
               ),
             source_template_uri: source_template_uri
           ) do
        {:ok, %{fresh?: fresh?}} -> {:ok, agent_uri, fresh?}
        {:error, _} = err -> err
      end
    end
  end

  defp ensure_legacy_member_present(
         member,
         _workspace_uri,
         _granted_by,
         nil,
         _role_name,
         _session_uri
       ) do
    case member_uri_field(member, :uri) do
      %URI{} = member_uri ->
        _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(member_uri)
        {:ok, member_uri, false}

      _ ->
        {:error, :member_missing_uri}
    end
  end

  defp source_template_content_and_flavor(%URI{} = source_template_uri) do
    with {:ok, _pid} <- Session.ensure_template_alive(source_template_uri),
         {:ok, content} <- Session.read_template_content(source_template_uri) do
      case Map.get(content, :flavor) || Map.get(content, "flavor") do
        flavor when is_binary(flavor) and flavor != "" -> {:ok, content, flavor}
        _ -> {:error, {:source_template_missing_flavor, source_template_uri}}
      end
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

  defp member_uri_field(member, key) when is_map(member) do
    case member_field(member, key) do
      %URI{} = uri -> uri
      value when is_binary(value) and value != "" -> Ezagent.URI.new!(value)
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
