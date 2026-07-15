defmodule EzagentCore.AgentRuntimeBoundaryScanner do
  @moduledoc """
  Syntax-only classifier for closed Agent-runtime boundary fixtures.

  The classifier intentionally does not infer URI targets or follow data flow.
  Agent targets are proven only by explicit variable names, keyword keys, or a
  small inventory-backed enclosing-function seam. The mixed-target
  `demand_spawn_member/1` body remains outside the table; its syntactically named
  invocation arguments are classified.
  """

  @forbidden_calls %{
    {Ezagent.Entity.Agent, :spawn_from_template_content} => :agent_materialization,
    {Ezagent.Entity.Agent, :spawn_from_manifest} => :agent_materialization,
    {Ezagent.Domain.Pty, :alive?} => :agent_executor_control,
    {Ezagent.Domain.Pty, :status} => :agent_executor_control,
    {Ezagent.Domain.Pty.Server, :phase} => :agent_executor_control,
    {Ezagent.ActionSet.Sandbox, :read_persisted_state} => :agent_config_or_credential_control
  }

  @agent_target_names [:agent_uri, :member_uri, :orchestrator_uri, :recipient_uri, :worker_uri]
  @allowed_classes [
    :agent_config_or_credential_control,
    :agent_destroy,
    :agent_ensure_live,
    :agent_executor_control,
    :agent_materialization,
    :legal_conversation_or_read,
    :legal_session_lifecycle
  ]
  @allowance_keys [:class, :path, :reason, :source_anchor]
  @rollback_path "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex"
  @imports_key :__agent_runtime_boundary_imports__

  @spec scan_source(Path.t(), String.t()) :: [map()]
  def scan_source(path, source) do
    ast =
      Code.string_to_quoted!(source,
        warn_on_unnecessary_quotes: false,
        emit_warnings: false
      )

    {offenders, _aliases} = walk(ast, %{}, path, "root")
    offenders
  end

  @spec scan_paths([Path.t()]) :: [map()]
  def scan_paths(paths) do
    Enum.flat_map(paths, fn path -> scan_source(path, File.read!(path)) end)
  end

  @spec validate_allowlist([map()], [map()], Path.t()) :: map()
  def validate_allowlist(offenders, allowances, repo_root) do
    {valid_allowances, invalid_allowances} = Enum.split_with(allowances, &valid_allowance?/1)
    matches = Enum.map(valid_allowances, &{&1, matching_offenders(offenders, &1, repo_root)})

    matched_offenders =
      matches
      |> Enum.flat_map(fn {_allowance, offenders} -> offenders end)
      |> MapSet.new()

    %{
      invalid_allowances: invalid_allowances,
      unmatched_allowances: for({allowance, []} <- matches, do: allowance),
      multiply_matched_allowances:
        for(
          {allowance, offenders} <- matches,
          multiply_matched?(offenders, matches),
          do: allowance
        ),
      unallowlisted_offenders: Enum.reject(offenders, &MapSet.member?(matched_offenders, &1))
    }
  end

  defp multiply_matched?(offenders, _matches) when length(offenders) > 1, do: true

  defp multiply_matched?([offender], matches) do
    Enum.count(matches, fn {_allowance, offenders} -> offender in offenders end) > 1
  end

  defp multiply_matched?([], _matches), do: false

  defp valid_allowance?(allowance) when is_map(allowance) do
    Map.keys(allowance) |> Enum.sort() == @allowance_keys and
      allowance.class in @allowed_classes and
      nonblank?(allowance.path) and
      nonblank?(allowance.source_anchor) and
      nonblank?(allowance.reason)
  end

  defp valid_allowance?(_allowance), do: false

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp walk({:__block__, _meta, expressions}, aliases, path, definition) do
    walk_sequence(expressions, aliases, path, definition)
  end

  defp walk(
         {:alias, _meta, [{{:., _, [base_ast, :{}]}, _, member_asts} | _options]},
         aliases,
         _path,
         _definition
       ) do
    base_module = resolve_module(base_ast, aliases)

    aliases =
      Enum.reduce(member_asts, aliases, fn {:__aliases__, _, parts}, aliases ->
        module = Module.concat([base_module | parts])
        Map.put(aliases, parts |> List.last(), module)
      end)

    {[], aliases}
  end

  defp walk({:alias, _meta, [{:__aliases__, _, parts} | options]}, aliases, _path, _definition) do
    module = resolve_alias_parts(parts, aliases)
    alias_name = options |> List.first([]) |> Keyword.get(:as) |> alias_name(module)
    {[], Map.put(aliases, alias_name, module)}
  end

  defp walk({:import, _meta, [{:__aliases__, _, parts} | _options]}, aliases, _path, _definition) do
    module = resolve_alias_parts(parts, aliases)
    imports = aliases |> Map.get(@imports_key, MapSet.new()) |> MapSet.put(module)
    {[], Map.put(aliases, @imports_key, imports)}
  end

  defp walk({form, _meta, arguments}, aliases, path, _definition)
       when form in [:defmodule, :def, :defp, :defmacro, :defmacrop] and is_list(arguments) do
    {head, body} = split_body(arguments)
    definition = definition_identity(form, List.first(head))
    {head_offenders, _aliases} = walk_sequence(head, aliases, path, nil)
    {body_offenders, _aliases} = walk(body, aliases, path, definition)
    {head_offenders ++ body_offenders, aliases}
  end

  defp walk({block, body}, aliases, path, definition)
       when block in [:do, :else, :after, :rescue, :catch] do
    {offenders, _aliases} = walk(body, aliases, path, definition)
    {offenders, aliases}
  end

  defp walk({:->, _meta, [patterns, body]}, aliases, path, definition) do
    {pattern_offenders, _aliases} = walk(patterns, aliases, path, definition)
    {body_offenders, _aliases} = walk(body, aliases, path, definition)
    {pattern_offenders ++ body_offenders, aliases}
  end

  defp walk(node, aliases, path, definition) when is_tuple(node) do
    offender = classify_call(node, aliases, path, definition)

    {child_offenders, aliases} =
      node |> Tuple.to_list() |> walk_sequence(aliases, path, definition)

    {maybe_list(offender) ++ child_offenders, aliases}
  end

  defp walk(nodes, aliases, path, definition) when is_list(nodes),
    do: walk_sequence(nodes, aliases, path, definition)

  defp walk(_node, aliases, _path, _definition), do: {[], aliases}

  defp walk_sequence(nodes, aliases, path, definition) do
    Enum.reduce(nodes, {[], aliases}, fn node, {offenders, aliases} ->
      {new_offenders, aliases} = walk(node, aliases, path, definition)
      {offenders ++ new_offenders, aliases}
    end)
  end

  defp split_body(arguments) do
    case List.pop_at(arguments, -1) do
      {{:do, body}, head} -> {head, body}
      {keywords, head} when is_list(keywords) -> {head, Keyword.get(keywords, :do)}
      {_last, _head} -> {arguments, nil}
    end
  end

  defp definition_identity(form, {:when, _, [head | _guards]}),
    do: definition_identity(form, head)

  defp definition_identity(form, {name, _, arguments}) when is_atom(name) do
    arity = if is_list(arguments), do: length(arguments), else: 0
    "#{form}:#{name}/#{arity}"
  end

  defp definition_identity(form, _head), do: to_string(form)

  defp alias_name(nil, module),
    do: module |> Module.split() |> List.last() |> String.to_existing_atom()

  defp alias_name({:__aliases__, _, [name]}, _module), do: name

  defp maybe_list(nil), do: []
  defp maybe_list(value), do: [value]

  defp classify_call(
         {{:., _, [module_ast, function]}, metadata, arguments},
         aliases,
         path,
         definition
       )
       when is_atom(function) and is_list(arguments) do
    module = resolve_module(module_ast, aliases)

    case classify(module, function, arguments, path, definition) do
      {:ok, class} ->
        %{
          path: path,
          line: Keyword.get(metadata, :line, 1),
          module: module,
          function: function,
          arity: length(arguments),
          class: class,
          source_anchor: source_anchor(definition, module, function, arguments)
        }

      :error ->
        nil
    end
  end

  defp classify_call({function, metadata, arguments}, aliases, path, definition)
       when is_atom(function) and is_list(arguments) and not is_nil(definition) do
    aliases
    |> Map.get(@imports_key, MapSet.new())
    |> Enum.find_value(fn module ->
      case classify(module, function, arguments, path, definition) do
        {:ok, class} ->
          %{
            path: path,
            line: Keyword.get(metadata, :line, 1),
            module: module,
            function: function,
            arity: length(arguments),
            class: class,
            source_anchor: source_anchor(definition, module, function, arguments)
          }

        :error ->
          nil
      end
    end)
  end

  defp classify_call(_node, _aliases, _path, _definition), do: nil

  defp classify(module, function, arguments, path, definition) do
    case Map.fetch(@forbidden_calls, {module, function}) do
      {:ok, class} ->
        {:ok, class}

      :error ->
        classify_contextual(module, function, arguments, repo_relative_path(path), definition)
    end
  end

  defp classify_contextual(Ezagent.SpawnRegistry, :ensure_live, [target], _path, _definition) do
    if agent_target?(target), do: {:ok, :agent_ensure_live}, else: :error
  end

  defp classify_contextual(Ezagent.SpawnRegistry, :spawn_detailed, [target], _path, _definition) do
    if agent_target?(target), do: {:ok, :agent_materialization}, else: :error
  end

  defp classify_contextual(Ezagent.Lifecycle, :destroy, [target, reason], path, definition) do
    if agent_target?(target) or
         (variable_name(target) == :uri and reason == :rollback and path == @rollback_path and
            definition == "def:compensate_spawned_members/1") do
      {:ok, :agent_destroy}
    else
      :error
    end
  end

  defp classify_contextual(
         EzagentDomainInstanceMessage.SessionCreator,
         :demand_spawn_member,
         arguments,
         _path,
         _definition
       ) do
    if Enum.any?(arguments, &agent_target?/1) do
      {:ok, :agent_materialization}
    else
      :error
    end
  end

  defp classify_contextual(
         Ezagent.Session.SessionManager,
         :stop,
         [target],
         _path,
         _definition
       ) do
    if variable_name(target) in [:agent_uri, :member_uri, :worker_uri, :pty_uri, :sidecar_uri] do
      {:ok, :agent_executor_control}
    else
      :error
    end
  end

  defp classify_contextual(
         Ezagent.Session.SessionManager,
         :ensure_started,
         [options],
         _path,
         _definition
       )
       when is_list(options) do
    keys = Keyword.keys(options)

    if :orchestrator_uri in keys and :session_uri in keys,
      do: :error,
      else: {:ok, :agent_executor_control}
  end

  defp classify_contextual(_module, _function, _arguments, _path, _definition), do: :error

  defp repo_relative_path(path) do
    marker = "apps/ezagent_domain_session/lib/"

    case String.split(path, marker, parts: 2) do
      [_prefix, suffix] -> marker <> suffix
      [relative_path] -> relative_path
    end
  end

  defp agent_target?(target), do: variable_name(target) in @agent_target_names

  defp variable_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp variable_name(_target), do: nil

  defp source_anchor(definition, module, function, arguments) do
    normalized_arguments =
      arguments
      |> Enum.map_join(", ", &Macro.to_string/1)
      |> String.replace(~r/\s+/, " ")

    "#{definition || "root"}|#{inspect(module)}.#{function}(#{normalized_arguments})"
  end

  defp matching_offenders(offenders, allowance, repo_root) do
    Enum.filter(offenders, fn offender ->
      Path.relative_to(offender.path, repo_root) == allowance.path and
        offender.class == allowance.class and
        allowance.source_anchor == offender.source_anchor
    end)
  end

  defp resolve_module({:__aliases__, _, parts}, aliases) do
    resolve_alias_parts(parts, aliases)
  end

  defp resolve_module(_module_ast, _aliases), do: nil

  defp resolve_alias_parts([first | rest] = parts, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, module} -> Module.concat([module | rest])
      :error -> Module.concat(parts)
    end
  end
end
