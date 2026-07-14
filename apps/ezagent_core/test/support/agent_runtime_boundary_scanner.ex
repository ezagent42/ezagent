defmodule EzagentCore.AgentRuntimeBoundaryScanner do
  @moduledoc """
  Syntax-only classifier for closed Agent-runtime boundary fixtures.

  The classifier intentionally does not infer URI targets or follow data flow.
  In particular, generic lifecycle calls and the mixed-target
  `demand_spawn_member/1` wrapper are outside this closed table.
  """

  @forbidden_calls %{
    {Ezagent.Entity.Agent, :spawn_from_template_content} => :agent_materialization,
    {Ezagent.Entity.Agent, :spawn_from_manifest} => :agent_materialization
  }

  @spec scan_source(Path.t(), String.t()) :: [map()]
  def scan_source(path, source) do
    ast =
      Code.string_to_quoted!(source,
        warn_on_unnecessary_quotes: false,
        emit_warnings: false
      )

    {offenders, _aliases} = walk(ast, %{}, path)
    offenders
  end

  @spec scan_paths([Path.t()]) :: [map()]
  def scan_paths(paths) do
    Enum.flat_map(paths, fn path -> scan_source(path, File.read!(path)) end)
  end

  defp walk({:__block__, _meta, expressions}, aliases, path) do
    walk_sequence(expressions, aliases, path)
  end

  defp walk({:alias, _meta, [{:__aliases__, _, parts} | options]}, aliases, _path) do
    module = resolve_alias_parts(parts, aliases)
    alias_name = options |> List.first([]) |> Keyword.get(:as) |> alias_name(module)
    {[], Map.put(aliases, alias_name, module)}
  end

  defp walk({form, _meta, arguments}, aliases, path)
       when form in [:defmodule, :def, :defp, :defmacro, :defmacrop] and is_list(arguments) do
    {head, body} = split_body(arguments)
    {head_offenders, _aliases} = walk_sequence(head, aliases, path)
    {body_offenders, _aliases} = walk(body, aliases, path)
    {head_offenders ++ body_offenders, aliases}
  end

  defp walk({block, body}, aliases, path)
       when block in [:do, :else, :after, :rescue, :catch] do
    {offenders, _aliases} = walk(body, aliases, path)
    {offenders, aliases}
  end

  defp walk({:->, _meta, [patterns, body]}, aliases, path) do
    {pattern_offenders, _aliases} = walk(patterns, aliases, path)
    {body_offenders, _aliases} = walk(body, aliases, path)
    {pattern_offenders ++ body_offenders, aliases}
  end

  defp walk(node, aliases, path) when is_tuple(node) do
    offender = classify_call(node, aliases, path)
    {child_offenders, aliases} = node |> Tuple.to_list() |> walk_sequence(aliases, path)
    {maybe_list(offender) ++ child_offenders, aliases}
  end

  defp walk(nodes, aliases, path) when is_list(nodes), do: walk_sequence(nodes, aliases, path)
  defp walk(_node, aliases, _path), do: {[], aliases}

  defp walk_sequence(nodes, aliases, path) do
    Enum.reduce(nodes, {[], aliases}, fn node, {offenders, aliases} ->
      {new_offenders, aliases} = walk(node, aliases, path)
      {offenders ++ new_offenders, aliases}
    end)
  end

  defp split_body(arguments) do
    case List.pop_at(arguments, -1) do
      {{:do, body}, head} -> {head, body}
      {[do: body], head} -> {head, body}
      {_last, _head} -> {arguments, nil}
    end
  end

  defp alias_name(nil, module),
    do: module |> Module.split() |> List.last() |> String.to_existing_atom()

  defp alias_name({:__aliases__, _, [name]}, _module), do: name

  defp maybe_list(nil), do: []
  defp maybe_list(value), do: [value]

  defp classify_call(
         {{:., _, [module_ast, function]}, metadata, arguments},
         aliases,
         path
       )
       when is_atom(function) and is_list(arguments) do
    module = resolve_module(module_ast, aliases)

    case Map.fetch(@forbidden_calls, {module, function}) do
      {:ok, class} ->
        %{
          path: path,
          line: Keyword.get(metadata, :line, 1),
          module: module,
          function: function,
          arity: length(arguments),
          class: class
        }

      :error ->
        nil
    end
  end

  defp classify_call(_node, _aliases, _path), do: nil

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
