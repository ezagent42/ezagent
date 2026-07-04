defmodule Ezagent.Socialware.ContentHash do
  @moduledoc """
  Deterministic content hash for socialware config bodies (P0 §3.2).

  Canonicalizes a body into a form with **recursive, key-sorted** map ordering,
  with every key stringified, then SHA-256s the JSON encoding (lowercase hex).
  Consequences of the canonical form:

    * the SAME logical body hashes identically regardless of key insertion order;
    * an atom-keyed fresh `Definition.body/1` and its Jason/Ecto round-tripped
      **string-keyed** persisted form produce the SAME hash (the round-trip
      stability the `publish_or_upgrade` `:exists` no-op depends on).

  This module is the **single algorithm source**.
  `Ezagent.Socialware.Definition.content_hash/1` (in `ezagent_domain_session`)
  delegates here: `config_store` lives in `ezagent_domain_identity`, which
  `ezagent_domain_session` depends on — not the reverse — so the shared algorithm
  must live at the identity layer for both `config_store` (populating the stored
  `content_hash` column) and the session-layer idempotency rule to use it.

  Replaces the former non-sorting `json_normalize/1` seed helper
  (`definition_registry.ex`) that imposed no canonical form.
  """

  @doc "Lowercase-hex SHA-256 over the recursively key-sorted canonical form of `body`."
  @spec of(term()) :: String.t()
  def of(body) do
    body
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Maps → a SORTED list of `[stringified_key, canonical(value)]` pairs. Encoding
  # a list (not a map) removes any reliance on Jason's map-iteration order and
  # makes the ordering explicit and recursive. Lists keep their order (order is
  # semantic). Scalars pass through.
  defp canonical(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> [to_string(key), canonical(value)] end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
