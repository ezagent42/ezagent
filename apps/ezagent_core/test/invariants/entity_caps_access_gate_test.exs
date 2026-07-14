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
                              :migrate_users, 1}
                           ])

  @snapshot_identity_caps_allowlist MapSet.new([
                                      {"apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
                                       :snapshot_caps, 1},
                                      {"apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
                                       :put_identity_caps, 2},
                                      {"apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
                                       :update_snapshot_locked, 2},
                                      {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                                       :rewrite_identity_caps, 1},
                                      {"apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_backfill.ex",
                                       :identity_caps, 1},
                                      {"apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
                                       :verify_snapshot_caps, 2},
                                      {"apps/ezagent_core/lib/ezagent/kind/snapshot.ex",
                                       :put_verified_snapshot_caps, 4}
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
      def indirect_user(uri) do
        %{caps: caps} = U.get_by_uri(uri)
        caps
      end
      def compatibility(uri), do: I.read_entity_caps(uri)
      def imported_compatibility(uri) do
        import Ezagent.Identity, only: [read_entity_caps: 1]
        read_entity_caps(uri)
      end
      def captured_compatibility, do: &I.read_entity_caps/1
      def persisted(uri), do: Ezagent.EntityCaps.load_persisted(uri)

      def snapshot(snapshot) do
        %{state: %{identity: %{state: %{caps: caps}}}} = snapshot
        Map.put(snapshot, :identity, %{caps: MapSet.put(caps, :forged)})
      end

      def dotted_snapshot(state), do: state.identity.caps
    end
    """

    definitions = definitions_from_source(fixture, "bad_caps_consumer.ex")

    assert violation_functions(definitions, :raw_user_caps) ==
             MapSet.new([
               {"bad_caps_consumer.ex", :user, 1},
               {"bad_caps_consumer.ex", :indirect_user, 1}
             ])

    assert violation_functions(definitions, :identity_compat_consumer) ==
             MapSet.new([
               {"bad_caps_consumer.ex", :compatibility, 1},
               {"bad_caps_consumer.ex", :imported_compatibility, 1},
               {"bad_caps_consumer.ex", :captured_compatibility, 0}
             ])

    assert violation_functions(definitions, :snapshot_identity_caps) ==
             MapSet.new([
               {"bad_caps_consumer.ex", :snapshot, 1},
               {"bad_caps_consumer.ex", :dotted_snapshot, 1}
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
            ast_any?(definition.body, &dot_caps_access?/1)))
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
  defp raw_caps_json?(_node), do: false

  defp user_caps_pattern?({:%{}, _, fields}) when is_list(fields) do
    case Keyword.fetch(fields, :caps) do
      {:ok, {_name, _meta, context}} when is_atom(context) or is_nil(context) -> true
      _ -> false
    end
  end

  defp user_caps_pattern?(_node), do: false

  defp dot_caps_access?({{:., _, [_owner, :caps]}, _, []}), do: true
  defp dot_caps_access?(_node), do: false

  defp identity_compat_call?(node), do: named_call?(node, :read_entity_caps)

  defp users_caps_source?(node),
    do: Enum.any?([:get_by_uri, :list_all, :list_in_workspace], &named_call?(node, &1))

  defp named_call?({{:., _, [_module, name]}, _, args}, name) when is_list(args), do: true
  defp named_call?({name, _, args}, name) when is_list(args), do: true
  defp named_call?(_node, _name), do: false

  defp snapshot_identity_shape?(ast) do
    identity_shape? =
      ast_any?(ast, fn
        {:identity, _value} -> true
        node -> map_key_mutation?(node, :identity)
      end)

    caps_shape? =
      ast_any?(ast, fn
        {:caps, _value} -> true
        _node -> false
      end)

    identity_shape? and caps_shape?
  end

  defp map_key_mutation?({{:., _, [module, function]}, _, args}, key)
       when function in [:put, :update] and is_list(args),
       do: Macro.to_string(module) == "Map" and key in args

  defp map_key_mutation?(_node, _key), do: false

  defp dotted_identity_caps?(ast) do
    ast_any?(ast, fn
      {{:., _, [{{:., _, [_state, :identity]}, _, []}, :caps]}, _, []} -> true
      _ -> false
    end)
  end

  defp snapshot_source?(node),
    do: Enum.any?([:latest, :decode_state], &named_call?(node, &1))

  defp identity_key_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :put, :update] and is_list(args),
       do: Macro.to_string(module) == "Map" and :identity in args

  defp identity_key_access?({:identity, _value}), do: true
  defp identity_key_access?({{:., _, [_owner, :identity]}, _, []}), do: true
  defp identity_key_access?(_node), do: false

  defp caps_key_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :put, :update] and is_list(args),
       do: Macro.to_string(module) == "Map" and :caps in args

  defp caps_key_access?({:caps, _value}), do: true
  defp caps_key_access?({{:., _, [_owner, :caps]}, _, []}), do: true
  defp caps_key_access?({:caps_from_slice, _, _args}), do: true
  defp caps_key_access?(_node), do: false

  defp ast_any?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end

  defp source_definitions do
    root = repo_root()

    root
    |> Path.join("apps/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.flat_map(fn absolute ->
      relative = String.replace_prefix(absolute, root <> "/", "")
      absolute |> File.read!() |> definitions_from_source(relative)
    end)
  end

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
