defmodule Ezagent.Entity.InviteCodeTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.InviteCode

  defp mint(attrs \\ %{}) do
    base = %{
      workspace_uri: "workspace://team-alpha",
      created_by: "entity://system/user/admin"
    }

    {:ok, {raw, row}} = InviteCode.mint(Map.merge(base, attrs))
    {raw, row}
  end

  test "mint/1 generates a code and stores workspace + creator + quota defaults" do
    {raw, row} = mint()
    assert is_binary(raw) and byte_size(raw) > 10
    assert row.code == raw
    assert row.workspace_uri == "workspace://team-alpha"
    assert row.max_uses == 1
    assert row.used_count == 0
  end

  test "mint/1 rejects max_uses < 1" do
    assert {:error, cs} =
             InviteCode.mint(%{
               workspace_uri: "workspace://team-alpha",
               created_by: "entity://system/user/admin",
               max_uses: 0
             })

    refute cs.valid?
  end

  test "validate/1 returns the row for a fresh code; :invalid for unknown" do
    {raw, _} = mint()
    assert {:ok, %InviteCode{}} = InviteCode.validate(raw)
    assert {:error, :invalid} = InviteCode.validate("nope")
  end

  test "consume/1 succeeds once for a single-use code, then :exhausted" do
    {raw, _} = mint(%{max_uses: 1})
    assert {:ok, row} = InviteCode.consume(raw)
    assert row.used_count == 1
    assert {:error, :exhausted} = InviteCode.consume(raw)
    assert {:error, :exhausted} = InviteCode.validate(raw)
  end

  test "consume/1 honors a quota of N" do
    {raw, _} = mint(%{max_uses: 3})
    assert {:ok, %{used_count: 1}} = InviteCode.consume(raw)
    assert {:ok, %{used_count: 2}} = InviteCode.consume(raw)
    assert {:ok, %{used_count: 3}} = InviteCode.consume(raw)
    assert {:error, :exhausted} = InviteCode.consume(raw)
  end

  test "expired code → :expired (not consumable)" do
    {raw, _} = mint(%{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
    assert {:error, :expired} = InviteCode.validate(raw)
    assert {:error, :expired} = InviteCode.consume(raw)
  end

  test "revoke/1 blocks future consumes; :revoked thereafter" do
    {raw, _} = mint(%{max_uses: 5})
    assert {:ok, _} = InviteCode.revoke(raw)
    assert {:error, :revoked} = InviteCode.validate(raw)
    assert {:error, :revoked} = InviteCode.consume(raw)
  end

  test "list/0 and list/1 by workspace" do
    {_, _} = mint(%{workspace_uri: "workspace://team-alpha"})
    {_, _} = mint(%{workspace_uri: "workspace://team-beta"})
    assert length(InviteCode.list()) >= 2
    only_beta = InviteCode.list("workspace://team-beta")
    assert Enum.all?(only_beta, &(&1.workspace_uri == "workspace://team-beta"))
  end
end
