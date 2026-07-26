defmodule Ezagent.Domain.Pty.ResolverSeamTest do
  @moduledoc """
  V5 pid-closure A1b — PROOF of the PTY sidecar migration onto the
  resolver seam:

    * a PtyServer started under the new `:via` key resolves via
      `Ezagent.Runtime.Resolver.pid_for({agent_uri, :ezagent_domain_pty,
      :pty})` / `whereis/1`;
    * status/phase/buffer queries are served by explicit
      `GenServer.call` client APIs — no `:sys.get_state/2`, no
      `DynamicSupervisor.which_children/1`;
    * the retired `EzagentDomainPty.Registry` is gone (nothing starts it);
    * duplicate-spawn collapse (PR-D2) still holds on the unified registry.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty
  alias Ezagent.Domain.Pty.Server, as: PtyServer
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  @plugin :ezagent_domain_pty
  @role :pty

  defmodule SlowServer do
    @moduledoc false
    # Stands in for a PtyServer sleeping inside RespawnBackoff.throttle/1:
    # it answers NO call within the 1s write_input timeout.
    use GenServer
    def init(_), do: {:ok, %{}}

    def handle_call({:write_input, _bytes}, _from, state) do
      Process.sleep(2_000)
      {:reply, :ok, state}
    end
  end

  setup do
    agent_uri =
      URI.new!("entity://team-alpha/agent/test_seam-#{System.unique_integer([:positive])}")

    {:ok, pid} = Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(EzagentDomainPty.Supervisor, pid)
      end
    end)

    {:ok, agent_uri: agent_uri, pid: pid}
  end

  test "the server self-registers under the unified :via key", %{agent_uri: uri, pid: pid} do
    assert {:via, Registry, {SidecarRegistry, key}} = PtyServer.via(uri)
    assert key == {URI.to_string(uri), @plugin, @role}

    # ...and the unified registry is the one holding the entry.
    assert [{^pid, _}] =
             Registry.lookup(SidecarRegistry, {URI.to_string(uri), @plugin, @role})
  end

  test "resolvable via Resolver.pid_for/1 and whereis/1", %{agent_uri: uri, pid: pid} do
    assert {:ok, ^pid} = Resolver.pid_for({uri, @plugin, @role})
    assert :ok = Resolver.whereis({uri, @plugin, @role})
  end

  test "status/1 and phase/1 work WITHOUT :sys.get_state", %{agent_uri: uri} do
    # test_mode walks :starting → :running in handle_continue; both
    # queries are served by explicit GenServer.call client APIs.
    assert :running = PtyServer.phase(uri)

    status = PtyServer.status(uri)
    assert is_map(status)
    assert status.phase == :running
    assert status.running == true
    assert status.test_mode == true
    assert status.agent_uri == uri
  end

  test "snapshot_buffer/2 and write_input/2 route through the seam", %{agent_uri: uri} do
    assert {:ok, buf} = PtyServer.snapshot_buffer(uri)
    assert is_binary(buf)
    # test_mode write short-circuits to :ok without erlexec.
    assert :ok = PtyServer.write_input(uri, "echo hi\r")
  end

  test "unregistered agent resolves to :not_found / :dead / nil" do
    ghost =
      URI.new!("entity://team-alpha/agent/test_seam-ghost-#{System.unique_integer([:positive])}")

    assert :not_found = Resolver.pid_for({ghost, @plugin, @role})
    assert :not_found = Resolver.whereis({ghost, @plugin, @role})
    assert :dead = PtyServer.phase(ghost)
    assert nil == PtyServer.status(ghost)
    assert :error = PtyServer.snapshot_buffer(ghost)
    assert {:error, :no_pty_server} = PtyServer.write_input(ghost, "x")
  end

  test "duplicate spawn collapses atomically on the unified registry (PR-D2)",
       %{agent_uri: uri, pid: pid} do
    assert {:error, {:already_started, ^pid}} =
             Pty.start(uri, %{cwd: "/tmp", test_mode: true})
  end

  test "stop/1 tears down and the seam entry dies with the child", %{agent_uri: uri, pid: pid} do
    assert :ok = Pty.stop(uri)
    refute Process.alive?(pid)

    assert_eventually(fn ->
      Resolver.whereis({uri, @plugin, @role}) == :not_found
    end)
  end

  test "list_agents/0 enumerates via the seam (no which_children walk, no pids)", %{
    agent_uri: uri
  } do
    entries = PtyServer.list_agents()
    assert Enum.any?(entries, fn e -> e.agent_uri == uri end)

    # Pid-free entries (codex A1b-pilot #2): keys + os_pid only.
    for e <- entries do
      assert Map.keys(e) |> Enum.sort() == [:agent_uri, :os_pid]
    end
  end

  test "the retired private registry is NOT started anywhere" do
    assert Process.whereis(EzagentDomainPty.Registry) == nil
  end

  test "write_input/2 to a busy (respawn-backing-off) server returns a clean {:error, _}",
       %{agent_uri: _uri} do
    # codex A1b-pilot #2 — the pilot's uncaught 1s GenServer.call ESCAPED
    # as an exit when the server was sleeping inside
    # RespawnBackoff.throttle/1. The seam's Resolver.call/3 catches the
    # exit; the caller gets the pre-migration clean error tuple.
    busy_uri =
      URI.new!("entity://team-alpha/agent/test_seam-busy-#{System.unique_integer([:positive])}")

    {:ok, slow} = GenServer.start_link(SlowServer, [], name: PtyServer.via(busy_uri))
    on_exit(fn -> if Process.alive?(slow), do: GenServer.stop(slow, :normal, 5_000) end)

    assert {:error, reason} = PtyServer.write_input(busy_uri, "x")
    assert match?({:timeout, _}, reason)
  end

  test "a live worker re-registers after a SidecarRegistry restart (codex #5)", %{
    agent_uri: uri,
    pid: pid
  } do
    assert :ok = Resolver.whereis({uri, @plugin, @role})

    registry_pid = Process.whereis(SidecarRegistry)
    ref = Process.monitor(registry_pid)
    # A simulated CRASH via the system-stop protocol (the Registry traps
    # exits, so `Process.exit/2` only :kill can take it down — and a brutal
    # :kill races its NAMED partition supervisor's cleanup against the
    # actor supervisor's restart: every restart attempt hits a still-
    # registered partition name, the intensity trips, and the WHOLE
    # ezagent_actor app — plus every app depending on it — goes down).
    # `GenServer.stop/3` with a crash reason terminates the registry
    # abnormally but cleanly: the supervisor restarts it EMPTY, which is
    # the topology hazard this test covers.
    GenServer.stop(SidecarRegistry, :simulated_crash)
    assert_receive {:DOWN, ^ref, :process, ^registry_pid, :simulated_crash}, 1_000

    # The actor-app supervisor restarts the registry EMPTY; the live worker
    # notices its watch :DOWN and re-registers ITSELF — same pid, still
    # resolvable, still answering queries.
    assert_eventually(fn ->
      Resolver.alive?({uri, @plugin, @role}) and
        Resolver.pid_for({uri, @plugin, @role}) == {:ok, pid}
    end)

    assert is_map(PtyServer.status(uri))
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
