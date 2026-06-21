defmodule Ezagent.MessageStoreRelabelIdentityTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}

  defp session_uri(suffix \\ "main") do
    Ezagent.URI.session(:team_alpha, :default, "relabel-#{suffix}-#{u()}")
  end

  defp user(name), do: Ezagent.URI.entity(:team_alpha, :user, name)
  defp u, do: System.unique_integer([:positive])

  setup do
    session = session_uri()
    other_session = session_uri("other")
    workspace = Ezagent.Capability.workspace_of(session)

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    :ok = Ezagent.WorkspaceRegistry.bind(other_session, workspace)

    %{session: session, other_session: other_session}
  end

  describe "relabel_identity/3" do
    test "rewrites sender and mention references within the requested session", %{
      session: session
    } do
      from = user("anon-#{u()}")
      to = user("confirmed-#{u()}")
      other = user("other-#{u()}")

      {:ok, authored} =
        Message.new(from, %{text: "authored", attachments: []}, mentions: [from, other])
        |> MessageStore.write(session)

      {:ok, mentioned} =
        Message.new(other, %{text: "mentioned", attachments: []}, mentions: [from])
        |> MessageStore.write(session)

      {:ok, untouched} =
        Message.new(other, %{text: "untouched", attachments: []}, mentions: [other])
        |> MessageStore.write(session)

      assert {:ok, 2} = MessageStore.relabel_identity(session, from, to)

      assert {:ok, authored} = MessageStore.by_id(authored.id)
      assert URI.to_string(authored.sender) == URI.to_string(to)

      assert Enum.map(authored.mentions, &URI.to_string/1) == [
               URI.to_string(to),
               URI.to_string(other)
             ]

      assert {:ok, mentioned} = MessageStore.by_id(mentioned.id)
      assert URI.to_string(mentioned.sender) == URI.to_string(other)
      assert Enum.map(mentioned.mentions, &URI.to_string/1) == [URI.to_string(to)]

      assert {:ok, untouched} = MessageStore.by_id(untouched.id)
      assert URI.to_string(untouched.sender) == URI.to_string(other)
      assert Enum.map(untouched.mentions, &URI.to_string/1) == [URI.to_string(other)]
    end

    test "is session-scoped and idempotent", %{
      session: session,
      other_session: other_session
    } do
      from = user("anon-#{u()}")
      to = user("confirmed-#{u()}")

      {:ok, in_scope} =
        Message.new(from, %{text: "in-scope", attachments: []}, mentions: [from])
        |> MessageStore.write(session)

      {:ok, out_of_scope} =
        Message.new(from, %{text: "out-of-scope", attachments: []}, mentions: [from])
        |> MessageStore.write(other_session)

      assert {:ok, 1} = MessageStore.relabel_identity(session, from, to)
      assert {:ok, 0} = MessageStore.relabel_identity(session, from, to)

      assert {:ok, in_scope} = MessageStore.by_id(in_scope.id)
      assert URI.to_string(in_scope.sender) == URI.to_string(to)
      assert Enum.map(in_scope.mentions, &URI.to_string/1) == [URI.to_string(to)]

      assert {:ok, out_of_scope} = MessageStore.by_id(out_of_scope.id)
      assert URI.to_string(out_of_scope.sender) == URI.to_string(from)
      assert Enum.map(out_of_scope.mentions, &URI.to_string/1) == [URI.to_string(from)]
    end
  end
end
