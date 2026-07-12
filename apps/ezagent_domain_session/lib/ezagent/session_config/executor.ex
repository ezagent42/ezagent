defmodule Ezagent.Session.Config.Executor do
  @moduledoc false

  alias Ezagent.Orchestrator.Tools

  @spec execute(term(), map(), keyword()) :: term()
  @doc false
  def execute({:core, "add_managed_member"}, args, opts) do
    with {:ok, template_uri} <- arg_uri(args, "source_agent_template_uri"),
         {:ok, role_name} <- arg_string(args, "role_name") do
      Tools.add_managed_member(
        template_uri,
        role_name,
        arg_optional_boolean(args, "in_session_template", true),
        opts
      )
    end
  end

  def execute({:core, "add_participant"}, args, opts) do
    with {:ok, ref} <- arg_string(args, "ref"),
         {:ok, role_name} <- arg_string(args, "role_name") do
      participant_opts =
        [
          in_session_template: arg_optional_boolean(args, "in_session_template", true),
          slots: arg_optional_map(args, "slots", %{})
        ] ++ opts

      Tools.add_participant(ref, role_name, participant_opts)
    end
  end

  def execute({:core, "update_member_template"}, args, opts) do
    with {:ok, role_name} <- arg_string(args, "role_name"),
         {:ok, template_uri} <- arg_uri(args, "new_source_template_uri") do
      Tools.update_member_template(role_name, template_uri, opts)
    end
  end

  def execute({:core, "remove_member"}, args, opts) do
    with {:ok, role_name} <- arg_string(args, "role_name") do
      Tools.remove_member(role_name, opts)
    end
  end

  def execute({:core, "define_rule_set_rule"}, args, opts) do
    with {:ok, matcher} <- arg_matcher(args, "matcher_ast"),
         {:ok, receiver_role} <- arg_string(args, "receiver_role_name"),
         {:ok, rule_set} <- arg_string(args, "rule_set") do
      rule_opts =
        [
          rule_set: rule_set,
          position: arg_optional_integer(args, "position", 0),
          prompt_template_ref: arg_optional_string(args, "prompt_template_ref")
        ] ++ opts

      Tools.define_rule_set_rule(matcher, receiver_role, rule_opts)
    end
  end

  def execute({:core, "define_prompt_template"}, args, opts) do
    with {:ok, name} <- arg_string(args, "name"),
         {:ok, template} <- arg_string(args, "template") do
      Tools.define_prompt_template(name, template, opts)
    end
  end

  def execute({:core, "define_legend"}, args, opts) do
    with {:ok, legend_name} <- arg_string(args, "legend_name"),
         {:ok, member_role_names} <- arg_string_list(args, "member_role_names"),
         {:ok, bound_rule_set} <- arg_string(args, "bound_rule_set") do
      Tools.define_legend(
        legend_name,
        member_role_names,
        bound_rule_set,
        arg_optional_boolean(args, "fold", true),
        opts
      )
    end
  end

  def execute({:core, "update_template"}, _args, opts), do: Tools.update_template(opts)

  def execute({:core, "save_template_as"}, args, opts) do
    with {:ok, new_name} <- arg_string(args, "new_name") do
      Tools.save_template_as(new_name, opts)
    end
  end

  def execute({:core, "migrate_session"}, args, opts) do
    with {:ok, target_uri} <- arg_uri(args, "target_session_template_uri") do
      Tools.migrate_session(target_uri, opts)
    end
  end

  def execute({:core, "list_templates"}, args, opts) do
    Tools.list_templates(arg_optional_string(args, "name_filter"), opts)
  end

  def execute(
        {:agent_action,
         %{agent_arg: agent_arg, behavior: behavior, action: action, args: arg_spec}},
        args,
        opts
      ) do
    with {:ok, agent_name} <- arg_string(args, agent_arg),
         {:ok, caller} <- Tools.require_opt(opts, :caller),
         {:ok, caps} <- Tools.require_opt(opts, :caps),
         {:ok, workspace_uri} <- Tools.require_opt(opts, :workspace_uri),
         {:ok, action_args} <- route_args(args, arg_spec) do
      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
      agent_uri = Ezagent.URI.agent(workspace_name, agent_name)

      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(agent_uri, behavior, action),
        mode: :call,
        args: action_args,
        ctx: %{caller: caller, caps: Tools.to_cap_set(caps), reply: {:caller_inbox, self()}}
      })
    end
  rescue
    _ -> {:error, {:invalid_agent_reference, Map.get(args, agent_arg)}}
  end

  def execute({:mfa, module, function}, args, opts), do: apply(module, function, [args, opts])
  def execute(route, _args, _opts), do: {:error, {:invalid_operation_route, route}}

  defp route_args(args, spec) do
    Enum.reduce_while(spec, {:ok, %{}}, fn
      {target_key, source_key}, {:ok, acc} when is_binary(source_key) ->
        case arg_string(args, source_key) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, target_key, value)}}
          {:error, _} = error -> {:halt, error}
        end

      {target_key, {source_key, default}}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, target_key, Map.get(args, source_key, default))}}
    end)
  end

  defp arg_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp arg_optional_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp arg_optional_boolean(args, key, default) do
    case Map.get(args, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp arg_optional_integer(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp arg_optional_map(args, key, default) do
    case Map.get(args, key) do
      %{} = value -> value
      _ -> default
    end
  end

  defp arg_uri(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" ->
        try do
          {:ok, Ezagent.URI.new!(value)}
        rescue
          ArgumentError -> {:error, {:invalid_arg, key}}
        end

      %URI{} = uri ->
        {:ok, uri}

      _ ->
        {:error, {:missing_arg, key}}
    end
  end

  defp arg_string_list(args, key) do
    case Map.get(args, key) do
      list when is_list(list) -> {:ok, Enum.map(list, &to_string/1)}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp arg_matcher(args, key) do
    case Map.get(args, key) do
      %{} = matcher -> {:ok, matcher}
      matcher when is_tuple(matcher) -> {:ok, matcher}
      _ -> {:error, {:missing_arg, key}}
    end
  end
end
