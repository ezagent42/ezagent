defmodule EzagentCli.FacadeRegistryTest do
  use ExUnit.Case, async: false

  alias EzagentCli.FacadeRegistry

  setup do
    FacadeRegistry.init_table()
    :ok
  end

  test "register/4 + lookup/2 round-trip" do
    op = :"create-#{System.unique_integer([:positive])}"
    fun = fn _parsed -> {:ok, :done} end
    spec = %{args: [name: :string], opts: [], about: "test"}

    assert :ok = FacadeRegistry.register(:test_kind, op, fun, spec)
    assert {:ok, ^fun, ^spec} = FacadeRegistry.lookup(:test_kind, op)
  end

  test "lookup returns :error for unknown op" do
    assert :error =
             FacadeRegistry.lookup(:test_kind, :"never-#{System.unique_integer([:positive])}")
  end

  test "G-1 registers the cap revoke-all operator verb" do
    assert {:ok, fun, %{args: [target: :uri]}} =
             FacadeRegistry.lookup(:cap, :revoke_all_to)

    assert is_function(fun, 1)
  end

  test "list/1 returns ops for one kind" do
    kind = :"list-#{System.unique_integer([:positive])}"
    FacadeRegistry.register(kind, :alpha, fn _ -> :ok end, %{about: "a"})
    FacadeRegistry.register(kind, :beta, fn _ -> :ok end, %{about: "b"})

    ops = FacadeRegistry.list(kind) |> Enum.map(fn {op, _, _} -> op end)
    assert ops == [:alpha, :beta]
  end

  test "list_kinds/0 returns all registered kind types" do
    kind = :"lk-#{System.unique_integer([:positive])}"
    FacadeRegistry.register(kind, :op, fn _ -> :ok end, %{})

    assert kind in FacadeRegistry.list_kinds()
  end
end
