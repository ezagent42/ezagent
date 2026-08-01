defmodule Ezagent.Session.MemberCapMigrationTest do
  @moduledoc """
  Membership-cap unification A1.4 (spec test 25 + the R3.2 acceptance cases) —
  the member-cap backfill migration: repo-only keyset READ, live-grant WRITE,
  idempotent by EXACT member-cap identity, sync-confirmed grants, `--dry-run` /
  `--gate` flags.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Session.MemberCapMigration, as: Migration
  alias Ezagent.Capability

  defp uniq, do: System.unique_integer([:positive])

  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # Seed a LEGACY session snapshot (members present, NO member-cap pre-granted)
  # through the sanctioned `SnapshotFixtures` helper (Gates #20) so the migration
  # has something to backfill. `session://system/…` derives its workspace
  # structurally, so the fixture write needs no registry binding.
  defp seed_session(member_uris, owner) do
    session = URI.new!("session://system/default/mig-#{uniq()}")
    members = Map.new(member_uris, fn u -> {u, %{online: false}} end)

    :ok =
      Ezagent.Test.SnapshotFixtures.save_kind_snapshot(
        session,
        Ezagent.Entity.Session,
        %{
          kind_base: %{
            state: %{behaviors: Ezagent.Entity.Session.behaviors()},
            transients: %{}
          },
          session: %{state: %{members: members, owner_uri: owner}, transients: %{}}
        }
      )

    session
  end

  defp member_cap_over?(%Capability{} = cap, session) do
    cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
      Capability.action_of(cap) == :receive and cap.instance == session
  end

  defp member_cap_over?(_, _), do: false

  defp holds_member_cap?(member, session) do
    member
    |> Ezagent.Identity.read_identity_caps()
    |> Enum.any?(&member_cap_over?(&1, session))
  end

  defp wait_holds(member, session, retries \\ 100) do
    cond do
      holds_member_cap?(member, session) ->
        true

      retries > 0 ->
        Process.sleep(10)
        wait_holds(member, session, retries - 1)

      true ->
        false
    end
  end

  test "migration grants the member-cap to every session member via the live grant path [test 25 core]" do
    owner = confirmed_user("owner")
    m1 = confirmed_user("m1")
    m2 = confirmed_user("m2")
    s1 = seed_session([m1], owner)
    s2 = seed_session([m2], owner)

    report = Migration.run([])

    assert report.sessions_scanned >= 2
    assert report.members_granted >= 2
    assert wait_holds(m1, s1), "m1 must hold the member-cap over s1 after migration"
    assert wait_holds(m2, s2), "m2 must hold the member-cap over s2 after migration"
  end

  test "migration backfills an existing owner even when the owner is absent from members" do
    owner = confirmed_user("owner-only")
    session = seed_session([], owner)

    refute holds_member_cap?(owner, session)
    Migration.run([])

    assert wait_holds(owner, session),
           "owner backfill must pair the removal of the structural owner bypass"
  end

  test "idempotent: a second run grants nothing and skips already-held [test 25]" do
    owner = confirmed_user("owner")
    m = confirmed_user("m")
    _s = seed_session([m], owner)

    first = Migration.run([])
    assert first.members_granted >= 1

    second = Migration.run([])
    assert second.members_granted == 0, "re-run must grant nothing (idempotent)"
    assert second.skipped_already_held >= 1, "re-run must skip the already-held member-cap"
  end

  test "session under an all-:any admin cap STILL receives its concrete member-cap [R3.2 idempotency]" do
    owner = confirmed_user("owner")
    member = confirmed_user("broad")
    session = seed_session([member], owner)

    # Give the member a BROAD :any session cap (authorizes :receive via matches?,
    # but is NOT the concrete member-cap).
    broad =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :any,
        session,
        Capability.workspace_of(session)
      )

    # A wildcard-action grant requires admin authority (genesis).
    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        member,
        broad,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )

    Migration.run([])

    assert wait_holds(member, session),
           "the concrete member-cap must be written even though a broad :any cap already authorizes"
  end

  test "a grant whose commit fails is NOT applied (only committed :ok migrates) [R3.2 grant-confirmation]" do
    owner = confirmed_user("owner")
    reachable = confirmed_user("reachable")
    # A member whose Kind is NEVER spawned → the live-grant dispatch fails.
    unreachable = URI.new!("entity://system/user/unreachable-#{uniq()}")
    session = seed_session([reachable, unreachable], owner)

    # Asserts per-member outcomes (robust to the persistent boot `default`
    # session that the global scan also sees): the reachable member IS granted,
    # the unreachable member's FAILED grant leaves no cap — so a non-committed
    # grant never counts as migrated.
    Migration.run([])

    assert wait_holds(reachable, session), "the reachable member's grant commits"

    refute holds_member_cap?(unreachable, session),
           "the unreachable member's failed grant leaves NO member-cap (not committed → not migrated)"
  end

  test "--dry-run writes nothing; --gate detects an uncovered member; migrate covers it [test 25]" do
    owner = confirmed_user("owner")
    m = confirmed_user("gate")
    session = seed_session([m], owner)

    # --dry-run: no writes.
    dry = Migration.run(["--dry-run"])
    assert dry.members_granted == 0, "--dry-run grants nothing"
    refute holds_member_cap?(m, session), "--dry-run must write no caps"

    # --gate BEFORE migrating m: the seeded member is uncovered → nonzero. (The
    # count is global — the persistent boot `default` session is also scanned —
    # so assert `>= 1`, driven by our own uncovered member, not an exact total.)
    assert {:error, {:uncovered_member_caps, n}} = Migration.run(["--gate"])
    assert n >= 1, "gate must report the uncovered member pre-migration"

    # Migrate → the seeded member is now covered.
    Migration.run([])
    assert wait_holds(m, session), "migration covers the member the gate flagged"
  end
end
