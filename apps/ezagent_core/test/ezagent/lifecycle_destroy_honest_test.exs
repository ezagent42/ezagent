defmodule Ezagent.LifecycleDestroyHonestTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.TestSupport.HonestTerminateKind

  test "destroy/2 preserves durable state when teardown is not confirmed" do
    uri =
      Ezagent.URI.new!(
        "entity://system/agent/honest-destroy-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} = Ezagent.Kind.spawn(HonestTerminateKind, %{uri: uri})

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
      end
    end)

    assert KindSnapshot.get(Ezagent.URI.stable_key(uri))
    assert {:error, :still_alive} = Ezagent.Lifecycle.destroy(uri)
    assert Process.alive?(pid)
    assert KindSnapshot.get(Ezagent.URI.stable_key(uri))
  end

  test "destroy!/2 coerces an incomplete teardown to :ok without deleting the snapshot" do
    uri =
      Ezagent.URI.new!(
        "entity://system/agent/honest-destroy-bang-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} = Ezagent.Kind.spawn(HonestTerminateKind, %{uri: uri})

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
      end
    end)

    assert :ok = Ezagent.Lifecycle.destroy!(uri)
    assert Process.alive?(pid)
    assert KindSnapshot.get(Ezagent.URI.stable_key(uri))
  end
end
