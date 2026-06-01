defmodule Ezagent.Behavior.ChatMemberFacetsTest do
  @moduledoc """
  team-routing-unification §3.1 (PR-5a) — pure unit coverage for the member
  facet accessors `Ezagent.Behavior.Chat.member_provenance/2` and
  `role_name_to_uri/2`. These read the per-session member-meta map; the
  threading that POPULATES that map (handle_join → do_join → meta) is covered
  end-to-end in the integration suite (session_auto_join_test.exs).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Chat

  defp uri(s), do: URI.new!(s)

  describe "member_provenance/2" do
    test "returns the provenance facet when present" do
      members = %{
        uri("entity://agent/team/builder") => %{
          online: true,
          provenance: uri("entity://user/system/admin")
        }
      }

      assert Chat.member_provenance(members, uri("entity://agent/team/builder")) ==
               uri("entity://user/system/admin")
    end

    test "returns nil for a member with no provenance facet (plain join meta)" do
      members = %{uri("entity://user/system/admin") => %{online: true}}
      assert Chat.member_provenance(members, uri("entity://user/system/admin")) == nil
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
