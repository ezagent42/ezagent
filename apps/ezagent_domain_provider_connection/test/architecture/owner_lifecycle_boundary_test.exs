defmodule Ezagent.ProviderConnection.OwnerLifecycleBoundaryTest do
  use ExUnit.Case, async: true

  @store_path Path.expand(
                "../../lib/ezagent/provider_connection/store.ex",
                __DIR__
              )

  @lifecycle_helpers MapSet.new([
                       :before_begin_settle,
                       :begin_attempt_changeset,
                       :begin_authorization,
                       :callback_artifact_digest,
                       :callback_correlation,
                       :cancel_begin_reservation,
                       :cancel_terminal_begin_reservation,
                       :digest,
                       :fetch_string,
                       :initial_scope_matches?,
                       :insert_begin_attempt,
                       :insert_initial_reservation,
                       :lock_cancelled_attempt,
                       :lock_connection_key,
                       :lock_open_attempt,
                       :reconcile_cancelled_or_insert_initial,
                       :reconcile_cancelled_or_insert_reauthorization,
                       :reconcile_initial_reservation,
                       :reconcile_or_insert_reauthorization,
                       :reservation_digest,
                       :reserve_initial_begin,
                       :reserve_reauthorization,
                       :settle_initial_begin,
                       :settle_reauthorization,
                       :settle_terminal_begin_failure,
                       :unwrap_begin_settle,
                       :unwrap_transaction
                     ])

  test "Store is a one-call facade for authorization lifecycle commands" do
    ast = parse(@store_path)

    assert ast |> execute_body(:begin_authorization) |> Macro.to_string() ==
             "OwnerLifecycle.begin_authorization(args, ctx)"

    assert ast |> execute_body(:reauthorize) |> Macro.to_string() ==
             "OwnerLifecycle.reauthorize(args, ctx)"
  end

  test "Store does not own authorization reservation or settlement helpers" do
    store_private_functions = @store_path |> parse() |> private_function_names()

    assert MapSet.disjoint?(store_private_functions, @lifecycle_helpers),
           "Store still owns lifecycle helpers: #{inspect(MapSet.intersection(store_private_functions, @lifecycle_helpers))}"
  end

  defp parse(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path, columns: true)
  end

  defp execute_body(ast, action) do
    {_ast, body} =
      Macro.prewalk(ast, nil, fn
        {:def, _meta, [{:execute, _call_meta, [^action, _args, _ctx]}, [do: body]]} = node, nil ->
          {node, body}

        node, body ->
          {node, body}
      end)

    body
  end

  defp private_function_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:defp, _meta, [head | _rest]} = node, names ->
          {node, MapSet.put(names, function_name(head))}

        node, names ->
          {node, names}
      end)

    names
  end

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)
  defp function_name({name, _meta, _args}) when is_atom(name), do: name
end
