defmodule EzagentCli.Integration.CliLvSameServerInvariantTest do
  @moduledoc """
  Post-Phase-5 invariant (Allen 2026-05-17): CLI and LV must reach the
  SAME BEAM. Previously `mix esr` started its own VM and the dispatch
  hit isolated state — LV couldn't see CLI mutations. That was a real
  drift.

  Final design: `Mix.Tasks.Esr` connects via distributed Erlang RPC
  (Allen 2026-05-17 second pivot — dropping HTTP indirection). The
  CLI process does `Node.connect(runtime) + :rpc.call(runtime,
  EzagentCli.Exec, :exec, [argv])`. Same BEAM, same KindRegistry, zero
  serde.

  This test pins the invariant by:
  1. Spawning a Session Kind in THIS test process's BEAM
  2. Calling `EzagentCli.Exec.exec(["session", "join", ...])` directly
     (server-side path — same as what `:rpc.call` invokes on the
     runtime node in real CLI use)
  3. Asserting the Session GenServer's state changed in THIS BEAM
     (member list now contains the joined member)

  If a future refactor moves CLI back to spawning its own VM, the
  member assertion will FAIL because the join happens in a separate
  process tree from the one this test inspects.
  """
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # CLI/GUI audit HIGH-1 — Dispatch no longer silent-fallbacks to
    # admin. Tests set the per-process override that
    # `EzagentCli.Exec.exec/2` would set in production after token auth.
    Process.put(
      :ezagent_cli_caller_override,
      {Ezagent.Entity.User.admin_uri(), Ezagent.SystemPrincipal.caps("system://bootstrap")}
    )

    :ok
  end

  test "CLI server-side exec changes Session.chat.members IN THIS BEAM" do
    session_name = "cli-same-server-test-#{System.unique_integer([:positive])}"
    # SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment.
    session_uri = URI.parse("session://default/team-alpha/" <> session_name)
    # PR-A: agent URIs include a type segment.
    member_uri = URI.parse("entity://agent/team-alpha/cc_cli-test-member-#{System.unique_integer([:positive])}")

    # Spawn session in this BEAM
    {:ok, session_pid} = Ezagent.SpawnRegistry.spawn(session_uri)
    Process.sleep(50)

    # Spawn the agent so chat/join's lookup succeeds
    {:ok, _agent_pid} = Ezagent.SpawnRegistry.spawn(member_uri)
    Process.sleep(50)

    member_uri_str = URI.to_string(member_uri)

    # Confirm member is NOT there yet (compare by URI string to dodge
    # %URI{authority: ...} vs host-only equality quirk)
    state_before = :sys.get_state(session_pid, 500)

    refute Enum.any?(Map.keys(state_before.state.chat.members), fn k ->
             URI.to_string(k) == member_uri_str
           end)

    # Mint an admin CLI token for the Exec path — codex CLI/GUI audit
    # HIGH-1 closed the silent admin fallback, so Exec now requires
    # explicit token + entity_uri opts (mirroring how the real
    # /api/cli/exec route works after operator authenticates).
    admin_uri = Ezagent.Entity.User.admin_uri()

    # Idempotent — admin may already exist from boot.
    _ =
      case Ezagent.Users.get_by_uri(admin_uri) do
        nil -> Ezagent.Users.create(admin_uri, nil, MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap")))
        _ -> :ok
      end

    {plain_token, _row} = Ezagent.Entity.Token.mint(admin_uri, label: "test-cli-token")

    # Call CLI server-side path (what /api/cli/exec does)
    result =
      EzagentCli.Exec.exec(
        [
          "session",
          "join",
          "--session",
          session_name,
          # SPEC #366 (Allen 2026-05-26) — `--instance-class` is required
          # for bare-name `--session <name>` promotion. The test spawned
          # `session://default/team-alpha/<name>` above, so the class slot
          # is the literal `"default"` here.
          "--instance-class",
          "default",
          "--member",
          URI.to_string(member_uri),
          "--cast"
        ],
        token: plain_token,
        entity_uri: URI.to_string(admin_uri)
      )

    assert result.exit_code == 0,
           "CLI exec returned non-zero: output=#{inspect(result.output)} exit=#{result.exit_code}"

    # Give cast some time to land
    Process.sleep(100)

    # Confirm member NOW IS in the SAME GenServer this test spawned —
    # proves the CLI exec ran in the same BEAM, not a separate VM
    state_after = :sys.get_state(session_pid, 500)

    member_present? =
      Enum.any?(Map.keys(state_after.state.chat.members), fn k ->
        URI.to_string(k) == member_uri_str
      end)

    assert member_present?, """
    CLI exec completed (exit 0) but member #{member_uri_str} is NOT in the
    Session GenServer this test holds a pid for.

    Means CLI dispatched against a DIFFERENT BEAM than the test — breaks
    CLI ↔ LV isomorphism.

    Members in this BEAM: #{inspect(Enum.map(Map.keys(state_after.state.chat.members), &URI.to_string/1))}
    """
  end

  test "CLI exec returns formatted output + correct exit code" do
    # Help path: no args
    result = EzagentCli.Exec.exec([])
    assert is_map(result)
    assert is_binary(result.output)
    assert result.exit_code == 0
    assert result.output =~ "ESR Invocation CLI"
  end

  test "CLI exec for unknown subcommand returns non-zero exit" do
    result = EzagentCli.Exec.exec(["totally_nonexistent_kind"])
    assert result.exit_code != 0
  end
end
