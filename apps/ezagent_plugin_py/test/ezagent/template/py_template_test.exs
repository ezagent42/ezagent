defmodule Ezagent.Template.PyAgentTest do
  @moduledoc """
  Task 1.3 (py-agent plan) — `Template.PyAgent` on the canonical config_dir
  seam. `provision_and_instantiate/4` for a py template with
  `config = %{script, timeout_ms}` + a `"config_dir"` reference allocates a
  config_dir, writes `agent.py` == the operator script, starts a LIVE
  subprocess, and records `script_path` in the slice. Plus the injection-gate
  unit (`install_script/2`) and pure validate/0.
  """

  # P4b — py spawns the UNIFIED Entity.Agent Kind, whose init reads the snapshot
  # store (DB). The provision_and_instantiate tests spawn a real Kind.Server, so
  # they need the DataCase shared sandbox (the old own-Kind init did no DB read).
  use EzagentCore.DataCase, async: false

  alias Ezagent.Template.PyAgent, as: Tmpl
  alias Ezagent.Domain.Python

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")

  defp script_src do
    """
    # /// script
    # requires-python = ">=3.11"
    # dependencies = []
    # ///
    import os, sys
    sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
    from ezagent_python import method, run


    @method("receive")
    def receive(params):
        return {"text": "echo:" + params.get("text", "")}


    if __name__ == "__main__":
        run()
    """
  end

  describe "template_name/0 + config_dir_namespace/0" do
    test "py.agent + py namespace" do
      assert Tmpl.template_name() == "py.agent"
      assert Tmpl.config_dir_namespace() == "py"
    end
  end

  describe "validate/1" do
    test "accepts a valid template with a script" do
      assert :ok =
               Tmpl.validate(%{
                 "class" => "py.agent",
                 "agent_uri" => "entity://team-alpha/agent/py_ok",
                 "script" => "print('x')"
               })
    end

    test "rejects a missing script" do
      assert {:error, :missing_script} =
               Tmpl.validate(%{
                 "class" => "py.agent",
                 "agent_uri" => "entity://team-alpha/agent/py_noscript"
               })
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "np.agent"}} =
               Tmpl.validate(%{
                 "class" => "np.agent",
                 "agent_uri" => "entity://team-alpha/agent/py_x",
                 "script" => "x"
               })
    end
  end

  describe "install_script/2 — the injection gate (Task 1.5b)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "py-install-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "writes agent.py on first install", %{dir: dir} do
      assert {:ok, path} = Tmpl.install_script(dir, "print(1)")
      assert path == Path.join(dir, "agent.py")
      assert File.read!(path) == "print(1)"
    end

    test "re-install with IDENTICAL content is idempotent", %{dir: dir} do
      assert {:ok, path} = Tmpl.install_script(dir, "print(1)")
      assert {:ok, ^path} = Tmpl.install_script(dir, "print(1)")
    end

    test "re-install with DIFFERENT content is REFUSED (:script_immutable)", %{dir: dir} do
      assert {:ok, _path} = Tmpl.install_script(dir, "print(1)")
      assert {:error, :script_immutable} = Tmpl.install_script(dir, "print(666)")
      # The original content is preserved.
      assert File.read!(Path.join(dir, "agent.py")) == "print(1)"
    end
  end

  describe "provision_and_instantiate/4 — the canonical seam (uv)" do
    @tag :uv
    test "allocates config_dir, writes agent.py, starts a live subprocess" do
      name = "py_prov-#{System.unique_integer([:positive])}"
      agent_uri_str = "entity://team-alpha/agent/#{name}"
      agent_uri = Ezagent.URI.new!(agent_uri_str)
      src = script_src()

      # The persisted template carries a "config_dir" REFERENCE — that drives
      # maybe_allocate_config_dir → "allocated_config_dir" → instantiate.
      ref_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, "py")

      tmpl = %{
        "class" => "py.agent",
        "agent_uri" => agent_uri_str,
        "config_dir" => ref_dir,
        "script" => src,
        "timeout_ms" => 10_000
      }

      on_exit(fn ->
        _ = Python.stop(agent_uri)
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = File.rm_rf(ref_dir)
      end)

      assert {:ok, [^agent_uri], %{fresh?: true}} =
               Ezagent.Kind.Template.provision_and_instantiate(
                 Tmpl,
                 "py.agent",
                 tmpl,
                 @workspace_uri
               )

      # agent.py was written into the allocated config_dir == the operator script.
      installed = Path.join(ref_dir, "agent.py")
      assert File.read!(installed) == src

      # The subprocess is LIVE + answers the operator's receive handler.
      assert Python.alive?(agent_uri)

      assert {:ok, %{"text" => "echo:hello"}} =
               Python.call(agent_uri, "receive", %{"text" => "hello"}, 10_000)
    end

    @tag :uv
    test "cold-restart re-spawns from the installed file (no re-write)" do
      name = "py_cold-#{System.unique_integer([:positive])}"
      agent_uri_str = "entity://team-alpha/agent/#{name}"
      agent_uri = Ezagent.URI.new!(agent_uri_str)
      src = script_src()
      ref_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, "py")

      tmpl = %{
        "class" => "py.agent",
        "agent_uri" => agent_uri_str,
        "config_dir" => ref_dir,
        "script" => src
      }

      on_exit(fn ->
        _ = Python.stop(agent_uri)
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = File.rm_rf(ref_dir)
      end)

      assert {:ok, [^agent_uri], %{fresh?: true}} =
               Ezagent.Kind.Template.provision_and_instantiate(
                 Tmpl,
                 "py.agent",
                 tmpl,
                 @workspace_uri
               )

      assert Python.alive?(agent_uri)

      # Simulate a subprocess death (cold restart of the runtime). The
      # ensure_subprocess_alive callback re-spawns from the EXISTING agent.py.
      Python.stop(agent_uri)
      refute Python.alive?(agent_uri)

      script_path = Path.join(ref_dir, "agent.py")

      assert :ok =
               Tmpl.ensure_subprocess_alive(agent_uri, %{
                 "script_path" => script_path,
                 "cwd" => ref_dir
               })

      assert Python.alive?(agent_uri)
      # The script file was NOT re-written (still the original operator script).
      assert File.read!(script_path) == src
    end
  end
end
