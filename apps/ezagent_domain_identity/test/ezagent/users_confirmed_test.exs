defmodule Ezagent.UsersConfirmedTest do
  @moduledoc """
  #154 spec 甲 PR-甲-1 — `confirmed` is the real source of truth for anon-ness.
  `create/3` mints a confirmed user; `create_read_only/2` mints an unconfirmed
  (anonymous) user; `confirmed?/1` reads it and fail-closes on an absent row.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Users

  test "create/3 makes a CONFIRMED user" do
    uri = "entity://t-conf/user/alice-#{System.unique_integer([:positive])}"
    {:ok, u} = Users.create(uri, "pw-not-secret", [])
    assert u.confirmed == true
    assert Users.confirmed?(uri) == true
  end

  test "create_read_only/2 makes an UNCONFIRMED (anon) user" do
    uri = "entity://t-conf/user/anon-#{System.unique_integer([:positive])}"
    {:ok, a} = Users.create_read_only(uri, [])
    assert a.confirmed == false
    assert Users.confirmed?(uri) == false
  end

  test "confirmed?/1 fail-closes to false on an absent row" do
    assert Users.confirmed?("entity://t-conf/user/ghost-#{System.unique_integer([:positive])}") ==
             false
  end
end
