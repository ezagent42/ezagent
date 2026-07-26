defmodule Ezagent.Runtime.SidecarRegistryTest do
  @moduledoc """
  V5 A1a — the unified sidecar registry: `:via` self-registration,
  plugin-qualified tuple keys, death-cleanup. ADDITIVE: the registry is
  started by the tests only; nothing in the app wires it yet.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Runtime.SidecarRegistry

  defmodule Sidecar do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, nil, opts)
    def init(_), do: {:ok, nil}
  end

  setup do
    start_supervised!(SidecarRegistry)
    :ok
  end

  test "via/3 returns a plugin-qualified :via tuple with a string parent URI" do
    assert {:via, Registry, {SidecarRegistry, {"entity://ws/a/agent/b", :plugin_cc, :backend}}} =
             SidecarRegistry.via("entity://ws/a/agent/b", :plugin_cc, :backend)

    assert {:via, Registry, {SidecarRegistry, {"entity://ws/a/agent/b", :plugin_cc, :backend}}} =
             SidecarRegistry.via(URI.parse("entity://ws/a/agent/b"), :plugin_cc, :backend)
  end

  test "a child SELF-registers under via/3 and lookup/1 resolves it" do
    parent = "entity://ws/a/agent/sr-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Sidecar.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

    assert {:ok, ^pid} = SidecarRegistry.lookup({parent, :plugin_cc, :backend})
    # plugin + role are BOTH part of the key
    assert :error = SidecarRegistry.lookup({parent, :plugin_codex, :backend})
    assert :error = SidecarRegistry.lookup({parent, :plugin_cc, :frontend})
  end

  test "plugin-qualified keys: two plugins may reuse the same role vocab" do
    parent = "entity://ws/a/agent/sr-#{System.unique_integer([:positive])}"

    {:ok, cc} = Sidecar.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

    {:ok, codex} =
      Sidecar.start_link(name: SidecarRegistry.via(parent, :plugin_codex, :backend))

    assert {:ok, ^cc} = SidecarRegistry.lookup({parent, :plugin_cc, :backend})
    assert {:ok, ^codex} = SidecarRegistry.lookup({parent, :plugin_codex, :backend})
  end

  test "the entry dies with the child (Registry DOWN-cleanup)" do
    parent = "entity://ws/a/agent/sr-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Sidecar.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

    assert {:ok, ^pid} = SidecarRegistry.lookup({parent, :plugin_cc, :backend})

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert_eventually(fn ->
      SidecarRegistry.lookup({parent, :plugin_cc, :backend}) == :error
    end)
  end

  # Registry DOWN-cleanup is prompt but asynchronous — poll briefly.
  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition never became true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
