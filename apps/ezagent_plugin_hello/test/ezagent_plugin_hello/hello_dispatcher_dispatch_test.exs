defmodule EzagentPluginHello.HelloDispatcherDispatchTest do
  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.HelloDispatcher

  setup do
    parent = self()

    Application.put_env(:ezagent_plugin_hello, :kanban_delegation_start, fn session,
                                                                            text,
                                                                            sender ->
      send(parent, {:delegated, session, text, sender})
      {:ok, self()}
    end)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_hello, :kanban_delegation_start)
    end)

    :ok
  end

  test "dispatches a valid hello instruction to the delegation service" do
    session = Ezagent.URI.session("system", :hello, "dispatcher-test")
    sender = Ezagent.URI.user("system", "admin")

    assert {:ok, %{}, []} =
             HelloDispatcher.handle_delegate_to_kanban(
               %{
                 session_uri: URI.to_string(session),
                 instruction: "  Ship the homepage  ",
                 sender_uri: URI.to_string(sender)
               },
               %{}
             )

    assert_receive {:delegated, ^session, "Ship the homepage", ^sender}
  end

  test "invalid URI input does not invoke the delegation service" do
    assert {:ok, %{}, []} =
             HelloDispatcher.handle_delegate_to_kanban(
               %{session_uri: "not-a-session", instruction: "Ship it", sender_uri: "not-a-user"},
               %{}
             )

    refute_receive {:delegated, _, _, _}
  end
end
