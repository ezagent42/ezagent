defmodule Ezagent.Domain.Pty.ScreenMatch do
  @moduledoc """
  Needle-vs-PTY-screen matching for `Ezagent.Domain.Pty.Server`'s scanners
  (`AutoPrompts`, `AuthObservers`). Extracted from `Server` to keep it under the
  oversized-module arch gate — the same pattern as the other scanner modules.

  Three match shapes: a `String.t()` (substring), a list of strings (ALL must be
  present — AND), or a `Regex.t()`.

  ## Whitespace is normalised on BOTH sides

  `Ezagent.AnsiStrip.strip/1` emits a SPACE for every CSI escape it removes, so a
  TUI line such as `❯\\e[39m \\e[38;5;246m1.` strips to `"❯   1."` (multiple
  spaces). Without normalisation an exact-spacing needle (`"❯ 1. Use this MCP
  server"`) NEVER matches the live dialog — the cause of the #505 live finding
  where the `:mcp_trust_dialog` scanner silently never fired, so claude's
  esr-bridge MCP was never approved and the transport bridge never JOINed.

  Normalisation does NOT bridge whitespace the TUI redraw injected INSIDE a word
  (e.g. `"serv r"`), so needles must still avoid redraw-split words — see the
  per-entry notes in `Ezagent.Domain.Pty.AutoPrompts`.
  """

  @doc "Match `needle` (string / list-of-strings / regex) against an ANSI-stripped screen."
  @spec matches?(String.t() | [String.t()] | Regex.t(), binary()) :: boolean()
  def matches?(needle, stripped) when is_binary(needle),
    do: String.contains?(normalize_ws(stripped), normalize_ws(needle))

  def matches?(needles, stripped) when is_list(needles),
    do: Enum.all?(needles, &matches?(&1, stripped))

  def matches?(%Regex{} = re, stripped), do: Regex.match?(re, scrub_invalid(stripped))

  @doc "Collapse runs of whitespace to a single space (and scrub invalid UTF-8 first)."
  @spec normalize_ws(binary()) :: binary()
  def normalize_ws(s) when is_binary(s),
    do: String.replace(scrub_invalid(s), ~r/\s+/u, " ")

  # #1201 ① defense-in-depth at the point the buffer enters regex scanning: `~r/…/u`
  # RAISES ArgumentError on invalid UTF-8. Boundary-aware trimming (Utf8Tail) keeps a
  # valid stream valid, but a PTY can emit genuinely invalid bytes, and a chunk boundary
  # can transiently split a codepoint (the raw buffer self-heals when the next chunk
  # appends the rest — so we scrub only this scan-side copy, never the buffer itself).
  defp scrub_invalid(s) when is_binary(s) do
    if String.valid?(s), do: s, else: String.replace_invalid(s)
  end
end
