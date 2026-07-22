defmodule Ezagent.Security.OsProcessSecretIsolationProbeTest do
  @moduledoc """
  Reproduction-only probes for the credential boundary of OsProcess children.

  The sentinel is deliberately not a credential and must never be replaced by
  production secret material.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.OsProcess

  @sentinel "EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP"

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "ezagent-secret-isolation-probe-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "mode 0600 is readable by a same-uid child when the path is known", %{
    tmp_dir: tmp_dir
  } do
    secret_path = Path.join(tmp_dir, "broker-secret")
    File.write!(secret_path, @sentinel)
    File.chmod!(secret_path, 0o600)

    assert {:ok, @sentinel} = run_argv(["/bin/cat", secret_path])
  end

  @tag :security_probe
  test "same-uid child environment is visible through proc", %{tmp_dir: tmp_dir} do
    {:ok, %{exec_pid: target_exec_pid, os_pid: target_os_pid}} =
      OsProcess.spawn(["/bin/sleep", "30"],
        cd: tmp_dir,
        env: %{"EZAGENT_PROBE_SECRET" => @sentinel}
      )

    try do
      environ_path = "/proc/#{target_os_pid}/environ"
      assert {:ok, environ} = run_argv(["/bin/cat", environ_path])

      assert String.split(environ, <<0>>) |> Enum.member?("EZAGENT_PROBE_SECRET=#{@sentinel}")
    after
      :ok = OsProcess.stop(target_exec_pid)
    end
  end

  defp run_argv(argv) do
    {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} =
      OsProcess.spawn(argv, cd: System.tmp_dir!(), stderr: :merge)

    try do
      collect_output(exec_pid, os_pid, [], 3_000)
    after
      :ok = OsProcess.stop(exec_pid)
    end
  end

  defp collect_output(exec_pid, os_pid, chunks, timeout) do
    receive do
      {:stdout, ^os_pid, bytes} ->
        collect_output(exec_pid, os_pid, [bytes | chunks], timeout)

      {:EXIT, ^exec_pid, :normal} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:EXIT, ^exec_pid, reason} ->
        {:error, reason, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      timeout -> {:error, :timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end
end
