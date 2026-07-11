defmodule EzagentPluginHello.HelloPublisherDispatchTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.ActionSet.HelloPublisher
  alias Ezagent.Entity.Agent

  setup do
    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok
  end

  test ":publish dispatch is cap-gated — denied without the :publish cap" do
    n = System.unique_integer([:positive])
    ws_uri = Ezagent.URI.workspace("team-alpha")
    publisher_uri = Ezagent.URI.agent("team-alpha", "hello_publisher_#{n}")
    denied_uri = Ezagent.URI.agent("team-alpha", "hello_denied_#{n}")

    {:ok, _pub_pid} =
      Ezagent.Kind.spawn(Agent, %{
        uri: publisher_uri,
        behaviors: Agent.base_behaviors() ++ [HelloPublisher],
        initial_caps: MapSet.new()
      })

    {:ok, _denied_pid} =
      Ezagent.Kind.spawn(Agent, %{uri: denied_uri, initial_caps: MapSet.new()})

    Enum.each([publisher_uri, denied_uri], fn uri ->
      :ok = Ezagent.WorkspaceRegistry.bind(uri, ws_uri)
    end)

    on_exit(fn ->
      Enum.each([publisher_uri, denied_uri], &Ezagent.WorkspaceRegistry.unbind/1)
    end)

    target = Ezagent.URI.with_action(publisher_uri, :agent, :publish)
    args = %{session_uri: "session://team-alpha/hello/test", instruction: "publish this"}

    # F1: a caller WITHOUT the :publish cap is rejected.
    result_denied =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: args,
        ctx: %{caller: denied_uri, caps: MapSet.new(), reply: {:caller_inbox, self()}}
      })

    assert {:error, :unauthorized} = result_denied

    # A caller WITH the :publish cap is authorized (but will fail on missing
    # session — that's expected; the cap-gate is what we are testing).
    publish_cap =
      %Capability{
        Capability.cap(:agent, HelloPublisher, :publish, publisher_uri, ws_uri)
        | granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: DateTime.utc_now()
      }

    result_allowed =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: MapSet.new([publish_cap]),
          reply: {:caller_inbox, self()}
        }
      })

    # :call mode gets a result (not just :ok for :cast). With admin + the
    # cap, the dispatch is authorized; the handler runs and returns {:ok,%{},[]}.
    assert {:ok, %{}, []} = result_allowed
  end
end

