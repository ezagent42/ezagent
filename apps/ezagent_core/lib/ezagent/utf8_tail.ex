defmodule Ezagent.Utf8Tail do
  @moduledoc """
  Codepoint-boundary-aware trailing-slice of a binary (jjkysy #1201 ①).

  `binary_part(buf, byte_size(buf) - keep, keep)` cuts at a RAW BYTE
  boundary: on a CJK-heavy stream the cut lands mid-codepoint 2 times in
  3 (a 3-byte codepoint vs `keep` not a multiple of 3), leaving the kept
  tail starting with a UTF-8 continuation byte. Any downstream consumer
  that treats the buffer as a String — notably a `/u`-flagged regex, which
  RAISES `ArgumentError` on invalid UTF-8 — then crashes.

  `tail/2` advances the cut point past continuation bytes (`0b10xxxxxx`,
  at most 3 — the longest continuation run in valid UTF-8) so the kept
  tail always starts on a codepoint boundary. If the input was valid
  UTF-8 at the cut, the tail is valid UTF-8. Genuinely invalid input
  (a PTY can emit garbage) is not repaired here — that is the consumer's
  concern (see `Ezagent.Domain.Pty.Server.matches?/2` scrubbing).
  """

  @doc """
  Return the trailing `max_bytes` of `bin`, shrunk by up to 3 bytes so the
  slice starts on a UTF-8 codepoint boundary. Returns `bin` unchanged when
  it already fits.
  """
  @spec tail(binary(), non_neg_integer()) :: binary()
  def tail(bin, max_bytes) when is_binary(bin) and byte_size(bin) <= max_bytes, do: bin

  def tail(bin, max_bytes) when is_binary(bin) do
    start = advance_past_continuation(bin, byte_size(bin) - max_bytes, 3)
    binary_part(bin, start, byte_size(bin) - start)
  end

  # Valid UTF-8 has at most 3 continuation bytes in a row; if we still see
  # one after 3 advances the input was invalid at the cut — stop and cut
  # anyway (the consumer-side scrub handles invalid input).
  defp advance_past_continuation(bin, start, budget)
       when budget > 0 and start < byte_size(bin) do
    case :binary.at(bin, start) do
      b when b in 0x80..0xBF -> advance_past_continuation(bin, start + 1, budget - 1)
      _ -> start
    end
  end

  defp advance_past_continuation(_bin, start, _budget), do: start
end
