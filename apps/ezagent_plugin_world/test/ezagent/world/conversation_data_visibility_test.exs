defmodule Ezagent.World.ConversationDataVisibilityTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Message, MessageStore}
  alias Ezagent.World.ConversationData

  @workspace_uri URI.new!("workspace://team-alpha")
  @sender URI.new!("entity://team-alpha/user/sender")
  @viewer URI.new!("entity://team-alpha/user/viewer")

  setup do
    session_uri =
      Ezagent.URI.new!("session://team-alpha/default/p8a-#{System.unique_integer([:positive])}")

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    %{session_uri: session_uri}
  end

  defp write(session_uri, text, opts) do
    message = Message.new(@sender, %{text: text, attachments: []}, opts)
    assert {:ok, written} = MessageStore.write(message, session_uri)
    written
  end

  defp state_texts(session_uri, caps) do
    session_uri
    |> ConversationData.state_for(%{
      caller_uri: @viewer,
      caller_caps: caps,
      workspace_uri: @workspace_uri,
      sessions: []
    })
    |> Map.fetch!("messages")
    |> Enum.map(&Map.fetch!(&1, "text"))
  end

  defp read_unfiltered_cap(session_uri) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :read_unfiltered,
      session_uri,
      @workspace_uri
    )
  end

  test "conversation state hides internal messages without read_unfiltered cap", %{
    session_uri: session_uri
  } do
    write(session_uri, "public", visibility: :external_visible)
    write(session_uri, "internal", visibility: :internal)

    assert state_texts(session_uri, MapSet.new()) == ["public"]

    assert state_texts(session_uri, MapSet.new([read_unfiltered_cap(session_uri)])) == [
             "public",
             "internal"
           ]
  end

  test "load_older hides internal messages without read_unfiltered cap", %{
    session_uri: session_uri
  } do
    base = ~U[2026-06-28 00:00:00.000000Z]
    write(session_uri, "public-old", inserted_at: DateTime.add(base, 1, :second))

    write(session_uri, "internal-old",
      inserted_at: DateTime.add(base, 2, :second),
      visibility: :internal
    )

    write(session_uri, "public-new", inserted_at: DateTime.add(base, 3, :second))

    cursor = DateTime.add(base, 10, :second) |> DateTime.to_iso8601()

    viewer_ctx = %{user_can_fix: false, fix_owner_display_name: nil}

    assert {rows, _cursor} =
             ConversationData.load_older(session_uri, cursor, MapSet.new(), viewer_ctx)

    assert Enum.map(rows, &Map.fetch!(&1, "text")) == ["public-old", "public-new"]
  end
end
