defmodule Ezagent.Invariants.EntityCapsAccessGateTest do
  @moduledoc """
  D arch gate: inbound entity capabilities cross `Ezagent.EntityCaps`.

  Existing physical SSOT adapters and explicit migration/core-framework code
  remain visible in a function-level allowlist. New application consumers may
  not read/write `users.caps_json`, call the retired Identity compatibility
  surface, or reach into snapshot `:identity` caps directly.
  """
  use ExUnit.Case, async: true

  @raw_user_caps_allowlist MapSet.new([
                             {"apps/ezagent_domain_identity/lib/ezagent/users.ex", :do_create, 4},
                             {"apps/ezagent_domain_identity/lib/ezagent/users.ex",
                              :create_read_only, 2},
                             {"apps/ezagent_domain_identity/lib/ezagent/users.ex", :decode, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/entity_caps/user_store.ex",
                              :load, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/entity_caps/user_store.ex",
                              :update_locked, 2},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_backfill.ex",
                              :user_candidates, 0},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                              :gate, 0},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                              :migrate_users, 1},
                             {"apps/ezagent_plugin_world/lib/ezagent/world/user_data.ex",
                              :list_users, 1},
                             {"apps/ezagent_plugin_world/lib/ezagent/world/user_data.ex",
                              :detail_state, 4}
                           ])

  @snapshot_identity_caps_allowlist MapSet.new([
                                      {"apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
                                       :snapshot_caps, 1},
                                      {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                                       :rewrite_identity_caps, 1},
                                      {"apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_backfill.ex",
                                       :identity_caps, 1},
                                      {"apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
                                       :verify_snapshot_caps, 2}
                                    ])

  @persisted_only_allowlist MapSet.new([
                              {"apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex", :load,
                               1},
                              {"apps/ezagent_domain_identity/lib/ezagent/entity.ex",
                               :spawn_with_hydrated_caps, 1},
                              {"apps/ezagent_domain_identity/lib/ezagent/entity/user.ex",
                               :initial_caps_for_spawn, 1},
                              {"apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex",
                               :member_snapshot_caps, 1}
                            ])

  test "raw user-cap access stays inside the physical adapter and migration allowlist" do
    assert violations(:raw_user_caps) == @raw_user_caps_allowlist
  end

  test "no executable consumer calls Identity.read_entity_caps/1" do
    assert violations(:identity_compat_consumer) == MapSet.new()
  end

  test "raw snapshot identity-cap access stays in facade, migrations, or core snapshot verification" do
    assert violations(:snapshot_identity_caps) == @snapshot_identity_caps_allowlist
  end

  test "persisted-only loader stays limited to lifecycle and non-blocking handler seams" do
    assert violations(:persisted_only_consumer) == @persisted_only_allowlist
  end

  test "adversarial executable fixtures are rejected by every gate leg" do
    fixture = """
    defmodule BadCapsConsumer do
      alias Ezagent.Identity, as: I
      alias Ezagent.Users, as: U

      def user(row), do: row.caps_json
      def mapped_json(row), do: Map.get(row, :caps_json)
      def fetched_json(row), do: Map.fetch!(row, :caps_json)
      def nested_json(row), do: get_in(row, [:caps_json])
      def applied_json(row), do: apply(Map, :get, [row, :caps_json])
      def indirect_user(uri) do
        %{caps: caps} = U.get_by_uri(uri)
        caps
      end
      def mapped_user(uri), do: U.get_by_uri(uri) |> Map.get(:caps)
      def fetched_user(uri), do: U.get_by_uri(uri) |> Map.fetch!(:caps)
      def nested_user(uri), do: get_in(U.get_by_uri(uri), [:caps])
      def compatibility(uri), do: I.read_entity_caps(uri)
      def imported_compatibility(uri) do
        import Ezagent.Identity, only: [read_entity_caps: 1]
        read_entity_caps(uri)
      end
      def captured_compatibility, do: &I.read_entity_caps/1
      def function_capture, do: Function.capture(I, :read_entity_caps, 1)
      def applied_compatibility(uri), do: apply(I, :read_entity_caps, [uri])
      def persisted(uri), do: Ezagent.EntityCaps.load_persisted(uri)

      def snapshot(snapshot) do
        %{state: %{identity: %{state: %{caps: caps}}}} = snapshot
        Map.put(snapshot, :identity, %{caps: MapSet.put(caps, :forged)})
      end

      def dotted_snapshot(state), do: state.identity.caps
      def sourced_snapshot(uri) do
        {:ok, %{state: state}} = Ezagent.SnapshotStore.latest(uri)
        get_in(state, [:identity, :caps])
      end

      def unrelated_axes(map) do
        Map.get(map, :identity)
        Map.get(map, :caps)
      end
    end
    """

    definitions = definitions_from_source(fixture, "bad_caps_consumer.ex")

    assert violation_functions(definitions, :raw_user_caps) ==
             MapSet.new([
               {"bad_caps_consumer.ex", :user, 1},
               {"bad_caps_consumer.ex", :mapped_json, 1},
               {"bad_caps_consumer.ex", :fetched_json, 1},
               {"bad_caps_consumer.ex", :nested_json, 1},
               {"bad_caps_consumer.ex", :applied_json, 1},
               {"bad_caps_consumer.ex", :indirect_user, 1},
               {"bad_caps_consumer.ex", :mapped_user, 1},
               {"bad_caps_consumer.ex", :fetched_user, 1},
               {"bad_caps_consumer.ex", :nested_user, 1}
             ])

    assert violation_functions(definitions, :identity_compat_consumer) ==
             MapSet.new([
               {"bad_caps_consumer.ex", :compatibility, 1},
               {"bad_caps_consumer.ex", :imported_compatibility, 1},
               {"bad_caps_consumer.ex", :captured_compatibility, 0},
               {"bad_caps_consumer.ex", :function_capture, 0},
               {"bad_caps_consumer.ex", :applied_compatibility, 1}
             ])

    assert violation_functions(definitions, :snapshot_identity_caps) ==
             MapSet.new([
               {"bad_caps_consumer.ex", :snapshot, 1},
               {"bad_caps_consumer.ex", :dotted_snapshot, 1},
               {"bad_caps_consumer.ex", :sourced_snapshot, 1}
             ])

    assert violation_functions(definitions, :persisted_only_consumer) ==
             MapSet.new([{"bad_caps_consumer.ex", :persisted, 1}])
  end

  defp violations(kind) do
    source_definitions()
    |> violation_functions(kind)
  end

  defp violation_functions(definitions, kind) do
    definitions
    |> Enum.filter(&violation?(kind, &1))
    |> Enum.map(&{&1.file, &1.name, &1.arity})
    |> MapSet.new()
  end

  defp violation?(:raw_user_caps, definition) do
    ast_any?(definition.ast, &raw_caps_json?/1) or
      (ast_any?(definition.body, &users_caps_source?/1) and
         (ast_any?(definition.body, &user_caps_pattern?/1) or
            ast_any?(definition.body, &caps_access?/1)))
  end

  defp violation?(:identity_compat_consumer, definition),
    do: ast_any?(definition.body, &identity_compat_call?/1)

  defp violation?(:snapshot_identity_caps, definition) do
    snapshot_identity_shape?(definition.ast) or
      dotted_identity_caps?(definition.ast) or
      (ast_any?(definition.body, &snapshot_source?/1) and
         ast_any?(definition.ast, &identity_key_access?/1) and
         ast_any?(definition.ast, &caps_key_access?/1))
  end

  defp violation?(:persisted_only_consumer, definition),
    do: ast_any?(definition.body, &named_call?(&1, :load_persisted))

  defp raw_caps_json?({{:., _, [_owner, :caps_json]}, _, []}), do: true
  defp raw_caps_json?({:caps_json, _value}), do: true

  defp raw_caps_json?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!] and is_list(args),
       do:
         Macro.to_string(module) == "Map" and Enum.any?(args, &(&1 in [:caps_json, "caps_json"]))

  defp raw_caps_json?({:get_in, _, [_source, path]}) when is_list(path),
    do: Enum.any?(path, &(&1 in [:caps_json, "caps_json"]))

  defp raw_caps_json?({{:., _, [_kernel, :apply]}, _, [module, function, args]}),
    do: map_apply_with_key?(module, function, args, :caps_json)

  defp raw_caps_json?({:apply, _, [module, function, args]}),
    do: map_apply_with_key?(module, function, args, :caps_json)

  defp raw_caps_json?(_node), do: false

  defp user_caps_pattern?({:%{}, _, fields}) when is_list(fields) do
    case Keyword.fetch(fields, :caps) do
      {:ok, {_name, _meta, context}} when is_atom(context) or is_nil(context) -> true
      _ -> false
    end
  end

  defp user_caps_pattern?(_node), do: false

  defp caps_access?({{:., _, [_owner, :caps]}, _, []}), do: true

  defp caps_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!] and is_list(args),
       do: Macro.to_string(module) == "Map" and Enum.any?(args, &(&1 == :caps))

  defp caps_access?({:get_in, _, [_source, path]}) when is_list(path),
    do: Enum.any?(path, &(&1 in [:caps, "caps"]))

  defp caps_access?({{:., _, [_kernel, :apply]}, _, [module, function, args]}),
    do: map_apply_with_key?(module, function, args, :caps)

  defp caps_access?({:apply, _, [module, function, args]}),
    do: map_apply_with_key?(module, function, args, :caps)

  defp caps_access?(node), do: user_caps_pattern?(node)

  defp map_apply_with_key?(module, function, args, key) do
    Macro.to_string(module) == "Map" and function in [:get, :fetch, :fetch!] and is_list(args) and
      Enum.any?(args, &(&1 in [key, Atom.to_string(key)]))
  end

  defp identity_compat_call?(node), do: named_call?(node, :read_entity_caps)

  defp users_caps_source?(node),
    do: Enum.any?([:get_by_uri, :list_all, :list_in_workspace], &named_call?(node, &1))

  defp named_call?({{:., _, [_module, :capture]}, _, [_target, name, _arity]}, name), do: true
  defp named_call?({{:., _, [_module, :apply]}, _, [_target, name, _args]}, name), do: true
  defp named_call?({:apply, _, [_target, name, _args]}, name), do: true
  defp named_call?({{:., _, [_module, name]}, _, args}, name) when is_list(args), do: true
  defp named_call?({name, _, args}, name) when is_list(args), do: true
  defp named_call?(_node, _name), do: false

  defp snapshot_identity_shape?(ast), do: nested_identity_caps?(ast)

  defp nested_identity_caps?(ast) do
    ast_any?(ast, fn
      {:identity, value} -> ast_any?(value, &caps_key_access?/1)
      node -> map_key_mutation_with_caps?(node)
    end)
  end

  defp map_key_mutation_with_caps?({{:., _, [module, function]}, _, args})
       when function in [:put, :update] and is_list(args) do
    Macro.to_string(module) == "Map" and :identity in args and
      Enum.any?(args, &ast_any?(&1, fn node -> caps_key_access?(node) end))
  end

  defp map_key_mutation_with_caps?(_node), do: false

  defp dotted_identity_caps?(ast) do
    ast_any?(ast, fn
      {{:., _, [owner, :caps]}, _, []} -> ast_any?(owner, &identity_dot?/1)
      _ -> false
    end)
  end

  defp identity_dot?({{:., _, [_owner, :identity]}, _, []}), do: true
  defp identity_dot?(_node), do: false

  defp snapshot_source?(node),
    do: Enum.any?([:latest, :decode_state], &named_call?(node, &1))

  defp identity_key_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!, :put, :update] and is_list(args),
       do: Macro.to_string(module) == "Map" and :identity in args

  defp identity_key_access?({:identity, _value}), do: true
  defp identity_key_access?({{:., _, [_owner, :identity]}, _, []}), do: true

  defp identity_key_access?({:get_in, _, [_source, path]}) when is_list(path),
    do: :identity in path or "identity" in path

  defp identity_key_access?(_node), do: false

  defp caps_key_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!, :put, :update] and is_list(args),
       do: Macro.to_string(module) == "Map" and :caps in args

  defp caps_key_access?({:caps, _value}), do: true
  defp caps_key_access?({{:., _, [_owner, :caps]}, _, []}), do: true

  defp caps_key_access?({:get_in, _, [_source, path]}) when is_list(path),
    do: :caps in path or "caps" in path

  defp caps_key_access?({:caps_from_slice, _, _args}), do: true
  defp caps_key_access?(_node), do: false

  defp ast_any?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        embedded_found? =
          if embedded_code_candidate?(node) do
            case Code.string_to_quoted(node) do
              {:ok, embedded} when embedded != node -> ast_any?(embedded, predicate)
              _ -> false
            end
          else
            false
          end

        {node, found? or predicate.(node) or embedded_found?}
      end)

    found?
  end

  defp embedded_code_candidate?(node) when is_binary(node) do
    Enum.any?(
      ["Ezagent.", "read_entity_caps", "load_persisted", "caps_json", "SnapshotStore"],
      &String.contains?(node, &1)
    )
  end

  defp embedded_code_candidate?(_node), do: false

  defp source_definitions do
    root = repo_root()

    ["apps/**/*.ex", "apps/**/*.exs"]
    |> Enum.flat_map(&(root |> Path.join(&1) |> Path.wildcard()))
    |> Enum.reject(
      &(String.contains?(&1, "/test/") or String.contains?(&1, "/priv/repo/migrations/"))
    )
    |> Enum.flat_map(fn absolute ->
      relative = String.replace_prefix(absolute, root <> "/", "")
      source = File.read!(absolute)
      definitions = definitions_from_source(source, relative)

      if String.ends_with?(relative, ".exs") do
        {:ok, ast} = Code.string_to_quoted(source)
        top_level = strip_module_definitions(ast)

        [
          %{file: relative, name: :__script__, arity: 0, ast: top_level, body: top_level}
          | definitions
        ]
      else
        definitions
      end
    end)
  end

  defp strip_module_definitions({:__block__, meta, expressions}) do
    {:__block__, meta, Enum.reject(expressions, &match?({:defmodule, _, _}, &1))}
  end

  defp strip_module_definitions({:defmodule, _, _}), do: {:__block__, [], []}
  defp strip_module_definitions(ast), do: ast

  defp definitions_from_source(source, file) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, clauses]} = node, acc
        when kind in [:def, :defp] and is_list(clauses) ->
          {name, arity} = head_signature(head)
          body = Keyword.fetch!(clauses, :do)
          definition = %{file: file, name: name, arity: arity, ast: node, body: body}
          {node, [definition | acc]}

        node, acc ->
          {node, acc}
      end)

    definitions
  end

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)
  defp head_signature({name, _, args}) when is_atom(name), do: {name, length(args || [])}

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
