defmodule Ezagent.DomainGit.GitTaskAccessPrincipalBoundaryTest do
  use ExUnit.Case, async: true

  defmodule Detector do
    @moduledoc false

    @authority_keys %{
      caller: :invocation_caller,
      caller_uri: :invocation_caller,
      granted_by: :capability_grantor,
      grantor: :capability_grantor,
      grantor_uri: :capability_grantor,
      member: :member_identity,
      member_uri: :member_identity,
      login_identity: :member_identity,
      token_identity: :token_identity,
      token_holder: :token_identity,
      holder_uri: :token_identity
    }

    def scan_source(source, path) do
      {:ok, ast} = Code.string_to_quoted(source, file: path, columns: true)
      {violations, _tainted} = scan(ast, MapSet.new(), path)
      violations
    end

    defp scan({:__block__, _, expressions}, tainted, path) do
      Enum.map_reduce(expressions, tainted, fn expression, acc -> scan(expression, acc, path) end)
      |> then(fn {violations, next} -> {List.flatten(violations), next} end)
    end

    defp scan({:=, _, [{name, _, context}, rhs]} = expression, tainted, path)
         when is_atom(name) and is_atom(context) do
      next = if tainted?(rhs, tainted), do: MapSet.put(tainted, name), else: tainted
      {inspect_expression(expression, next, path), next}
    end

    defp scan(expression, tainted, path) do
      nested =
        expression
        |> child_blocks()
        |> Enum.flat_map(fn child -> elem(scan(child, tainted, path), 0) end)

      {inspect_expression(expression, tainted, path) ++ nested, tainted}
    end

    defp inspect_expression(expression, tainted, path) do
      {_ast, violations} =
        Macro.prewalk(expression, [], fn
          {:%{}, meta, entries} = node, acc ->
            {node, authority_entries(entries, meta, tainted, path) ++ acc}

          {:%, meta, [module, {:%{}, _, entries}]} = node, acc ->
            category = if system_principal?(module), do: :system_principal, else: nil

            own =
              if category && Enum.any?(entries, &tainted_entry?(&1, tainted)),
                do: [site(category, meta, path)],
                else: []

            {node, own ++ authority_entries(entries, meta, tainted, path) ++ acc}

          {{:., _, [module, _function]}, meta, args} = node, acc when is_list(args) ->
            own =
              if system_principal?(module) and Enum.any?(args, &tainted?(&1, tainted)),
                do: [site(:system_principal, meta, path)],
                else: []

            {node, own ++ acc}

          node, acc ->
            {node, acc}
        end)

      Enum.uniq(violations)
    end

    defp authority_entries(entries, meta, tainted, path) do
      for {key, value} <- entries,
          category = Map.get(@authority_keys, key),
          category != nil,
          tainted?(value, tainted),
          do: site(category, meta, path)
    end

    defp tainted_entry?({_key, value}, tainted), do: tainted?(value, tainted)

    defp tainted?(ast, tainted) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:__aliases__, _, parts} = node, found ->
            {node, found or List.last(parts) == :GitTaskAccess}

          {name, _, context} = node, found when is_atom(name) and is_atom(context) ->
            {node, found or name == :task_access_uri or MapSet.member?(tainted, name)}

          value, found when is_binary(value) ->
            {value, found or String.contains?(value, ["git_task_access", "gta_"])}

          node, found ->
            {node, found}
        end)

      found?
    end

    defp system_principal?({:__aliases__, _, parts}), do: List.last(parts) == :SystemPrincipal
    defp system_principal?(_module), do: false

    defp child_blocks({:defmodule, _, [_name, [do: body]]}), do: [body]
    defp child_blocks({kind, _, [_head, [do: body]]}) when kind in [:def, :defp], do: [body]
    defp child_blocks(_expression), do: []

    defp site(category, meta, path), do: {category, path, Keyword.get(meta, :line)}
  end

  @root Path.expand("../../../..", __DIR__)
  @production_glob Path.join(@root, "apps/*/lib/**/*.{ex,exs}")

  test "production code never uses GitTaskAccess as principal authority" do
    violations =
      @production_glob
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> Detector.scan_source(File.read!(path), path) end)

    assert violations == []
  end

  for {category, fixture} <- [
        invocation_caller: "%Ezagent.Invocation{caller:\n  task_access_uri\n}",
        capability_grantor: "%Ezagent.Capability{granted_by:\n  receiver\n}",
        member_identity: "%{member_uri:\n  receiver\n}",
        token_identity: "%{token_holder:\n  receiver\n}",
        system_principal: "Ezagent.SystemPrincipal.new(\n  receiver\n)"
      ] do
    test "detects #{category} independently across multiline local bindings" do
      source =
        """
        task_access_uri = GitTaskAccess.uri_from_args(policy)
        receiver = task_access_uri
        """ <> unquote(fixture)

      assert [{unquote(category), "fixture.ex", _line}] =
               Detector.scan_source(source, "fixture.ex")
    end
  end
end
