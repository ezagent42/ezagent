defmodule Ezagent.IdentityCapsMatchFailLoudTest do
  # `async: true` so each test owns an isolated (manual-mode) Ecto sandbox
  # connection — a process WITHOUT an allowance then genuinely cannot read the
  # authority table. (The main IdentityTest is `async: false` → shared-mode
  # sandbox, where spawned processes CAN read, so this deterministic
  # fault-injection lives here. Same pattern as
  # `Ezagent.Cap.AuthorityCheckedVerifyTest`.)
  use EzagentCore.DataCase, async: true

  import Ezagent.Test.CapHelper, only: [install_test_authority!: 2, authority_signed_cap!: 3]

  # P3 (cap-revocation hardening) fail-LOUD contract: `caps_match?/2`'s per-call
  # target re-verify must RAISE `Ezagent.Cap.AuthorityReadError` on a TRANSIENT
  # authority-store read failure — NEVER silently return `false` (the
  # silent-denial class #1346 / `Ezagent.Cap.HoldsCap` forbid).
  test "caps_match?/2 RAISES on a transient authority-store read failure (never a silent false)" do
    suffix = System.unique_integer([:positive])
    holder = Ezagent.URI.new!("entity://team-alpha/user/p3-loud-#{suffix}")
    target = Ezagent.URI.new!("entity://team-alpha/agent/p3-loud-target-#{suffix}")

    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Manage,
      action: :read_cascade,
      instance: Ezagent.URI.instance(target),
      workspace_uri: Ezagent.Capability.workspace_of(target)
    }

    authority = install_test_authority!(target, :agent)

    manage_cap =
      authority_signed_cap!(
        authority,
        holder,
        Ezagent.Capability.cap(
          :agent,
          Ezagent.ActionSet.Manage,
          :read_cascade,
          Ezagent.URI.instance(target),
          Ezagent.Capability.workspace_of(target)
        )
      )

    # Sanity: with this process's sandbox connection, the cap re-verifies.
    assert Ezagent.Identity.caps_match?([manage_cap], needed)

    # A process WITHOUT sandbox ownership cannot read the authority table →
    # the checked verifier returns {:error, :authority_read_failed} →
    # `caps_match?/2` must RAISE (fail-LOUD), not return `false`.
    parent = self()

    spawn(fn ->
      result =
        try do
          {:no_raise, Ezagent.Identity.caps_match?([manage_cap], needed)}
        rescue
          e in Ezagent.Cap.AuthorityReadError -> {:raised, e}
        end

      send(parent, {:caps_match_result, result})
    end)

    assert_receive {:caps_match_result, {:raised, %Ezagent.Cap.AuthorityReadError{}}}, 2_000
  end
end
