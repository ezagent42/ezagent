defmodule Ezagent.AnsiStrip do
  @moduledoc """
  Cheap ANSI escape stripper — ported from old esr (PR-24 step 2) per
  Phase 4-completion PR 8 cc-pty enhancement.

  Used by `Ezagent.Domain.Pty.Server` to detect claude's
  `--dangerously-load-development-channels` dialog text in raw PTY
  stdout (ANSI codes interleave between words so we can't substring-
  match the raw bytes).

  Sequences handled (CSI / OSC / DCS / SOS / PM / APC / ESC-2byte /
  bare control chars). Not handled: true colour rendering, cursor
  positioning, line clears (TUI redraws come out as gibberish — fine
  for substring-match purposes).
  """

  defguardp is_csi_final(b) when b >= 0x40 and b <= 0x7E

  @doc """
  Strip ANSI escapes from a binary, returning printable text.

  CSI sequences are replaced with a single space so cursor-positioning
  escapes (which claude uses to lay out words on a row) don't squish
  adjacent words together — operator/auto-detector reads
  "Loading development channels" rather than "Loadingdevelopmentchannels".
  """
  @spec strip(binary()) :: binary()
  def strip(bin) when is_binary(bin) do
    bin |> do_strip([]) |> IO.iodata_to_binary()
  end

  defp do_strip(<<0x1B, ?[, rest::binary>>, acc) do
    rest |> drop_until_csi_final() |> do_strip([acc | " "])
  end

  defp do_strip(<<0x1B, ?], rest::binary>>, acc) do
    rest |> drop_until_st_or_bel() |> do_strip(acc)
  end

  defp do_strip(<<0x1B, intro, rest::binary>>, acc) when intro in [?P, ?X, ?^, ?_] do
    rest |> drop_until_st() |> do_strip(acc)
  end

  defp do_strip(<<0x1B, _next, rest::binary>>, acc), do: do_strip(rest, acc)

  defp do_strip(<<c, rest::binary>>, acc)
       when (c >= 0x00 and c <= 0x08) or (c >= 0x0B and c <= 0x0C) or
              (c >= 0x0E and c <= 0x1F) do
    do_strip(rest, acc)
  end

  defp do_strip(<<0x7F, rest::binary>>, acc), do: do_strip(rest, acc)

  defp do_strip(<<c, rest::binary>>, acc), do: do_strip(rest, [acc | <<c>>])

  defp do_strip(<<>>, acc), do: acc

  defp drop_until_csi_final(<<b, rest::binary>>) when is_csi_final(b), do: rest
  defp drop_until_csi_final(<<_b, rest::binary>>), do: drop_until_csi_final(rest)
  defp drop_until_csi_final(<<>>), do: <<>>

  defp drop_until_st_or_bel(<<0x07, rest::binary>>), do: rest
  defp drop_until_st_or_bel(<<0x1B, ?\\, rest::binary>>), do: rest
  defp drop_until_st_or_bel(<<_b, rest::binary>>), do: drop_until_st_or_bel(rest)
  defp drop_until_st_or_bel(<<>>), do: <<>>

  defp drop_until_st(<<0x1B, ?\\, rest::binary>>), do: rest
  defp drop_until_st(<<_b, rest::binary>>), do: drop_until_st(rest)
  defp drop_until_st(<<>>), do: <<>>
end
