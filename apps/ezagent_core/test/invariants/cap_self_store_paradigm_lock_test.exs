defmodule Ezagent.Invariants.CapSelfStoreParadigmLockTest do
  @moduledoc """
  S6/S7 I12 paradigm lock.

  Capability authority moves issuer -> artifact, while storage moves only
  through the grantee's own lifecycle (`create/1`) or the VM-internal
  `absorb_cap` cast.  Existing, not-yet-migrated grant drivers are pinned as
  shrink-only debt; all three Phase-3 cold-agent cutovers are zero-tolerance.
  """
  use ExUnit.Case, async: true

  @identity_facade "apps/ezagent_domain_identity/lib/ezagent/identity.ex"
  @identity_behavior "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
  @grant_chokepoint "apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex"
  @recipe_grant_task "apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex"
  @orchestrator_caps "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex"
  @composition_caps "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex"
  @workspace_facade "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex"
  @cap_delivery_schema "apps/ezagent_core/lib/ezagent/cap/delivery.ex"
  @cap_delivery_envelope "apps/ezagent_core/lib/ezagent/cap/delivery_outbox/envelope.ex"
  @cap_verifier "apps/ezagent_core/lib/ezagent/cap/verifier.ex"
  @config_evolve "apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex"
  @target_authority "apps/ezagent_domain_identity/lib/ezagent/identity/target_authority.ex"
  @host_login_adopt "apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex"

  @legacy_grant_drivers %{
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex" => %{
      {:grant_cap_via_router, 4} => 1
    },
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex" => %{
      {:grant_cap_via_router, 4} => 2
    },
    "apps/ezagent_domain_session/lib/ezagent/behavior/template.ex" => %{
      {:grant_cap, 3} => 1
    },
    "apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex" => %{
      {:grant_cap, 3} => 1
    },
    "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex" => %{
      {:grant_cap, 3} => 1
    },
    "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex" => %{
      {:grant_cap_via_router, 4} => 1
    },
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex" =>
      %{{:grant_cap, 3} => 4},
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex" => %{
      {:grant_cap_effect, 3} => 1
    },
    "apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignments.ex" => %{
      {:grant_cap, 3} => 1
    },
    "apps/ezagent_plugin_world/lib/ezagent/world/layout_bootstrap.ex" => %{{:grant_cap, 3} => 1},
    "apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex" => %{
      {:grant_cap_via_router, 4} => 1
    }
  }
  @legacy_driver_files 11
  @legacy_driver_sites 15

  @legacy_local_grant_drivers %{}

  @recipe_cutover_files [
    @recipe_grant_task,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex"
  ]

  @absorb_producers %{
    @grant_chokepoint => %{{:absorb_cap, 2} => 1},
    @config_evolve => %{{:absorb_cap, 2} => 2},
    @recipe_grant_task => %{{:absorb_cap, 2} => 1},
    @orchestrator_caps => %{{:absorb_cap, 2} => 1},
    @composition_caps => %{{:absorb_cap, 2} => 1},
    @workspace_facade => %{{:absorb_cap, 2} => 1},
    @target_authority => %{{:absorb_cap, 2} => 1},
    @host_login_adopt => %{{:absorb_cap, 2} => 1}
  }

  @absorb_action_literals %{
    @grant_chokepoint => 1,
    @cap_delivery_schema => 2,
    @cap_delivery_envelope => 6,
    @cap_verifier => 1,
    @config_evolve => 2,
    @recipe_grant_task => 1,
    @orchestrator_caps => 1,
    @composition_caps => 1,
    @identity_behavior => 3,
    @identity_facade => 2,
    @workspace_facade => 1,
    @target_authority => 1,
    @host_login_adopt => 1
  }

  test "remaining issuer-driven grant sites are shrink-only migration debt" do
    actual =
      grant_driver_calls()
      |> Map.drop([@identity_facade, @grant_chokepoint])

    assert actual == @legacy_grant_drivers,
           "I12 grant-driver ratchet changed; migrate sites to issue + self-store, never widen:\n#{inspect(actual, pretty: true)}"

    assert map_size(@legacy_grant_drivers) == @legacy_driver_files
    assert fingerprint_site_count(@legacy_grant_drivers) == @legacy_driver_sites
    assert local_grant_driver_calls() == @legacy_local_grant_drivers
    assert restricted_driver_imports() == %{}
  end

  test "the compatibility facade remains one internal edge, not an external grant site" do
    assert Map.take(grant_driver_calls(), [@identity_facade]) == %{
             @identity_facade => %{{:grant_cap, 3} => 1}
           }
  end

  test "aliases, imports, captures, and apply cannot evade the grant-driver fingerprint" do
    {:ok, ast} =
      Code.string_to_quoted("""
      alias Ezagent.Identity.Grant
      alias Ezagent.Identity, as: IdentityFacade
      Grant.grant_cap(target, cap, auth)
      IdentityFacade.grant_cap(target, cap, issuer)
      import Ezagent.Identity.Grant
      apply(Ezagent.Identity.Grant, :grant_cap, [target, cap, auth])
      dynamic_args = [target, cap, auth]
      Kernel.apply(Ezagent.Identity.Grant, :grant_cap, dynamic_args)
      Function.capture(Ezagent.Identity.Grant, :grant_cap, 3)
      &Ezagent.Identity.Grant.grant_cap/3
      """)

    fingerprints = call_fingerprints(ast, &grant_driver_fingerprint/1)

    assert fingerprints[{:grant_cap, 3}] == 2
    assert fingerprints[{:grant_cap, {:apply, 3}}] == 1
    assert fingerprints[{:grant_cap, {:apply, :dynamic_arity}}] == 1
    assert fingerprints[{:grant_cap, {:capture, 3}}] == 1
    assert fingerprints[{:grant_cap, 0}] == 1
    assert count_ast(ast, &restricted_driver_import?/1) == 1

    {:ok, imported_call_ast} =
      Code.string_to_quoted("""
      alias Ezagent.Identity.Grant, as: G
      import G
      defp imported_driver(target, cap, auth), do: grant_cap(target, cap, auth)
      defp imported_capture, do: &grant_cap/3
      """)

    assert definition_body_fingerprints(imported_call_ast, "grant_cap") == %{
             {:grant_cap, 3} => 1,
             {:grant_cap, {:capture, 3}} => 1
           }
  end

  test "recipe cutover has zero issuer-to-grantee grant dispatches" do
    calls = grant_driver_calls()

    assert Map.take(calls, @recipe_cutover_files) == %{}

    definition_agents = source!(Enum.at(@recipe_cutover_files, 1))
    refute definition_agents =~ "GrantRecipeCaps.grant_recipe_caps"
  end

  test "S7 orchestrator and workspace cold-agent lanes issue-all before self-store" do
    orchestrator =
      @orchestrator_caps
      |> source!()
      |> definition_source(:do_grant_orchestrator_scoped_caps, 4)

    assert ordered?(orchestrator, "issue_scoped_caps", "absorb_scoped_caps")
    refute orchestrator =~ "Identity.Grant"
    refute orchestrator =~ "mode: :call"
    refute orchestrator =~ "await_ready"

    workspace =
      @workspace_facade
      |> source!()
      |> definition_source(:issue_and_absorb_initial_caps, 3)

    assert ordered?(workspace, "<- issue_initial_caps(", "<- absorb_initial_caps(")
    refute workspace =~ "Identity.Grant"
    refute workspace =~ "mode: :call"
    refute workspace =~ "await_ready"
  end

  test "absorb dispatch is constructed exactly once by the identity self-store facade" do
    assert absorb_cmd_constructors() == %{@identity_facade => 1}
    assert absorb_target_constructors() == %{@identity_facade => 1}
    assert absorb_cmd_new_constructors() == %{}
    assert absorb_struct_constructors() == %{}
    assert absorb_literal_target_constructors() == %{}
    assert direct_absorb_handler_calls() == %{}
    assert absorb_action_literals() == @absorb_action_literals
    assert absorb_producer_calls() == @absorb_producers
    assert local_absorb_producer_calls() == %{}

    body = definition_source(source!(@identity_facade), :absorb_cap, 2)

    assert body =~ "Ezagent.URI.instance"
    assert body =~ "Ezagent.URI.with_action"
    assert body =~ "caller: :vm_internal"
    assert body =~ "mode: :cast"
    assert body =~ "reply: :ignore"
    assert body =~ "Router.dispatch"
    refute body =~ "await_ready"
    refute body =~ "mode: :call"
    refute body =~ "Invocation.dispatch"

    producer =
      definition_source(source!(@recipe_grant_task), :issue_and_absorb_recipe_caps, 4)

    assert ordered?(producer, "issue_all", "absorb_all")

    operator = definition_source(source!(@recipe_grant_task), :do_grant, 2)

    assert ordered?(
             operator,
             "issue_and_absorb_recipe_caps",
             "CapAbsorbAwait.await_exact"
           )

    orchestrator =
      definition_source(source!(@orchestrator_caps), :do_grant_orchestrator_scoped_caps, 4)

    assert ordered?(orchestrator, "issue_scoped_caps", "absorb_scoped_caps")

    workspace =
      @workspace_facade
      |> source!()
      |> definition_source(:issue_and_absorb_initial_caps, 3)

    assert ordered?(workspace, "<- issue_initial_caps(", "<- absorb_initial_caps(")

    {:ok, dynamic_apply_ast} =
      Code.string_to_quoted("""
      args = [target, artifact]
      apply(Ezagent.Identity, :absorb_cap, args)
      Function.capture(Ezagent.Identity, :absorb_cap, 2)
      """)

    assert call_fingerprints(dynamic_apply_ast, &absorb_producer_fingerprint/1) == %{
             {:absorb_cap, {:apply, :dynamic_arity}} => 1,
             {:absorb_cap, {:capture, 2}} => 1
           }
  end

  test "the verified caps writer has exactly the legacy-grant and absorb callers" do
    source = source!(@identity_behavior)
    grant = definition_source(source, :handle_grant_cap, 2)
    absorb = definition_source(source, :handle_absorb_cap, 2)

    assert grant =~ "store_verified_cap"
    assert absorb =~ "store_verified_cap"

    assert length(Regex.scan(~r/\bstore_verified_cap\(/, source)) == 3,
           "store_verified_cap must have exactly two callers plus its definition"
  end

  test "product code cannot bypass guarded pending-delivery ingress or loud drains" do
    assert unguarded_pending_delivery_calls() == %{},
           "PendingDelivery.buffer/2 and flush/1 are legacy/test-only; product ingress must be incarnation-guarded and drains must pass ReadyTransition DLQ handling"
  end

  test "the pending-delivery scanner catches aliased local and dynamic escape calls" do
    {:ok, ast} =
      Code.string_to_quoted("""
      defmodule Escape do
        alias Ezagent.PendingDelivery, as: PD
        import PD, only: [buffer: 2, flush: 1]

        def bypass(uri, invocation), do: buffer(uri, invocation)
        def silent_drop(uri), do: flush(uri)
        def dynamic_drop(uri), do: apply(PD, :flush, [uri])
        def capture_drop, do: Function.capture(PD, :flush, 1)
      end
      """)

    assert pending_delivery_escape_fingerprints(ast) == %{
             {:buffer, 2} => 1,
             {:flush, 1} => 1,
             {:flush, {:apply, 1}} => 1,
             {:flush, {:capture, 1}} => 1,
             {:pending_delivery_import, 0} => 1
           }
  end

  defp grant_driver_calls do
    fingerprints_by_file(&grant_driver_fingerprint/1)
  end

  defp local_grant_driver_calls do
    "grant_cap"
    |> definition_body_fingerprints_by_file()
    |> Map.drop([@identity_facade, @grant_chokepoint])
  end

  defp grant_driver_fingerprint({{:., _, [_module, :capture]}, _, [_target, function, arity]})
       when is_atom(function) do
    if String.starts_with?(Atom.to_string(function), "grant_cap") do
      {function, captured_arity(arity)}
    end
  end

  defp grant_driver_fingerprint({{:., _, [_kernel, :apply]}, _, [_module, function, args]})
       when is_atom(function) do
    if String.starts_with?(Atom.to_string(function), "grant_cap") do
      {function, applied_arity(args)}
    end
  end

  defp grant_driver_fingerprint({{:., _, [_module_ast, function]}, _, args})
       when is_atom(function) and is_list(args) do
    # Deliberately match by remote function fingerprint rather than spelling
    # the module. `alias Ezagent.Identity.Grant, as: Driver` must not evade the
    # ledger by changing only the receiver token.
    if String.starts_with?(Atom.to_string(function), "grant_cap") do
      {function, length(args)}
    end
  end

  defp grant_driver_fingerprint({:apply, _, [_module, function, args]})
       when is_atom(function) do
    if String.starts_with?(Atom.to_string(function), "grant_cap") do
      {function, applied_arity(args)}
    end
  end

  defp grant_driver_fingerprint(_node), do: nil

  defp restricted_driver_imports do
    count_by_file(&restricted_driver_import?/1)
  end

  defp restricted_driver_import?({:import, _, [module_ast | _options]}) do
    Macro.to_string(module_ast) in ["Ezagent.Identity", "Ezagent.Identity.Grant"]
  end

  defp restricted_driver_import?(_node), do: false

  defp absorb_producer_calls do
    fingerprints_by_file(&absorb_producer_fingerprint/1)
  end

  defp local_absorb_producer_calls do
    definition_body_fingerprints_by_file("absorb_cap")
  end

  defp absorb_producer_fingerprint(
         {{:., _, [_module, :capture]}, _, [_target, :absorb_cap, arity]}
       ),
       do: {:absorb_cap, captured_arity(arity)}

  defp absorb_producer_fingerprint({{:., _, [_module_ast, :absorb_cap]}, _, args})
       when is_list(args),
       do: {:absorb_cap, length(args)}

  defp absorb_producer_fingerprint({{:., _, [_kernel, :apply]}, _, [_module, :absorb_cap, args]}),
    do: {:absorb_cap, applied_arity(args)}

  defp absorb_producer_fingerprint({:apply, _, [_module, :absorb_cap, args]}),
    do: {:absorb_cap, applied_arity(args)}

  defp absorb_producer_fingerprint(_node), do: nil

  defp absorb_cmd_constructors do
    count_by_file(fn
      {:%, _, [_struct, {:%{}, _, fields}]} when is_list(fields) ->
        Keyword.get(fields, :action) == :absorb_cap

      _node ->
        false
    end)
  end

  defp absorb_target_constructors do
    count_by_file(fn
      {{:., _, [module_ast, :with_action]}, _, [_target, :identity, :absorb_cap]} ->
        Macro.to_string(module_ast) in ["Ezagent.URI", "URI"]

      _node ->
        false
    end)
  end

  defp absorb_cmd_new_constructors do
    count_by_file(fn
      {{:., _, [_module_ast, :new]}, _, [_target, :absorb_cap | _rest]} -> true
      _node -> false
    end)
  end

  defp absorb_struct_constructors do
    count_by_file(fn
      {:struct, _, [_module_ast, fields]} when is_list(fields) ->
        Keyword.get(fields, :action) == :absorb_cap

      _node ->
        false
    end)
  end

  defp absorb_action_literals do
    count_by_file(&(&1 == :absorb_cap))
  end

  defp absorb_literal_target_constructors do
    count_by_file(fn
      literal when is_binary(literal) ->
        String.contains?(literal, "action=identity.absorb_cap") or
          String.contains?(literal, "action=_.absorb_cap")

      _node ->
        false
    end)
  end

  defp direct_absorb_handler_calls do
    count_by_file(fn
      {{:., _, [_module_ast, :handle_absorb_cap]}, _, args} when is_list(args) -> true
      _node -> false
    end)
  end

  defp unguarded_pending_delivery_calls do
    source_files()
    |> Enum.filter(fn {_relative, absolute} ->
      File.read!(absolute) =~ "PendingDelivery"
    end)
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      fingerprints = absolute |> quoted!() |> pending_delivery_escape_fingerprints()
      if map_size(fingerprints) == 0, do: acc, else: Map.put(acc, relative, fingerprints)
    end)
  end

  defp pending_delivery_escape_fingerprints(ast) do
    remote =
      call_fingerprints(ast, fn
        {{:., _, [_module, function]}, _, args}
        when function in [:buffer, :flush] and is_list(args) ->
          {function, length(args)}

        {{:., _, [_module, :capture]}, _, [_target, function, arity]}
        when function in [:buffer, :flush] ->
          {function, captured_arity(arity)}

        {{:., _, [_kernel, :apply]}, _, [_module, function, args]}
        when function in [:buffer, :flush] ->
          {function, applied_arity(args)}

        {:apply, _, [_module, function, args]} when function in [:buffer, :flush] ->
          {function, applied_arity(args)}

        _node ->
          nil
      end)

    import_count = pending_delivery_import_count(ast)

    if import_count == 0 do
      remote
    else
      local =
        ast
        |> definition_body_fingerprints("buffer")
        |> merge_frequencies(definition_body_fingerprints(ast, "flush"))

      remote
      |> merge_frequencies(local)
      |> Map.put({:pending_delivery_import, 0}, import_count)
    end
  end

  defp pending_delivery_import_count(ast) do
    {_ast, {_aliases, imports}} =
      Macro.prewalk(ast, {%{}, 0}, fn
        {:alias, _, [target_ast | opts]} = node, {aliases, imports} ->
          target = target_ast |> Macro.to_string() |> expand_alias(aliases)
          alias_name = alias_name(target, opts)
          {node, {Map.put(aliases, alias_name, target), imports}}

        {:import, _, [module_ast | _opts]} = node, {aliases, imports} ->
          module = module_ast |> Macro.to_string() |> expand_alias(aliases)
          count = if module == "Ezagent.PendingDelivery", do: imports + 1, else: imports
          {node, {aliases, count}}

        node, state ->
          {node, state}
      end)

    imports
  end

  defp alias_name(target, opts) do
    case opts do
      [[as: as_ast]] -> Macro.to_string(as_ast)
      _ -> target |> String.split(".") |> List.last()
    end
  end

  defp expand_alias(module, aliases) do
    case String.split(module, ".", parts: 2) do
      [prefix, suffix] -> Map.get(aliases, prefix, prefix) <> "." <> suffix
      [prefix] -> Map.get(aliases, prefix, prefix)
    end
  end

  defp count_by_file(predicate) do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      count = absolute |> quoted!() |> count_ast(predicate)
      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp fingerprints_by_file(fingerprint_fn) do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      fingerprints = absolute |> quoted!() |> call_fingerprints(fingerprint_fn)
      if map_size(fingerprints) == 0, do: acc, else: Map.put(acc, relative, fingerprints)
    end)
  end

  defp definition_body_fingerprints_by_file(prefix) do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      fingerprints = absolute |> quoted!() |> definition_body_fingerprints(prefix)
      if map_size(fingerprints) == 0, do: acc, else: Map.put(acc, relative, fingerprints)
    end)
  end

  # Scan only function bodies so a local function definition such as
  # `def grant_cap/3` is not mistaken for a dispatch. This closes the alias +
  # import escape hatch: once imported, `grant_cap(...)` has no remote receiver
  # left for the global call scanner to fingerprint.
  defp definition_body_fingerprints(ast, prefix) do
    {_ast, frequencies} =
      Macro.prewalk(ast, %{}, fn
        {kind, _meta, [_head, body]} = node, frequencies
        when kind in [:def, :defp] and is_list(body) ->
          body_frequencies =
            body
            |> Keyword.get(:do)
            |> call_fingerprints(&local_call_fingerprint(&1, prefix))

          {node,
           Map.merge(frequencies, body_frequencies, fn _fingerprint, left, right ->
             left + right
           end)}

        node, frequencies ->
          {node, frequencies}
      end)

    frequencies
  end

  defp local_call_fingerprint(
         {:&, _meta, [{:/, _, [{function, _, _context}, arity]}]},
         prefix
       )
       when is_atom(function) and is_integer(arity) do
    if String.starts_with?(Atom.to_string(function), prefix) do
      {function, {:capture, arity}}
    end
  end

  defp local_call_fingerprint({function, _meta, args}, prefix)
       when is_atom(function) and is_list(args) do
    if String.starts_with?(Atom.to_string(function), prefix) do
      {function, length(args)}
    end
  end

  defp local_call_fingerprint(_node, _prefix), do: nil

  defp applied_arity(args) when is_list(args), do: {:apply, length(args)}
  defp applied_arity(_args), do: {:apply, :dynamic_arity}

  defp captured_arity(arity) when is_integer(arity), do: {:capture, arity}
  defp captured_arity(_arity), do: {:capture, :dynamic_arity}

  defp call_fingerprints(ast, fingerprint_fn) do
    {_ast, frequencies} =
      Macro.prewalk(ast, %{}, fn node, frequencies ->
        case fingerprint_fn.(node) do
          nil -> {node, frequencies}
          fingerprint -> {node, Map.update(frequencies, fingerprint, 1, &(&1 + 1))}
        end
      end)

    frequencies
  end

  defp merge_frequencies(left, right) do
    Map.merge(left, right, fn _fingerprint, left_count, right_count ->
      left_count + right_count
    end)
  end

  defp fingerprint_site_count(by_file) do
    by_file
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.sum()
  end

  defp ordered?(source, first, second) do
    case {:binary.match(source, first), :binary.match(source, second)} do
      {{first_at, _}, {second_at, _}} -> first_at < second_at
      _ -> false
    end
  end

  defp count_ast(ast, predicate) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, count ->
        {node, if(predicate.(node), do: count + 1, else: count)}
      end)

    count
  end

  defp definition_source(source, name, arity) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {kind, _meta, [head, _body]} = node, nil when kind in [:def, :defp] ->
          if definition_head?(head, name, arity) do
            {node, Macro.to_string(node)}
          else
            {node, nil}
          end

        node, found ->
          {node, found}
      end)

    found || flunk("#{name}/#{arity} not found")
  end

  defp definition_head?({:when, _, [head | _guards]}, name, arity),
    do: definition_head?(head, name, arity)

  defp definition_head?({name, _, args}, name, arity) when is_list(args),
    do: length(args) == arity

  defp definition_head?(_head, _name, _arity), do: false

  defp source_files do
    root = repo_root()

    root
    |> Path.join("apps/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&{String.replace_prefix(&1, root <> "/", ""), &1})
  end

  defp source!(relative), do: repo_root() |> Path.join(relative) |> File.read!()

  defp quoted!(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{file}: #{inspect(reason)}"
    end
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
