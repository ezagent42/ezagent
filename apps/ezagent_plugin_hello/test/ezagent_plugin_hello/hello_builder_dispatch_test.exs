defmodule EzagentPluginHello.HelloBuilderDispatchTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message}
  alias Ezagent.ActionSet.HelloBuilder
  alias Ezagent.Entity.{Agent, Session}

  setup do
    old_generator_start = Application.get_env(:ezagent_plugin_hello, :generator_start)

    on_exit(fn ->
      case old_generator_start do
        nil -> Application.delete_env(:ezagent_plugin_hello, :generator_start)
        fun -> Application.put_env(:ezagent_plugin_hello, :generator_start, fun)
      end
    end)

    :ok
  end

  test "rebuild dispatch is authorized by caller-held cap and starts generation" do
    n = System.unique_integer([:positive])
    session_uri = Ezagent.URI.session("team-alpha", "default", "hello-rebuild-#{n}")
    builder_uri = Ezagent.URI.agent("team-alpha", "hello_builder_#{n}")
    allowed_uri = Ezagent.URI.agent("team-alpha", "hello_rebuilder_allowed_#{n}")
    denied_uri = Ezagent.URI.agent("team-alpha", "hello_rebuilder_denied_#{n}")
    workspace_uri = Ezagent.URI.workspace("team-alpha")
    test_pid = self()

    Application.put_env(:ezagent_plugin_hello, :generator_start, fn session, instruction ->
      send(test_pid, {:hello_rebuild_started, session, instruction})
      {:ok, self()}
    end)

    {:ok, _session_pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors()
      })

    {:ok, builder_pid} =
      Ezagent.Kind.spawn(Agent, %{
        uri: builder_uri,
        behaviors: Agent.base_behaviors() ++ [HelloBuilder],
        initial_caps: MapSet.new()
      })

    {:ok, _denied_pid} =
      Ezagent.Kind.spawn(Agent, %{uri: denied_uri, initial_caps: MapSet.new()})

    target = Ezagent.URI.with_action(builder_uri, :hello_builder, :rebuild)
    rebuild_cap = Ezagent.Test.CapHelper.signed_action_cap!(target, allowed_uri)

    {:ok, _allowed_pid} =
      Ezagent.Kind.spawn(Agent, %{
        uri: allowed_uri,
        initial_caps: MapSet.new([rebuild_cap])
      })

    Enum.each([session_uri, builder_uri, allowed_uri, denied_uri], fn uri ->
      :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri)
    end)

    on_exit(fn ->
      Enum.each(
        [session_uri, builder_uri, allowed_uri, denied_uri],
        &Ezagent.WorkspaceRegistry.unbind/1
      )
    end)

    join_builder(session_uri, builder_uri)
    :sys.get_state(builder_pid)

    args = %{session_uri: URI.to_string(session_uri), instruction: "refresh the hello page"}

    assert :ok =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: target,
               mode: :cast,
               args: args,
               ctx: %{
                 caller: denied_uri,
                 authenticated_principal: denied_uri,
                 caps: MapSet.new(),
                 reply: :ignore
               }
             })

    refute_receive {:hello_rebuild_started, _, _}, 100

    assert :ok =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: target,
               mode: :cast,
               args: args,
               ctx: %{
                 caller: allowed_uri,
                 authenticated_principal: allowed_uri,
                 caps: MapSet.new([rebuild_cap]),
                 reply: :ignore
               }
             })

    assert_receive {:hello_rebuild_started, ^session_uri, "refresh the hello page"}, 500
  end

  test "legacy receive entry still ignores agent senders" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_hello, :generator_start, fn session, instruction ->
      send(test_pid, {:unexpected_receive_generation, session, instruction})
      {:ok, self()}
    end)

    session_uri = Ezagent.URI.session("team-alpha", "default", "hello-receive-ignore")
    agent_sender = Ezagent.URI.agent("team-alpha", "agent_sender")
    msg = Message.new(agent_sender, %{text: "do not rebuild", attachments: []})

    assert {:ok, %{}, []} =
             HelloBuilder.handle_receive(%{message: msg}, %{caller: session_uri})

    refute_receive {:unexpected_receive_generation, _, _}, 100
  end

  defp join_builder(session_uri, builder_uri) do
    admin = URI.new!("entity://system/user/admin")
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{member: builder_uri, role_name: "builder"},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([cap]),
          reply: :ignore
        }
      })

    {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)
    :sys.get_state(session_pid)
    :ok
  end
end
