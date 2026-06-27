defmodule Ezagent.Socialware.AdapterRegistrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry}
  alias Ezagent.Socialware.{ChatFeedAdapter, ExternalFeedAdapter}

  test "socialware registers chat and external pull adapters at boot" do
    assert {:ok, ChatFeedAdapter} = AdapterRegistry.lookup("chat_feed")
    assert {:ok, ExternalFeedAdapter} = AdapterRegistry.lookup("external_feed")
    assert Adapter.kind_of(ChatFeedAdapter) == :pull
    assert Adapter.kind_of(ExternalFeedAdapter) == :pull
  end

  test "registered adapters publish their allow cap subjects" do
    assert {:ok, %{behavior: ChatFeedAdapter.Allow}} =
             Ezagent.CapabilityRegistry.lookup_subject(
               Ezagent.Entity.Session,
               :allow_chat_feed
             )

    assert {:ok, %{behavior: ExternalFeedAdapter.Allow}} =
             Ezagent.CapabilityRegistry.lookup_subject(
               Ezagent.Entity.Session,
               :allow_external_feed
             )
  end

  test "registered disciplines are distinct and intact" do
    assert Adapter.delivery_discipline_of(ChatFeedAdapter) == :snapshot_refresh
    assert Adapter.participation_profile_of(ChatFeedAdapter) == :read_only
    assert Adapter.delivery_discipline_of(ExternalFeedAdapter) == :cursor_replay
    assert Adapter.participation_profile_of(ExternalFeedAdapter) == :participatory
  end
end
