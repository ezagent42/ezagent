defmodule Ezagent.Ecto.KindSnapshotDecodeTest do
  @moduledoc """
  Cold-load decode regression (Allen 2026-06-03 — live 传话游戏 e2e).

  `decode_state/1` used `:erlang.binary_to_term(bin, [:safe])`, which rejects
  any atom NOT already in the VM's atom table. Snapshots are framework-
  authored TRUSTED data (our own `term_to_binary` of Kind state) and legitimately
  reference module atoms (`Ezagent.Message`, `Ezagent.Publisher.Event`, …) +
  struct/key atoms. On a COLD restart, a referenced module atom may not be
  loaded at the moment the session decodes → `binary_to_term(:safe)` raises →
  `{:error, :unsafe_atom}` → the PR-4 fail-loud guard refuses to wipe → the
  session can't rehydrate → inbound dispatch returns `:no_such_actor`.

  `:safe` is the wrong tool for trusted internal snapshots (it guards against
  ATOM-TABLE INJECTION from UNTRUSTED input). Fix: decode without `:safe`.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Ecto.KindSnapshot

  # Hand-build an Erlang External Term Format binary for `%{"x" => :<atom>}`
  # where <atom> is a RUNTIME-UNIQUE name never materialised as an Elixir atom
  # literal — so it is guaranteed absent from the atom table, exactly the
  # cold-load condition. Building via bytes (not `String.to_atom`) avoids
  # creating the atom in this test VM.
  defp etf_map_with_fresh_atom do
    name = "coldatom_" <> Integer.to_string(System.unique_integer([:positive]))
    atom_ext = <<119, byte_size(name)::8>> <> name
    key_ext = <<109, 1::32, "x">>
    map_ext = <<116, 1::32>> <> key_ext <> atom_ext
    {<<131>> <> map_ext, name}
  end

  test "the crafted binary's atom is genuinely absent — :safe decode raises (documents the bug)" do
    {bin, _name} = etf_map_with_fresh_atom()

    assert_raise ArgumentError, fn ->
      :erlang.binary_to_term(bin, [:safe])
    end
  end

  test "decode_state succeeds on a trusted snapshot whose atom isn't pre-loaded (cold-load)" do
    {bin, name} = etf_map_with_fresh_atom()
    row = %KindSnapshot{state_binary: bin}

    assert {:ok, decoded} = KindSnapshot.decode_state(row)
    assert decoded["x"] == String.to_atom(name)
  end

  test "decode_state still round-trips a normal map snapshot" do
    state = %{session: %{state: %{messages: []}}, routing: %{calls: 0}}
    row = %KindSnapshot{state_binary: :erlang.term_to_binary(state)}

    assert {:ok, ^state} = KindSnapshot.decode_state(row)
  end
end
