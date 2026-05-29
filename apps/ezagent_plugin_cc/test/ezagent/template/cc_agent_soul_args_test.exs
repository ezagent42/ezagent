defmodule Ezagent.PluginCc.Template.CcAgent.SoulArgsTest do
  @moduledoc """
  Regression for the erlexec `{packet,2}` `:einval` crash via a large
  soul argument.

  A cc agent's soul/system-prompt must be passed to `claude` by FILE
  (`--append-system-prompt-file <path>`), never inlined as an argv
  element (`--append-system-prompt <contents>`). erlexec frames each run
  command to its `exec-port` over a `{packet,2}` channel (65535-byte
  max — deps/erlexec/src/exec.erl). A large soul (the real cinnox soul
  is ~89 KB) inlined as an arg pushes the `term_to_binary`-encoded
  command past 64 KB → the BEAM port write fails `:einval` → the shared
  node-wide `:exec` manager crashes → every later spawn `:no_pty`. A
  file path is a handful of bytes regardless of soul size.
  """
  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.CcAgent

  @agent_uri URI.new!("entity://agent/cinnox/cc_soul_test")

  setup do
    cwd = Path.join(System.tmp_dir!(), "cc_soul_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  defp soul_file(cwd, body) do
    path = Path.join(cwd, "soul_src.md")
    File.write!(path, body)
    path
  end

  test "absent soul_path → no system-prompt args", %{cwd: cwd} do
    assert CcAgent.build_soul_args(@agent_uri, cwd, %{}) == []
  end

  test "unreadable soul_path → no system-prompt args (non-fatal)", %{cwd: cwd} do
    args =
      CcAgent.build_soul_args(@agent_uri, cwd, %{"soul_path" => Path.join(cwd, "missing.md")})

    assert args == []
  end

  test "soul is passed by FILE (not inline); the file holds preamble + soul", %{cwd: cwd} do
    sp = soul_file(cwd, "TENANT SOUL BODY: be nice.")
    args = CcAgent.build_soul_args(@agent_uri, cwd, %{"soul_path" => sp})

    assert ["--append-system-prompt-file", path] = args
    assert File.exists?(path)

    written = File.read!(path)
    assert written =~ "TENANT SOUL BODY: be nice."
    # the channel-protocol preamble is prepended
    assert written =~ "Channel Protocol"

    # the soul body must NOT appear in the argv itself
    refute Enum.any?(args, fn a -> a =~ "TENANT SOUL BODY" end)
  end

  test "an 89 KB soul keeps the argv tiny — no {packet,2} overflow", %{cwd: cwd} do
    big = String.duplicate("X", 89_000)
    sp = soul_file(cwd, big)
    args = CcAgent.build_soul_args(@agent_uri, cwd, %{"soul_path" => sp})

    assert ["--append-system-prompt-file", path] = args

    # The argv encodes to a handful of bytes regardless of soul size —
    # the whole point of the file form vs. inlining the 89 KB soul, which
    # would blow erlexec's 64 KB {packet,2} command budget.
    assert byte_size(:erlang.term_to_binary(args)) < 1_024

    # …and the file genuinely contains the full soul.
    assert byte_size(File.read!(path)) >= 89_000
  end
end
