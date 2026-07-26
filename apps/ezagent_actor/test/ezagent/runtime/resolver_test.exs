defmodule Ezagent.Runtime.ResolverTest do
  @moduledoc """
  V5 A1a — the resolver facade: `pid_for/1` resolves both key spaces, the
  public face (`dispatch/4`, `send_envelope/2`, `whereis/1`) routes without
  ever returning a pid, and sidecar entries clean up on child death.

  ADDITIVE: nothing in the app is wired onto the resolver; these tests
  register throwaway processes directly.
  """
  use ExUnit.Case, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Runtime.{Resolver, SidecarRegistry}

  defmodule EchoServer do
    @moduledoc false
    use GenServer

    # Kind-URI mode: registers ITSELF in KindRegistry (caller-owned there).
    def start_link(uri) when is_binary(uri),
      do: GenServer.start_link(__MODULE__, {:kind, self(), uri})

    # Sidecar mode: self-registers via the `name:` :via tuple in `opts`.
    def start_link(opts) when is_list(opts),
      do: GenServer.start_link(__MODULE__, {:sidecar, self()}, opts)

    def init({:kind, parent, uri}) do
      :ok = KindRegistry.put_new(uri)
      send(parent, :kr_registered)
      {:ok, %{notify: nil}}
    end

    def init({:sidecar, parent}), do: {:ok, %{notify: parent}}

    def handle_call({:ezagent_dispatch, %Invocation{} = inv}, _from, state) do
      {:reply, {:echo, inv}, state}
    end

    def handle_cast({:ezagent_dispatch, %Invocation{} = inv}, state) do
      if notify = inv.ctx[:test_notify], do: send(notify, {:cast_echo, inv})
      {:noreply, state}
    end

    def handle_info(msg, state) do
      if state.notify, do: send(state.notify, {:sidecar_msg, msg})
      {:noreply, state}
    end
  end

  defp unique_uri(tag),
    do: "entity://test/agent/resolver-#{tag}-#{System.unique_integer([:positive])}"

  defp start_kind(uri) do
    {:ok, pid} = EchoServer.start_link(uri)
    assert_receive :kr_registered
    pid
  end

  describe "pid_for/1 (INTERNAL — the sole pid fetch)" do
    test "resolves a Kind URI through the existing KindRegistry" do
      uri = unique_uri("kind")
      pid = start_kind(uri)

      assert {:ok, ^pid} = Resolver.pid_for(uri)
      assert {:ok, ^pid} = Resolver.pid_for(URI.parse(uri))
    end

    test ":not_found for an unregistered Kind URI" do
      assert :not_found = Resolver.pid_for(unique_uri("absent"))
    end

    test "resolves a sidecar key through the unified SidecarRegistry" do
      start_supervised!(SidecarRegistry)
      parent = unique_uri("parent")

      {:ok, pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert {:ok, ^pid} = Resolver.pid_for({parent, :plugin_cc, :backend})
      assert :not_found = Resolver.pid_for({parent, :plugin_codex, :backend})
    end

    test "a sidecar key on an UNSTARTED SidecarRegistry is :not_found (A1a unwired default)" do
      # A1a starts the registry nowhere; the seam must not crash on it.
      refute SidecarRegistry.started?()
      assert :not_found = Resolver.pid_for({unique_uri("parent"), :plugin_cc, :backend})
    end
  end

  describe "whereis/1 — liveness, no pid" do
    test ":ok for a registered Kind URI, :not_found otherwise" do
      uri = unique_uri("alive")
      _pid = start_kind(uri)

      assert :ok = Resolver.whereis(uri)
      assert :not_found = Resolver.whereis(unique_uri("dead"))
    end
  end

  describe "send_envelope/2 — resolve + send, never a pid" do
    test "delivers a raw message to a Kind URI target" do
      uri = unique_uri("envelope")
      :ok = KindRegistry.put_new(uri)

      assert :ok = Resolver.send_envelope(uri, {:hello, self()})
      assert_receive {:hello, _}
    end

    test "delivers to a sidecar key target" do
      start_supervised!(SidecarRegistry)
      parent = unique_uri("parent")

      {:ok, _pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert :ok = Resolver.send_envelope({parent, :plugin_cc, :backend}, :ping)
      assert_receive {:sidecar_msg, :ping}
    end

    test ":not_found for an absent key" do
      assert :not_found = Resolver.send_envelope(unique_uri("absent"), :ping)
    end
  end

  describe "dispatch/4 — resolve + dispatch, never a pid" do
    test ":call mode routes {:ezagent_dispatch, %Invocation{}} to the resolved pid" do
      uri = unique_uri("dispatch")
      _pid = start_kind(uri)

      assert {:echo, %Invocation{} = inv} =
               Resolver.dispatch(uri, :ping, %{"x" => 1}, %{
                 mode: :call,
                 caller: :vm_internal,
                 reply: :ignore
               })

      assert inv.mode == :call
      assert inv.args == %{"x" => 1}
      assert inv.target.query == "action=_.ping"
      assert MapSet.new() == inv.ctx.caps
    end

    test ":cast mode (derived from reply: :ignore) delivers the envelope" do
      uri = unique_uri("dispatch-cast")
      _pid = start_kind(uri)

      assert :ok =
               Resolver.dispatch(uri, :bump, %{}, %{
                 caller: :vm_internal,
                 reply: :ignore,
                 test_notify: self()
               })

      assert_receive {:cast_echo, %Invocation{mode: :cast, target: %{query: "action=_.bump"}}}
    end

    test "{:error, :no_such_actor} for an unregistered target" do
      assert {:error, :no_such_actor} =
               Resolver.dispatch(unique_uri("absent"), :ping, %{}, %{
                 mode: :call,
                 caller: :vm_internal
               })
    end
  end

  describe "death-cleanup" do
    test "a sidecar entry resolves to :not_found after the child exits" do
      start_supervised!(SidecarRegistry)
      parent = unique_uri("parent")

      {:ok, pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert {:ok, ^pid} = Resolver.pid_for({parent, :plugin_cc, :backend})

      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert_eventually(fn ->
        Resolver.pid_for({parent, :plugin_cc, :backend}) == :not_found and
          Resolver.whereis({parent, :plugin_cc, :backend}) == :not_found
      end)
    end
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
