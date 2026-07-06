defmodule Ezagent.World.ConversationView do
  @moduledoc """
  world-owned `Ezagent.UI.SessionView` for the chat stream, registered so the
  chat tab is enumerated through `Ezagent.UI.SessionViewRegistry` like every
  other view (pty / hello-page / …) rather than being a hard-coded world-native
  default.

  world renders the chat content in React (`Conversation.tsx`), NOT through this
  `render/1` — the HEEx below is a contract-satisfying stub for the (retired)
  admin_live host. Not cap-gated (`view_behavior/0 → nil`): chat is visible to
  any caller who can already see the session.
  """
  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  @impl true
  def id, do: :conversation

  @impl true
  def label, do: "Chat"

  @impl true
  def icon, do: "message-square"

  @impl true
  def applies_to?(%URI{}), do: true
  def applies_to?(_), do: false

  @impl true
  def view_behavior, do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id="world-conversation-view" class="flex-1 min-h-0">
      <%!-- world renders chat in React; this stub only satisfies the contract. --%>
    </div>
    """
  end
end
