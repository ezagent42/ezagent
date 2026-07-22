defmodule Ezagent.KindTerminateHonestTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.TestSupport.HonestTerminateKind

  defp uri do
    Ezagent.URI.new!(
      "entity://system/agent/honest-terminate-#{System.unique_integer([:positive])}"
    )
  end

  defp spawn_kind do
    uri = uri()
    {:ok, pid} = Ezagent.Kind.spawn(HonestTerminateKind, %{uri: uri})

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
      end
    end)

    {uri, pid}
  end

  defp wait_unregistered(_uri, 0), do: :still_registered

  defp wait_unregistered(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> Process.sleep(5) && wait_unregistered(uri, attempts - 1)
    end
  end

  test "terminate/1 reports a custom teardown that leaves the Kind alive" do
    {uri, pid} = spawn_kind()

    assert {:error, :still_alive} = Ezagent.Kind.terminate(uri)
    assert Process.alive?(pid)
  end

  test "terminate!/1 preserves best-effort semantics for don't-care callers" do
    {uri, pid} = spawn_kind()

    assert :ok = Ezagent.Kind.terminate!(uri)
    assert Process.alive?(pid)
  end

  test "terminate/1 returns :ok only after a standard child is confirmed gone" do
    uri = uri()
    {:ok, pid} = Ezagent.Kind.spawn(Ezagent.Test.TestKind, %{uri: uri})

    assert :ok = Ezagent.Kind.terminate(uri)
    refute Process.alive?(pid)
    assert :ok = wait_unregistered(uri, 100)
  end
end
