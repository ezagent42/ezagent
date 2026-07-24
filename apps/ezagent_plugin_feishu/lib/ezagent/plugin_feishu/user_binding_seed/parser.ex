defmodule EzagentPluginFeishu.UserBindingSeed.Parser do
  @moduledoc """
  Strict decode + validate for the Feishu user-binding seed file
  (handoff B1 Phase 1). Pure module — no DB, no dispatch.

  ## Schema

      bindings:
        - open_id: "fake_..."
          user_uri: "entity://team-alpha/user/alice"

  Every row must have EXACTLY `open_id` + `user_uri` (unknown extra keys
  reject the row). `user_uri` must be a canonical, fully-qualified
  `entity://<workspace>/user/<name>` URI — parsed with
  `Ezagent.URI.new!/1` directly on the raw string, with NO bare-name or
  implicit-workspace promotion (unlike the CLI's convenience promotion).
  This rejects `person://`, `workspace://`, non-`user` entity types, bare
  names, and structurally malformed URIs uniformly, by construction.

  `row` on each parsed row is the row's 1-based ordinal position within
  the `bindings:` list (NOT a source-file line number — the YAML decoder
  does not preserve line/column metadata) — enough for an operator to
  locate the offending entry without a full line-accurate parser.

  Duplicate `open_id` values anywhere in the file reject the WHOLE file
  (Locked Decision #8) — even when every duplicate declares the identical
  `user_uri`, since a file that non-canonically repeats a key is itself
  an ambiguous authoring error.
  """

  alias EzagentPluginFeishu.Redact

  @type row :: %{row: pos_integer(), open_id: String.t(), user_uri: URI.t()}

  @allowed_row_keys MapSet.new(["open_id", "user_uri"])

  @spec parse_and_validate(String.t()) :: {:ok, [row]} | {:error, term()}
  def parse_and_validate(body) when is_binary(body) do
    with {:ok, decoded} <- decode_yaml(body),
         {:ok, raw_rows} <- extract_bindings_list(decoded),
         {:ok, rows} <- validate_rows(raw_rows),
         :ok <- check_duplicates(rows) do
      {:ok, rows}
    end
  end

  defp decode_yaml(body) do
    case YamlElixir.read_from_string(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:malformed_yaml, reason}}
    end
  end

  defp extract_bindings_list(%{"bindings" => bindings} = doc) when is_list(bindings) do
    # Reject unknown top-level keys — only `bindings` is allowed.
    if map_size(doc) == 1 do
      {:ok, bindings}
    else
      {:error, {:invalid_shape, "top-level map must contain ONLY a `bindings` key"}}
    end
  end

  defp extract_bindings_list(%{"bindings" => _not_a_list}) do
    {:error, {:invalid_shape, "top-level `bindings` must be a list"}}
  end

  defp extract_bindings_list(%{} = _no_bindings_key) do
    {:error, {:invalid_shape, "missing top-level `bindings` key"}}
  end

  defp extract_bindings_list(_not_a_map) do
    {:error, {:invalid_shape, "document must be a top-level map with a `bindings` key"}}
  end

  defp validate_rows(raw_rows) do
    raw_rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, idx}, {:ok, acc} ->
      case validate_row(raw, idx) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = err -> err
    end
  end

  defp validate_row(raw, idx) when is_map(raw) do
    keys = raw |> Map.keys() |> MapSet.new()

    if MapSet.equal?(keys, @allowed_row_keys) do
      with {:ok, open_id} <- fetch_nonempty_string(raw, "open_id"),
           {:ok, user_uri} <- fetch_user_uri(raw) do
        {:ok, %{row: idx, open_id: open_id, user_uri: user_uri}}
      else
        {:error, reason} -> {:error, {:invalid_row, idx, reason}}
      end
    else
      {:error, {:invalid_row, idx, {:bad_keys, MapSet.to_list(keys)}}}
    end
  end

  defp validate_row(_raw, idx) do
    {:error, {:invalid_row, idx, :not_a_map}}
  end

  defp fetch_nonempty_string(raw, key) do
    case Map.get(raw, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:empty_or_missing, key}}
    end
  end

  defp fetch_user_uri(raw) do
    with {:ok, s} <- fetch_nonempty_string(raw, "user_uri"),
         {:ok, uri} <- safe_parse_uri(s),
         :ok <- ensure_user_entity_uri(uri) do
      {:ok, uri}
    end
  end

  defp safe_parse_uri(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> {:error, {:invalid_uri, "malformed URI"}}
  end

  defp ensure_user_entity_uri(%URI{} = uri) do
    if Ezagent.URI.type?(uri, :user) do
      :ok
    else
      {:error, {:invalid_uri, "must be a user entity URI"}}
    end
  end

  defp check_duplicates(rows) do
    open_id_of = fn r -> Map.fetch!(r, :open_id) end

    dupes =
      rows
      |> Enum.group_by(open_id_of)
      |> Enum.filter(fn {_oid, group} -> length(group) > 1 end)
      |> Enum.sort_by(fn {_oid, group} -> group |> hd() |> Map.fetch!(:row) end)

    case dupes do
      [] ->
        :ok

      [{open_id, group} | _rest] ->
        row_numbers = group |> Enum.map(fn r -> Map.fetch!(r, :row) end) |> Enum.sort()
        {:error, {:duplicate_open_id, Redact.fingerprint(open_id), row_numbers}}
    end
  end
end
