defmodule Ezagent.Domain.Pty.Server.BufferUtf8TrimTest do
  @moduledoc """
  Regression tests for jjkysy #1201 finding ① — PTY buffer trimming cut at a
  RAW BYTE boundary, splitting multi-byte UTF-8 codepoints.

  `trim_buffer_only/1` kept the trailing 16KB of a >64KB buffer via
  `binary_part/3`. When the cut landed mid-codepoint (guaranteed 2-in-3 for a
  CJK-heavy tail: 16_384 mod 3 == 1) the retained buffer started with a UTF-8
  continuation byte. The next stdout chunk then flowed through
  `scan_auth_observers` / `scan_auto_prompts` → `matches?/2` → `normalize_ws/1`,
  whose `~r/\\s+/u` regex raises `ArgumentError` on invalid UTF-8 — crashing the
  PtyServer. Long turns (lots of CJK output) reliably died; short turns never
  did (buffer stayed under 64KB, no trim, no invalid bytes).

  The fix: codepoint-boundary-aware trimming (`Ezagent.Utf8Tail`) at every
  byte-cut site, plus a `String.replace_invalid/1` scrub where the buffer
  enters regex scanning (defense-in-depth for genuinely invalid PTY bytes).
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  # 64KB of ASCII filler, then 6_000 3-byte CJK chars (18_000 bytes) → total
  # 83_536 bytes > 64KB, so the scanner trims to the trailing 16KB. The cut
  # offset lands mid-codepoint: after the first stdout chunk below (21 bytes)
  # the buffer is 83_557 bytes, cut start = 83_557 - 16_384 = 67_173; offset
  # into the CJK region = 67_173 - 65_536 = 1_637 ≡ 2 (mod 3) → the kept tail
  # starts on the LAST byte of a 3-byte 中 — a continuation byte.
  defp cjk_heavy_buffer, do: String.duplicate("x", 65_536) <> String.duplicate("中", 6_000)

  defp start_server do
    agent_uri =
      URI.new!("entity://team-alpha/agent/test_utf8trim-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Ezagent.Domain.Pty.start(agent_uri, %{
        cwd: "/tmp",
        test_mode: true,
        # A never-matching observer forces every chunk through
        # matches?/2 → normalize_ws/1 (the /u regex) — the production
        # scan path that crashed on the mangled buffer.
        auth_observers: [%{name: :probe_never_matches, match: "NEVER MATCHES ANYTHING §§"}]
      })

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(EzagentDomainPty.Supervisor, pid)
      end
    end)

    {agent_uri, pid}
  end

  test "raw 16KB byte-cut of a CJK-heavy buffer splits a codepoint (the #1201 hazard, pinned)" do
    buf = cjk_heavy_buffer()
    assert String.valid?(buf)

    # This is exactly what trim_buffer_only/1 did before the fix.
    raw_cut = binary_part(buf, byte_size(buf) - 16_384, 16_384)

    refute String.valid?(raw_cut),
           "expected the raw byte-boundary cut to land mid-codepoint (test-vector sanity)"

    # First byte of the kept tail is a UTF-8 continuation byte (0b10xxxxxx).
    <<first, _::binary>> = raw_cut
    assert first in 0x80..0xBF
  end

  test "matches?/2 does not raise when the stripped buffer contains invalid UTF-8" do
    # Defense-in-depth at the consumption point: a PTY can emit genuinely
    # invalid bytes (or a chunk boundary can split a codepoint before the
    # buffer self-heals on the next append). The scan must not crash.
    invalid = <<0xB1, 0x89>> <> "some terminal output 中文"
    refute String.valid?(invalid)

    refute PtyServer.matches?("NEVER MATCHES ANYTHING §§", invalid)
  end

  test "PtyServer survives a long CJK turn whose trim lands mid-codepoint (server-level #1201 repro)" do
    {_uri, pid} = start_server()
    ref = Process.monitor(pid)

    # test_mode leaves exec_pid nil, and scan_auto_prompts/1 short-circuits
    # (no trim) when exec_pid is nil — set it so the trim path runs exactly
    # as it does under a live spawn. Inject the oversized valid buffer.
    :sys.replace_state(pid, fn s ->
      %{s | exec_pid: self(), pty_buffer: cjk_heavy_buffer()}
    end)

    # Chunk 1 (21 bytes of CJK): the scan runs on a still-valid buffer, then
    # trim_buffer_only cuts the tail — mid-codepoint before the fix.
    send(pid, {:stdout, 0, "下一段中文输出"})

    # Chunk 2: the scan now runs over the trimmed buffer. Before the fix the
    # buffer starts with a continuation byte → normalize_ws's /u regex raises
    # ArgumentError → the PtyServer crashes.
    send(pid, {:stdout, 0, "再来一段中文"})

    refute_receive {:DOWN, ^ref, :process, ^pid, _reason},
                   500,
                   "PtyServer crashed scanning the byte-trimmed buffer (#1201 finding ①)"

    # And the retained buffer must be valid UTF-8 (the input stream was valid).
    %{pty_buffer: buf} = :sys.get_state(pid)
    assert byte_size(buf) <= 16 * 1024 + 32
    assert String.valid?(buf), "trimmed pty_buffer must start on a codepoint boundary"
  end

  test "snapshot_buffer/2 never returns a tail that starts mid-codepoint" do
    {uri, pid} = start_server()

    :sys.replace_state(pid, fn s -> %{s | pty_buffer: cjk_heavy_buffer()} end)

    # 4_096 ≡ 1 (mod 3) → a raw byte cut into the CJK region starts
    # mid-codepoint; the boundary-aware cut must not.
    assert {:ok, tail} = PtyServer.snapshot_buffer(uri, 4_096)
    assert String.valid?(tail), "snapshot tail must be valid UTF-8"
    assert byte_size(tail) >= 4_096 - 3
    assert byte_size(tail) <= 4_096
  end
end
