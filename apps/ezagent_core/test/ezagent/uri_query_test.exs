defmodule Ezagent.UriQueryTest do
  use ExUnit.Case, async: false

  alias Ezagent.UriQuery

  setup do
    attr = :"uri_query_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :ets.delete(UriQuery.table(), attr)
    end)

    %{attr: attr}
  end

  test "resolve/2 fails loud when no resolver is registered", %{attr: attr} do
    assert {:error, {:no_resolver, ^attr}} = UriQuery.resolve(attr, :anything)
  end

  test "register/2 installs a resolver and resolve/2 dispatches to it", %{attr: attr} do
    assert :ok = UriQuery.register(attr, fn arg -> {:ok, {:resolved, arg}} end)

    assert {:ok, {:resolved, "entity://default/agent/cc_demo"}} =
             UriQuery.resolve(attr, "entity://default/agent/cc_demo")
  end

  test "resolve/2 preserves :none distinctly from unregistered resolver", %{attr: attr} do
    assert :ok = UriQuery.register(attr, fn _arg -> :none end)

    assert :none = UriQuery.resolve(attr, :missing)
  end

  test "resolve/2 preserves resolver errors", %{attr: attr} do
    assert :ok = UriQuery.register(attr, fn _arg -> {:error, :bad_entity} end)

    assert {:error, :bad_entity} = UriQuery.resolve(attr, :anything)
  end

  test "register/2 rejects duplicate attr owners", %{attr: attr} do
    assert :ok = UriQuery.register(attr, fn arg -> {:ok, arg} end)

    assert {:error, {:already_registered, ^attr}} =
             UriQuery.register(attr, fn arg -> {:ok, {:other, arg}} end)
  end

  test "resolver return values are constrained to the UriQuery contract", %{attr: attr} do
    assert :ok = UriQuery.register(attr, fn _arg -> :bad_return end)

    assert {:error, {:invalid_resolver_return, :bad_return}} = UriQuery.resolve(attr, :anything)
  end
end
