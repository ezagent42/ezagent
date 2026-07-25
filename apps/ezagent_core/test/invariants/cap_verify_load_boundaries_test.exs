defmodule Ezagent.Invariants.CapVerifyLoadBoundariesTest do
  @moduledoc """
  S4 I5 gate: storage admission is structural and bounded to the load/store
  homes, while cryptographic verification belongs only to the live target's
  central verifier.

  Boundary #3 is deliberately the durable identity-slice to dispatch-context
  loader. Born-signed artifacts use recipient-aware `storable_for?/2` or
  `verified_set/2` before entering an entity slice. These checks do not claim
  cryptographic authority; the target Kind verifies its own signature at
  dispatch.

  Git task access carries NO in-handler storage-boundary re-scan: every
  `GitTaskAccess` action is cap-gated, so the runtime dispatch verifier
  (`Cap.Verifier.authorize/5`, step 5.5) already strictly crypto-verifies the
  presented receiver-bound artifact before the handler runs. The handler adds
  only the policy-grantee binding (`caller == policy.grantee_uri`); a duplicate
  in-handler `storable_for?`/`signed_for?` check was a forgeable presence-only
  gate and is removed (see AuthorizeChokepointRatchetTest).
  """
  use ExUnit.Case, async: true

  @identity_behavior "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
  @identity_facade "apps/ezagent_domain_identity/lib/ezagent/identity.ex"
  @entity_caps "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex"
  @recipe_cap_binding "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex"
  @outbound_grant "apps/ezagent_domain_identity/lib/ezagent/outbound_grant.ex"
  @snapshot "apps/ezagent_actor/lib/ezagent/kind/snapshot.ex"
  @authority_adapter "apps/ezagent_core/lib/ezagent/kind/adapters/authority_adapter.ex"
  @cap "apps/ezagent_core/lib/ezagent/cap.ex"
  @cli_dispatch "apps/ezagent_cli/lib/ezagent_cli/dispatch.ex"
  @provider_connection "apps/ezagent_domain_provider_connection/lib/ezagent/behavior/provider_connection.ex"

  @storage_homes %{
    @identity_behavior => 3,
    @entity_caps => 1,
    @recipe_cap_binding => 1,
    @outbound_grant => 1,
    # C5 §3.4 AuthorityPort — snapshot's `verified_set` call moved behind the
    # config-resolved port; the core ADAPTER is the reviewed storage-boundary
    # home now (the literal `Cap.verified_set` call lives here).
    @authority_adapter => 1
  }
  @storage_home_count 7

  test "I5 structural storage boundary calls are exact, ratcheted, and at most eight" do
    actual = cap_storage_calls()

    assert actual == @storage_homes,
           "Cap storage checks moved outside the reviewed load boundaries:\n#{inspect(actual, pretty: true)}"

    assert Enum.sum(Map.values(@storage_homes)) == @storage_home_count
    assert @storage_home_count <= 8
  end

  test "I5 named boundaries route through the reviewed verification helpers" do
    assert definition_source(@identity_behavior, :create, 1) =~ "Ezagent.Cap.verified_set"

    assert definition_source(@identity_behavior, :activate, 2) =~
             "reconcile_recipe_binding_state"

    assert definition_source(@identity_behavior, :reconcile_recipe_binding_state, 2) =~
             "Ezagent.Cap.verified_set"

    assert definition_source(@identity_behavior, :handle_grant_cap, 2) =~
             "store_verified_cap"

    assert definition_source(@identity_behavior, :handle_absorb_cap, 2) =~
             "store_verified_cap"

    store = definition_source(@identity_behavior, :store_verified_cap, 3)
    assert store =~ "Ezagent.Cap.storable_for?"
    assert store =~ "set_caps_effect(new_caps)"

    assert definition_source(@identity_behavior, :set_caps_effect, 1) =~
             "{:set, :caps, caps}"

    assert definition_source(@identity_facade, :list_caps_for, 1) =~
             "Ezagent.EntityCaps.load"

    assert definition_source(@identity_facade, :read_held_caps, 1) =~
             "Ezagent.EntityCaps.load"

    assert source(@identity_facade) =~
             "defdelegate read_entity_caps(entity_uri), to: Ezagent.EntityCaps, as: :load"

    refute source(@identity_facade) =~ "defp verified_cap_set"

    entity_caps_verifier = definition_source(@entity_caps, :verified_set, 2)
    assert entity_caps_verifier =~ "Ezagent.Cap.verified_set"

    assert definition_source(@recipe_cap_binding, :validate_artifact, 4) =~
             "Ezagent.Cap.storable_for?"

    assert definition_source(@outbound_grant, :normalize_attrs, 1) =~
             "Ezagent.Cap.storable_for?"

    assert definition_source(@snapshot, :load_with_fallback, 3) =~
             "verify_snapshot_caps(receiver_uri)"

    assert definition_source(@snapshot, :verify_snapshot_caps, 2) =~
             "put_verified_snapshot_caps"

    # C5 §3.4 AuthorityPort — the snapshot load path calls the port; the
    # literal `Cap.verified_set` delegation lives in the core adapter.
    assert definition_source(@snapshot, :put_verified_snapshot_caps, 4) =~
             "authority().verified_set"

    assert definition_source(@authority_adapter, :verified_set, 2) =~
             "Ezagent.Cap.verified_set"

    assert definition_source(@cap, :verified_set, 2) =~ "storable_for?(cap, receiver_uri)"

    verifier = source("apps/ezagent_core/lib/ezagent/cap/verifier.ex")
    assert verifier =~ "Authority.verify_current(cap, presenter)"

    strict_verify_callers =
      source_files()
      |> Enum.filter(fn {_relative, absolute} ->
        File.read!(absolute) =~ "Authority.verify_current("
      end)
      |> Enum.map(&elem(&1, 0))

    assert strict_verify_callers == [
             "apps/ezagent_core/lib/ezagent/cap.ex",
             "apps/ezagent_core/lib/ezagent/cap/verifier.ex"
           ]

    provider_callback =
      definition_source(@provider_connection, :validate_callback_artifact, 2)

    assert provider_callback =~ "Cap.validate_for_current_target"

    narrow_helper = definition_source(@cap, :validate_for_current_target, 2)
    assert narrow_helper =~ "Authority.verify_current(artifact, receiver)"

    assert MapSet.new(narrow_helper_calls()) ==
             MapSet.new([
               {Ezagent.Cap.Authority, :current_target?, 1},
               {Ezagent.Cap.Authority, :target_uri, 1},
               {Ezagent.Cap.Authority, :verify_current, 2},
               {Ezagent.Cap.TargetArtifactValidator, :validate, 2},
               {Ezagent.URI, :stable_key, 1}
             ])
  end

  test "current-target validator scanner rejects every forbidden call category" do
    forbidden = [
      quote(do: Ezagent.Cap.issue(:admin, receiver, artifact)),
      quote(do: Ezagent.Cap.store(artifact, receiver)),
      quote(do: Ezagent.Cap.verified_set([], receiver)),
      quote(do: Ezagent.Cap.absorb(artifact, receiver)),
      quote(do: Ezagent.Router.dispatch(cmd)),
      quote(do: Ezagent.Invocation.dispatch(invocation)),
      quote(do: Ezagent.Cmd.new(target, :read, %{}, %{})),
      quote(do: Ezagent.Capability.matches?(artifact, needed)),
      quote(do: Ezagent.CapabilityRegistry.register(K, :read, B)),
      quote(do: module.invoke(action, args, ctx)),
      quote(do: apply(module, function, args))
    ]

    for ast <- forbidden do
      assert {:error, _call} = validate_current_target_ast(ast)
    end
  end

  test "current-target validator scanner rejects local wrapper and anonymous evasions" do
    evasions = %{
      direct: "Ezagent.Cap.issue(:admin, receiver, artifact)",
      one_hop: "one(artifact)",
      multi_hop: "two(artifact)",
      anonymous: "(fn value -> Ezagent.Cap.store(value, receiver) end).(artifact)",
      capture: "(&Ezagent.Cap.absorb/2).(artifact, receiver)",
      dynamic: "fun = :hidden; apply(__MODULE__, fun, [artifact])"
    }

    for {name, body} <- evasions do
      source = """
      defmodule Controlled#{Macro.camelize(to_string(name))} do
        def validate_for_current_target(artifact, receiver) do
          #{body}
        end

        def one(artifact), do: Ezagent.Router.dispatch(artifact)
        def two(artifact), do: three(artifact)
        def three(artifact), do: Ezagent.Capability.matches?(artifact, %{})
        def hidden(artifact), do: Ezagent.CapabilityRegistry.register(K, :read, artifact)
      end
      """

      assert {:error, _call} =
               source
               |> Code.string_to_quoted!()
               |> scan_current_target()
    end
  end

  test "slice-to-ctx callers use the verified identity loader without filtering inline caps" do
    cli_loader = definition_source(@cli_dispatch, :lookup_identity_caps, 1)
    assert cli_loader =~ "Ezagent.Identity.read_held_caps"
    refute cli_loader =~ "Ezagent.Kind.get_slice"

    runtime = source("apps/ezagent_actor/lib/ezagent/kind/runtime.ex")
    refute runtime =~ "Ezagent.Cap.verified_set"
    # C5 §3.4 AuthzPort — the runtime's step-5.5 authorization goes through
    # the config-resolved port; the literal verifier call lives in the
    # core adapter.
    assert runtime =~ "authz().authorize_dispatch"

    assert source("apps/ezagent_core/lib/ezagent/kind/adapters/authz_adapter.ex") =~
             "Ezagent.Cap.Verifier.authorize"
  end

  test "no matches consumption function also performs verification" do
    violations =
      for {relative, absolute} <- source_files(),
          definition <- definitions(absolute),
          definition =~ "Cap.storable_for?" or definition =~ "Cap.verified_set",
          definition =~ ".matches?",
          do: relative

    assert violations == []
  end

  defp cap_storage_calls do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      count =
        absolute
        |> quoted!()
        |> count_calls(&cap_storage_call?/1)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp cap_storage_call?({{:., _, [module, function]}, _, args})
       when function in [:verified_set, :storable_for?] and is_list(args) and
              length(args) in [1, 2] do
    Macro.to_string(module) in ["Cap", "Ezagent.Cap"]
  end

  defp cap_storage_call?(_node), do: false

  defp count_calls(ast, predicate) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, count ->
        {node, if(predicate.(node), do: count + 1, else: count)}
      end)

    count
  end

  defp narrow_helper_calls do
    @cap
    |> absolute()
    |> quoted!()
    |> scan_current_target()
    |> then(fn {:ok, calls} -> calls end)
  end

  defp scan_current_target(ast) do
    definitions = definition_bodies(ast)

    scan_function(
      {:validate_for_current_target, 2},
      definitions,
      MapSet.new(),
      MapSet.new()
    )
    |> case do
      {:ok, calls, _visited} -> {:ok, calls |> MapSet.to_list() |> Enum.sort()}
      {:error, call} -> {:error, call}
    end
  end

  defp scan_function(signature, definitions, visited, calls) do
    if MapSet.member?(visited, signature) do
      {:ok, calls, visited}
    else
      case Map.fetch(definitions, signature) do
        {:ok, bodies} ->
          scan_nodes(bodies, definitions, MapSet.put(visited, signature), calls)

        :error ->
          {:error, {:unresolved_local, signature}}
      end
    end
  end

  defp scan_nodes(ast, definitions, visited, calls) do
    allowed =
      MapSet.new([
        {Ezagent.Cap.Authority, :current_target?, 1},
        {Ezagent.Cap.Authority, :target_uri, 1},
        {Ezagent.Cap.Authority, :verify_current, 2},
        {Ezagent.Cap.TargetArtifactValidator, :validate, 2},
        {Ezagent.URI, :stable_key, 1}
      ])

    {_ast, result} =
      Macro.prewalk(ast, {:ok, calls, visited}, fn
        node, {:error, _call} = error ->
          {node, error}

        {{:., _, [module_ast, function]}, _, args} = node, {:ok, calls, visited}
        when is_atom(function) and is_list(args) ->
          expanded = Macro.expand(module_ast, __ENV__)
          call = {expanded, function, length(args)}

          cond do
            match?({:fn, _, _}, module_ast) ->
              {node, {:ok, calls, visited}}

            MapSet.member?(allowed, call) ->
              {node, {:ok, MapSet.put(calls, call), visited}}

            is_atom(expanded) ->
              {node, {:error, call}}

            true ->
              {node, {:error, {:dynamic_dispatch, Macro.to_string(node)}}}
          end

        {:&, _, [{:/, _, [{name, _, context}, arity]}]} = node, {:ok, calls, visited}
        when is_atom(name) and is_atom(context) and is_integer(arity) ->
          case scan_function({name, arity}, definitions, visited, calls) do
            {:ok, next_calls, next_visited} -> {node, {:ok, next_calls, next_visited}}
            {:error, call} -> {node, {:error, call}}
          end

        {:apply, _, args} = node, {:ok, _calls, _visited} when is_list(args) ->
          {node, {:error, {Kernel, :apply, length(args)}}}

        {name, _, args} = node, {:ok, calls, visited}
        when is_atom(name) and is_list(args) and name not in [:__block__, :fn, :when, :if] ->
          signature = {name, length(args)}

          if Map.has_key?(definitions, signature) do
            case scan_function(signature, definitions, visited, calls) do
              {:ok, next_calls, next_visited} -> {node, {:ok, next_calls, next_visited}}
              {:error, call} -> {node, {:error, call}}
            end
          else
            if safe_local_form?(signature) do
              {node, {:ok, calls, visited}}
            else
              {node, {:error, {:unresolved_local, signature}}}
            end
          end

        node, state ->
          {node, state}
      end)

    result
  end

  defp safe_local_form?({name, _arity}) do
    name in [
      :if,
      :case,
      :cond,
      :with,
      :->,
      :and,
      :or,
      :not,
      :==,
      :!=,
      :===,
      :!==,
      :<,
      :>,
      :<=,
      :>=,
      :in,
      :is_atom,
      :is_binary,
      :is_list,
      :is_map,
      :is_nil,
      :is_struct,
      :.,
      :__aliases__,
      :%,
      :{}
    ]
  end

  defp definition_bodies(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [do: body]]} = node, definitions when kind in [:def, :defp] ->
          signature = head_signature(head)
          {node, Map.update(definitions, signature, [body], &[body | &1])}

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp validate_current_target_ast(ast) do
    quote do
      defmodule ControlledDirect do
        def validate_for_current_target(artifact, receiver) do
          _ = artifact
          _ = receiver
          unquote(ast)
        end
      end
    end
    |> scan_current_target()
  end

  defp definition_source(relative, name, arity) do
    sources =
      relative
      |> absolute()
      |> definitions()
      |> Enum.filter(fn source -> definition_signature(source) == {name, arity} end)

    assert sources != [], "missing #{name}/#{arity} in #{relative}"
    Enum.join(sources, "\n")
  end

  defp definitions(file) do
    file
    |> quoted!()
    |> then(fn ast ->
      {_ast, defs} =
        Macro.prewalk(ast, [], fn
          {kind, _, [_head, [do: _body]]} = node, defs when kind in [:def, :defp] ->
            {node, [Macro.to_string(node) | defs]}

          node, defs ->
            {node, defs}
        end)

      defs
    end)
  end

  defp definition_signature(source) do
    {:ok, {kind, _, [head, [do: _body]]}} = Code.string_to_quoted(source)
    true = kind in [:def, :defp]
    head_signature(head)
  end

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)
  defp head_signature({name, _, args}) when is_atom(name), do: {name, length(args || [])}

  defp source(relative), do: relative |> absolute() |> File.read!()
  defp absolute(relative), do: Path.join(repo_root(), relative)

  defp source_files do
    root = repo_root()

    root
    |> Path.join("apps/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&{String.replace_prefix(&1, root <> "/", ""), &1})
  end

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
