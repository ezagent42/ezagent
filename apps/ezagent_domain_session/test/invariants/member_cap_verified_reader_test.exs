defmodule Ezagent.Invariants.MemberCapVerifiedReaderTest do
  use ExUnit.Case, async: true

  @member_cap Path.expand(
                "../../lib/ezagent/behavior/session/member_cap.ex",
                __DIR__
              )
  @member_cap_migration Path.expand(
                          "../../lib/ezagent/session/member_cap_migration.ex",
                          __DIR__
                        )
  @orchestrator_caps Path.expand(
                       "../../lib/ezagent/entity/session/orchestrator/caps.ex",
                       __DIR__
                     )

  test "member capability idempotency reads only through EntityCaps" do
    source = File.read!(@member_cap)

    assert source =~ "Ezagent.EntityCaps.effective_caps_persisted(member_uri)"
    assert source =~ "{:ok, caps}"
    assert source =~ "{:error, _reason}"
    refute source =~ "defp member_snapshot_caps"
    refute source =~ "SnapshotStore.latest"
    refute source =~ "caps_json"
    refute source =~ "Users.get_by_uri"
  end

  test "all reconciliation callers consume tagged effective views" do
    migration = File.read!(@member_cap_migration)
    orchestrator = File.read!(@orchestrator_caps)

    assert migration =~ "Ezagent.EntityCaps.effective_caps(member_uri)"
    assert migration =~ "{:error, reason}"
    assert orchestrator =~ "Ezagent.EntityCaps.effective_caps(orchestrator_uri)"
    assert orchestrator =~ "with {:ok, current}"
  end
end
