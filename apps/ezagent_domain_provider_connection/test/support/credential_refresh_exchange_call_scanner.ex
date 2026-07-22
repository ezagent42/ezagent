defmodule Ezagent.ProviderConnection.Test.CredentialRefreshExchangeCallScanner do
  @moduledoc """
  Test-only source scanner for the credential refresh exchange call boundary.

  The scanner normalizes the statically visible spellings of the two private
  credential-backend callbacks and propagates those sinks through each module's
  local call graph. It is an architecture drift alarm, not a runtime security
  boundary: code that constructs both a module and callback dynamically (for
  example with `Module.concat/1`) cannot be proven safe by source inspection.
  The one-shot runtime scope claim remains the security boundary.
  """

  @callbacks [:begin_refresh_exchange, :consume_refresh_exchange]

  @doc false
  def scan_files(paths) do
    Enum.reduce(paths, empty_result(), fn path, result ->
      path
      |> File.read!()
      |> scan_source(path: path)
      |> merge_results(result)
    end)
    |> sort_result()
  end

  @doc false
  def scan_source(source, opts \\ []) when is_binary(source) do
    path = Keyword.get(opts, :path, "fixture.ex")
    ast = quoted!(source, path)

    {direct_sites, definitions} =
      ast
      |> module_entries()
      |> Enum.reduce({[], %{}}, fn {module, body}, {sites, definitions} ->
        env = scan_env(body)

        body
        |> block_items()
        |> Enum.reduce({sites, definitions}, fn
          definition, acc when elem(definition, 0) in [:def, :defp] ->
            collect_definition(definition, module, path, env, acc)

          {:defdelegate, _, _} = delegate, {sites, definitions} ->
            collect_delegate(delegate, module, path, env, sites, definitions)

          _other, acc ->
            acc
        end)
      end)

    direct_sites =
      direct_sites
      |> Enum.uniq_by(
        &{&1.path, &1.module, &1.function, &1.arity, &1.line, &1.column, &1.callback}
      )

    %{
      direct_sites: direct_sites,
      reachable_functions: reachable_functions(definitions, direct_sites)
    }
    |> sort_result()
  end

  defp collect_definition(definition, module, path, env, {sites, definitions}) do
    with {:ok, visibility, name, arity, body} <- definition_parts(definition) do
      signature = {module, name, arity}
      expanded = expand_pipes(body)
      taint = backend_taint(expanded, definition)

      definition_sites =
        expanded
        |> direct_sites(env, taint)
        |> Enum.map(
          &Map.merge(&1, %{
            path: path,
            module: module,
            function: name,
            arity: arity,
            visibility: visibility
          })
        )

      local_calls = local_calls(expanded)

      definition_info = %{
        calls: local_calls,
        line: ast_line(definition),
        path: path,
        visibility: visibility
      }

      {definition_sites ++ sites, put_definition(definitions, signature, definition_info)}
    else
      :error -> {sites, definitions}
    end
  end

  defp collect_delegate(
         {:defdelegate, meta, [{name, _, args}, opts]} = node,
         module,
         path,
         env,
         sites,
         definitions
       )
       when is_atom(name) and is_list(args) and is_list(opts) do
    arity = length(args)
    signature = {module, name, arity}

    callback = Keyword.get(opts, :as, name)
    receiver = Keyword.get(opts, :to)

    delegate_sites =
      if callback in @callbacks and backend_receiver?(receiver, env, MapSet.new()) do
        [
          %{
            path: path,
            module: module,
            function: name,
            arity: arity,
            visibility: :def,
            callback: callback,
            line: Keyword.get(meta, :line, ast_line(node)),
            column: Keyword.get(meta, :column, 1),
            kind: :defdelegate,
            expression: Macro.to_string(node)
          }
        ]
      else
        []
      end

    info = %{calls: MapSet.new(), line: ast_line(node), path: path, visibility: :def}
    {delegate_sites ++ sites, put_definition(definitions, signature, info)}
  end

  defp collect_delegate(_node, _module, _path, _env, sites, definitions),
    do: {sites, definitions}

  defp definition_parts({visibility, _, [head, body_opts]})
       when visibility in [:def, :defp] and is_list(body_opts) do
    with {name, args} <- unwrap_head(head),
         true <- is_atom(name) and is_list(args),
         {:ok, body} <- Keyword.fetch(body_opts, :do) do
      {:ok, visibility, name, length(args), body}
    else
      _ -> :error
    end
  end

  defp definition_parts(_definition), do: :error

  defp unwrap_head({:when, _, [head | _guards]}), do: unwrap_head(head)
  defp unwrap_head({name, _, args}), do: {name, args || []}
  defp unwrap_head(_head), do: :error

  defp direct_sites(ast, env, taint) do
    {_ast, sites} =
      Macro.prewalk(ast, [], fn node, sites ->
        {node, detect_site(node, env, taint) ++ sites}
      end)

    Enum.reverse(sites)
  end

  # Function.capture(backend, :callback, 1)
  defp detect_site(
         {{:., meta, [receiver, :capture]}, _, [_backend, callback, 1]} = node,
         env,
         _taint
       )
       when callback in @callbacks do
    if function_module?(receiver, env),
      do: [site(callback, :function_capture, meta, node)],
      else: []
  end

  # Kernel.apply/3 and :erlang.apply/3. Keep this before the ordinary remote call.
  defp detect_site(
         {{:., meta, [receiver, :apply]}, _, [backend, callback, _args]} = node,
         env,
         taint
       ) do
    if apply_module?(receiver, env) and callback in @callbacks,
      do: [site(callback, :remote_apply, meta, node)],
      else: dynamic_apply_site(callback, backend, env, taint, meta, node)
  end

  # &backend.callback/1
  defp detect_site(
         {:&, meta,
          [
            {:/, _, [{{:., _, [_backend, callback]}, _, []}, 1]}
          ]} = node,
         _env,
         _taint
       )
       when callback in @callbacks do
    [site(callback, :capture, meta, node)]
  end

  # apply(backend, :callback, args)
  defp detect_site({:apply, meta, [backend, callback, _args]} = node, env, taint) do
    if callback in @callbacks,
      do: [site(callback, :bare_apply, meta, node)],
      else: dynamic_apply_site(callback, backend, env, taint, meta, node)
  end

  # backend.callback(args), including aliases, attributes, and dynamic receivers.
  defp detect_site({{:., meta, [_backend, callback]}, _, args} = node, _env, _taint)
       when callback in @callbacks and is_list(args) do
    [site(callback, :remote_call, meta, node)]
  end

  # import Backend; callback(args)
  defp detect_site({callback, meta, args} = node, %{backend_import?: true}, _taint)
       when callback in @callbacks and is_list(args),
       do: [site(callback, :imported_call, meta, node)]

  defp detect_site(_node, _env, _taint), do: []

  defp dynamic_apply_site(callback, backend, env, taint, meta, node) do
    if not is_atom(callback) and backend_receiver?(backend, env, taint),
      do: [site(:dynamic, :dynamic_apply, meta, node)],
      else: []
  end

  defp site(callback, kind, meta, node) do
    %{
      callback: callback,
      line: Keyword.get(meta, :line, ast_line(node)),
      column: Keyword.get(meta, :column, 1),
      kind: kind,
      expression: Macro.to_string(node)
    }
  end

  defp local_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _, args} = node, calls
        when is_atom(name) and is_list(args) and name not in @callbacks ->
          if local_call_form?(name),
            do: {node, calls},
            else: {node, MapSet.put(calls, {name, length(args)})}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp local_call_form?(name) do
    name in [
      :__block__,
      :__aliases__,
      :.,
      :->,
      :=,
      :|>,
      :{},
      :%{},
      :%,
      :<<>>,
      :&,
      :/,
      :when,
      :fn,
      :case,
      :cond,
      :with,
      :if,
      :unless,
      :for,
      :try,
      :receive,
      :quote,
      :unquote,
      :alias,
      :import,
      :require,
      :apply,
      :and,
      :or,
      :not,
      :in,
      :==,
      :!=,
      :===,
      :!==,
      :<,
      :>,
      :<=,
      :>=,
      :+,
      :-,
      :*,
      :div,
      :rem,
      :<>
    ]
  end

  defp reachable_functions(definitions, direct_sites) do
    initial =
      Enum.reduce(direct_sites, %{}, fn site, acc ->
        Map.update(
          acc,
          {site.module, site.function, site.arity},
          MapSet.new([site.callback]),
          &MapSet.put(&1, site.callback)
        )
      end)

    definitions
    |> propagate(initial)
    |> Enum.flat_map(fn {{module, function, arity} = signature, callbacks} ->
      info = Map.fetch!(definitions, signature)

      Enum.map(callbacks, fn callback ->
        %{
          module: module,
          function: function,
          arity: arity,
          callback: callback,
          line: info.line,
          column: 1,
          path: info.path,
          visibility: info.visibility,
          kind: :reachable_wrapper,
          expression: nil
        }
      end)
    end)
  end

  defp propagate(definitions, callbacks_by_signature) do
    next =
      Enum.reduce(definitions, callbacks_by_signature, fn
        {{module, _name, _arity} = caller, %{calls: calls}}, acc ->
          Enum.reduce(calls, acc, fn {callee_name, callee_arity}, inner ->
            case Map.get(inner, {module, callee_name, callee_arity}) do
              nil -> inner
              callbacks -> Map.update(inner, caller, callbacks, &MapSet.union(&1, callbacks))
            end
          end)
      end)

    if next == callbacks_by_signature, do: next, else: propagate(definitions, next)
  end

  defp put_definition(definitions, signature, info) do
    Map.update(definitions, signature, info, fn existing ->
      %{
        existing
        | calls: MapSet.union(existing.calls, info.calls),
          line: min(existing.line, info.line)
      }
    end)
  end

  defp backend_taint(ast, definition) do
    initial =
      definition
      |> definition_arguments()
      |> Enum.filter(&backend_variable_name?/1)
      |> MapSet.new()

    {_ast, taint} =
      Macro.prewalk(ast, initial, fn
        {:=, _, [{name, _, context}, rhs]} = node, taint
        when is_atom(name) and is_atom(context) ->
          if backend_variable_name?(name) or backend_expression?(rhs, taint),
            do: {node, MapSet.put(taint, name)},
            else: {node, taint}

        node, taint ->
          {node, taint}
      end)

    taint
  end

  defp definition_arguments({_, _, [head, _body]}) do
    case unwrap_head(head) do
      {_name, args} ->
        Enum.flat_map(args, fn
          {name, _, context} when is_atom(name) and is_atom(context) -> [name]
          _ -> []
        end)

      :error ->
        []
    end
  end

  defp backend_expression?({name, _, context}, taint)
       when is_atom(name) and is_atom(context),
       do: MapSet.member?(taint, name)

  defp backend_expression?({:__aliases__, _, _}, _taint), do: true
  defp backend_expression?({:@, _, _}, _taint), do: true
  defp backend_expression?(_other, _taint), do: false

  defp backend_receiver?({name, _, context}, _env, taint)
       when is_atom(name) and is_atom(context),
       do: backend_variable_name?(name) or MapSet.member?(taint, name)

  defp backend_receiver?({:__aliases__, _, _}, _env, _taint), do: true
  defp backend_receiver?({:@, _, _}, _env, _taint), do: true
  defp backend_receiver?(_receiver, _env, _taint), do: false

  defp backend_variable_name?(name) do
    name
    |> Atom.to_string()
    |> String.contains?("backend")
  end

  defp function_module?({:__aliases__, _, segments}, env),
    do: expand_alias(segments, env) == [:Function]

  defp function_module?(_receiver, _env), do: false

  defp apply_module?(:erlang, _env), do: true

  defp apply_module?({:__aliases__, _, segments}, env),
    do: expand_alias(segments, env) == [:Kernel]

  defp apply_module?(_receiver, _env), do: false

  defp scan_env(ast) do
    {_ast, env} =
      Macro.prewalk(ast, %{aliases: %{}, backend_import?: false, attrs: %{}}, fn
        {:alias, _, [{:__aliases__, _, module_segments} | opts]} = node, env ->
          short = alias_as(opts, module_segments)
          {node, put_in(env, [:aliases, short], module_segments)}

        {:import, _, [module_ast | _opts]} = node, env ->
          {node,
           %{env | backend_import?: env.backend_import? or backend_module?(module_ast, env)}}

        {:@, _, [{name, _, [{:__aliases__, _, module_segments}]}]} = node, env
        when is_atom(name) ->
          {node, put_in(env, [:attrs, name], module_segments)}

        node, env ->
          {node, env}
      end)

    env
  end

  defp backend_module?({:__aliases__, _, segments}, env) do
    segments
    |> expand_alias(env)
    |> List.last()
    |> Atom.to_string()
    |> then(&(String.contains?(&1, "Credential") or String.contains?(&1, "Backend")))
  end

  defp backend_module?(_module, _env), do: false

  defp alias_as([opts | _], module_segments) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, segments} -> segments
      _ -> [List.last(module_segments)]
    end
  end

  defp alias_as(_opts, module_segments), do: [List.last(module_segments)]

  defp expand_alias(segments, %{aliases: aliases}) do
    case Map.get(aliases, [List.first(segments)]) do
      nil -> segments
      expanded -> expanded ++ Enum.drop(segments, 1)
    end
  end

  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, meta, [lhs, {call, call_meta, args}]} when is_list(args) ->
        {call, Keyword.merge(meta, call_meta), [lhs | args]}

      node ->
        node
    end)
  end

  defp module_entries(ast) do
    {_ast, entries} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, segments}, body_opts]} = node, entries
        when is_list(body_opts) ->
          case Keyword.fetch(body_opts, :do) do
            {:ok, body} -> {node, [{Module.concat(segments), body} | entries]}
            :error -> {node, entries}
          end

        node, entries ->
          {node, entries}
      end)

    Enum.reverse(entries)
  end

  defp block_items({:__block__, _, items}), do: items
  defp block_items(item), do: [item]

  defp ast_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, 1)
  defp ast_line(_node), do: 1

  defp quoted!(source, path) do
    case Code.string_to_quoted(source, file: path, columns: true) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{path}: #{inspect(reason)}"
    end
  end

  defp empty_result, do: %{direct_sites: [], reachable_functions: []}

  defp merge_results(result, acc) do
    %{
      direct_sites: result.direct_sites ++ acc.direct_sites,
      reachable_functions: result.reachable_functions ++ acc.reachable_functions
    }
  end

  defp sort_result(result) do
    Map.new(result, fn {key, findings} ->
      {key,
       Enum.sort_by(findings, fn finding ->
         {Map.get(finding, :path, ""), finding.module, finding.line, finding.function,
          finding.column, finding.callback}
       end)}
    end)
  end
end
