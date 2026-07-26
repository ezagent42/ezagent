defmodule Ezagent.Runtime.ResolverTest do
  @moduledoc """
  V5 A1a/A1b — the resolver facade: `pid_for/1` resolves both key spaces,
  and the pid-free public face (`call/3`, `cast/2`, `alive?/1`,
  `terminate_child/2`, `list_keys/1`, `dispatch/4`, `send_envelope/2`,
  `whereis/1`) routes without ever returning a pid. Sidecar entries clean
  up on child death.

  A1b: the `SidecarRegistry` is app-started (`EzagentActor.Application`);
  these tests register throwaway processes into it directly.
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

    # Plain query verb for `Resolver.call/3` tests.
    def handle_call({:echo, term}, _from, state), do: {:reply, {:echoed, term}, state}

    def handle_cast({:ezagent_dispatch, %Invocation{} = inv}, state) do
      if notify = inv.ctx[:test_notify], do: send(notify, {:cast_echo, inv})
      {:noreply, state}
    end

    # Plain cast verb for `Resolver.cast/2` tests.
    def handle_cast({:echo_cast, term}, state) do
      if state.notify, do: send(state.notify, {:cast_received, term})
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
      parent = unique_uri("parent")

      {:ok, pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert {:ok, ^pid} = Resolver.pid_for({parent, :plugin_cc, :backend})
      assert :not_found = Resolver.pid_for({parent, :plugin_codex, :backend})
    end

    test "a sidecar key for an UNREGISTERED sidecar is :not_found" do
      # A1b: the registry runs under EzagentActor.Application; an
      # unregistered key must resolve to :not_found, never a crash.
      assert SidecarRegistry.started?()
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
                 reply: :ignore,
                 origin: :trusted_internal
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
                 origin: :trusted_internal,
                 test_notify: self()
               })

      assert_receive {:cast_echo, %Invocation{mode: :cast, target: %{query: "action=_.bump"}}}
    end

    test "{:error, :no_such_actor} for an unregistered target" do
      assert {:error, :no_such_actor} =
               Resolver.dispatch(unique_uri("absent"), :ping, %{}, %{
                 mode: :call,
                 caller: :vm_internal,
                 origin: :trusted_internal
               })
    end
  end

  describe "dispatch/4 — provenance is CALLER-OWNED (V5 A1b codex blocker A)" do
    test "REJECTS a missing origin instead of stamping :trusted_internal" do
      uri = unique_uri("dispatch-no-origin")
      _pid = start_kind(uri)

      assert {:error, :missing_origin} =
               Resolver.dispatch(uri, :ping, %{}, %{mode: :call, caller: :vm_internal})
    end

    test "REJECTS an invalid origin" do
      uri = unique_uri("dispatch-bad-origin")
      _pid = start_kind(uri)

      assert {:error, {:invalid_origin, :bogus}} =
               Resolver.dispatch(uri, :ping, %{}, %{
                 mode: :call,
                 caller: :vm_internal,
                 origin: :bogus
               })

      assert {:error, :missing_origin} =
               Resolver.dispatch(uri, :ping, %{}, %{
                 mode: :call,
                 caller: :vm_internal,
                 origin: nil
               })
    end

    test "PRESERVES a caller-supplied origin on the envelope" do
      uri = unique_uri("dispatch-origin")
      _pid = start_kind(uri)

      for origin <- [:trusted_internal, :authenticated_external] do
        assert {:echo, %Invocation{} = inv} =
                 Resolver.dispatch(uri, :ping, %{}, %{
                   mode: :call,
                   caller: :vm_internal,
                   origin: origin
                 })

        assert inv.origin == origin
        # The :origin key is consumed (stamped on the envelope), not passed
        # through in ctx.
        refute Map.has_key?(inv.ctx, :origin)
      end
    end
  end

  describe "call/3 — resolve + GenServer.call, never a pid (A1b)" do
    test "returns the target's REPLY for a sidecar key" do
      parent = unique_uri("parent")

      {:ok, _pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert {:ok, {:echoed, :hello}} =
               Resolver.call({parent, :plugin_cc, :backend}, {:echo, :hello})
    end

    test "returns the REPLY for a Kind URI target too" do
      uri = unique_uri("call-kind")
      _pid = start_kind(uri)

      assert {:ok, {:echoed, 42}} = Resolver.call(uri, {:echo, 42})
    end

    test "{:error, :no_such_actor} for an unregistered key" do
      assert {:error, :no_such_actor} =
               Resolver.call({unique_uri("absent"), :plugin_cc, :backend}, {:echo, :x})
    end

    test "{:error, reason} (not an escaping exit) when the target dies mid-call" do
      parent = unique_uri("parent")

      {:ok, pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # Once the registry entry is gone this is the :no_such_actor path; the
      # exit-catching contract (busy/dead target → clean {:error, _}) is
      # exercised by the PTY sidecar's write_input respawn-backoff test.
      assert_eventually(fn ->
        Resolver.call({parent, :plugin_cc, :backend}, {:echo, :x}) ==
          {:error, :no_such_actor}
      end)
    end
  end

  describe "cast/2 — resolve + GenServer.cast, never a pid (A1b)" do
    test "delivers the cast to the resolved sidecar" do
      parent = unique_uri("parent")

      {:ok, _pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert :ok = Resolver.cast({parent, :plugin_cc, :backend}, {:echo_cast, :ping})
      assert_receive {:cast_received, :ping}
    end

    test ":not_found for an absent key" do
      assert :not_found = Resolver.cast({unique_uri("absent"), :plugin_cc, :backend}, :ping)
    end
  end

  describe "alive?/1 — boolean liveness, no pid (A1b)" do
    test "true for a registered sidecar key, false otherwise" do
      parent = unique_uri("parent")

      {:ok, _pid} =
        EchoServer.start_link(name: SidecarRegistry.via(parent, :plugin_cc, :backend))

      assert Resolver.alive?({parent, :plugin_cc, :backend}) == true
      assert Resolver.alive?({parent, :plugin_codex, :backend}) == false
      assert Resolver.alive?(unique_uri("absent")) == false
    end
  end

  describe "terminate_child/2 — seam-held pid, caller-named supervisor (A1b)" do
    test "terminates the resolved child under the CALLER's supervisor" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      parent = unique_uri("parent")

      {:ok, pid} =
        DynamicSupervisor.start_child(
          sup,
          {EchoServer, name: SidecarRegistry.via(parent, :plugin_cc, :backend)}
        )

      assert :ok = Resolver.terminate_child({parent, :plugin_cc, :backend}, sup)
      refute Process.alive?(pid)

      assert_eventually(fn ->
        Resolver.whereis({parent, :plugin_cc, :backend}) == :not_found
      end)
    end

    test ":not_found when nothing is registered under the key" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

      assert :not_found =
               Resolver.terminate_child({unique_uri("absent"), :plugin_cc, :backend}, sup)
    end
  end

  describe "list_keys/1 — key-only enumeration, NEVER pids (A1b)" do
    test "returns the plugin's resolver keys (usable with call/cast), never a pid" do
      parent_a = unique_uri("parent-a")
      parent_b = unique_uri("parent-b")

      {:ok, _pid_a} =
        EchoServer.start_link(name: SidecarRegistry.via(parent_a, :plugin_cc, :backend))

      {:ok, _pid_b} =
        EchoServer.start_link(name: SidecarRegistry.via(parent_b, :plugin_cc, :frontend))

      keys = Resolver.list_keys(:plugin_cc)

      assert {parent_a, :plugin_cc, :backend} in keys
      assert {parent_b, :plugin_cc, :frontend} in keys

      # Pid-free: every entry is a {uri_string, plugin, role} key — no pid
      # anywhere in the result.
      for key <- keys do
        assert {parent_uri, plugin, role} = key
        assert is_binary(parent_uri)
        assert is_atom(plugin)
        assert is_atom(role)
      end

      # …and the keys are directly usable with the rest of the public face.
      assert {:ok, {:echoed, :via_key}} =
               Resolver.call({parent_a, :plugin_cc, :backend}, {:echo, :via_key})
    end

    test "an unknown plugin enumerates to []" do
      assert Resolver.list_keys(:plugin_that_never_registers) == []
    end
  end

  describe "death-cleanup" do
    test "a sidecar entry resolves to :not_found after the child exits" do
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
