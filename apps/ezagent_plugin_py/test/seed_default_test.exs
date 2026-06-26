defmodule Ezagent.PluginPy.SeedDefaultTest do
  @moduledoc """
  P2 HIGH-1 evidence — `EzagentPluginPy.Application.seed_default/0` brings up a
  LIVE `py_default` (the echo.py py-agent that replaced the deleted echo
  default agent). This is the seed the OpenAI `/v1/chat/completions` default
  path + the web home view depend on.

  Proves: the seed reads `echo.py` from priv, provisions via the canonical
  `provision_and_instantiate` seam under `workspace://system`, the subprocess
  is live, and a `:receive` round-trips. Also proves idempotency (re-seed is a
  no-op) + boot-safety (the seed always returns `:ok`).

  `:uv`-tagged — provisions a real Domain.Python subprocess.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginPy.Application, as: PyApp
  alias Ezagent.Domain.Python

  @moduletag :uv

  setup do
    case System.find_executable("uv") do
      nil ->
        {:skip, "uv not on PATH"}

      _ ->
        # Isolation: the seed installs echo.py into py_default's per-agent
        # config_dir, which lives under the shared HOME. A stale leftover with
        # DIFFERING bytes makes install_script refuse with :script_immutable and
        # the boot-seed fail. Clear it so the seed always writes fresh (no-op on
        # a clean HOME / CI).
        _ = File.rm_rf(Ezagent.Sandbox.ConfigDir.path(PyApp.default_uri(), "py"))
        :ok
    end
  end

  test "seed_default/0 brings up a live py_default that echoes via echo.py" do
    default_uri = PyApp.default_uri()

    assert URI.to_string(default_uri) == "entity://system/agent/py_default"

    # boot-safe contract: always :ok
    assert :ok = PyApp.seed_default()

    on_exit(fn ->
      _ = Python.stop(default_uri)
      _ = Ezagent.Kind.terminate(default_uri)
    end)

    # The subprocess comes up via activate/2 (async on the adopt fast-path when
    # py_default was already seeded by a prior boot); poll for liveness.
    assert wait_alive(default_uri, 30_000),
           "seed_default/0 must leave py_default's Domain.Python subprocess alive"

    # echo.py echoes the text verbatim.
    assert {:ok, %{"text" => "seed-hi"}} =
             Python.call(default_uri, "receive", %{"text" => "seed-hi"}, 10_000)

    # Idempotent: re-seeding is a no-op (identical script + adopted Kind).
    assert :ok = PyApp.seed_default()
    assert wait_alive(default_uri, 30_000)
  end

  defp wait_alive(uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_alive(uri, deadline)
  end

  defp do_wait_alive(uri, deadline) do
    cond do
      Python.alive?(uri) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        Process.sleep(200)
        do_wait_alive(uri, deadline)
    end
  end
end
