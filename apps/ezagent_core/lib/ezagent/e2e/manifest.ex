defmodule Ezagent.E2E.Manifest do
  @moduledoc """
  #21 PR-2 — the sidecar metadata persisted next to a layer tar.

  Because restore restarts the node (in-memory `ctx` is lost), `ctx` is persisted here —
  but JSON-serializable is not enough (codex r4): `%URI{}`, atom keys, `MapSet`/atoms/PIDs
  don't round-trip. So the codec is explicit + versioned:

    * keys MUST be strings (atom keys rejected — no silent string-shape change on decode);
    * `%URI{}` values are tagged (`{"__uri__": str}`) and reloaded with `URI.new!/1`;
    * binaries/numbers/booleans/nil/nested maps/lists pass through;
    * anything else (atoms, tuples, structs, PIDs, MapSets) is REJECTED at encode with a
      clear error — caps etc. must be rebuilt from durable principals, never stashed in ctx.
  """

  @schema_version 1

  defstruct [
    :scenario_id,
    :step_index,
    :step_name,
    :fp,
    :assert_passed,
    :ctx,
    schema_version: @schema_version
  ]

  @type t :: %__MODULE__{
          scenario_id: String.t(),
          step_index: non_neg_integer(),
          step_name: String.t(),
          fp: String.t(),
          assert_passed: boolean(),
          ctx: map(),
          schema_version: pos_integer()
        }

  @doc "Current manifest schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec encode(t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%__MODULE__{} = m) do
    with {:ok, enc_ctx} <- encode_ctx(m.ctx) do
      payload = %{
        "schema_version" => @schema_version,
        "scenario_id" => m.scenario_id,
        "step_index" => m.step_index,
        "step_name" => m.step_name,
        "fp" => m.fp,
        "assert_passed" => m.assert_passed,
        "ctx" => enc_ctx
      }

      {:ok, Jason.encode!(payload)}
    end
  end

  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"schema_version" => @schema_version} = p} ->
        {:ok,
         %__MODULE__{
           schema_version: @schema_version,
           scenario_id: p["scenario_id"],
           step_index: p["step_index"],
           step_name: p["step_name"],
           fp: p["fp"],
           assert_passed: p["assert_passed"],
           ctx: decode_ctx(p["ctx"] || %{})
         }}

      {:ok, %{"schema_version" => v}} ->
        {:error, {:schema_version_mismatch, v, @schema_version}}

      {:ok, _} ->
        {:error, :missing_schema_version}

      {:error, reason} ->
        {:error, {:undecodable, reason}}
    end
  end

  # --- ctx codec --------------------------------------------------------

  defp encode_ctx(nil), do: {:ok, %{}}

  defp encode_ctx(ctx) when is_map(ctx) do
    Enum.reduce_while(ctx, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, key} <- encode_key(k),
           {:ok, val} <- encode_val(v) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        err -> {:halt, err}
      end
    end)
  end

  defp encode_key(k) when is_binary(k), do: {:ok, k}
  defp encode_key(k), do: {:error, {:unencodable_ctx_key, k}}

  # %URI{} is a struct (is_map true) — this clause MUST precede the struct/map clauses.
  defp encode_val(%URI{} = u), do: {:ok, %{"__uri__" => URI.to_string(u)}}
  # Any OTHER struct (MapSet, DateTime, caps, …) is rejected — it would otherwise be
  # Enum-reduced as a plain map and either crash or lose its type. Store URIs (tagged),
  # ISO8601 strings, or primitives in ctx; rebuild caps from durable principals.
  defp encode_val(%_{} = other), do: {:error, {:unencodable_ctx_value, other}}
  defp encode_val(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: {:ok, v}
  defp encode_val(v) when is_list(v), do: encode_list(v)
  defp encode_val(v) when is_map(v), do: encode_ctx(v)
  defp encode_val(v), do: {:error, {:unencodable_ctx_value, v}}

  defp encode_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn v, {:ok, acc} ->
      case encode_val(v) do
        {:ok, ev} -> {:cont, {:ok, [ev | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp decode_ctx(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, decode_val(v)} end)
  defp decode_ctx(_), do: %{}

  defp decode_val(%{"__uri__" => s}) when is_binary(s), do: URI.new!(s)
  defp decode_val(v) when is_map(v), do: decode_ctx(v)
  defp decode_val(v) when is_list(v), do: Enum.map(v, &decode_val/1)
  defp decode_val(v), do: v
end
