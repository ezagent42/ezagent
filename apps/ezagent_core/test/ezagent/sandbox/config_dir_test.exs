defmodule Ezagent.Sandbox.ConfigDirTest do
  @moduledoc """
  PR-3 (domain.agent §3.1.2/§3.1.3, D2) — the per-agent config_dir TARGET is
  owned by the domain (the sandbox concept) in core, not the flavor plugin.
  """
  use ExUnit.Case, async: false
  import Bitwise

  alias Ezagent.Home
  alias Ezagent.Sandbox.ConfigDir

  defp agent_uri(ws, name), do: Ezagent.URI.new!("entity://#{ws}/agent/#{name}")

  describe "path/2" do
    test "builds <Home>/<namespace>-agents/<ws>/<name> — byte-identical to the cc layout" do
      uri = agent_uri("myws", "cc_foo")

      assert ConfigDir.path(uri, "cc") ==
               Path.join([Home.path("cc-agents"), "myws", "cc_foo"])
    end

    test "the namespace parameterizes the prefix" do
      uri = agent_uri("w", "x")

      assert ConfigDir.path(uri, "codex") ==
               Path.join([Home.path("codex-agents"), "w", "x"])
    end

    test "raises on a non-agent URI (defense-in-depth — no silent default)" do
      not_agent = Ezagent.URI.new!("entity://system/user/admin")
      assert_raise ArgumentError, fn -> ConfigDir.path(not_agent, "cc") end
    end
  end

  describe "allocate/2" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "ezagent-cfgdir-test-#{System.unique_integer([:positive])}"
        )

      prev = System.get_env("EZAGENT_HOME")
      System.put_env("EZAGENT_HOME", tmp)

      on_exit(fn ->
        if prev, do: System.put_env("EZAGENT_HOME", prev), else: System.delete_env("EZAGENT_HOME")
        File.rm_rf(tmp)
      end)

      :ok
    end

    test "creates the per-agent dir at the canonical path, mode 0o700, idempotent" do
      uri = agent_uri("ws1", "cc_a")

      assert {:ok, target} = ConfigDir.allocate(uri, "cc")
      assert target == ConfigDir.path(uri, "cc")
      assert File.dir?(target)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(target)
      assert (mode &&& 0o777) == 0o700

      # second call is a harmless no-op (DD-7 idempotence)
      assert {:ok, ^target} = ConfigDir.allocate(uri, "cc")
      assert File.dir?(target)
    end
  end

  describe "safe_to_destroy?/3" do
    test "true only for the canonical path of this agent + namespace" do
      uri = agent_uri("ws", "cc_z")

      assert ConfigDir.safe_to_destroy?(ConfigDir.path(uri, "cc"), uri, "cc")
      refute ConfigDir.safe_to_destroy?("/etc", uri, "cc")
      refute ConfigDir.safe_to_destroy?("/tmp/elsewhere", uri, "cc")
      # a path for a DIFFERENT agent is not safe to destroy under this uri
      refute ConfigDir.safe_to_destroy?(ConfigDir.path(agent_uri("ws", "other"), "cc"), uri, "cc")
    end
  end

  describe "validate_project_cwd/2" do
    test "accepts cwd within config_dir" do
      config_dir = "/tmp/ezagent-test/config"

      assert {:ok, "/tmp/ezagent-test/config/sub"} =
               Ezagent.Sandbox.ConfigDir.validate_project_cwd(
                 "/tmp/ezagent-test/config/sub",
                 config_dir
               )
    end

    test "rejects cwd outside config_dir and operator roots" do
      assert {:error, {:cwd_outside_allowed_roots, _}} =
               Ezagent.Sandbox.ConfigDir.validate_project_cwd(
                 "/etc/passwd",
                 "/tmp/ezagent-test/config"
               )
    end

    test "accepts cwd within operator-configured root" do
      prev = System.get_env("EZAGENT_ALLOWED_CWD_ROOTS")
      System.put_env("EZAGENT_ALLOWED_CWD_ROOTS", "/Users/h2oslabs/Workspace")

      assert {:ok, _} =
               Ezagent.Sandbox.ConfigDir.validate_project_cwd(
                 "/Users/h2oslabs/Workspace/esr-ng",
                 "/tmp/ezagent"
               )

      if prev,
        do: System.put_env("EZAGENT_ALLOWED_CWD_ROOTS", prev),
        else: System.delete_env("EZAGENT_ALLOWED_CWD_ROOTS")
    end
  end
end
