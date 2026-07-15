defmodule Ezagent.Invariants.MemberCapVerifiedReaderTest do
  use ExUnit.Case, async: true

  @member_cap Path.expand(
                "../../lib/ezagent/behavior/session/member_cap.ex",
                __DIR__
              )

  test "member capability idempotency reads only through EntityCaps" do
    source = File.read!(@member_cap)
    [reader] = Regex.run(~r/defp member_snapshot_caps.*?\n\s*# The member-cap granter/s, source)

    assert reader =~ "Ezagent.EntityCaps.load_persisted(member_uri)"
    refute reader =~ "SnapshotStore.latest"
    refute reader =~ "caps_json"
    refute reader =~ "Users.get_by_uri"
  end

  test "reader failures are treated as grant not observed" do
    source = File.read!(@member_cap)
    [reader] = Regex.run(~r/defp member_snapshot_caps.*?\n\s*# The member-cap granter/s, source)

    assert reader =~ "rescue"
    assert reader =~ "_ -> []"
  end
end
