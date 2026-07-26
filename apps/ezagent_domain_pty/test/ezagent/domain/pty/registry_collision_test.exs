defmodule Ezagent.Domain.Pty.RegistryCollisionTest do
  @moduledoc """
  V5 pid-closure A1b (codex blocker B) — the SidecarRegistry restart-
  COLLISION policy.

  During the registry's empty-restart window a fresh `Pty.start/2` can
  register a REPLACEMENT under the same `{agent_uri, :ezagent_domain_pty,
  :pty}` key. When the ORIGINAL worker then re-registers, it must NOT
  retry forever (two live PTYs / two OS children, one unreachable) — it
  LOSES: it terminates itself gracefully, its `terminate/2` releases the
  erlexec child, and `restart: :transient` keeps the DynamicSupervisor
  from resurrecting it.

  This test runs REAL children (`test_mode: false`, like the respawn-
  breaker suite) and forces the race deterministically: the original is
  `:sys.suspend`ed before the registry goes down, so the replacement
  provably registers first; resuming the original drives its losing
  `re_register`.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty
  alias Ezagent.Domain.Pty.Server, as: PtyServer
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  @plugin :ezagent_domain_pty
  @role :pty

  test "restart/start race: exactly one worker + one OS child survives, resolvable" do
    n = System.unique_integer([:positive])
    uri = URI.new!("entity://team-alpha/agent/pty_collision-#{n}")
    log = Path.join(System.tmp_dir!(), "pty_collision_#{n}.log")
    File.rm(log)
    cmd = ["/bin/sh", "-c", "echo spawn >> #{log}; sleep 30"]

    on_exit(fn ->
      Pty.stop(uri)
      File.rm(log)
    end)

    # Worker A (the ORIGINAL) + its real OS child.
    {:ok, pid_a} = Pty.start(uri, %{cwd: "/tmp", test_mode: false, cmd_override: cmd})
    wait_until(fn -> count(log) == 1 end)
    os_pid_a = PtyServer.status(uri).os_pid
    assert is_integer(os_pid_a)
    assert os_alive?(os_pid_a)

    # Freeze A so it CANNOT re-register during the registry's empty window.
    :sys.suspend(pid_a)

    # The registry restarts EMPTY (same simulated-crash harness as the
    # codex #5 re-register test: `Process.exit/2`'s :kill would race the
    # named partition supervisors; a clean abnormal stop restarts it empty).
    registry_pid = Process.whereis(SidecarRegistry)
    ref = Process.monitor(registry_pid)
    GenServer.stop(SidecarRegistry, :simulated_crash)
    assert_receive {:DOWN, ^ref, :process, ^registry_pid, :simulated_crash}, 1_000

    wait_until(fn ->
      SidecarRegistry.started?() and Process.whereis(SidecarRegistry) != registry_pid
    end)

    # A fresh start wins the empty key — the REPLACEMENT (worker B) + its
    # own OS child.
    {:ok, pid_b} = Pty.start(uri, %{cwd: "/tmp", test_mode: false, cmd_override: cmd})
    wait_until(fn -> count(log) == 2 end)

    # Unfreeze the ORIGINAL: its re_register finds the key owned by a
    # different LIVE pid (B) and LOSES — graceful self-termination, no
    # retry loop.
    ref_a = Process.monitor(pid_a)
    :sys.resume(pid_a)
    assert_receive {:DOWN, ^ref_a, :process, ^pid_a, {:shutdown, :registry_collision}}, 5_000

    # EXACTLY ONE worker survives — the replacement — resolvable through
    # the seam, answering queries.
    assert Process.alive?(pid_b)

    wait_until(fn ->
      Resolver.pid_for({uri, @plugin, @role}) == {:ok, pid_b}
    end)

    survivors =
      uri
      |> URI.to_string()
      |> then(fn parent ->
        Enum.filter(Resolver.list_keys(@plugin), fn
          {^parent, @plugin, @role} -> true
          _other -> false
        end)
      end)

    assert length(survivors) == 1
    assert is_map(PtyServer.status(uri))

    # ...and exactly one OS child: the loser's erlexec child is RELEASED
    # (terminate/2), the winner's is alive — and no third spawn happened
    # (the supervisor did not resurrect the loser).
    os_pid_b = PtyServer.status(uri).os_pid
    assert is_integer(os_pid_b)
    assert os_pid_b != os_pid_a

    wait_until(fn -> not os_alive?(os_pid_a) end)
    assert os_alive?(os_pid_b)

    assert count(log) == 2,
           "expected exactly 2 spawns total (original + replacement); the losing " <>
             "worker must terminate, not respawn — got #{count(log)}"
  end

  # ---- helpers ---------------------------------------------------------

  defp os_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp count(log) do
    case File.read(log) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.count(&(&1 == "spawn"))
      _ -> 0
    end
  end

  defp wait_until(fun, timeout \\ 6_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition never became true")
      true -> Process.sleep(50) && do_wait(fun, deadline)
    end
  end
end
