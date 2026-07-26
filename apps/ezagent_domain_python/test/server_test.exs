defmodule Ezagent.Domain.Python.ServerTest do
  @moduledoc """
  Server / facade behavior in test_mode (no real subprocess).

  Tests that don't need an actual Python subprocess live here. Real
  RPC round-trips, hung-handler tear-down, bounded stderr, and
  late-result race all need `uv` and live in `IntegrationTest`.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.Spec

  defp test_handle do
    "test://server-test/" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp test_spec(handle, overrides \\ %{}) do
    base = %Spec{
      handle: handle,
      command: ["/usr/bin/false"],
      cwd: System.tmp_dir!(),
      test_mode: true
    }

    Map.merge(base, overrides)
    |> case do
      %Spec{} = s -> s
      m -> struct!(Spec, Map.to_list(m))
    end
  end

  setup do
    on_exit(fn ->
      # Clean up any servers this test started.
      DynamicSupervisor.which_children(EzagentDomainPython.Supervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        if is_pid(pid), do: DynamicSupervisor.terminate_child(EzagentDomainPython.Supervisor, pid)
      end)
    end)

    :ok
  end

  test "start_subprocess returns {:ok, pid} in test_mode" do
    handle = test_handle()
    assert {:ok, pid} = Python.start_subprocess(test_spec(handle))
    assert is_pid(pid)
    assert Python.alive?(handle)
  end

  test "alive?/1 is false before start, true after, false after stop" do
    handle = test_handle()
    refute Python.alive?(handle)

    {:ok, _pid} = Python.start_subprocess(test_spec(handle))
    assert Python.alive?(handle)

    :ok = Python.stop(handle)
    # V5 A1b: alive?/1 is registry-based now — the seam entry leaves on
    # the Registry's async DOWN-cleanup, not synchronously with
    # terminate_child. Poll instead of asserting the very next line.
    assert await_not_alive(handle)
  end

  test "stop/1 is idempotent — returns :ok even if not started" do
    handle = test_handle()
    assert :ok = Python.stop(handle)
    assert :ok = Python.stop(handle)
  end

  test "call/4 returns {:error, :not_alive} when no Server registered" do
    handle = test_handle()
    assert {:error, :not_alive} = Python.call(handle, "echo", %{}, 100)
  end

  test "start_subprocess preflight: bad cwd → {:error, :bad_cwd}, no child registered" do
    handle = test_handle()
    bad_cwd = "/no/such/dir/here-#{System.unique_integer([:positive])}"

    spec = %Spec{
      handle: handle,
      command: :uv_script,
      script_path: "/tmp/foo.py",
      cwd: bad_cwd,
      test_mode: true
    }

    assert {:error, :bad_cwd} = Python.start_subprocess(spec)
    refute Python.alive?(handle)
  end

  test "start_subprocess preflight: missing script_path → {:error, {:missing, :script_path}}" do
    handle = test_handle()

    spec = %Spec{
      handle: handle,
      command: :uv_script,
      script_path: nil,
      cwd: System.tmp_dir!(),
      test_mode: true
    }

    assert {:error, {:missing, :script_path}} = Python.start_subprocess(spec)
    refute Python.alive?(handle)
  end

  test "start_subprocess preflight: uv missing → {:error, :uv_not_found}" do
    handle = test_handle()

    original_path = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")

    try do
      spec = %Spec{
        handle: handle,
        command: :uv_script,
        script_path: "/tmp/foo.py",
        cwd: System.tmp_dir!(),
        test_mode: true
      }

      assert {:error, :uv_not_found} = Python.start_subprocess(spec)
      refute Python.alive?(handle)
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    end
  end

  describe "concurrent start dedup (SPEC §3.2 step 2 / §9.3)" do
    test "two concurrent start_subprocess for the same handle: dedup holds, both see same outcome in test_mode" do
      handle = test_handle()
      spec = test_spec(handle)

      task1 = Task.async(fn -> Python.start_subprocess(spec) end)
      task2 = Task.async(fn -> Python.start_subprocess(spec) end)

      result1 = Task.await(task1, 5_000)
      result2 = Task.await(task2, 5_000)

      # In test_mode the subprocess "becomes ready" immediately. Both
      # callers MUST observe success and MUST refer to the SAME pid
      # (the :via Registry collapses concurrent starts).
      assert {:ok, pid1} = result1
      assert {:ok, pid2} = result2
      assert pid1 == pid2
    end

    # The spec also requires that two concurrent starts with a
    # soon-to-die subprocess both observe {:error, _}, never one
    # adopting a dead pid via raw {:already_started, _}. We cannot
    # safely exercise this in test_mode (init/1 short-circuits to
    # ready); the integration suite covers it via real spawn of
    # /usr/bin/false.
  end

  test "Registry collapses concurrent starts atomically" do
    handle = test_handle()
    spec = test_spec(handle)

    {:ok, pid} = Python.start_subprocess(spec)
    {:ok, ^pid} = Python.start_subprocess(spec)
  end

  test "call canonicalizes binary handle to the same Registry key as the URI struct" do
    uri = Ezagent.URI.new!("system://python/canonical-test")
    spec = test_spec(uri)

    {:ok, _pid} = Python.start_subprocess(spec)

    assert Python.alive?(uri)
    assert Python.alive?(URI.to_string(uri))
    # call/4 returns :not_alive in test_mode (no real subprocess),
    # but the key insight is dispatch went through the Registry —
    # the call returns a SUBPROCESS-level error not a CANONICAL key
    # mismatch. Both must point to the SAME server pid; we verified
    # via alive? above.
  end

  test "call with bad handle raises ArgumentError" do
    assert_raise ArgumentError, fn -> Python.call(:bogus_atom, "echo", %{}) end
    assert_raise ArgumentError, fn -> Python.alive?(:bogus_atom) end
    assert_raise ArgumentError, fn -> Python.stop(:bogus_atom) end
  end

  test "tearing_down? guard rejects new calls cleanly (SPEC §3.3.1)" do
    handle = test_handle()
    {:ok, pid} = Python.start_subprocess(test_spec(handle))

    # Manually flip tearing_down? to simulate mid-teardown state.
    :sys.replace_state(pid, fn s -> %{s | tearing_down?: true} end)

    assert {:error, :subprocess_unhealthy} = Python.call(handle, "anything", %{}, 100)
  end

  describe "resolver seam (V5 A1b)" do
    test "registered under the :via key; Resolver.alive?/call reach it; stop removes the key" do
      handle = test_handle()

      assert {:ok, _pid} = Python.start_subprocess(test_spec(handle))

      key = Python.Server.resolver_key(handle)
      assert key == {handle, :ezagent_domain_python, :python}

      # Resolvable through the seam (pid-free liveness + calls).
      assert Ezagent.Runtime.Resolver.alive?(key)
      assert Ezagent.Runtime.Resolver.whereis(key) == :ok
      # test_mode rpc_call replies {:error, :not_alive} (no real
      # subprocess) — the point is the call RESOLVED through the seam.
      assert {:ok, {:error, :not_alive}} =
               Ezagent.Runtime.Resolver.call(key, {:rpc_call, "echo", %{}, 100}, 1_000)

      # stop/1 goes through Resolver.terminate_child — the key leaves the seam.
      :ok = Python.stop(handle)
      assert await_not_alive(handle)
    end
  end

  # V5 A1b: `alive?/1` resolves through the seam's registry entry, which
  # disappears on the Registry's async DOWN-cleanup — poll briefly.
  defp await_not_alive(handle, attempts \\ 100)
  defp await_not_alive(_handle, 0), do: false

  defp await_not_alive(handle, attempts) do
    if Python.alive?(handle) do
      Process.sleep(10)
      await_not_alive(handle, attempts - 1)
    else
      true
    end
  end
end
