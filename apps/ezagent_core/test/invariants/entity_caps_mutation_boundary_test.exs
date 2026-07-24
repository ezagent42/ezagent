defmodule Ezagent.Invariants.EntityCapsMutationBoundaryTest do
  @moduledoc """
  Pins the VM-internal EntityCaps mutation protocol to one constructor and
  rejects direct storage consumers that could bypass issue-before-grant.
  """
  use ExUnit.Case, async: true

  @facade "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex"
  @identity_facade "apps/ezagent_domain_identity/lib/ezagent/identity.ex"
  @cascade_hook "apps/ezagent_core/lib/ezagent/kind/cascade_hook.ex"
  @identity_behavior "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
  @cap_verifier "apps/ezagent_core/lib/ezagent/cap/verifier.ex"
  @identity_grant "apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex"
  @recipe_binding "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex"
  @actions [:persist_caps, :store_cap, :remove_cap]

  test "storage action literals and producers are exact" do
    assert action_literals() == %{
             @cap_verifier => %{persist_caps: 1, store_cap: 1, remove_cap: 1},
             @facade => %{persist_caps: 1, store_cap: 1, remove_cap: 1},
             @identity_behavior => %{persist_caps: 3, store_cap: 3, remove_cap: 3},
             @identity_grant => %{store_cap: 2, remove_cap: 2}
           }

    assert mutation_dispatch_calls() == %{
             @facade => %{persist_caps: 1, store_cap: 1, remove_cap: 1}
           }

    assert vm_internal_cmd_builders() ==
             MapSet.new([
               {@cascade_hook, :maybe_enqueue, 1},
               {@facade, :dispatch_mutation, 3},
               {@identity_facade, :absorb_cap, 2},
               {@recipe_binding, :sync_live, 1}
             ])

    assert direct_handler_calls() == MapSet.new()
  end

  test "handlers require exact VM provenance and strict issued inputs" do
    source = source!(@identity_behavior)

    for {handler, field} <- [
          {:handle_persist_caps, "caps"},
          {:handle_store_cap, "cap"},
          {:handle_remove_cap, "cap"}
        ] do
      bodies = definition_bodies(source, handler, 2)
      body = Enum.find(bodies, &String.contains?(&1, "caller: :vm_internal"))
      assert is_binary(body)
      assert body =~ "caller: :vm_internal"
      assert body =~ field
    end

    assert Enum.any?(
             definition_bodies(source, :handle_persist_caps, 2),
             &String.contains?(&1, "validate_issued_caps")
           )

    assert Enum.any?(
             definition_bodies(source, :handle_store_cap, 2),
             &String.contains?(&1, "validate_issued_caps")
           )

    refute Enum.any?(
             definition_bodies(source, :handle_remove_cap, 2),
             &String.contains?(&1, "validate_issued_caps")
           )

    for handler <- [:handle_persist_caps, :handle_store_cap, :handle_remove_cap] do
      assert Regex.scan(~r/def #{handler}\(/, source) |> length() == 2
      assert source =~ "def #{handler}(_args, _ctx), do: {:error, :unauthorized}"
    end
  end

  test "production has zero EntityCaps.grant consumers" do
    assert entity_caps_grant_calls(production_asts()) == []
  end

  test "grant-consumer scanner catches aliases, imports, captures, and apply" do
    {:ok, ast} =
      Code.string_to_quoted("""
      defmodule Escape do
        alias Ezagent.EntityCaps, as: EC
        import EC, only: [grant: 2]

        def direct(uri, cap), do: EC.grant(uri, cap)
        def imported(uri, cap), do: grant(uri, cap)
        def applied(uri, cap), do: apply(EC, :grant, [uri, cap])
        def captured, do: Function.capture(EC, :grant, 2)
        def remote_capture, do: &EC.grant/2
      end
      """)

    {:ok, script_ast} = Code.string_to_quoted("Ezagent.EntityCaps.grant(uri, cap)")

    assert length(entity_caps_grant_calls([{"fixture.ex", ast}, {"fixture.exs", script_ast}])) ==
             6
  end

  test "direct-handler scanner catches remote calls, captures, and apply" do
    {:ok, ast} =
      Code.string_to_quoted("""
      Ezagent.ActionSet.IdentityAdmin.handle_store_cap(args, ctx)
      apply(Ezagent.ActionSet.IdentityAdmin, :handle_persist_caps, [args, ctx])
      Kernel.apply(Ezagent.ActionSet.IdentityAdmin, :handle_remove_cap, dynamic_args)
      Function.capture(Ezagent.ActionSet.IdentityAdmin, :handle_store_cap, 2)
      &Ezagent.ActionSet.IdentityAdmin.handle_remove_cap/2
      """)

    assert count_ast(ast, &direct_handler_call?/1) == 5
  end

  test "VM-internal producer scanner catches struct/2 and Cmd.new with dynamic actions" do
    {:ok, ast} =
      Code.string_to_quoted("""
      alias Ezagent.Cmd
      %Cmd{target: target, action: dynamic_action, args: args, ctx: %{caller: :vm_internal}}
      struct(Cmd, target: target, action: dynamic_action, args: args, ctx: %{caller: :vm_internal})
      Cmd.new(target, dynamic_action, args, %{caller: :vm_internal})
      """)

    assert count_ast(ast, &vm_internal_cmd_constructor?/1) == 3
  end

  test "VM-internal producer scanner resolves an explicitly renamed Cmd alias" do
    {:ok, ast} =
      Code.string_to_quoted("""
      alias Ezagent.Cmd, as: C
      struct(C, target: target, action: dynamic_action, args: args, ctx: %{caller: :vm_internal})
      C.new(target, dynamic_action, args, %{caller: :vm_internal})
      """)

    aliases = aliases(ast)
    assert count_ast(ast, &vm_internal_cmd_constructor?(&1, aliases)) == 2
  end

  defp action_literals do
    production_asts()
    |> Enum.reduce(%{}, fn {file, ast}, acc ->
      counts =
        Enum.reduce(@actions, %{}, fn action, action_acc ->
          count = count_ast(ast, &(&1 == action))
          if count == 0, do: action_acc, else: Map.put(action_acc, action, count)
        end)

      if map_size(counts) == 0, do: acc, else: Map.put(acc, file, counts)
    end)
  end

  defp mutation_dispatch_calls do
    production_definitions()
    |> Enum.reduce(%{}, fn definition, acc ->
      calls =
        Enum.reduce(@actions, %{}, fn action, action_acc ->
          count =
            count_ast(definition.body, fn
              {:dispatch_mutation, _, [_uri, ^action, _args]} -> true
              {{:., _, [_module, :dispatch_mutation]}, _, [_uri, ^action, _args]} -> true
              _ -> false
            end)

          if count == 0, do: action_acc, else: Map.put(action_acc, action, count)
        end)

      if map_size(calls) == 0 do
        acc
      else
        Map.update(acc, definition.file, calls, &Map.merge(&1, calls, fn _, a, b -> a + b end))
      end
    end)
  end

  defp vm_internal_cmd_builders do
    production_definitions()
    |> Enum.filter(fn definition ->
      count_ast(definition.body, &vm_internal_cmd_constructor?(&1, definition.aliases)) > 0
    end)
    |> Enum.map(&{&1.file, &1.name, &1.arity})
    |> MapSet.new()
  end

  defp direct_handler_calls do
    production_definitions()
    |> Enum.filter(fn definition ->
      count_ast(definition.body, &direct_handler_call?/1) > 0
    end)
    |> Enum.map(&{&1.file, &1.name, &1.arity})
    |> MapSet.new()
  end

  defp vm_internal_cmd_constructor?(node), do: vm_internal_cmd_constructor?(node, %{})

  defp vm_internal_cmd_constructor?({:%, _, [module, {:%{}, _, fields}]}, aliases)
       when is_list(fields),
       do: cmd_module?(module, aliases) and ast_contains?(fields, {:caller, :vm_internal})

  defp vm_internal_cmd_constructor?({:struct, _, [module, fields]}, aliases),
    do: cmd_module?(module, aliases) and ast_contains?(fields, {:caller, :vm_internal})

  defp vm_internal_cmd_constructor?(
         {{:., _, [kernel, :struct]}, _, [module, fields]},
         aliases
       ),
       do:
         Macro.to_string(kernel) == "Kernel" and cmd_module?(module, aliases) and
           ast_contains?(fields, {:caller, :vm_internal})

  defp vm_internal_cmd_constructor?(
         {{:., _, [module, :new]}, _, [_target, _action, _args, ctx]},
         aliases
       ),
       do: cmd_module?(module, aliases) and ast_contains?(ctx, {:caller, :vm_internal})

  defp vm_internal_cmd_constructor?(_node, _aliases), do: false

  defp cmd_module?(module, aliases) do
    name = Macro.to_string(module)
    name in ["Cmd", "Ezagent.Cmd"] or Map.get(aliases, name) == "Ezagent.Cmd"
  end

  defp direct_handler_call?({{:., _, [_module, handler]}, _, args})
       when handler in [:handle_persist_caps, :handle_store_cap, :handle_remove_cap] and
              is_list(args),
       do: true

  defp direct_handler_call?({{:., _, [_module, :capture]}, _, [_target, handler, _arity]})
       when handler in [:handle_persist_caps, :handle_store_cap, :handle_remove_cap],
       do: true

  defp direct_handler_call?({{:., _, [_module, :apply]}, _, [_target, handler, _args]})
       when handler in [:handle_persist_caps, :handle_store_cap, :handle_remove_cap],
       do: true

  defp direct_handler_call?({:apply, _, [_target, handler, _args]})
       when handler in [:handle_persist_caps, :handle_store_cap, :handle_remove_cap],
       do: true

  defp direct_handler_call?(_node), do: false

  defp entity_caps_grant_calls(asts) do
    Enum.flat_map(asts, fn {file, ast} ->
      aliases = aliases(ast)
      imported? = imports_entity_caps?(ast, aliases)

      ast
      |> definitions(file)
      |> Enum.flat_map(fn definition ->
        count = count_ast(definition.body, &entity_caps_grant_call?(&1, aliases, imported?))
        List.duplicate({file, definition.name, definition.arity}, count)
      end)
    end)
  end

  defp entity_caps_grant_call?({{:., _, [module, :grant]}, _, args}, aliases, _imported?)
       when is_list(args),
       do: entity_caps_module?(module, aliases)

  defp entity_caps_grant_call?(
         {{:., _, [_module, :capture]}, _, [module, :grant, _arity]},
         aliases,
         _imported?
       ),
       do: entity_caps_module?(module, aliases)

  defp entity_caps_grant_call?(
         {{:., _, [_module, :apply]}, _, [module, :grant, _args]},
         aliases,
         _
       ),
       do: entity_caps_module?(module, aliases)

  defp entity_caps_grant_call?({:apply, _, [module, :grant, _args]}, aliases, _),
    do: entity_caps_module?(module, aliases)

  defp entity_caps_grant_call?({:grant, _, args}, _aliases, true) when is_list(args), do: true
  defp entity_caps_grant_call?(_node, _aliases, _imported?), do: false

  defp entity_caps_module?(module, aliases) do
    name = Macro.to_string(module)
    name == "Ezagent.EntityCaps" or Map.get(aliases, name) == "Ezagent.EntityCaps"
  end

  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [module, options]} = node, acc when is_list(options) ->
          full = Macro.to_string(module)
          short = options |> Keyword.get(:as, module) |> Macro.to_string()
          {node, Map.put(acc, short, full)}

        {:alias, _, [module]} = node, acc ->
          full = Macro.to_string(module)
          short = full |> String.split(".") |> List.last()
          {node, Map.put(acc, short, full)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp imports_entity_caps?(ast, aliases) do
    count_ast(ast, fn
      {:import, _, [module | _]} -> entity_caps_module?(module, aliases)
      _ -> false
    end) > 0
  end

  defp production_asts do
    cache_key = {__MODULE__, :production_asts}

    case :persistent_term.get(cache_key, :missing) do
      :missing ->
        asts = load_production_asts()
        :persistent_term.put(cache_key, asts)
        asts

      asts ->
        asts
    end
  end

  defp load_production_asts do
    root = repo_root()

    ["apps/**/*.ex", "apps/**/*.exs"]
    |> Enum.flat_map(&(root |> Path.join(&1) |> Path.wildcard()))
    |> Enum.reject(
      &(String.contains?(&1, "/test/") or String.contains?(&1, "/priv/repo/migrations/"))
    )
    |> Enum.map(fn absolute ->
      relative = String.replace_prefix(absolute, root <> "/", "")
      {:ok, ast} = absolute |> File.read!() |> Code.string_to_quoted()
      {relative, ast}
    end)
  end

  defp production_definitions do
    Enum.flat_map(production_asts(), fn {file, ast} -> definitions(ast, file) end)
  end

  defp definitions(ast, file) do
    aliases = aliases(ast)

    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, clauses]} = node, acc when kind in [:def, :defp] and is_list(clauses) ->
          {name, arity} = head_signature(head)

          definition = %{
            file: file,
            name: name,
            arity: arity,
            ast: node,
            body: Keyword.fetch!(clauses, :do),
            aliases: aliases
          }

          {node, [definition | acc]}

        node, acc ->
          {node, acc}
      end)

    if String.ends_with?(file, ".exs") do
      top_level = strip_module_definitions(ast)

      [
        %{
          file: file,
          name: :__script__,
          arity: 0,
          ast: top_level,
          body: top_level,
          aliases: aliases
        }
        | definitions
      ]
    else
      definitions
    end
  end

  defp strip_module_definitions({:__block__, meta, expressions}) do
    {:__block__, meta, Enum.reject(expressions, &match?({:defmodule, _, _}, &1))}
  end

  defp strip_module_definitions({:defmodule, _, _}), do: {:__block__, [], []}
  defp strip_module_definitions(ast), do: ast

  defp definition_bodies(source, name, arity) do
    {:ok, ast} = Code.string_to_quoted(source)

    ast
    |> definitions("source.ex")
    |> Enum.filter(&(&1.name == name and &1.arity == arity))
    |> Enum.map(&Macro.to_string(&1.ast))
  end

  defp head_signature({:when, _, [head | _]}), do: head_signature(head)
  defp head_signature({name, _, args}), do: {name, length(args || [])}

  defp ast_contains?(ast, value), do: count_ast(ast, &(&1 == value)) > 0

  defp count_ast(ast, predicate) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, count ->
        embedded_count =
          if embedded_boundary_code?(node) do
            case Code.string_to_quoted(node) do
              {:ok, embedded} when embedded != node -> count_ast(embedded, predicate)
              _ -> 0
            end
          else
            0
          end

        count = count + embedded_count
        {node, if(predicate.(node), do: count + 1, else: count)}
      end)

    count
  end

  defp embedded_boundary_code?(node) when is_binary(node) do
    Enum.any?(
      [
        "EntityCaps",
        "persist_caps",
        "store_cap",
        "remove_cap",
        "handle_persist_caps",
        "handle_store_cap",
        "handle_remove_cap",
        "vm_internal",
        "Cmd"
      ],
      &String.contains?(node, &1)
    )
  end

  defp embedded_boundary_code?(_node), do: false

  defp source!(relative), do: repo_root() |> Path.join(relative) |> File.read!()

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
