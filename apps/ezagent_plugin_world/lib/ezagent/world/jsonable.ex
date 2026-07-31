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
  # would otherwise crash-loop those sockets. Two totality hazards are handled
  # explicitly: non-string map keys (`safe_key/1`) and invalid-UTF-8 binaries.

  @doc false
  def to_json(%URI{} = uri), do: URI.to_string(uri)
  def to_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def to_json(%_struct{} = struct), do: struct |> Map.from_struct() |> to_json()

  def to_json(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {safe_key(key), to_json(value)} end)

  def to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  def to_json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> to_json()
  def to_json(atom) when is_atom(atom), do: Atom.to_string(atom)
  def to_json(pid) when is_pid(pid), do: inspect(pid)
  def to_json(port) when is_port(port), do: inspect(port)
  def to_json(ref) when is_reference(ref), do: inspect(ref)
  # Valid UTF-8 passes through; a non-UTF-8 binary (Jason would raise on it)
  # is rendered as its inspected form so the payload stays encodable.
  def to_json(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  def to_json(value) when is_number(value) or is_boolean(value), do: value
  def to_json(nil), do: nil
  def to_json(other), do: inspect(other)

  # JSON object keys must be strings. `to_string/1` covers the common cases
  # (atoms, binaries, numbers) but raises for tuples / pids / arbitrary terms,
  # so fall back to `inspect/1` — keeping the coercion total.
  defp safe_key(key) do
    to_string(key)
  rescue
    _ -> inspect(key)
  end
end
