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

      # The subprocess comes up + answers the operator's receive handler.
      # FIRE-AND-FORGET provision (fix Ⓑ): `instantiate/3` no longer blocks on
      # `await_ready`; `activate/2` brings the subprocess up async → POLL.
      assert wait_alive(agent_uri, 30_000)

      assert {:ok, %{"text" => "echo:hello"}} =
               Python.call(agent_uri, "receive", %{"text" => "hello"}, 10_000)
    end

    @tag :uv
    test "B1 — flavor is DURABLY resolvable from the sandbox slice (cold-restart routing)" do
      # codex-review B1: py now routes inbound chat through AgentBridge, which
      # resolves the agent's flavor to pick the :in_process_sync transport. The
      # ETS AgentFlavorAttributes record is VOLATILE (lost on BEAM restart); the
      # durable source is the :sandbox slice's template_class. Without it a
      # workspace py agent self-heals its subprocess but silently never replies
      # after a cold restart (delivery mis-routes to :subprocess_ws). This asserts
      # the DURABLE path `AgentFlavorResolver.resolve_flavor_from_sandbox/1` (what
      # cold-load uses — ETS-independent) recovers "py".
      name = "py_flavor-#{System.unique_integer([:positive])}"
      agent_uri_str = "entity://team-alpha/agent/#{name}"
      agent_uri = Ezagent.URI.new!(agent_uri_str)
      src = script_src()
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

      assert {:ok, [^agent_uri], _} =
               Ezagent.Kind.Template.provision_and_instantiate(Tmpl, "py.agent", tmpl, @workspace_uri)

      # Read the DURABLE snapshot slice (the cold-load source), NOT ETS.
      {:ok, %{state: state}} = Ezagent.SnapshotStore.latest(agent_uri)
      sandbox = Ezagent.Kind.normalize_slice_view(Map.get(state, :sandbox))

      assert sandbox.template_class == Ezagent.Template.PyAgent,
             "py spawn must persist template_class into the :sandbox slice for cold-restart flavor routing"

      assert {:ok, "py"} = Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(sandbox)
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

      # Async provision (fix Ⓑ) — poll for the subprocess `activate/2` brings up.
      assert wait_alive(agent_uri, 30_000)

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

    @tag :uv
    test "fix Ⓑ — instantiate does NOT block the create dispatch on a slow subprocess provision" do
      # REGRESSION (go-live 2026-07-06). A first-run np/py member on a fresh
      # container provisions its `uv` subprocess in ~9.6s (numpy/sympy). When
      # `instantiate/3` started that subprocess SYNCHRONOUSLY — blocking on
      # `Domain.Python.start_subprocess`'s `await_ready` ping — it ran INSIDE the
      # Workspace `create_session` GenServer call and blew the 5s dispatch budget,
      # so EVERY session create after ANY redeploy timed out
      # (`{:create_session_exit, {:timeout, {GenServer, :call, [_, _, 5000]}}}`).
      #
      # The fix defers the subprocess bring-up to the async `activate/2`, so
      # `instantiate/3` returns the instant the Kind is spawned + registered. A
      # script that sleeps before serving `python.ping` stands in for the cold
      # provision delay — deterministic, no dependency download.
      # `config/test.exs` sets a generous 5s `spawn_await_ready_ms` (so slow-boot
      # Kinds don't flap other tests). Prod uses the 500ms default. Mirror prod
      # here so the assertion reflects the real create latency: `Kind.spawn`'s
      # `do_await_ready` times out at this budget while the ~8s provision runs
      # async in `activate/2` (Kind stays `:not_ready`, buffering). Dropped to
      # 200ms to SHARPEN the discriminator — latency tracks the readiness budget,
      # NOT the provision (pre-fix: budget + 8s; post-fix: ≈ budget).
      prev_budget = Application.get_env(:ezagent_core, :spawn_await_ready_ms)
      Application.put_env(:ezagent_core, :spawn_await_ready_ms, 200)

      on_exit(fn ->
        if is_nil(prev_budget) do
          Application.delete_env(:ezagent_core, :spawn_await_ready_ms)
        else
          Application.put_env(:ezagent_core, :spawn_await_ready_ms, prev_budget)
        end
      end)

      name = "py_slowprov-#{System.unique_integer([:positive])}"
      agent_uri_str = "entity://team-alpha/agent/#{name}"
      agent_uri = Ezagent.URI.new!(agent_uri_str)
      ref_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, "py")

      tmpl = %{
        "class" => "py.agent",
        "agent_uri" => agent_uri_str,
        "config_dir" => ref_dir,
        "script" => slow_start_script(8),
        "timeout_ms" => 10_000
      }

      on_exit(fn ->
        _ = Python.stop(agent_uri)
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = File.rm_rf(ref_dir)
      end)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Ezagent.Kind.Template.provision_and_instantiate(
            Tmpl,
            "py.agent",
            tmpl,
            @workspace_uri
          )
        end)

      assert {:ok, [^agent_uri], %{fresh?: true}} = result

      # THE fix: create returns fast (bounded by the 200ms readiness budget, not
      # the ~8s subprocess provision). Pre-fix this took ~8s (the blocking
      # `start_python` → `await_ready`) and timed out the 5s session-create
      # dispatch.
      assert elapsed_us < 1_000_000,
             "instantiate/3 must not block on subprocess provision; took #{div(elapsed_us, 1000)}ms"

      # The Kind is materialized + REGISTERED (so it is joinable as a session
      # member) the instant instantiate returns — role routing resolves while the
      # subprocess is still provisioning.
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

      # …and it is held `:not_ready` DURING the provision. This is the buffering
      # precondition: a first `:cast` routed to the member in this window is
      # buffered via `PendingDelivery` and DELIVERED once it flips `:ready` (the
      # generic buffer→drain path is proven end-to-end in
      # `agent_template_spawn_sandbox_materialization_test.exs` "fire-and-forget …
      # buffers the write" — cast buffered while `:not_ready`, drained on `:ready`).
      assert Ezagent.ReadyGate.status(agent_uri) == :not_ready

      # The subprocess still comes up asynchronously via `activate/2` (after its
      # ~8s stand-in delay), and answers the operator's receive handler.
      assert wait_alive(agent_uri, 30_000)

      assert {:ok, %{"text" => "slow:hello"}} =
               Python.call(agent_uri, "receive", %{"text" => "hello"}, 10_000)
    end
  end

  # A script that sleeps `sleep_s` BEFORE registering its `python.ping` handler,
  # standing in for a cold `uv` provision so the readiness ping is slow — WITHOUT
  # a real dependency download (deterministic).
  defp slow_start_script(sleep_s) do
    """
    # /// script
    # requires-python = ">=3.11"
    # dependencies = []
    # ///
    import os, sys, time

    time.sleep(#{sleep_s})
    sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
    from ezagent_python import method, run


    @method("receive")
    def receive(params):
        return {"text": "slow:" + params.get("text", "")}


    if __name__ == "__main__":
        run()
    """
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
