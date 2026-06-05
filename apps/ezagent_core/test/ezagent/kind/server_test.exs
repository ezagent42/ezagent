defmodule Ezagent.Kind.ServerTest do
  use ExUnit.Case
  alias Ezagent.Test.{TestKind, TestBehavior}

  setup do
    # Each test gets a unique URI so registry state doesn't leak.
    # PR #141: agent URIs are entity://agent/<flavor>_<name>; use "test" flavor.
    uri =
      URI.parse(
        "entity://team-alpha/agent/test_kind-server-#{System.unique_integer([:positive])}"
      )

    # Wire TestKind/TestBehavior into the BehaviorRegistry for this test —
    # idempotent register so reruns are fine.
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :fail, TestBehavior)
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :raise, TestBehavior)

    {:ok, uri: uri}
  end

  test "init registers URI, marks not_ready, then announce_ready transitions", %{uri: uri} do
    {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})

    # Wait for handle_continue to run.
    :ok = wait_until_ready(uri, 500)

    # Registered.
    assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(uri)
    # Ready.
    assert :ready = Ezagent.ReadyGate.status(uri)
  end

  test "handle_call :ezagent_dispatch invokes behavior, updates slice, returns result", %{
    uri: uri
  } do
    {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 500)

    inv = %Ezagent.Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop"),
      mode: :call,
      args: %{msg: "hello"},
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: :ignore
      }
    }

    assert {:ok, %{echoed: "hello"}} = GenServer.call(pid, {:ezagent_dispatch, inv})
  end

  test "handle_cast :ezagent_dispatch invokes behavior + replies to caller_inbox", %{uri: uri} do
    {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 500)

    inv = %Ezagent.Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop"),
      mode: :cast,
      args: %{msg: "via-cast"},
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    }

    GenServer.cast(pid, {:ezagent_dispatch, inv})

    assert_receive {:ezagent_reply, {:ok, %{echoed: "via-cast"}}}, 1000
  end

  test "PendingDelivery flush on announce_ready", %{uri: uri} do
    # Buffer a message *before* the server exists, then start the server —
    # the message should be drained during announce_ready.
    pre_inv = %Ezagent.Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop"),
      mode: :cast,
      args: %{msg: "pre-ready"},
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    }

    :ok = Ezagent.PendingDelivery.buffer(uri, pre_inv)
    assert Ezagent.PendingDelivery.buffer_size(uri) == 1

    {:ok, _pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})

    # Buffered cast should be drained and flow through dispatch → reply.
    assert_receive {:ezagent_reply, {:ok, %{echoed: "pre-ready"}}}, 1000
    # Buffer should be empty after flush.
    assert Ezagent.PendingDelivery.buffer_size(uri) == 0
  end

  defp wait_until_ready(uri, timeout_ms) do
    poll(uri, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          poll(uri, deadline)
        end
    end
  end
end
