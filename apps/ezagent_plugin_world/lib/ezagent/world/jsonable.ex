defmodule Ezagent.World.Jsonable do
  @moduledoc false
  # #83-style cohesive extraction out of WorldLive (keeps world_live.ex under the
  # oversized_modules_gt_1000 gate). Pure, recursive JSON-safe coercion — turns
  # arbitrary BEAM terms (URIs, structs, maps, tuples, pids, …) into values the
  # SPA can serialize. No socket/assigns dependency; thin-delegated from WorldLive.
  #
  # TOTALITY CONTRACT: `to_json/1` must never raise, and its result must always
  # be `Jason.encode!`-able. This is a shared serialization boundary for the
  # operator-observability streams (audit / cc_event / operator_event), which
  # fan out to every connected operator LiveView — a single un-encodable term
  # would otherwise crash-loop those sockets. The totality hazards handled
  # explicitly: non-string / invalid-UTF-8 map keys (`safe_key/1`), invalid-UTF-8
  # binary values and URI output (`utf8_or_inspect/2`), and improper lists
  # (`proper_list?/1`). All fallbacks are `inspect/1`, which is total.
  #
  # MONOTONICITY: any term that was already coercible to encodable JSON produces
  # byte-identical output; only terms that previously RAISED / produced
  # un-encodable output change (they now inspect-fallback).

  @doc false
  # URI host/path are user-controlled and can carry invalid UTF-8 → validate the
  # rendered string, inspect-fallback if it isn't valid UTF-8. The `rescue` also
  # covers a type-malformed struct (`%URI{host: non-binary}` / `port: non-int`),
  # which makes `URI.to_string/1` itself raise — unreachable with real data
  # (`Ezagent.URI.new!` / `URI.parse` always yield binary|nil host + int|nil
  # port), but keeps the totality contract literally true.
  def to_json(%URI{} = uri) do
    utf8_or_inspect(URI.to_string(uri), uri)
  rescue
    _ -> inspect(uri)
  end

  def to_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def to_json(%_struct{} = struct), do: struct |> Map.from_struct() |> to_json()

  def to_json(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {safe_key(key), to_json(value)} end)

  # Only PROPER lists are coerced element-wise; an improper list (e.g. `[1 | 2]`)
  # raises in `Enum`, so it is rendered inspected.
  def to_json(list) when is_list(list) do
    if proper_list?(list), do: Enum.map(list, &to_json/1), else: inspect(list)
  end

  def to_json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> to_json()
  def to_json(atom) when is_atom(atom), do: Atom.to_string(atom)
  def to_json(pid) when is_pid(pid), do: inspect(pid)
  def to_json(port) when is_port(port), do: inspect(port)
  def to_json(ref) when is_reference(ref), do: inspect(ref)
  # Valid UTF-8 passes through; a non-UTF-8 binary (Jason would raise on it)
  # is rendered inspected so the payload stays encodable.
  def to_json(value) when is_binary(value), do: utf8_or_inspect(value, value)
  def to_json(value) when is_number(value) or is_boolean(value), do: value
  def to_json(nil), do: nil
  def to_json(other), do: inspect(other)

  # JSON object keys must be UTF-8 strings. `to_string/1` covers atoms /
  # binaries / numbers but raises for tuples / pids / arbitrary terms; and a
  # binary key can itself be invalid UTF-8. Both cases fall back to `inspect/1`.
  defp safe_key(key) do
    utf8_or_inspect(to_string(key), key)
  rescue
    _ -> inspect(key)
  end

  # A binary that is valid UTF-8 passes through unchanged (monotonic); otherwise
  # the original term is inspected, keeping the result `Jason.encode!`-able.
  defp utf8_or_inspect(str, fallback) when is_binary(str) do
    if String.valid?(str), do: str, else: inspect(fallback)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
