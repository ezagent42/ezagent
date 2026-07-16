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

    # Instruction is intentionally EMPTY. A non-empty instruction makes
    # `handle_publish` call `extract_explicit_name/1`, which shells out to a real
    # `claude -p` subprocess (EzagentPluginHello.LLM.ClaudeCode) to extract a
    # user-specified template name. Under `:call` mode that blocks the dispatch
    # past the 5s GenServer.call deadline and the test times out. An empty
    # instruction exercises the real production fallback
    # (`extract_explicit_name(_) -> :none` → session-name path) with no external
    # dependency, so the test stays hermetic. Do NOT restore a non-empty
    # instruction here — it reintroduces the subprocess hang.
    args = %{session_uri: "session://team-alpha/hello/test", instruction: ""}

    # F1: a caller WITHOUT the :publish cap is rejected.
    result_denied =
      Invocation.dispatch(%Invocation{origin: :trusted_internal,
        target: target,
        mode: :call,
        args: args,
        ctx: %{caller: denied_uri, caps: MapSet.new(), reply: {:caller_inbox, self()}}
      })

    assert {:error, :unauthorized} = result_denied

    # A caller WITH the :publish cap is authorized. The handler then runs and
    # fail-fasts on the missing session (expected) — the cap-gate is what we test.
    publish_cap =
      %Capability{
        Capability.cap(:agent, HelloPublisher, :publish, publisher_uri, ws_uri)
        | granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: DateTime.utc_now()
      }

    result_allowed =
      Invocation.dispatch(%Invocation{origin: :trusted_internal,
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: MapSet.new([publish_cap]),
          reply: {:caller_inbox, self()}
        }
      })

    # :call mode returns the dispatch result (not just :ok as for :cast). With
    # admin + the cap the dispatch is authorized; the handler returns its
    # `{:ok, reply, effects}` contract and dispatch surfaces the reply as
    # `{:ok, reply}` — here `{:ok, %{}}`.
    assert {:ok, %{}} = result_allowed
  end
end

