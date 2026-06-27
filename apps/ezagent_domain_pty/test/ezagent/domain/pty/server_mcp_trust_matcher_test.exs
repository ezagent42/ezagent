defmodule Ezagent.Domain.Pty.Server.McpTrustMatcherTest do
  @moduledoc """
  #505 regression — the `:mcp_trust_dialog` auto-prompt silently never fired
  against a LIVE claude, so the framework-supplied `esr-bridge` MCP was never
  approved and the cc transport bridge never JOINed.

  Root cause: `Ezagent.AnsiStrip.strip/1` emits a SPACE for every CSI escape it
  removes, so claude's selection-marker line `❯\e[39m \e[38;5;246m1.` strips to
  "❯   1." (multiple spaces). The matcher required the exact-spacing substring
  "❯ 1. Use this MCP server", which therefore never matched.

  The fixture below is the REAL, byte-for-byte PTY buffer captured from a live
  `claude` 2.x process parked at the MCP-trust dialog on the disposable stack
  (2026-06-27). The fix normalises whitespace on both sides of the match.
  """
  use ExUnit.Case, async: true

  alias Ezagent.AnsiStrip
  alias Ezagent.Domain.Pty.AutoPrompts
  alias Ezagent.Domain.Pty.Server

  # Real captured `state.pty_buffer` bytes (base64) — a live claude parked at:
  #   "New MCP server found in this project: esr-bridge ... ❯ 1. Use this MCP server"
  @live_mcp_trust_buffer_b64 "G1sxRBtbNEIbWzJLG1sxQRtbMksbWzFBG1sySxtbMUEbWzJLG1sxQRtbMksbW0cbWzFBDRtbMUMbWzEwQSAbWzM4OzU7MjIwbRtbMW1OZXcgTUNQIHNlcnZlciBmb3VuZCBpbiB0aGlzIHByb2plY3Q6IGVzci1icmlkZ2UNG1sxQxtbMkIbWzIybRtbMzltIE1DUCBzZXJ2ZXJzIG1heSBleGVjdXRlIGNvZGUgb3IgYWNjZXNzIHN5c3RlbRtbNDlHcmVzb3VyY2VzLhtbNjBHQWxsG1s2NEd0b29sG1s2OUdjYWxscxtbNzVHcmVxdWlyZRtbODNHYXBwcm92YWwuG1s5M0dMZWFybhtbOTlHbW9yZRtbMTA0R2luG1sxMDdHdGhlG1sxMTFHG104O2lkPWM0MTV6dztodHRwczovL2NvZGUuY2xhdWRlLmNvbS9kb2NzL2VuL21jcAdNQ1AgG104OzsHDRtbMkMbWzFCG104O2lkPWM0MTV6dztodHRwczovL2NvZGUuY2xhdWRlLmNvbS9kb2NzL2VuL21jcAdkb2N1bWVudGF0aW9uG104OzsHLg0bWzFDG1sxQhtbSw0bWzFDG1sxQiAbWzM4OzU7MTUzbeKdrxtbMzltIBtbMzg7NTsyNDZtMS4gG1szODs1OzE1M21Vc2UgdGhpcyBNQ1Agc2VydmVyG1szOW0bW0sNG1s0QxtbMUIbWzM4OzU7MjQ2bTIuIBtbMzltVXNlG1sxMkd0aGlzG1sxN0dhbmQbWzIxR2FsbBtbMjVHZnV0dXJlG1szMkdNQ1AbWzM2R3NlcnZlcnMbWzQ0R2luG1s0N0d0aGlzG1s1Mkdwcm9qZWN0DRtbMUMbWzFCICAgG1szODs1OzI0Nm0zLiAbWzM5bUNvbnRpbnVlG1sxN0d3aXRob3V0G1syNUd1c2luZyB0aGlzIE1DUBtbNDBHc2VydhtbNDVHchtbSw0bWzFDG1syQiAbWzM4OzU7MjQ2bRtbM21FbnRlciB0byBjb25maXJtIMK3IEVzYyB0byBjYW5jZWwNG1sxQhtbMjNtG1szOW0bW0sNG1sxQhtbSw0bWzFCG1tLDRtbMUIbW0sNG1sxQhtbSw0bWzRBG1syQxtbNUE="

  defp live_stripped do
    @live_mcp_trust_buffer_b64 |> Base.decode64!() |> AnsiStrip.strip()
  end

  defp mcp_trust_match do
    AutoPrompts.default()
    |> Enum.find(fn p -> p.name == :mcp_trust_dialog end)
    |> Map.fetch!(:match)
  end

  test "AnsiStrip injects extra spaces — exact-spacing marker is NOT a substring (the bug)" do
    stripped = live_stripped()

    assert String.contains?(stripped, "New MCP server found")
    # The pre-fix exact-spacing marker the matcher used: absent from the real buffer.
    refute String.contains?(stripped, "❯ 1. Use this MCP server")
    # The marker is present with the AnsiStrip-injected extra spaces.
    assert String.contains?(stripped, "❯")
    assert stripped =~ ~r/❯\s+1\.\s+Use this MCP server/u
  end

  test "Server.matches? (whitespace-normalised) fires the :mcp_trust_dialog on the real buffer" do
    assert Server.matches?(mcp_trust_match(), live_stripped()),
           ":mcp_trust_dialog must match the live ANSI-stripped buffer so the " <>
             "esr-bridge MCP is approved and the cc bridge can JOIN (#505)"
  end

  test "matches? does not fire on unrelated prose" do
    refute Server.matches?(mcp_trust_match(), "just some normal claude output line")
  end
end
