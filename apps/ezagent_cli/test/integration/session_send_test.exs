defmodule EzagentCli.Integration.SessionSendTest do
  @moduledoc """
  Phase 3 ③ T7h Part A — `mix ezagent session send` builds a REAL
  `%Ezagent.Message{}` (with server-side @mention resolution) and routes it
  through the sanctioned `session.send` dispatch.

  Regression target (act4 发现 2-#2): the auto-derived verb handed
  `Behavior.Session.handle_send/2` a plain map, which its `%{message:
  %Message{}}` head rejected → the `:cast` was silently dropped (0 rows in
  `messages`, no fan-out, "ok" was only cast-accept). This proves the message
  now lands in the store AND the `@member` mention resolves to the member URI
  (so an `@pm` would route to pm).
  """

  use EzagentCore.DataCase, async: false

  alias EzagentCli.Dispatch
  alias Ezagent.{KindRegistry, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}

  setup do
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "main",
        User.admin_uri(),
        template_name: "default"
      )

    # Mirror what `EzagentCli.Exec.exec/2` sets after token auth — no admin
    # fallback in `Dispatch.derive_caller/1`.
    Process.put(
      :ezagent_cli_caller_override,
      {User.admin_uri(), MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
    )

    :ok
  end

  defp join_member(session_uri, member_uri) do
    {:ok, pid} = GenServer.start(__MODULE__.NoopMember, member_uri)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: caps, reply: :ignore}
      })

    {:ok, session_pid} = KindRegistry.lookup(session_uri)
    _ = :sys.get_state(session_pid)
    {:ok, session_pid}
  end

  test "session send builds a real Message + resolves @mention + lands in the store" do
    session_uri = Session.default_uri()

    member_uri =
      URI.new!("entity://team-alpha/agent/cli-send-#{System.unique_integer([:positive])}")

    {:ok, session_pid} = join_member(session_uri, member_uri)

    seg = member_uri |> Ezagent.URI.name() |> elem(1)
    text = "@#{seg} please claim n2 #{System.unique_integer([:positive])}"

    parsed = %{
      options: %{session: URI.to_string(session_uri), message: text},
      flags: %{cast: true, json: false}
    }

    assert {:ok, _} = Dispatch.run_session_send(parsed)

    # Drain the cast commit through the GenServer before reading the store.
    _ = :sys.get_state(session_pid)

    # `body` round-trips through JSON in MessageStore → string keys on read.
    rows = MessageStore.recent_in_session(session_uri, 50)
    stored = Enum.find(rows, fn %Message{} = m -> Map.get(m.body, "text") == text end)

    assert %Message{} = stored, "expected the sent message to land in the store"
    assert stored.sender == User.admin_uri()
    assert Enum.map(stored.mentions, &URI.to_string/1) == [URI.to_string(member_uri)]
  end

  test "session send refuses without an identity (no silent admin elevation)" do
    Process.delete(:ezagent_cli_caller_override)

    parsed = %{
      options: %{session: URI.to_string(Session.default_uri()), message: "hi"},
      flags: %{cast: true, json: false}
    }

    assert {:error, :no_identity} = Dispatch.run_session_send(parsed)
  end

  test "session send requires --message" do
    parsed = %{
      options: %{session: URI.to_string(Session.default_uri())},
      flags: %{cast: true, json: false}
    }

    assert {:error, :missing_message} = Dispatch.run_session_send(parsed)
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
