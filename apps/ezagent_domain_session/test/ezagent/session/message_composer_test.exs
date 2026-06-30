defmodule Ezagent.Session.MessageComposerTest do
  @moduledoc """
  Unit coverage for the sanctioned composer-surface message builder.

  Drives a LIVE default Session (`session://system/default/main`, spawned at
  domain boot) + a real `chat.join` so the `:session` slice carries a member;
  then asserts the composer resolves bare + explicit `@mentions` and builds a
  real `%Message{}` (the exact shape `Behavior.Session.handle_send/2` consumes).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message}
  alias Ezagent.Session.MessageComposer
  alias Ezagent.Entity.{Session, User}

  setup do
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "main",
        User.admin_uri(),
        template_name: "default"
      )

    :ok = EzagentDomainInstanceMessage.AgentBridgeTestAdapter.ensure_registered()
    :ok
  end

  defp join_member(session_uri, member_uri) do
    {:ok, pid} = GenServer.start(__MODULE__.NoopMember, member_uri)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    bootstrap_caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: bootstrap_caps, reply: :ignore}
      })

    # Drain the join commit through the GenServer before reading the slice.
    {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)
    _ = :sys.get_state(session_pid)
    :ok
  end

  describe "member_options/1" do
    test "reads the live :session slice members + resolves display names" do
      session_uri = Session.default_uri()

      member_uri =
        URI.new!("entity://team-alpha/agent/mc-#{System.unique_integer([:positive])}")

      :ok = join_member(session_uri, member_uri)

      rows = MessageComposer.member_options(session_uri)
      uris = Enum.map(rows, &Map.get(&1, "uri"))

      assert URI.to_string(member_uri) in uris
      assert Enum.all?(rows, &is_binary(Map.get(&1, "display_name")))
    end
  end

  describe "parse_mentions/2" do
    test "explicit @entity:// URI resolves" do
      members = []
      uri = "entity://team-alpha/agent/pm-coordinator-kbflow"

      assert MessageComposer.parse_mentions("hey @#{uri} please claim", members)
             |> Enum.map(&URI.to_string/1) == [uri]
    end

    test "bare @name resolves by URI path segment against members" do
      uri = "entity://team-alpha/agent/pm-coordinator-kbflow"
      members = [%{"uri" => uri, "display_name" => "PM Coordinator"}]

      assert MessageComposer.parse_mentions("@pm-coordinator-kbflow take n2", members)
             |> Enum.map(&URI.to_string/1) == [uri]
    end

    test "unknown bare @name resolves to nothing (no guess)" do
      members = [%{"uri" => "entity://team-alpha/agent/pm", "display_name" => "PM"}]
      assert MessageComposer.parse_mentions("@nobody hi", members) == []
    end
  end

  describe "build_message/3 (live session)" do
    test "builds a real %Message{} with @name resolved against the live slice" do
      session_uri = Session.default_uri()
      sender = User.admin_uri()

      member_uri =
        URI.new!("entity://team-alpha/agent/mc-build-#{System.unique_integer([:positive])}")

      :ok = join_member(session_uri, member_uri)

      seg = member_uri |> Ezagent.URI.name() |> elem(1)
      text = "@#{seg} please claim n2"

      msg = MessageComposer.build_message(sender, text, session_uri)

      assert %Message{} = msg
      assert msg.sender == sender
      assert msg.body.text == text
      assert Enum.map(msg.mentions, &URI.to_string/1) == [URI.to_string(member_uri)]
    end
  end

  defmodule NoopMember do
    @moduledoc false
    use GenServer

    @impl true
    def init(uri) do
      :ok = Ezagent.KindRegistry.put_new(uri)
      {:ok, %{}}
    end
  end
end
