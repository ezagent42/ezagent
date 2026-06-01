defmodule Ezagent.Domain.Pty.Server.EnvTest do
  @moduledoc """
  Regression for the erlexec `{packet, 2}` `:einval` crash.

  `build_env/1` must pass ONLY the env vars ezagent adds or overrides —
  never the whole inherited OS environment.

  History: `build_env` used to splat all of `:os.getenv()` into
  `{:env, ...}`. erlexec frames each run command to its `exec-port`
  over a `{packet, 2}` channel (65535-byte max — deps/erlexec/src/exec.erl).
  On a host with a large environment the encoded command exceeded that
  limit, the BEAM failed the port write with `:einval`, the erlexec
  `:exec` manager crashed, the erlexec application shut down, and EVERY
  subsequent PTY spawn failed with `:no_pty` — blocking cc-agent replies
  node-wide. (Misdiagnosed at the time as an OTP-28 / erlexec-2.3.0 PTY
  incompatibility; the real trigger was environment *size*.)

  Dropping the splat is behaviour-preserving: the child still receives
  the operator's ambient env via normal OS-process inheritance through
  erlexec's `exec-port`, and anything claude-specific is passed
  explicitly via `:cmd_env`.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  # erlexec's {packet,2} framing caps each run command at 65535 bytes.
  # {:env, ...} is only part of that command, so we keep env well under it.
  @packet2_max 65_535

  defp state(cmd_env) do
    %PtyServer{
      agent_uri: URI.new!("entity://agent/team-alpha/env_test"),
      cmd_env: cmd_env
    }
  end

  test "does NOT enumerate the inherited OS environment" do
    # A var present in this BEAM's env (hence in :os.getenv/0). The old
    # build_env copied every such var into the {:env, ...} list.
    System.put_env("EZ_PTY_ENV_SENTINEL", "must-not-leak-into-exec-env")
    on_exit(fn -> System.delete_env("EZ_PTY_ENV_SENTINEL") end)

    env = PtyServer.build_env(state(nil))

    refute Enum.any?(env, fn {k, _v} -> k == ~c"EZ_PTY_ENV_SENTINEL" end),
           "build_env must not copy inherited OS env vars into {:env,...}; " <>
             "the child inherits them via erlexec's exec-port instead"
  end

  test "carries the ezagent overrides and the caller-supplied cmd_env" do
    env = PtyServer.build_env(state(%{"CLAUDE_CONFIG_DIR" => "/sandbox/x"}))

    assert Enum.any?(env, fn {k, _} -> k == ~c"EZAGENT_AGENT_URI" end)
    assert Enum.any?(env, fn {k, _} -> k == ~c"EZAGENT_DEPLOYMENT_ID" end)

    assert Enum.any?(env, fn {k, v} ->
             k == ~c"CLAUDE_CONFIG_DIR" and v == ~c"/sandbox/x"
           end),
           "caller cmd_env (e.g. CLAUDE_CONFIG_DIR) must still be passed as an override"
  end

  test "stays far under erlexec's {packet,2} limit even with a huge inherited env" do
    # A >64KB var in the OS env. The OLD build_env read :os.getenv/0 at
    # spawn time, so this alone would blow the {packet,2} budget and
    # crash the :exec manager with :einval. The fixed build_env ignores
    # the ambient env entirely.
    System.put_env("EZ_PTY_HUGE", String.duplicate("A", 100_000))
    on_exit(fn -> System.delete_env("EZ_PTY_HUGE") end)

    env = PtyServer.build_env(state(%{"CLAUDE_CONFIG_DIR" => "/sandbox/x"}))
    encoded = byte_size(:erlang.term_to_binary([{:env, env}]))

    assert encoded < 8_192,
           "encoded {:env,...} was #{encoded} bytes; it must stay well under " <>
             "erlexec's {packet,2} max of #{@packet2_max} to avoid the :einval port crash"
  end

  test "produces only well-formed {non-empty charlist key, charlist value} entries" do
    # An empty key (a var named "") is what erlexec rejects as
    # "invalid env argument"; the override-only env can never contain one.
    env = PtyServer.build_env(state(%{"CLAUDE_CONFIG_DIR" => "/x"}))

    Enum.each(env, fn {k, v} ->
      assert is_list(k) and k != [], "env key must be a non-empty charlist, got: #{inspect(k)}"
      assert is_list(v), "env value must be a charlist, got: #{inspect(v)}"
    end)
  end
end
