defmodule Ezagent.PluginPy.ProvisionFailureTest do
  @moduledoc """
  PR #1259 codex review item 1 — a py member whose subprocess provision FAILS
  (uv/network/cwd trouble during the async `activate/2` bring-up) must not be
  a silent zombie:

    (a) the failure is VISIBLY recorded — durable
        `:last_error {:provision_failed, reason}` on the agent's `:py_agent`
        slice (not just a log line);
    (b) a subsequent instantiate/ADOPT of the same URI does not report success
        over the dead subprocess — it RETRIES the provision asynchronously
        (`:py_ensure_alive`) and RECOVERS once the underlying failure clears,
        clearing the marker.

  Failure fixture: a nonexistent `cwd` — `Domain.Python.start_subprocess`
  fail-fasts with `{:error, :bad_cwd}` (0ms, no uv dependency), standing in
  for any provision-time failure. "Failure clears" = `mkdir` the cwd.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Template.PyAgent, as: Tmpl
  alias Ezagent.Domain.Python

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")

  @script """
  # /// script
  # requires-python = ">=3.11"
  # dependencies = []
  # ///
  import os, sys
  sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
  from ezagent_python import method, run


  @method("receive")
  def receive(params):
      return {"text": "revived:" + params.get("text", "")}


  if __name__ == "__main__":
      run()
  """

  @tag :uv
  test "provision failure → durable {:provision_failed, _} marker; adopt retries and recovers" do
    name = "py_provfail-#{System.unique_integer([:positive])}"
    agent_uri_str = "entity://team-alpha/agent/#{name}"
    agent_uri = Ezagent.URI.new!(agent_uri_str)

    config_dir = Path.join(System.tmp_dir!(), "py-provfail-#{System.unique_integer([:positive])}")
    bad_cwd = config_dir <> "-cwd-missing"
    File.mkdir_p!(config_dir)

    on_exit(fn ->
      _ = Python.stop(agent_uri)
      _ = Ezagent.Kind.terminate(agent_uri)
      _ = File.rm_rf(config_dir)
      _ = File.rm_rf(bad_cwd)
    end)

    {:ok, script_path} = Tmpl.install_script(config_dir, @script)

    # --- 1. Spawn with a BROKEN cwd → the async activate/2 provision fails. --
    # (Mirrors the template's init_args; the template always uses config_dir as
    # cwd, so the broken-provision phase is driven through the same Kind spawn
    # the template performs, with the cwd sabotaged.)
    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: agent_uri,
        python_handle: agent_uri,
        script_path: script_path,
        cwd: bad_cwd,
        timeout_ms: 10_000,
        behaviors: Ezagent.Entity.Agent.base_behaviors() ++ [Ezagent.ActionSet.PyAgent],
        template_class: Tmpl
      })

    assert wait_until(fn -> Ezagent.ReadyGate.status(agent_uri) == :ready end, 10_000),
           "agent Kind must still become ready (joinable) after a provision failure"

    # (a) The failure is OBSERVABLE on the slice — not just a log line.
    assert wait_until(
             fn -> match?({:provision_failed, _}, read_last_error(agent_uri)) end,
             5_000
           ),
           "expected a {:provision_failed, _} :last_error marker; " <>
             "got #{inspect(read_last_error(agent_uri))}"

    refute Python.alive?(agent_uri)

    # --- 2. The failure CLEARS (cwd appears), and an ADOPT retries. ----------
    File.mkdir_p!(bad_cwd)

    tmpl = %{
      "class" => "py.agent",
      "agent_uri" => agent_uri_str,
      "allocated_config_dir" => config_dir,
      "script" => @script
    }

    # Adopt arm: the Kind is :already_started → pre-fix this reported success
    # and NEVER retried (zombie until a user message failed). Post-fix it
    # dispatches the async :py_ensure_alive retry.
    assert {:ok, [^agent_uri], %{fresh?: false}} =
             Tmpl.instantiate("py.agent", tmpl, @workspace_uri)

    # (b) The retry recovers the member...
    assert wait_until(fn -> Python.alive?(agent_uri) end, 30_000),
           "adopt must retry the provision and recover once the failure cleared"

    # ...and clears the provision-failure marker.
    assert wait_until(fn -> read_last_error(agent_uri) == nil end, 5_000),
           "recovery must clear the {:provision_failed, _} marker; " <>
             "got #{inspect(read_last_error(agent_uri))}"

    # End-to-end: the recovered subprocess actually serves.
    assert {:ok, %{"text" => "revived:ping"}} =
             Python.call(agent_uri, "receive", %{"text" => "ping"}, 10_000)
  end

  defp read_last_error(agent_uri) do
    case Ezagent.Kind.read(agent_uri, Ezagent.ActionSet.PyAgent.state_slice(), spawn: :never) do
      {:ok, slice} -> Ezagent.Kind.normalize_slice_view(slice) |> Map.get(:last_error)
      _ -> :no_slice
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(100) && do_wait_until(fun, deadline)
    end
  end
end
