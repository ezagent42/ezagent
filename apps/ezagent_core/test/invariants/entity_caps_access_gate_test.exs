defmodule Ezagent.Invariants.IdentityCapsAccessGateTest do
  @moduledoc """
  D arch gate: inbound entity capabilities cross `Ezagent.IdentityCaps`.

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
                             # PR #1501 — the physical legacy-user adapter now
                             # exposes a tagged checked read so effective-cap
                             # callers can fail closed instead of collapsing a
                             # malformed row to `[]`.
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/user_store.ex",
                              :load_checked, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/user_store.ex",
                              :update_locked, 2},
                             # #189 PR-3 FIX 1 — the POST-epoch Store-first user
                             # path: `read_current_caps/1` READS the current legacy
                             # `caps` (the fun's input) and `write_caps_json_locked/2`
                             # PROJECTS the already-authoritative store set back into
                             # `users.caps_json`. Both are the physical user adapter's
                             # own seam (parallel to `load/1` + `update_locked/2`);
                             # neither mints/grants and a projection failure changes no
                             # authz outcome (reads are store-authoritative post-epoch).
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/user_store.ex",
                              :read_current_caps, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/user_store.ex",
                              :write_caps_json_locked, 2},
                             # #189 PR-1 — the unified identity-caps store is a NEW
                             # physical cap adapter (parallel to `user_store.ex`) for
                             # the `identity_caps` table. Its raw-cap accessors are the
                             # adapter's own storage seam (write-shadow in PR-1; reads
                             # never store-authoritative). codex-reviewed (5 rounds).
                             #
                             # #189 PR-2 (codex spec-review F1): the shadow writer's
                             # `caps_json` write moved OUT of `do_persist/2` into the
                             # status-deciding `persist_changes/3` (the write-boundary
                             # resurrection guard — `active iff current-valid
                             # self-license`). `do_persist/2` no longer touches the
                             # column (it now delegates to the row-locked
                             # `persist_locked/4` → `persist_changes/3`); the raw-cap
                             # seam is `persist_changes/3` instead. Still the adapter's
                             # own storage seam — no new external reader.
                             #
                             # #189 PR-2 (codex IMPL-review finding 1): `update_locked`
                             # gained the `uri` param (arity 3 → 4) so it can route the
                             # transformed set through the SAME `persist_changes/3`
                             # resurrection guard as `persist/2` (it was a bypass: it
                             # wrote caps and left the fresh row on the schema `"active"`
                             # default). It still reads `row.caps_json` for the
                             # transform (hence still on THIS read-side allowlist) but no
                             # longer writes the column directly — see the
                             # `cap_issue_chokepoint` assignment count (8 → 7).
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :activate_changes, 2},
                             # #189 PR-3 FIX 3 — `adopt_absent_authority_history/1`
                             # writes an EMPTY (`caps_json: "[]"`) `revoked_unprovisioned`
                             # row for an authority-history URI with no store row. It
                             # writes NO caps and is strictly absent-only — the adapter's
                             # own storage seam, no new external reader.
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :adopt_absent_authority_history, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :fetch_durable_caps, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :fetch_durable_identities, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :fetch_durable_identity, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :load, 1},
                             # P2 per-cap revocation reads the complete locked
                             # Store set solely to resolve the trusted stored
                             # grant_id before removing it in the same txn.
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :locked_caps, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :persist_changes, 3},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :tombstone, 1},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
                              :update_locked, 4},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                              :gate, 0},
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                              :migrate_users, 1},
                             # #189 PR-2 — the backfill migration + the fleet-parity
                             # barrier READ the legacy user cap set (read-only, via
                             # `Ezagent.Users.list_all/0`) to MIRROR it into the
                             # identity-caps store / verify store↔legacy parity. They
                             # never write `users.caps_json` and change no authz
                             # outcome (reads stay legacy in PR-2). Directly analogous
                             # to `grant_migration.ex :migrate_users/1`.
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/fleet_parity.ex",
                              :legacy_users, 0},
                             # #189 release-runnable cutover extraction — moved from
                             # the (now thin-shell) mix task
                             # `lib/mix/tasks/ezagent.identity.backfill.ex` into the
                             # plain lib module `Ezagent.Identity.Backfill`, so the
                             # backfill WORK runs from a Mix-less release node too.
                             # Same read-only access, same site, new file.
                             {"apps/ezagent_domain_identity/lib/ezagent/identity/backfill.ex",
                              :backfill_users, 1}
                           ])

  # `identity_caps.ex :snapshot_caps/1` is NO LONGER a raw-snapshot reader after
  # actor-extraction C1: it projects the durable `:identity` slice through the
  # public `Ezagent.Kind.read_durable/3` read surface (no `SnapshotStore.latest`
  # + `Map.get(:identity)` reach-in), so it drops off this allowlist.
  @snapshot_identity_caps_allowlist MapSet.new([
                                      {"apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
                                       :rewrite_identity_caps, 1},
                                      {"apps/ezagent_actor/lib/ezagent/kind/snapshot.ex",
                                       :verify_snapshot_caps, 2},
                                      # #189 PR-3 FIX 4 — the Session self-license
                                      # migration writes the minted license into the
                                      # snapshot `:identity` slice (in place). A
                                      # governed one-shot migration row-rewrite,
                                      # analogous to `grant_migration.ex
                                      # :rewrite_identity_caps` — it materializes
                                      # (never authorizes) the caps.
                                      {"apps/ezagent_domain_session/lib/ezagent/socialware/session_self_license_migration.ex",
                                       :rewrite_state, 2}
                                    ])

  @persisted_only_allowlist MapSet.new([
                              {"apps/ezagent_domain_identity/lib/ezagent/entity.ex",
                               :spawn_with_hydrated_caps, 1},
                              {"apps/ezagent_domain_identity/lib/ezagent/entity/user.ex",
                               :initial_caps_for_spawn, 1},
                              # PR #1501 shrank this allowlist: the IdentityCaps
                              # facade now owns the checked persisted/effective
                              # composition, and MemberCap consumes that public
                              # tagged API instead of calling the legacy loader.
                              # `:add_self` can be cast from the grantee's
                              # after-commit hook while that Kind is still busy.
                              # Persisted-only keeps projection convergence
                              # non-blocking while signature + generation
                              # verification remain fail-closed.
                              {"apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex",
                               :authorize_and_add, 4}
                            ])

  test "raw user-cap access stays inside the physical adapter and migration allowlist" do
    assert violations(:raw_user_caps) == @raw_user_caps_allowlist
  end

  test "no executable consumer calls Identity.read_identity_caps/1" do
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
      def bracket_json(row), do: row[:caps_json]
      def embedded_json, do: "row[:caps_json]"
      def indirect_user(uri) do
        %{caps: caps} = U.get_by_uri(uri)
        caps
      end
      def mapped_user(uri), do: U.get_by_uri(uri) |> Map.get(:caps)
      def fetched_user(uri), do: U.get_by_uri(uri) |> Map.fetch!(:caps)
      def nested_user(uri), do: get_in(U.get_by_uri(uri), [:caps])
      def bracket_user(uri), do: U.get_by_uri(uri)[:caps]
      def compatibility(uri), do: I.read_identity_caps(uri)
      def imported_compatibility(uri) do
        import Ezagent.Identity, only: [read_identity_caps: 1]
        read_identity_caps(uri)
      end
      def captured_compatibility, do: &I.read_identity_caps/1
      def function_capture, do: Function.capture(I, :read_identity_caps, 1)
      def applied_compatibility(uri), do: apply(I, :read_identity_caps, [uri])
      def persisted(uri), do: Ezagent.IdentityCaps.load_persisted(uri)

      def snapshot(snapshot) do
        %{state: %{identity: %{state: %{caps: caps}}}} = snapshot
        Map.put(snapshot, :identity, %{caps: MapSet.put(caps, :forged)})
      end

      def dotted_snapshot(state), do: state.identity.caps
      def sourced_snapshot(uri) do
        {:ok, %{state: state}} = Ezagent.SnapshotStore.latest(uri)
        get_in(state, [:identity, :caps])
      end
      def bracket_snapshot(uri) do
        {:ok, %{state: state}} = Ezagent.SnapshotStore.latest(uri)
        state[:identity][:caps]
      end
      def embedded_snapshot(state) do
        Code.eval_string("state[:identity][:caps]", state: state)
      end
      def unrelated_snapshot_words, do: "identity + caps"

      def unrelated_axes(map) do
        Map.get(map, :identity)
        Map.get(map, :caps)
      end
      def unrelated_user(uri) do
        %{caps: caps} = Unrelated.get_by_uri(uri)
        caps
      end
      def unrelated_compatibility(uri), do: Unrelated.read_identity_caps(uri)
      def unrelated_persisted(uri), do: Unrelated.load_persisted(uri)
      def local_compatibility(uri), do: read_identity_caps(uri)
      def local_persisted(uri), do: load_persisted(uri)
      def local_user(uri), do: get_by_uri(uri) |> Map.get(:caps)
      def local_snapshot(uri) do
        state = latest(uri)
        Map.get(state, :identity)
        Map.get(state, :caps)
      end
      def unrelated_snapshot(uri) do
        state = Unrelated.latest(uri)
        Map.get(state, :identity)
        Map.get(state, :caps)
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
               {"bad_caps_consumer.ex", :bracket_json, 1},
               {"bad_caps_consumer.ex", :embedded_json, 0},
               {"bad_caps_consumer.ex", :indirect_user, 1},
               {"bad_caps_consumer.ex", :mapped_user, 1},
               {"bad_caps_consumer.ex", :fetched_user, 1},
               {"bad_caps_consumer.ex", :nested_user, 1},
               {"bad_caps_consumer.ex", :bracket_user, 1}
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
               {"bad_caps_consumer.ex", :sourced_snapshot, 1},
               {"bad_caps_consumer.ex", :bracket_snapshot, 1},
               {"bad_caps_consumer.ex", :embedded_snapshot, 1}
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
      (ast_any?(definition.body, &users_caps_source?(&1, definition)) and
         (ast_any?(definition.body, &user_caps_pattern?/1) or
            ast_any?(definition.body, &caps_access?/1)))
  end

  defp violation?(:identity_compat_consumer, definition),
    do: ast_any?(definition.body, &identity_compat_call?(&1, definition))

  defp violation?(:snapshot_identity_caps, definition) do
    snapshot_identity_shape?(definition.ast) or
      dotted_identity_caps?(definition.ast) or
      (ast_any?(definition.body, &snapshot_source?(&1, definition)) and
         ast_any?(definition.ast, &identity_key_access?/1) and
         ast_any?(definition.ast, &caps_key_access?/1))
  end

  defp violation?(:persisted_only_consumer, definition),
    do:
      ast_any?(
        definition.body,
        &named_call?(&1, :load_persisted, ["Ezagent.IdentityCaps"], definition)
      )

  defp raw_caps_json?({{:., _, [_owner, :caps_json]}, _, []}), do: true
  defp raw_caps_json?({:caps_json, _value}), do: true

  defp raw_caps_json?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!] and is_list(args),
       do:
         Macro.to_string(module) in ["Map", "Access"] and
           Enum.any?(args, &(&1 in [:caps_json, "caps_json"]))

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
       do:
         Macro.to_string(module) in ["Map", "Access"] and
           Enum.any?(args, &(&1 in [:caps, "caps"]))

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

  defp identity_compat_call?(node, definition),
    do: named_call?(node, :read_identity_caps, ["Ezagent.Identity"], definition)

  defp users_caps_source?(node, definition),
    do:
      Enum.any?(
        [:get_by_uri, :list_all, :list_in_workspace],
        &named_call?(node, &1, ["Ezagent.Users"], definition)
      )

  defp named_call?(
         {{:., _, [capture_module, :capture]}, _, [target, name, _arity]},
         name,
         target_modules,
         definition
       ) do
    Macro.to_string(capture_module) == "Function" and
      target_module?(target, target_modules, definition.aliases)
  end

  defp named_call?(
         {:&, _, [{:/, _, [{{:., _, [target, name]}, _, []}, _arity]}]},
         name,
         target_modules,
         definition
       ),
       do: target_module?(target, target_modules, definition.aliases)

  defp named_call?(
         {{:., _, [apply_module, :apply]}, _, [target, name, _args]},
         name,
         target_modules,
         definition
       ) do
    Macro.to_string(apply_module) == "Kernel" and
      target_module?(target, target_modules, definition.aliases)
  end

  defp named_call?(
         {:apply, _, [target, name, _args]},
         name,
         target_modules,
         definition
       ),
       do: target_module?(target, target_modules, definition.aliases)

  defp named_call?(
         {{:., _, [module, name]}, _, args},
         name,
         target_modules,
         definition
       )
       when is_list(args),
       do: target_module?(module, target_modules, definition.aliases)

  defp named_call?({name, _, args}, name, target_modules, definition) when is_list(args),
    do:
      Enum.any?(target_modules, fn target_module ->
        MapSet.member?(definition.imports, target_module) or
          MapSet.member?(definition.modules, target_module)
      end)

  defp named_call?(_node, _name, _target_modules, _definition), do: false

  defp target_module?(module, target_modules, aliases) do
    module_name = Macro.to_string(module)
    resolved = Map.get(aliases, module_name, module_name)
    resolved in target_modules
  end

  defp snapshot_identity_shape?(ast),
    do: nested_identity_caps?(ast) or bracket_identity_caps?(ast)

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

  defp bracket_identity_caps?(ast) do
    ast_any?(ast, fn
      {{:., _, [module, :get]}, _, [owner, key]}
      when key in [:caps, "caps"] ->
        Macro.to_string(module) == "Access" and
          ast_any?(owner, fn
            {{:., _, [inner_module, :get]}, _, [_source, inner_key]}
            when inner_key in [:identity, "identity"] ->
              Macro.to_string(inner_module) == "Access"

            _ ->
              false
          end)

      _ ->
        false
    end)
  end

  defp dotted_identity_caps?(ast) do
    ast_any?(ast, fn
      {{:., _, [owner, :caps]}, _, []} -> ast_any?(owner, &identity_dot?/1)
      _ -> false
    end)
  end

  defp identity_dot?({{:., _, [_owner, :identity]}, _, []}), do: true
  defp identity_dot?(_node), do: false

  defp snapshot_source?(node, definition) do
    named_call?(node, :latest, ["Ezagent.SnapshotStore"], definition) or
      named_call?(node, :decode_state, ["Ezagent.Ecto.KindSnapshot"], definition)
  end

  defp identity_key_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!, :put, :update] and is_list(args),
       do:
         Macro.to_string(module) in ["Map", "Access"] and
           Enum.any?(args, &(&1 in [:identity, "identity"]))

  defp identity_key_access?({:identity, _value}), do: true
  defp identity_key_access?({{:., _, [_owner, :identity]}, _, []}), do: true

  defp identity_key_access?({:get_in, _, [_source, path]}) when is_list(path),
    do: :identity in path or "identity" in path

  defp identity_key_access?(_node), do: false

  defp caps_key_access?({{:., _, [module, function]}, _, args})
       when function in [:get, :fetch, :fetch!, :put, :update] and is_list(args),
       do:
         Macro.to_string(module) in ["Map", "Access"] and
           Enum.any?(args, &(&1 in [:caps, "caps"]))

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
    known_boundary? =
      Enum.any?(
        ["Ezagent.", "read_identity_caps", "load_persisted", "caps_json", "SnapshotStore"],
        &String.contains?(node, &1)
      )

    raw_snapshot_shape? = String.contains?(node, "identity") and String.contains?(node, "caps")
    known_boundary? or raw_snapshot_shape?
  end

  defp embedded_code_candidate?(_node), do: false

  defp source_definitions do
    root = repo_root()

    ["apps/**/*.ex", "apps/**/*.exs"]
    |> Enum.flat_map(&(root |> Path.join(&1) |> Path.wildcard()))
    |> Enum.reject(
      &(String.contains?(&1, "/test/") or String.contains?(&1, "/priv/repo/migrations/") or
          EzagentCore.AstScan.tmp_fixture?(&1))
    )
    |> Enum.flat_map(fn absolute ->
      relative = String.replace_prefix(absolute, root <> "/", "")
      source = File.read!(absolute)
      definitions = definitions_from_source(source, relative)

      if String.ends_with?(relative, ".exs") do
        {:ok, ast} = Code.string_to_quoted(source)
        top_level = strip_module_definitions(ast)
        metadata = ast |> strip_function_definitions() |> definition_metadata()

        [
          %{
            file: relative,
            name: :__script__,
            arity: 0,
            ast: top_level,
            body: top_level,
            aliases: metadata.aliases,
            imports: metadata.imports,
            modules: metadata.modules
          }
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
    base_metadata = ast |> strip_function_definitions() |> definition_metadata()

    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, clauses]} = node, acc
        when kind in [:def, :defp] and is_list(clauses) ->
          {name, arity} = head_signature(head)
          body = Keyword.fetch!(clauses, :do)
          metadata = merge_metadata(base_metadata, definition_metadata(node))

          definition = %{
            file: file,
            name: name,
            arity: arity,
            ast: node,
            body: body,
            aliases: metadata.aliases,
            imports: metadata.imports,
            modules: metadata.modules
          }

          {node, [definition | acc]}

        node, acc ->
          {node, acc}
      end)

    definitions
  end

  defp definition_metadata(ast) do
    aliases = aliases(ast)

    imports =
      ast
      |> imports()
      |> Enum.map(fn module -> Map.get(aliases, module, module) end)
      |> MapSet.new()

    %{aliases: aliases, imports: imports, modules: modules(ast)}
  end

  defp merge_metadata(base, local) do
    %{
      aliases: Map.merge(base.aliases, local.aliases),
      imports: MapSet.union(base.imports, local.imports),
      modules: MapSet.union(base.modules, local.modules)
    }
  end

  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [prefix, :{}]}, _, suffixes}]} = node, acc
        when is_list(suffixes) ->
          prefix = Macro.to_string(prefix)

          aliases =
            Enum.reduce(suffixes, acc, fn suffix, aliases ->
              short = Macro.to_string(suffix)
              Map.put(aliases, short, prefix <> "." <> short)
            end)

          {node, aliases}

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

  defp modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:defmodule, _, [module, _body]} = node, acc ->
          {node, MapSet.put(acc, Macro.to_string(module))}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  defp strip_function_definitions(ast) do
    Macro.prewalk(ast, fn
      {kind, _, [_head, clauses]} when kind in [:def, :defp] and is_list(clauses) ->
        {:__block__, [], []}

      node ->
        node
    end)
  end

  defp imports(ast) do
    {_ast, imports} =
      Macro.prewalk(ast, [], fn
        {:import, _, [module | _]} = node, acc ->
          {node, [Macro.to_string(module) | acc]}

        node, acc ->
          {node, acc}
      end)

    imports
  end

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)
  defp head_signature({name, _, args}) when is_atom(name), do: {name, length(args || [])}

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
