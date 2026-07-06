defmodule Ezagent.World.ConversationViewTest do
  @moduledoc """
  Stage 1 — chat is enumerated through `Ezagent.UI.SessionViewRegistry` via a
  world-owned `ConversationView`, not a hard-coded world-native tab. These pin
  the SessionView contract callbacks + registry discoverability.
  """
  use ExUnit.Case, async: false

  alias Ezagent.UI.SessionViewRegistry
  alias Ezagent.World.ConversationView

  setup do
    :ok = SessionViewRegistry.init()
    :ok = SessionViewRegistry.register(ConversationView)
    :ok
  end

  test "declares the chat view contract" do
    assert ConversationView.id() == :conversation
    assert ConversationView.label() == "Chat"
    assert ConversationView.icon() == "message-square"
    assert ConversationView.view_behavior() == nil
    assert ConversationView.applies_to?(Ezagent.URI.session("acme", "default", "s1")) == true
    refute ConversationView.applies_to?(:not_a_uri)
  end

  test "is discoverable in the registry after registration" do
    assert {:ok, ConversationView} = SessionViewRegistry.lookup(:conversation)
  end
end
