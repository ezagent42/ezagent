defmodule Ezagent.Orchestrator.Tools.Migration do
  @moduledoc false

  alias Ezagent.ActionSet.Session
  alias Ezagent.Entity.Session, as: SessionEntity
  alias Ezagent.Orchestrator.Tools
  alias Ezagent.Routing.{Resolver, RuleStore}
  alias Ezagent.Socialware.{DefinitionEditor, Installation}

  @spec migrate_session(URI.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate_session(target_session_template_uri, opts \\ [])

  def migrate_session(%URI{} = target_session_template_uri, opts) do
    with {:ok, session_uri} <- Tools.require_opt(opts, :session_uri),
         {:ok, workspace_uri} <- Tools.require_opt(opts, :workspace_uri),
         {:ok, caller_uri} <- Tools.require_opt(opts, :caller),
         {:ok, caps} <- Tools.require_opt(opts, :caps),
         :ok <-
           Tools.preflight_within_session_cap(
             caller_uri,
             caps,
             session_uri,
             :set_working_copy
           ),
         :ok <- preflight_session_template_cap(caps, workspace_uri, caller_uri),
         {:ok, target_content} <- read_target_template(target_session_template_uri),
         {:ok, target_config} <-
           DefinitionEditor.config_for_template(target_content, workspace_uri),
         {:ok, plan} <- changed_member_plan(session_uri, target_config),
         :ok <- ensure_ledger(session_uri, target_session_template_uri, plan),
         :ok <- run_member_plan(session_uri, target_session_template_uri, plan, opts),
         :ok <- replace_session_rule_sets(session_uri, workspace_uri, target_config),
         :ok <- install_prompt_templates(session_uri, target_config),
         :ok <- install_legends(session_uri, target_config),
         :ok <-
           Installation.repoint_template_installs(
             session_uri,
             workspace_uri,
             target_content,
             caller_uri
           ),
         :ok <- finalize_pin(session_uri, target_session_template_uri) do
      {:ok,
       %{session_template_uri: target_session_template_uri, migrated_members: Map.keys(plan)}}
    end
  end

  def migrate_session(_target, _opts), do: {:error, :invalid_target_session_template_uri}

  defp read_target_template(%URI{} = target_uri) do
    with true <-
           Ezagent.URI.type?(target_uri, :session) ||
             {:error, {:not_a_session_template_uri, target_uri}},
         {:ok, _pid} <- SessionEntity.ensure_template_alive(target_uri),
         {:ok, content} when is_map(content) <- SessionEntity.read_template_content(target_uri) do
      {:ok, content}
    else
      {:error, _} = err -> err
      other -> {:error, {:target_template_not_readable, other}}
    end
  end

  defp changed_member_plan(%URI{} = session_uri, target_content) do
    target_members =
      target_content
      |> target_role_members()
      |> Enum.reduce(%{}, fn member, acc ->
        role = map_get(member, :role_name)
        source = target_source_template_uri(member)

        if is_binary(role) and match?(%URI{}, source),
          do: Map.put(acc, role, source),
          else: acc
      end)

    current_members = Tools.read_members(session_uri)

    plan =
      Enum.reduce(target_members, %{}, fn {role, target_source}, acc ->
        current_source = current_source_for_role(current_members, role)

        cond do
          is_nil(current_source) ->
            Map.put(acc, role, target_source)

          same_uri?(current_source, target_source) ->
            acc

          true ->
            Map.put(acc, role, target_source)
        end
      end)

    {:ok, plan}
  end

  defp target_role_members(target_content) do
    case map_get(target_content, :roles, []) do
      roles when is_list(roles) and roles != [] -> roles
      _ -> map_get(target_content, :members, [])
    end
  end

  defp target_source_template_uri(member) do
    case normalize_uri(map_get(member, :source_template_uri)) do
      %URI{} = uri ->
        uri

      _ ->
        case {map_get(member, :fill), map_get(member, :recipe)} do
          {fill, recipe} when fill in [:agent, "agent"] and is_binary(recipe) and recipe != "" ->
            Ezagent.URI.template(:system, :agent, recipe)

          _ ->
            nil
        end
    end
  end

  defp current_source_for_role(current_members, role) do
    Enum.find_value(current_members, fn {_uri, meta} ->
      if map_get(meta, :role_name) == role do
        normalize_uri(map_get(meta, :source_template_uri))
      end
    end)
  end

  defp ensure_ledger(%URI{} = session_uri, %URI{} = target_uri, plan) do
    wc = SessionEntity.read_template_working_copy(session_uri)

    ledger =
      case Map.get(wc, :migration_ledger) || Map.get(wc, "migration_ledger") do
        %{target_session_template_uri: ^target_uri} = existing ->
          merge_plan(existing, plan)

        %{"target_session_template_uri" => target_str} = existing ->
          if target_str == URI.to_string(target_uri) do
            merge_plan(existing, plan)
          else
            new_ledger(target_uri, plan)
          end

        _ ->
          new_ledger(target_uri, plan)
      end

    write_working_copy(session_uri, Map.put(wc, :migration_ledger, ledger))
  end

  defp new_ledger(%URI{} = target_uri, plan) do
    %{
      target_session_template_uri: target_uri,
      members: Map.new(plan, fn {role, _source} -> {role, :pending} end)
    }
  end

  defp merge_plan(existing, plan) do
    members = map_get(existing, :members, %{})

    merged_members =
      Enum.reduce(plan, members, fn {role, _source}, acc ->
        Map.put_new(acc, role, :pending)
      end)

    %{
      target_session_template_uri: normalize_uri(map_get(existing, :target_session_template_uri)),
      members: merged_members
    }
  end

  defp run_member_plan(%URI{} = session_uri, %URI{} = target_uri, plan, opts) do
    Enum.reduce_while(plan, :ok, fn {role, source_uri}, :ok ->
      case ledger_status(session_uri, role) do
        :done ->
          {:cont, :ok}

        _ ->
          checkpoint_member(session_uri, target_uri, role, :pending)

          case Tools.update_member_template(role, source_uri, opts) do
            {:ok, _} ->
              :ok = checkpoint_member(session_uri, target_uri, role, :done)

              case injected_fault(role) do
                :none -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, reason} ->
              _ = checkpoint_member(session_uri, target_uri, role, :failed)
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp checkpoint_member(%URI{} = session_uri, %URI{} = target_uri, role, status) do
    wc = SessionEntity.read_template_working_copy(session_uri)
    ledger = Map.get(wc, :migration_ledger) || %{}
    members = map_get(ledger, :members, %{})

    next_ledger = %{
      target_session_template_uri: target_uri,
      members: Map.put(members, role, status)
    }

    write_working_copy(session_uri, Map.put(wc, :migration_ledger, next_ledger))
  end

  defp ledger_status(%URI{} = session_uri, role) do
    session_uri
    |> SessionEntity.read_template_working_copy()
    |> Map.get(:migration_ledger, %{})
    |> map_get(:members, %{})
    |> Map.get(role)
  end

  defp injected_fault(role) do
    case Application.get_env(:ezagent_domain_session, :migrate_session_fault) do
      {:after_role_done, ^role} -> {:error, {:injected_migration_failure, role}}
      _ -> :none
    end
  end

  defp replace_session_rule_sets(%URI{} = session_uri, %URI{} = workspace_uri, target_content) do
    table = Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    with :ok <- delete_existing_rule_sets(table, session_str),
         :ok <- install_target_rule_sets(table, session_uri, workspace_uri, target_content) do
      Tools.reload_registry(table)
    end
  end

  defp delete_existing_rule_sets(table, session_str) do
    table
    |> RuleStore.list()
    |> Enum.filter(fn rule -> rule.created_by == session_str and not is_nil(rule.rule_set) end)
    |> Enum.reduce_while(:ok, fn rule, :ok ->
      case RuleStore.delete(rule.id, force: true) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp install_target_rule_sets(
         table,
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         target_content
       ) do
    role_to_uri = role_to_uri_map(session_uri)

    target_content
    |> map_get(:routing_rules, [])
    |> Enum.reduce_while(:ok, fn rule, :ok ->
      matcher = map_get(rule, :matcher)
      rule_set = map_get(rule, :rule_set)
      position = map_get(rule, :position, 0)
      prompt_template_ref = map_get(rule, :prompt_template_ref)

      with {:ok, receivers} <- resolve_receivers(map_get(rule, :receivers, []), role_to_uri),
           {:ok, _row} <-
             RuleStore.add(table, matcher, receivers, session_uri,
               source: RuleStore.system_default_source(),
               workspace_uri: workspace_uri,
               rule_set: rule_set,
               position: position,
               prompt_template_ref: prompt_template_ref
             ) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp role_to_uri_map(%URI{} = session_uri) do
    session_uri
    |> Tools.read_members()
    |> Enum.flat_map(fn
      {%URI{} = uri, meta} ->
        case map_get(meta, :role_name) do
          role when is_binary(role) -> [{role, uri}]
          _ -> []
        end
    end)
    |> Map.new()
  end

  defp resolve_receivers(receivers, role_to_uri) when is_list(receivers) do
    Enum.reduce_while(receivers, {:ok, []}, fn receiver, {:ok, acc} ->
      cond do
        is_binary(receiver) and Map.has_key?(role_to_uri, receiver) ->
          {:cont, {:ok, acc ++ [Map.fetch!(role_to_uri, receiver)]}}

        is_binary(receiver) ->
          {:cont, {:ok, acc ++ [receiver]}}

        match?(%URI{}, receiver) ->
          {:cont, {:ok, acc ++ [receiver]}}

        true ->
          {:halt, {:error, {:invalid_receiver, receiver}}}
      end
    end)
  end

  defp resolve_receivers(other, _role_to_uri), do: {:error, {:invalid_receivers, other}}

  defp install_prompt_templates(%URI{} = session_uri, target_content) do
    target = map_get(target_content, :prompt_templates, %{})

    if target == %{} and current_chat_field(session_uri, :prompt_templates) == %{} do
      :ok
    else
      case Session.system_set_prompt_templates(session_uri, target) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_prompt_templates_result, other}}
      end
    end
  end

  defp install_legends(%URI{} = session_uri, target_content) do
    target = map_get(target_content, :legends, %{})

    if target == %{} and current_chat_field(session_uri, :legends) == %{} do
      :ok
    else
      case Session.system_set_legends(session_uri, target) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_legends_result, other}}
      end
    end
  end

  defp current_chat_field(%URI{} = session_uri, field) do
    case Ezagent.Kind.get_raw_slice(session_uri, :session) do
      {:ok, slice} ->
        slice
        |> get_in([:state, field])
        |> case do
          value when is_map(value) -> value
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp finalize_pin(%URI{} = session_uri, %URI{} = target_uri) do
    wc =
      session_uri
      |> SessionEntity.read_template_working_copy()
      |> Map.put(:session_template_uri, target_uri)
      |> Map.delete(:migration_ledger)

    write_working_copy(session_uri, wc)
  end

  defp write_working_copy(%URI{} = session_uri, wc) do
    result =
      case Session.system_set_working_copy(session_uri, wc) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_set_working_copy_result, other}}
      end

    drain_dispatch_reply()
    result
  end

  defp drain_dispatch_reply do
    receive do
      {:ezagent_reply, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp preflight_session_template_cap(caps, %URI{} = workspace_uri, %URI{} = caller) do
    if Ezagent.Session.Config.Admission.template_cap?(
         Tools.to_cap_set(caps),
         :session_template,
         workspace_uri,
         caller
       ) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false

  defp normalize_uri(%URI{} = uri), do: uri
  defp normalize_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)
  defp normalize_uri(other), do: other

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
