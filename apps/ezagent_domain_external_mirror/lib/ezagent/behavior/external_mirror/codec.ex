defmodule Ezagent.Behavior.ExternalMirror.Codec do
  @moduledoc """
  Pure data-mapping / opts-codec helpers for the external-mirror binding
  projection. Extracted verbatim from `Ezagent.Behavior.ExternalMirror`
  (#25 Phase-3, PR-3N) to keep the Behavior focused on the Lifecycle
  contract + effect grammar.

  **Pure module.** No DB, no effects, no process state — every function
  is a total transformation over its argument. The Behavior calls these;
  they call nothing back.
  """

  alias Ezagent.ExternalMirror.BindingRow

  @doc """
  Rehydrate a `%BindingRow{}` (the durable projection) into the
  session slice's human-readable binding map.

  The slice's `binding_id` is the session-local human-readable key
  (`"<adapter>/<target>"`) — NOT the DB row's `:id` (a session-scoped
  hash). The `:unbind` action body looks up by the human-readable key,
  so rehydration reconstructs it from `(adapter_id, target_id)` via
  `BindingRow.binding_id/2` rather than reading `row.id`.
  """
  @spec row_to_slice_binding(BindingRow.t()) :: map()
  def row_to_slice_binding(%BindingRow{} = row) do
    %{
      binding_id: BindingRow.binding_id(row.adapter_id, row.target_id),
      adapter_id: row.adapter_id,
      target_id: row.target_id,
      opts: decode_opts(row.opts_json),
      bound_by: Ezagent.URI.new!(row.bound_by),
      bound_at: row.bound_at
    }
  end

  @doc """
  JSON-encode binding-time `opts` for the `:string` `opts_json` column.
  Non-maps and encode failures fall back to the empty-object default.
  """
  @spec encode_opts(term()) :: String.t()
  def encode_opts(opts) when is_map(opts) do
    case Jason.encode(opts) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  def encode_opts(_), do: "{}"

  @doc """
  JSON-decode the `opts_json` column into a **string-keyed** map.

  NO `String.to_atom/1` on JSON-decoded caller-controlled data — the
  previous `atomize_keys` was an unbounded atom-generation DoS vector
  (codex r1 HIGH, 2026-05-25). Adapters that need atom keys MUST convert
  via `String.to_existing_atom/1` against a fixed allowlist (SPEC §6).
  """
  @spec decode_opts(term()) :: map()
  def decode_opts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def decode_opts(_), do: %{}

  @doc """
  True when an `Ecto.Changeset`'s errors carry `constraint: :unique`
  anywhere — the DB-side idempotency signal for a concurrent `:bind`
  on the same natural key. The same triple can fire either the PK
  constraint OR the natural-key unique index depending on race timing;
  both are idempotency cases.
  """
  @spec unique_constraint_violation?(Ecto.Changeset.t()) :: boolean()
  def unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} when is_list(opts) ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end
end
