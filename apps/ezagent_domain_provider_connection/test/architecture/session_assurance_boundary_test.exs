defmodule Ezagent.ProviderConnection.SessionAssuranceBoundaryTest do
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.ProviderConnection

  @app_root Path.expand("../..", __DIR__)
  @behavior_path Path.join(@app_root, "lib/ezagent/behavior/provider_connection.ex")
  @unavailable_path Path.join(
                      @app_root,
                      "lib/ezagent/provider_connection/unavailable_session_assurance_verifier.ex"
                    )

  test "production source has no runtime assurance-verifier configuration" do
    forbidden_keys = [:assurance_validator, :session_assurance_verifier]

    findings =
      @app_root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> Code.string_to_quoted!(file: path)
        |> application_env_keys()
        |> Enum.filter(&(&1 in forbidden_keys))
        |> Enum.map(&{path, &1})
      end)

    assert findings == []
  end

  test "the non-test compile branch calls only the hard-wired unavailable verifier" do
    ast = @behavior_path |> File.read!() |> Code.string_to_quoted!(file: @behavior_path)
    {test_branch, production_branch} = assurance_compile_branches(ast)

    unavailable_call =
      {Ezagent.ProviderConnection.UnavailableSessionAssuranceVerifier, :verify_and_consume, 3}

    dynamic_call =
      {Ezagent.ProviderConnection.SessionAssuranceVerifier, :verify_and_consume, 5}

    assert exact_production_verifier_branch?(production_branch)
    refute contains_atom?(production_branch, :test_session_assurance_verifier)

    {:defp, metadata, [head, [do: body]]} = production_branch

    assert {{:., call_metadata, [_receiver, :verify_and_consume]}, invoke_metadata, body_args} =
             body

    refute exact_production_verifier_branch?(
             {:defp, metadata, [head, [do: {:__block__, [], [body]}]]}
           )

    dynamic_body =
      {{:., call_metadata, [{:verifier, [], nil}, :verify_and_consume]}, invoke_metadata,
       body_args}

    refute exact_production_verifier_branch?({:defp, metadata, [head, [do: dynamic_body]]})

    anonymous_body = {{:., call_metadata, [{:verifier, [], nil}]}, invoke_metadata, body_args}
    refute exact_production_verifier_branch?({:defp, metadata, [head, [do: anonymous_body]]})

    assert unavailable_call in remote_calls(test_branch)
    assert dynamic_call in remote_calls(test_branch)
    assert contains_atom?(test_branch, :test_session_assurance_verifier)
  end

  test "the unavailable verifier has one exact closed result and no alternate implementation" do
    ast = @unavailable_path |> File.read!() |> Code.string_to_quoted!(file: @unavailable_path)

    definitions = public_function_asts(ast, :verify_and_consume)
    assert exact_unavailable_verifier_definitions?(definitions)

    three = Enum.find(definitions, &(definition_arity(&1) == 3))
    {:def, metadata, [head, [do: body]]} = three

    refute exact_unavailable_verifier_definitions?(
             List.replace_at(
               definitions,
               Enum.find_index(definitions, &(&1 == three)),
               {:def, metadata, [head, [do: {:__block__, [], [body]}]]}
             )
           )

    refute exact_unavailable_verifier_definitions?(
             List.replace_at(
               definitions,
               Enum.find_index(definitions, &(&1 == three)),
               {:def, metadata,
                [head, [do: {{:., [], [{:verifier, [], nil}]}, [], [nil, :a, :b, :c]}]]}
             )
           )

    assert {:error, :assurance_validation_unavailable} =
             Ezagent.ProviderConnection.UnavailableSessionAssuranceVerifier.verify_and_consume(
               :poison_action,
               %{poison: "secret"},
               %{poison: "secret"}
             )
  end

  test "verification context is built only from authenticated invocation coordinates" do
    ast = @behavior_path |> File.read!() |> Code.string_to_quoted!(file: @behavior_path)

    authenticated_calls =
      ast
      |> local_call_arguments(:assurance_verification_context)
      |> Enum.filter(fn
        [
          {:owner, _, _},
          {:workspace, _, _},
          {{:., _, [{:__aliases__, _, [:Map]}, :fetch!]}, _, [{:ctx, _, _}, :caller]},
          {:args, _, _},
          {:now, _, _}
        ] ->
          true

        _other ->
          false
      end)

    assert length(authenticated_calls) == 1

    assert [%{body: context_body}] =
             private_function_definitions(ast, :assurance_verification_context)

    refute contains_atom?(context_body, :assurance)
    assert Enum.count(remote_calls(context_body), &match?({Map, :fetch!, 2}, &1)) == 2
  end

  test "registered reachability is explicitly four live and three deferred" do
    deferred = [:reauthorize, :revoke, :disconnect]
    live = [:begin_authorization, :consume_callback, :refresh, :read_connection]

    assert ProviderConnection.actions() |> Enum.sort() == Enum.sort(deferred ++ live)

    for action <- deferred do
      assert ProviderConnection.__action_spec__(action).description =~ "Deferred in D1"
    end

    for action <- live do
      refute ProviderConnection.__action_spec__(action).description =~ "Deferred in D1"
    end
  end

  defp application_env_keys(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_module, function]}, _, args} = node, keys
        when function in [:get_env, :fetch_env, :fetch_env!] and is_list(args) ->
          {node, Enum.filter(args, &is_atom/1) ++ keys}

        {function, _, args} = node, keys
        when function in [:get_env, :fetch_env, :fetch_env!] and is_list(args) ->
          {node, Enum.filter(args, &is_atom/1) ++ keys}

        node, keys ->
          {node, keys}
      end)

    keys
  end

  defp assurance_compile_branches(ast) do
    {_ast, branches} =
      Macro.prewalk(ast, nil, fn
        {:if, _, [condition, options]} = node, nil ->
          if test_condition?(condition) do
            {node, {Keyword.fetch!(options, :do), Keyword.fetch!(options, :else)}}
          else
            {node, nil}
          end

        node, branches ->
          {node, branches}
      end)

    case branches do
      {test_branch, production_branch} -> {test_branch, production_branch}
      nil -> flunk("missing compile-time Mix.env() == :test assurance branch")
    end
  end

  defp test_condition?({:==, _, [{{:., _, [{:__aliases__, _, [:Mix]}, :env]}, _, []}, :test]}),
    do: true

  defp test_condition?(_condition), do: false

  defp exact_production_verifier_branch?(
         {:defp, _,
          [
            {:invoke_session_assurance_verifier, _,
             [action, assurance, verification_context, {:_ctx, _, _}]},
            [
              do:
                {{:., _,
                  [
                    {:__aliases__, _,
                     [
                       :Ezagent,
                       :ProviderConnection,
                       :UnavailableSessionAssuranceVerifier
                     ]},
                    :verify_and_consume
                  ]}, _, [body_action, body_assurance, body_verification_context]}
            ]
          ]}
       ) do
    same_variable?(action, body_action) and
      same_variable?(assurance, body_assurance) and
      same_variable?(verification_context, body_verification_context)
  end

  defp exact_production_verifier_branch?(_branch), do: false

  defp exact_unavailable_verifier_definitions?(definitions) when length(definitions) == 2 do
    Enum.count(definitions, &exact_unavailable_three?/1) == 1 and
      Enum.count(definitions, &exact_unavailable_four?/1) == 1
  end

  defp exact_unavailable_verifier_definitions?(_definitions), do: false

  defp exact_unavailable_three?(
         {:def, _,
          [
            {:verify_and_consume, _, [action, assurance, context]},
            [do: {:verify_and_consume, _, [nil, body_action, body_assurance, body_context]}]
          ]}
       ) do
    same_variable?(action, body_action) and
      same_variable?(assurance, body_assurance) and same_variable?(context, body_context)
  end

  defp exact_unavailable_three?(_definition), do: false

  defp exact_unavailable_four?(
         {:def, _,
          [
            {:verify_and_consume, _, [state, action, assurance, context]},
            [do: {:error, :assurance_validation_unavailable}]
          ]}
       ) do
    Enum.all?([state, action, assurance, context], &ignored_variable?/1)
  end

  defp exact_unavailable_four?(_definition), do: false

  defp same_variable?({name, _, context}, {name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp same_variable?(_left, _right), do: false

  defp ignored_variable?({name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: name |> Atom.to_string() |> String.starts_with?("_")

  defp ignored_variable?(_variable), do: false

  defp remote_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, function]}, _, args} = node, calls
        when is_list(parts) and is_atom(function) and is_list(args) ->
          {node, [{Module.concat(parts), function, length(args)} | calls]}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp public_function_asts(ast, expected_name) do
    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{^expected_name, _, args}, [do: _body]]} = node, definitions
        when is_list(args) ->
          {node, [node | definitions]}

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp definition_arity({:def, _, [{_name, _, args}, [do: _body]]}), do: length(args)

  defp private_function_definitions(ast, expected_name) do
    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {:defp, _, [{^expected_name, _, args}, [do: body]]} = node, definitions
        when is_list(args) ->
          {node, [%{arity: length(args), body: body} | definitions]}

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp local_call_arguments(ast, expected_name) do
    {_ast, arguments} =
      Macro.prewalk(ast, [], fn
        {^expected_name, _, args} = node, arguments when is_list(args) ->
          {node, [args | arguments]}

        node, arguments ->
          {node, arguments}
      end)

    arguments
  end

  defp contains_atom?(ast, expected) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        ^expected = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end
end
