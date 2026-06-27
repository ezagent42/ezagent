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

  # Real captured buffer of a live claude parked at:
  #   "Allow external CLAUDE.md file imports? ... ❯ 1. Yes, allow external imports"
  # (the dialog AFTER MCP-trust, when the project CLAUDE.md @imports ~/.claude/RTK.md).
  @live_external_imports_buffer_b64 "G1syRBtbNUING1syQxtbMTBBG1szODs1OzIyMG0bWzFtQWxsb3cgZXh0G1sxNEduYWwbWzE4R0NMQVVERS5tZCBmG1szMEdsZSBpbXBvchtbMzlHcz8bWzIybRtbMzltG1tLDRtbMkMbWzJCVGhpcyBwG1sxMEdvamVjdCdzIENMQVVERS5tZCBpbXBvcnRzIGZpbGUbWzQyR291dHNpZGUgdGhlIGN1cnJlbnQgd29ya2luZyBkaXJlY3RvcnkuIE5ldmVyIGFsbG93G1s5M0d0aGlzIGZvciB0aBtbMTA1R3JkLXBhcnR5G1tLDRtbMkMbWzFCcmVwb3NpdG9yaWVzLhtbSw0bWzJDG1syQhtbMzg7NTsyNDZtRXh0ZXJuYWwgaW1wb3J0czobWzM5bRtbSw0bWzJDG1sxQhtbMzg7NTsyNDZtICAvVXNlcnMvaDJvc2xhYnMvLmNsYXVkZS9SVEsubWQbWzM2RxtbMzltG1tLDRtbNEMbWzFCG1tLDRtbMkMbWzFCG1szODs1OzI0Nm1JbXBvcnRhbnQ6IE9ubHkgdXNlIENsYXVkZSBDb2RlIHdpdGggZmlsZXMgeW91IHRydXN0LiBBY2Nlc3NpbmcgdW50cnVzdGVkIGZpbGVzIG1heSBwb3NlIHNlY3VyaXR5IHJpc2tzIA0bWzJDG1sxQhtdODtpZD16YXhtZGE7aHR0cHM6Ly9jb2RlLmNsYXVkZS5jb20vZG9jcy9lbi9zZWN1cml0eQdodHRwczovL2NvZGUuY2xhdWRlLmNvbS9kb2NzL2VuL3NlY3VyaXR5G104OzsHIBtbMzltDQ0KDQ0KG1szRxtbMzg7NTsxNTNt4p2vG1s1RxtbMzg7NTsyNDZtMS4bWzhHG1szODs1OzE1M21ZZXMsG1sxM0dhbGxvdxtbMTlHZXh0ZXJuYWwbWzI4R2ltcG9ydHMbWzM5bQ0NChtbNUcbWzM4OzU7MjQ2bTIuG1s4RxtbMzltTm8sG1sxMkdkaXNhYmxlG1syMEdleHRlcm5hbBtbMjlHaW1wb3J0cw0NCg0NChtbM0cbWzM4OzU7MjQ2bRtbM21FbnRlchtbOUd0bxtbMTJHY29uZmlybRtbMjBHwrcbWzIyR0VzYxtbMjZHdG8bWzI5R2NhbmNlbBtbMjNtG1szOW0NDQobWzJDG1s0QQ=="

  test "the :claude_md_external_imports_dialog rule fires on the real captured buffer" do
    stripped = @live_external_imports_buffer_b64 |> Base.decode64!() |> AnsiStrip.strip()

    match =
      AutoPrompts.default()
      |> Enum.find(fn p -> p.name == :claude_md_external_imports_dialog end)
      |> Map.fetch!(:match)

    assert Server.matches?(match, stripped),
           ":claude_md_external_imports_dialog must match the live dialog so the " <>
             "headless cc PTY auto-confirms external CLAUDE.md imports (#505)"
  end

  test "external-imports matcher tolerates run-to-run fragmentation of option 2" do
    # Real-run variant where option 2's "disable" fragmented to "d sable" — the
    # rule must still fire (it anchors only on the atomic option-1 label).
    fragmented =
      "Allow ext nal CLAUDE.md f le impor s?  ... " <>
        "❯   1.  Yes, allow external imports     2.  No, d sable external imports"

    match =
      AutoPrompts.default()
      |> Enum.find(fn p -> p.name == :claude_md_external_imports_dialog end)
      |> Map.fetch!(:match)

    assert Server.matches?(match, fragmented)
  end
end
