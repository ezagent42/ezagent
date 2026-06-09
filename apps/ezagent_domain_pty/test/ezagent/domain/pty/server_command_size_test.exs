defmodule Ezagent.Domain.Pty.Server.CommandSizeTest do
  @moduledoc """
  Backstop for the erlexec `{packet,2}` `:einval` crash.

  erlexec frames each run command to its `exec-port` over a `{packet,2}`
  channel (65535-byte max). If the encoded run command exceeds it, the
  BEAM port write fails `:einval` and crashes the SHARED node-wide
  `:exec` manager — taking every later PTY/Python spawn down (`:no_pty`),
  not just the oversized one. `spawn_claude_directly/1` guards on
  `estimated_command_size/2` and fails the single spawn with
  `{:error, {:command_too_large, size}}` instead, so one bad command
  can never become a node-wide outage.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  # erlexec's {packet,2} framing caps each run command at 65535 bytes.
  @packet2_max 65_535

  test "a normal claude command estimates well under the {packet,2} limit" do
    cmd = [~c"/Users/x/.local/bin/claude", ~c"--permission-mode", ~c"bypassPermissions"]
    env = [{~c"EZAGENT_AGENT_URI", ~c"entity://team-alpha/agent/x"}]

    assert PtyServer.estimated_command_size(cmd, env) < 4_096
  end

  test "a command with a ~100 KB argv element estimates OVER the limit" do
    # This is exactly the shape that crashed :exec: a large soul inlined
    # as an --append-system-prompt argv element. estimated_command_size
    # must catch it so the guard rejects this one spawn.
    huge_arg = String.to_charlist(String.duplicate("A", 100_000))
    cmd = [~c"/Users/x/.local/bin/claude", ~c"--append-system-prompt", huge_arg]
    env = [{~c"EZAGENT_AGENT_URI", ~c"entity://team-alpha/agent/x"}]

    assert PtyServer.estimated_command_size(cmd, env) > @packet2_max
  end

  test "a ~100 KB env value also estimates OVER the limit" do
    # The other historical trigger: a huge inherited env splatted into
    # {:env, ...} (now fixed in build_env, but the guard covers it too).
    cmd = [~c"/Users/x/.local/bin/claude"]
    env = [{~c"BIG", String.to_charlist(String.duplicate("A", 100_000))}]

    assert PtyServer.estimated_command_size(cmd, env) > @packet2_max
  end
end
