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
      login_identity: :member_identity
    }

    def scan_source(source, path) do
      {:ok, ast} = Code.string_to_quoted(source, file: path, columns: true)
      {violations, _state} = scan(ast, %{tainted: MapSet.new(), aliases: %{}}, path)
      violations
    end

    defp scan({:__block__, _, expressions}, state, path) do
      Enum.map_reduce(expressions, state, fn expression, acc -> scan(expression, acc, path) end)
      |> then(fn {violations, next} -> {List.flatten(violations), next} end)
    end

    defp scan({:alias, _, arguments}, state, _path) do
      {[], %{state | aliases: add_aliases(state.aliases, arguments)}}
    end

    defp scan({:=, _, [{name, _, context}, rhs]} = expression, state, path)
         when is_atom(name) and is_atom(context) do
      tainted =
        if tainted?(rhs, state.tainted),
          do: MapSet.put(state.tainted, name),
          else: state.tainted

      next = %{state | tainted: tainted}
      {inspect_expression(expression, next, path), next}
    end

    defp scan(expression, state, path) do
      nested =
        expression
        |> child_blocks()
        |> Enum.flat_map(fn child -> elem(scan(child, state, path), 0) end)

      {inspect_expression(expression, state, path) ++ nested, state}
    end

    defp inspect_expression(expression, state, path) do
      {_ast, violations} =
        Macro.prewalk(expression, [], fn
          {:%{}, meta, entries} = node, acc ->
            {node, authority_entries(entries, meta, state.tainted, path) ++ acc}

          {:%, meta, [module, {:%{}, _, entries}]} = node, acc ->
            category = if system_principal?(module), do: :system_principal, else: nil

            own =
              if category && Enum.any?(entries, &tainted_entry?(&1, state.tainted)),
                do: [site(category, meta, path)],
                else: []

            {node, own ++ authority_entries(entries, meta, state.tainted, path) ++ acc}

          {:|>, meta, [principal, {{:., _, [module, function]}, _, args}]} = node, acc
          when is_list(args) ->
            own =
              call_violations(
                expand_module(module, state.aliases),
                function,
                [principal | args],
                meta,
                state.tainted,
                path
              )

            {node, own ++ acc}

          {{:., _, [module, _function]}, meta, args} = node, acc when is_list(args) ->
            {{:., _, [_module, function]}, _, _args} = node

            own =
              call_violations(
                expand_module(module, state.aliases),
                function,
                args,
                meta,
                state.tainted,
                path
              )

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

    defp call_violations(module, function, args, meta, tainted, path) do
      category =
        cond do
          system_principal?(module) ->
            :system_principal

          exact_module?(module, [:Ezagent, :Entity, :Token]) and function == :mint ->
            :token_identity

          exact_module?(module, [:Ezagent, :EntityCaps]) and function in [:persist, :grant] ->
            :capability_holder

          exact_module?(module, [:Ezagent, :Entity, :Profile]) and function == :upsert ->
            :member_identity

          true ->
            nil
        end

      case {category, args} do
        {nil, _args} ->
          []

        {category, [principal | _rest]} ->
          if tainted?(principal, tainted), do: [site(category, meta, path)], else: []

        {_category, []} ->
          []
      end
    end

    defp exact_module?({:__aliases__, _, parts}, parts), do: true
    defp exact_module?(_module, _parts), do: false

    defp add_aliases(aliases, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes}]) do
      Enum.reduce(suffixes, aliases, fn {:__aliases__, _, suffix}, acc ->
        full = prefix ++ suffix
        Map.put(acc, List.last(suffix), full)
      end)
    end

    defp add_aliases(aliases, [{:__aliases__, _, full} | options]) do
      options = List.first(options) || []

      short =
        case Keyword.get(options, :as) do
          {:__aliases__, _, [name]} -> name
          nil -> List.last(full)
        end

      Map.put(aliases, short, full)
    end

    defp expand_module({:__aliases__, meta, [short]} = module, aliases) do
      case Map.fetch(aliases, short) do
        {:ok, full} -> {:__aliases__, meta, full}
        :error -> module
      end
    end

    defp expand_module(module, _aliases), do: module

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
        token_identity: "Ezagent.Entity.Token.mint(\n  receiver,\n  label: \"fixture\"\n)",
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

  for {category, fixture} <- [
        token_identity: "alias Ezagent.Entity.Token\nToken.mint(receiver, label: \"fixture\")",
        member_identity:
          "alias Ezagent.Entity.Profile, as: IdentityProfile\nIdentityProfile.upsert(%{entity_uri: receiver, display_name: \"Fixture\"})",
        capability_holder:
          "alias Ezagent.{EntityCaps, Entity.Token}\nEntityCaps.persist(receiver, caps)",
        capability_holder: "alias Ezagent.EntityCaps\nEntityCaps.grant(receiver, cap)"
      ] do
    test "detects aliased real #{category} chokepoint: #{fixture}" do
      source =
        """
        task_access_uri = GitTaskAccess.uri_from_args(policy)
        receiver = task_access_uri
        """ <> unquote(fixture)

      assert [{unquote(category), "fixture.ex", _line}] =
               Detector.scan_source(source, "fixture.ex")
    end
  end

  for {category, fixture} <- [
        token_identity: "alias Ezagent.Entity.Token\nreceiver |> Token.mint(label: \"fixture\")",
        member_identity:
          "alias Ezagent.Entity.Profile\n%{entity_uri: receiver, display_name: \"Fixture\"} |> Profile.upsert()",
        capability_holder: "alias Ezagent.EntityCaps\nreceiver |> EntityCaps.persist(caps)",
        capability_holder: "alias Ezagent.EntityCaps\nreceiver |> EntityCaps.grant(cap)"
      ] do
    test "detects piped real #{category} chokepoint: #{fixture}" do
      source =
        """
        task_access_uri = GitTaskAccess.uri_from_args(policy)
        receiver = task_access_uri
        """ <> unquote(fixture)

      assert [{unquote(category), "fixture.ex", _line}] =
               Detector.scan_source(source, "fixture.ex")
    end
  end

  for {category, fixture} <- [
        member_identity:
          "Ezagent.Entity.Profile.upsert(%{entity_uri: receiver, display_name: \"Fixture\"})",
        capability_holder: "Ezagent.EntityCaps.persist(receiver, caps)",
        capability_holder: "Ezagent.EntityCaps.grant(receiver, cap)"
      ] do
    test "detects real #{category} production call shape: #{fixture}" do
      source =
        """
        task_access_uri = GitTaskAccess.uri_from_args(policy)
        receiver = task_access_uri
        """ <> unquote(fixture)

      assert [{unquote(category), "fixture.ex", _line}] =
               Detector.scan_source(source, "fixture.ex")
    end
  end

  test "allows task access only as operation receiver and exact grantee_uri" do
    source = """
    task_access_uri = GitTaskAccess.uri_from_args(policy)
    operation = %Ezagent.Invocation{target: task_access_uri}
    capability = %Ezagent.Capability{grantee_uri: task_access_uri}
    """

    assert Detector.scan_source(source, "fixture.ex") == []
  end

  test "does not flag real principal APIs without a GitTaskAccess value" do
    source = """
    user_uri = Ezagent.URI.user("acme", "owner")
    Ezagent.Entity.Token.mint(user_uri, label: "fixture")
    Ezagent.Entity.Profile.upsert(%{entity_uri: user_uri, display_name: "Owner"})
    Ezagent.EntityCaps.persist(user_uri, caps)
    Ezagent.EntityCaps.grant(user_uri, cap)
    """

    assert Detector.scan_source(source, "fixture.ex") == []
  end
end
