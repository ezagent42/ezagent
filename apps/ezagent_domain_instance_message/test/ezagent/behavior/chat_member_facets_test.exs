defmodule Ezagent.Behavior.ChatMemberFacetsTest do
  @moduledoc """
  team-routing-unification §3.1 (PR-5a) — pure unit coverage for the member
  facet read accessor `Ezagent.Behavior.Chat.role_name_to_uri/2`. The threading
  that POPULATES member meta (handle_join → do_join → meta), the role_name
  uniqueness guard, and facet-preservation on rejoin are covered end-to-end in
  the integration suite (session_auto_join_test.exs).

  NOTE: `:provenance` (management authority) is NOT a PR-5a facet — it lands in
  PR-5b with its caller-derivation + authorization, so there is no
  `member_provenance/2` accessor here yet.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Chat

  defp uri(s), do: URI.new!(s)

  describe "role_name_to_uri/2" do
    test "resolves a role_name to its member URI" do
      relay = uri("entity://team/agent/relay")

      members = %{
        relay => %{online: true, role_name: "relay"},
        uri("entity://system/user/admin") => %{online: true}
      }

      assert Chat.role_name_to_uri(members, "relay") == relay
    end

    test "returns nil when no member carries that role_name" do
      members = %{uri("entity://system/user/admin") => %{online: true, role_name: "owner"}}
      assert Chat.role_name_to_uri(members, "relay") == nil
    end

    test "returns nil against an empty members map" do
      assert Chat.role_name_to_uri(%{}, "relay") == nil
    end
  end
end
