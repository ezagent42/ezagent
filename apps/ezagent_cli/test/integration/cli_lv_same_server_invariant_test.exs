defmodule EzagentCli.Integration.CliRuntimeSameServerInvariantTest do
  @moduledoc """
  Post-Phase-5 invariant (Allen 2026-05-17): CLI and runtime UI must reach the
  SAME BEAM. Previously `mix ezagent` started its own VM and the dispatch
  hit isolated state — the UI couldn't see CLI mutations. That was a real
  drift.

  Final design: `Mix.Tasks.Esr` connects via distributed Erlang RPC
  (Allen 2026-05-17 second pivot — dropping HTTP indirection). The
  CLI process does `Node.connect(runtime) + :rpc.call(runtime,
  EzagentCli.Exec, :exec, [argv])`. Same BEAM, same KindRegistry, zero
  serde.

  This test pins the invariant by:
  1. Spawning a User Kind in THIS test process's BEAM
  2. Calling `EzagentCli.Exec.exec(["user", "grant_cap", ...])` directly
     (server-side path — same as what `:rpc.call` invokes on the
     runtime node in real CLI use)
  3. Asserting the User GenServer's state changed in THIS BEAM
     (the identity cap set now contains the granted cap)

  If a future refactor moves CLI back to spawning its own VM, the
  cap assertion will FAIL because the grant happens in a separate
  process tree from the one this test inspects.
  """
  use EzagentCore.DataCase, async: false
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.Session

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).

    # The CLI tree is derived from BehaviorRegistry at invocation time.
    # Keep this invariant independent from umbrella test ordering: earlier
    # suites may alter registry state, but this test specifically needs the
    # session.join action to exist.
    :ok = Ezagent.CapabilityRegistry.register(Session, :join, SessionBehavior)

    # CLI/GUI audit HIGH-1 — Dispatch no longer silent-fallbacks to
    # admin. Tests set the per-process override that
    # `EzagentCli.Exec.exec/2` would set in production after token auth.
    #
    # 2026-05-26 (Allen): caller is a `team-alpha` workspace user so the
    # CLI's `promote_to_3seg/4` fills the workspace slot with
    # `team-alpha` — matching the session spawned below at
    # `session://team-alpha/default/...`. Previously the override
    # carried `admin_uri()` (workspace `system`), which made the CLI
    # promote `--session <bare>` to `session://system/default/<bare>`
    # while the test had spawned in `team-alpha` → "no such actor"
    # mismatch surfaced once PR #362 tightened structural workspace
    # derivation. Holding `*` caps so caps step 5.5 isn't the gate
    # under test here (this test pins the BEAM-isomorphism invariant).
    test_user_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/cli-lv-isomorphism-tester-#{System.unique_integer([:positive])}"
      )

    Process.put(
      :ezagent_cli_caller_override,
      {test_user_uri, MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
    )

    {:ok, caller_uri: test_user_uri}
  end

  test "CLI server-side exec changes Identity caps IN THIS BEAM", ctx do
    subject_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/cli-runtime-isomorphism-subject-#{System.unique_integer([:positive])}"
      )

    {:ok, _decoded} = Ezagent.Users.create(subject_uri, nil, [])
    {:ok, subject_pid} = Ezagent.SpawnRegistry.spawn(subject_uri)
    Process.sleep(50)

    cap =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.World.Behavior.Layout,
        :manage,
        Ezagent.URI.new!("workspace://team-alpha"),
        Ezagent.URI.new!("workspace://team-alpha")
      )
      |> Map.put(:granted_by, ctx.caller_uri)
      |> Map.put(:granted_at, DateTime.utc_now())

    cap_json = Jason.encode!(Ezagent.Capability.to_map(cap))

    state_before = :sys.get_state(subject_pid, 500)
    refute cap_present?(state_before, cap)

    # Mint a CLI token for a `team-alpha` workspace user — codex CLI/GUI audit
    # HIGH-1 closed the silent admin fallback, so Exec now requires
    # explicit token + entity_uri opts (mirroring how the real
    # /api/cli/exec route works after operator authenticates).
    #
    # 2026-05-26 (Allen): the caller's workspace must MATCH the session's
    # workspace because CLI's `promote_to_3seg/4` fills the workspace
    # slot of the bare `--session <name>` from the caller URI. The
    # session was spawned in `team-alpha` above, so the caller is in
    # `team-alpha` too. Caps include `*` so step 5.5 isn't the test gate.
    caller_uri = ctx.caller_uri

    signed_genesis =
      Ezagent.Test.CapHelper.issue!(caller_uri, Ezagent.Capability.admin_genesis_cap())

    {:ok, _decoded} =
      Ezagent.Users.create(
        caller_uri,
        nil,
        [signed_genesis]
      )

    {plain_token, _row} = Ezagent.Entity.Token.mint(caller_uri, label: "test-cli-token")

    # Call CLI server-side path (what /api/cli/exec does)
    result =
      EzagentCli.Exec.exec(
        [
          "user",
          "grant_cap",
          "--user",
          URI.to_string(subject_uri),
          "--cap",
          cap_json
        ],
        token: plain_token
      )

    assert result.exit_code == 0,
           "CLI exec returned non-zero: output=#{inspect(result.output)} exit=#{result.exit_code}"

    state_after = :sys.get_state(subject_pid, 500)

    assert cap_present?(state_after, cap), """
    CLI exec completed (exit 0) but cap #{inspect(Ezagent.Capability.identity_key(cap))} is NOT in the
    User GenServer this test holds a pid for.

    Means CLI dispatched against a DIFFERENT BEAM than the test — breaks
    CLI ↔ runtime UI isomorphism.

    Caps in this BEAM: #{inspect(Enum.map(state_after.state.identity.state.caps, &Ezagent.Capability.identity_key/1))}
    """
  end

  test "CLI exec returns formatted output + correct exit code" do
    # Help path: no args
    result = EzagentCli.Exec.exec([])
    assert is_map(result)
    assert is_binary(result.output)
    assert result.exit_code == 0
    assert result.output =~ "Ezagent Invocation CLI"
  end

  test "CLI exec for unknown subcommand returns non-zero exit" do
    result = EzagentCli.Exec.exec(["totally_nonexistent_kind"])
    assert result.exit_code != 0
  end

  defp cap_present?(state, cap) do
    target = Ezagent.Capability.identity_key(cap)

    state.state.identity.state.caps
    |> Enum.any?(&(Ezagent.Capability.identity_key(&1) == target))
  end
end
