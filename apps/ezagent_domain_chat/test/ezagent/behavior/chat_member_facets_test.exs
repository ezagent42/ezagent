defmodule Ezagent.Behavior.ChatMemberFacetsTest do
  @moduledoc """
  team-routing-unification §3.1 (PR-5a) — pure unit coverage for the member
  facet read accessor `Ezagent.Behavior.Chat.role_name_to_uri/2`. The threading
  that POPULATES member meta (handle_join → do_join → meta), the role_name
  uniqueness guard, and facet-preservation on rejoin are covered end-to-end in
  the integration suite (session_auto_join_test.exs).

  PR-5b-i adds `:provenance` (management authority) — honored only from a
  trusted `system://` caller and set first-non-nil; the read accessor
  `member_provenance/2` is covered here, the trust/set-once threading in the
  integration suite.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Chat

  defp uri(s), do: URI.new!(s)

  describe "member_provenance/2" do
    test "returns the provenance facet when present" do
      builder = uri("entity://agent/team/builder")
      owner = uri("entity://user/system/admin")
      members = %{builder => %{online: true, provenance: owner}}

      assert Chat.member_provenance(members, builder) == owner
    end

    test "returns nil for a member with no provenance facet" do
      admin = uri("entity://user/system/admin")
      assert Chat.member_provenance(%{admin => %{online: true}}, admin) == nil
    end

    test "returns nil for an absent member" do
      assert Chat.member_provenance(%{}, uri("entity://user/system/ghost")) == nil
    end
  end

  describe "role_name_to_uri/2" do
    test "resolves a role_name to its member URI" do
      relay = uri("entity://agent/team/relay")

      members = %{
        relay => %{online: true, role_name: "relay"},
        uri("entity://user/system/admin") => %{online: true}
      }

      assert Chat.role_name_to_uri(members, "relay") == relay
    end

    test "returns nil when no member carries that role_name" do
      members = %{uri("entity://user/system/admin") => %{online: true, role_name: "owner"}}
      assert Chat.role_name_to_uri(members, "relay") == nil
    end

    test "returns nil against an empty members map" do
      assert Chat.role_name_to_uri(%{}, "relay") == nil
    end
  end
end
