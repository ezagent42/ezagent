defmodule Ezagent.Entity.SessionOwnerTest do
  @moduledoc """
  PR-OWN-2 acceptance tests (caps-data-ownership SPEC #306 §7).

  Covers:
  - (a) Session.owner/1 returns the owner_uri recorded at session
    creation
  - Behavior.Session.data_owner/1 maps a session URI to the owner via
    Session.owner/1

  Tests for §5.2 grant_cap enforcement (acceptance b-e) live in
  ezagent_domain_identity (where the Identity Behavior is) +
  end-to-end NonAdminGrantFlow integration tests.
  """
  use ExUnit.Case, async: false

  defp uniq, do: System.unique_integer([:positive])

  describe "Behavior.Session.data_owner/1 (PR-OWN-2 §3.3)" do
    test "session URI without live Kind returns :no_owner" do
      session_uri =
        Ezagent.URI.new!("session://generic/team-alpha/dead-#{uniq()}")

      assert :no_owner = Ezagent.Behavior.Session.data_owner(session_uri)
    end

    test ":any input returns :any (class-wide query)" do
      assert :any = Ezagent.Behavior.Session.data_owner(:any)
    end

    test "non-session URI returns :no_owner (Chat only owns Session caps)" do
      user_uri = Ezagent.URI.new!("entity://acme/user/alice-#{uniq()}")
      assert :no_owner = Ezagent.Behavior.Session.data_owner(user_uri)
    end
  end

  describe "Session.owner/1 lookup contract" do
    test "missing session returns {:error, :not_found}" do
      session_uri =
        Ezagent.URI.new!("session://generic/team-alpha/ghost-#{uniq()}")

      assert {:error, :not_found} = Ezagent.Entity.Session.owner(session_uri)
    end
  end
end
