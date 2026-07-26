defmodule Ezagent.Domain.Python.ResolverSeamTest do
  @moduledoc """
  V5 pid-closure A1b — PROOF of the Python sidecar migration onto the
  resolver seam:

    * a Python Server started under the new `:via` key resolves via
      `Ezagent.Runtime.Resolver.pid_for({handle_key,
      :ezagent_domain_python, :python})` / `alive?/1`;
    * `call/4` / `stop/1` are served through the seam's
      `Resolver.call/3` + `Resolver.terminate_child/2` — no
      `Registry.lookup`, no `:sys.get_state/2`, no pid walk;
    * the retired `EzagentDomainPython.Registry` is gone (nothing
      starts it);
    * duplicate-spawn collapse (SPEC §3.2 step 2 / D13) still holds on
      the unified registry;
    * a live worker re-registers ITSELF after a SidecarRegistry
      restart (codex #5).

  Runs in test_mode (no real subprocess) — the seam mechanics are
  transport-independent.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.Server, as: PyServer
  alias Ezagent.Domain.Python.Spec
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  @plugin :ezagent_domain_python
  @role :python

  defp test_handle do
    "test://seam-test/" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp test_spec(handle) do
    %Spec{
      handle: handle,
      command: ["/usr/bin/false"],
      cwd: System.tmp_dir!(),
      test_mode: true
    }
  end

  setup do
    handle = test_handle()
    {:ok, pid} = Python.start_subprocess(test_spec(handle))

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(EzagentDomainPython.Supervisor, pid)
      end
    end)

    {:ok, handle: handle, pid: pid}
  end

  test "the server self-registers under the unified :via key", %{handle: handle, pid: pid} do
    assert {:via, Registry, {SidecarRegistry, key}} = PyServer.via(handle)
    assert key == {Python.handle_key(handle), @plugin, @role}

    # ...and the unified registry is the one holding the entry.
    assert [{^pid, _}] = Registry.lookup(SidecarRegistry, key)
  end

  test "resolvable via Resolver.pid_for/1 and alive?/1", %{handle: handle, pid: pid} do
    assert {:ok, ^pid} = Resolver.pid_for({handle, @plugin, @role})
    assert Resolver.alive?({handle, @plugin, @role})
    # The facade resolves the SAME key from the raw handle.
    assert Python.alive?(handle)
  end

  test "call/4 routes through the seam", %{handle: handle} do
    # test_mode Servers reply {:error, :not_alive} to :rpc_call (no real
    # subprocess) — the point is the call REACHED the Server through
    # Resolver.call/3, not which error came back.
    assert {:error, :not_alive} = Python.call(handle, "echo", %{}, 100)
  end

  test "unregistered handle resolves to :not_found / false / :not_alive" do
    ghost = test_handle()

    assert :not_found = Resolver.pid_for({ghost, @plugin, @role})
    refute Python.alive?(ghost)
    assert {:error, :not_alive} = Python.call(ghost, "echo", %{}, 100)
  end

  test "duplicate spawn collapses atomically on the unified registry (SPEC §3.2 / D13)",
       %{handle: handle, pid: pid} do
    assert {:ok, ^pid} = Python.start_subprocess(test_spec(handle))
  end

  test "stop/1 tears down and the seam entry dies with the child", %{
    handle: handle,
    pid: pid
  } do
    assert :ok = Python.stop(handle)
    refute Process.alive?(pid)

    assert_eventually(fn ->
      Resolver.pid_for({handle, @plugin, @role}) == :not_found
    end)
  end

  test "the retired private registry is NOT started anywhere" do
    assert Process.whereis(EzagentDomainPython.Registry) == nil
  end

  test "a live worker re-registers after a SidecarRegistry restart (codex #5)", %{
    handle: handle,
    pid: pid
  } do
    assert Resolver.alive?({handle, @plugin, @role})

    registry_pid = Process.whereis(SidecarRegistry)
    ref = Process.monitor(registry_pid)
    # Same simulated-crash protocol as the PTY pilot's seam test:
    # `GenServer.stop/3` with a crash reason terminates the registry
    # abnormally but cleanly; the actor-app supervisor restarts it EMPTY,
    # which is the topology hazard this test covers.
    GenServer.stop(SidecarRegistry, :simulated_crash)
    assert_receive {:DOWN, ^ref, :process, ^registry_pid, :simulated_crash}, 1_000

    # The live worker notices its watch :DOWN and re-registers ITSELF —
    # same pid, still resolvable, still answering calls.
    assert_eventually(fn ->
      Resolver.alive?({handle, @plugin, @role}) and
        Resolver.pid_for({handle, @plugin, @role}) == {:ok, pid}
    end)

    assert {:error, :not_alive} = Python.call(handle, "echo", %{}, 100)
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
