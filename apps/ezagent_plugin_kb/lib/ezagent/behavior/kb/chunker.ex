defmodule Ezagent.Behavior.Kb.Chunker do
  @moduledoc """
  The MVP source chunker (SPEC §4.4: "simple size/overlap chunker for MVP").

  Splits raw source bytes into overlapping fixed-size character windows. Overlap
  keeps a phrase that straddles a boundary findable in at least one chunk. The
  unit is grapheme/character count (NOT bytes) so multibyte (zh) text is not
  split mid-codepoint. Returns `{chunk_index, text}` tuples for `Store.ingest/3`.
  """

  # Defaults chosen small for predictable retrieval over short docs; tunable
  # later via agent metadata (deferred — single config for the MVP).
  @default_size 800
  @default_overlap 100

  @doc """
  Chunk `text` into `{index, chunk_text}` tuples.

  Options: `:size` (window length in characters, default #{@default_size}),
  `:overlap` (characters re-included from the previous window, default
  #{@default_overlap}; must be < size).
  """
  @spec chunk(binary(), keyword()) :: [{non_neg_integer(), String.t()}]
  def chunk(text, opts \\ []) when is_binary(text) do
    size = Keyword.get(opts, :size, @default_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)
    step = max(size - overlap, 1)

    graphemes = String.graphemes(text)
    total = length(graphemes)

    cond do
      total == 0 ->
        []

      total <= size ->
        [{0, text}]

      true ->
        0..(total - 1)//step
        |> Enum.map(fn start ->
          graphemes |> Enum.slice(start, size) |> Enum.join()
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.with_index()
        |> Enum.map(fn {chunk, idx} -> {idx, chunk} end)
    end
  end
end
