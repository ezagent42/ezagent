defmodule Ezagent.Cap.AuthorityCache do
  @moduledoc """
  ETS memo of the IMMUTABLE `key_id -> public_key` mapping for per-Kind
  capability authorities.

  A `key_id` (`kind-g<generation>:<fingerprint>`, see
  `Ezagent.Cap.Authority`) binds exactly one public key forever, so a memo
  entry can never be stale and never needs invalidation — entries are
  add-only. There is deliberately **no** mutable `uri -> current authority`
  entry here: the CURRENT `key_id` for a target is always read fresh from the
  DB active row (`Ezagent.Ecto.KindCapAuthority.active/1`), which
  `Authority.regenesis/3` flips atomically in-transaction. That removes the
  stale-PRESENT window a mutable "current" cache would have (MF4(b)) — the
  invariant is "the current key_id is always the committed DB active row; ETS
  holds only immutable-by-construction data."

  The table is owned by `EzagentCore.EtsOwner` (crash-recovery + boot-order
  discipline, mirroring `Ezagent.Cap.DeliveryOutbox`). `public_key/1` reads
  through to the durable authority row on a memo miss, so a cold or just
  re-created table degrades to a DB read, never to a wrong answer.
  """

  alias Ezagent.Ecto.KindCapAuthority

  @table :ezagent_cap_authority_keys

  @doc "ETS table name, owned by `EzagentCore.EtsOwner`."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Fetch the public key bound to `key_id`, reading through to the durable
  authority rows on a memo miss (and memoizing the result).
  """
  @spec public_key(String.t()) :: {:ok, binary()} | :error
  def public_key(key_id) when is_binary(key_id) do
    case :ets.lookup(@table, key_id) do
      [{^key_id, public_key}] -> {:ok, public_key}
      [] -> read_through(key_id)
    end
  rescue
    # Table not yet created (boot ordering) — the durable row is
    # authoritative anyway; degrade to the read-through.
    ArgumentError -> read_through(key_id)
  end

  def public_key(_key_id), do: :error

  @doc """
  Warm the memo from the durable authority rows (boot rehydrate, mirroring
  `Ezagent.Cap.DeliveryOutbox.rehydrate_hints/0`).

  The memo is an optimization only — a miss reads through — so a failed or
  skipped rehydrate (e.g. the test sandbox not yet checked out) is harmless.
  """
  @spec rehydrate() :: :ok
  def rehydrate do
    KindCapAuthority.list_key_material()
    |> Enum.each(fn {key_id, public_key} -> memoize(key_id, public_key) end)

    :ok
  rescue
    _ -> :ok
  end

  defp read_through(key_id) do
    case KindCapAuthority.with_key_id(key_id) do
      %KindCapAuthority{public_key: public_key} ->
        memoize(key_id, public_key)
        {:ok, public_key}

      nil ->
        :error
    end
  rescue
    # Fail-closed: an unreadable authority store yields no key.
    _ -> :error
  end

  defp memoize(key_id, public_key) do
    :ets.insert(@table, {key_id, public_key})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
