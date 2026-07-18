defmodule Ezagent.PluginPy.CreateE2ETest do
  @moduledoc """
  Task 1.4 (py-agent plan) — the HEADLINE create-path test that closes np's
  gap: create a py-agent via the REAL create path (`Workspace.create_agent`,
  flavor "py", an operator `script`) and assert the Domain.Python subprocess
  is LIVE after create (not just the Kind spawned), `:receive` replies
  end-to-end, and a cold-restart re-spawns + re-loads the script.

  `:uv`-tagged (needs a real subprocess).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Domain.Python

  @moduletag :uv

  @operator_script """
  # /// script
  # requires-python = ">=3.11"
  # dependencies = []
  # ///
  import os, sys
  sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
  from ezagent_python import method, run


  @method("receive")
  def receive(params):
      return {"text": "py-reply:" + params.get("text", "")}


  if __name__ == "__main__":
      run()
  """

  setup do
    case System.find_executable("uv") do
      nil ->
        {:skip, "uv not on PATH"}

      _ ->
        ws_name = "py-create-#{System.unique_integer([:positive])}"
        {:ok, _ws_pid} = Workspace.create(ws_name, %{})
        workspace_uri = URI.new!("workspace://#{ws_name}")

        admin_ctx =
          Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

        {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
    end
  end

  test "create a py-agent via the real path -> subprocess LIVE + :receive replies + cold-restart re-spawns",
       %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    name = "calc#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: %URI{} = agent_uri, template_name: tmpl_name}} =
             Workspace.create_agent(
               workspace_uri,
               %{
                 flavor: "py",
                 name: name,
                 cwd: "",
                 with_pty: false,
                 flavor_config: %{"script" => @operator_script, "timeout_ms" => "10000"}
               },
               admin_ctx
             )

    assert is_binary(tmpl_name)

    on_exit(fn ->
      _ = Python.stop(agent_uri)
      _ = Ezagent.Kind.terminate(agent_uri)
    end)

    # THE np-gap closer: the subprocess comes up after create (not just the
    # Kind spawned). The np direct-spawn route never called instantiate/3, so
    # np-via-UI came up with no subprocess; py's template route does.
    #
    # FIRE-AND-FORGET provision (fix Ⓑ, 2026-07-06): `instantiate/3` no longer
    # blocks the create dispatch on `Domain.Python.await_ready` — the subprocess
    # is brought up ASYNCHRONOUSLY by `ActionSet.PyAgent.activate/2`. So the
    # liveness assertion POLLS (it is eventually alive), not synchronously alive
    # the instant create returns.
    assert wait_alive(agent_uri, 30_000),
           "the py-agent's Domain.Python subprocess must come up after create"

    # :receive replies end-to-end via the operator script.
    assert {:ok, %{"text" => "py-reply:hi"}} =
             Python.call(agent_uri, "receive", %{"text" => "hi"}, 10_000)

    # Cold-restart re-spawns from the installed script (not re-written).
    config_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, "py")
    installed = Path.join(config_dir, "agent.py")
    assert File.read!(installed) == @operator_script

    Python.stop(agent_uri)
    refute Python.alive?(agent_uri)

    assert :ok =
             Ezagent.Template.PyAgent.ensure_subprocess_alive(agent_uri, %{
               "script_path" => installed,
               "cwd" => config_dir
             })

    assert Python.alive?(agent_uri)
    assert File.read!(installed) == @operator_script

    assert {:ok, %{"text" => "py-reply:again"}} =
             Python.call(agent_uri, "receive", %{"text" => "again"}, 10_000)
  end

  defp wait_alive(uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_alive(uri, deadline)
  end

  defp do_wait_alive(uri, deadline) do
    cond do
      Python.alive?(uri) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(200) && do_wait_alive(uri, deadline)
    end
  end
end
