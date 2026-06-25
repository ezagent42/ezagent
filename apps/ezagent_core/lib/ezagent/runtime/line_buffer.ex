defmodule Ezagent.Runtime.LineBuffer do
  @moduledoc """
  Newline-framing buffer for `{:stdout, os_pid, bytes}` chunks delivered by
  erlexec — which does NOT guarantee line-boundaries.

  ## Design

  erlexec delivers arbitrary byte chunks; JSON-line sidecars need complete lines
  before decoding. `LineBuffer` accumulates bytes, emits complete lines on
  `\\r?\\n`, and holds a partial tail.

  `max_line_bytes` is a **generous safety ceiling** to bound memory growth
  (default: sidecars should set ≥ 1 MiB for large events). It is NOT the old
  `{:line, N}` delivery chunk size from native `Port`. When the no-newline tail
  reaches `max_line_bytes`, the capped prefix is emitted (invalid JSON if
  truncated → dropped with a warning by callers; framing resyncs at the next
  `\\n`).

  SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md` §3.3.
  """

  defstruct buf: "", max: 1_048_576

  @type t :: %__MODULE__{buf: binary(), max: pos_integer()}

  @doc """
  Create a new `LineBuffer` with the given byte cap.

  `max_line_bytes` is the maximum byte length of the no-newline accumulation
  before forcing a flush. A too-small value is a regression for large events
  (e.g. feishu JSON payloads). Use ≥ 1 MiB for sidecars.
  """
  @spec new(pos_integer()) :: t()
  def new(max_line_bytes) when is_integer(max_line_bytes) and max_line_bytes > 0 do
    %__MODULE__{max: max_line_bytes}
  end

  @doc """
  Feed bytes into the buffer. Returns `{updated_buffer, [complete_line]}`.

  Lines are split on `~r/\\r?\\n/` (handles both LF and CRLF). The tail
  (bytes after the last newline) is held in the buffer. If the tail reaches
  `max` bytes, the capped prefix is emitted immediately and the remainder
  is stored for the next call.
  """
  @spec feed(t(), binary()) :: {t(), [String.t()]}
  def feed(%__MODULE__{buf: buf, max: max} = lb, bytes) when is_binary(bytes) do
    data = buf <> bytes
    {complete_lines, tail} = split_on_newlines(data)
    {capped_lines, new_tail} = maybe_cap(tail, max)
    {%{lb | buf: new_tail}, complete_lines ++ capped_lines}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Split `data` into complete lines (before the last `\r?\n`) and the tail
  # (after the last newline). Returns `{[String.t()], tail :: binary()}`.
  defp split_on_newlines(data) do
    case :binary.split(data, ["\r\n", "\n"], [:global]) do
      [only] ->
        # No newline at all — all goes to tail
        {[], only}

      parts ->
        # The last element is the tail (may be ""); everything before is complete
        complete = Enum.drop(parts, -1)
        tail = List.last(parts)
        {complete, tail}
    end
  end

  # If the tail is >= max bytes, emit the capped prefix and keep the rest.
  # Only emit ONE prefix per call (callers loop by calling feed repeatedly).
  defp maybe_cap(tail, max) when byte_size(tail) >= max do
    <<prefix::binary-size(max), rest::binary>> = tail
    {[prefix], rest}
  end

  defp maybe_cap(tail, _max), do: {[], tail}
end
