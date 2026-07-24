defmodule EzagentPluginFeishu.Integration.BootSeedWiringTest do
  @moduledoc """
  Handoff B1 Phase 2 — A-layer wiring tests with FakeExecutor.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.UserBindingSeed
  alias EzagentPluginFeishu.UserBindingSeed.FakeExecutor

  setup do
    Application.put_env(:ezagent_plugin_feishu, :seed_enabled, true)
    Application.put_env(:ezagent_plugin_feishu, :seed_executor_port, FakeExecutor.port())

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_feishu, :seed_enabled)
      Application.delete_env(:ezagent_plugin_feishu, :seed_executor_port)
      FakeExecutor.stop()
    end)

    FakeExecutor.start()
    :ok
  end

  defp seed_file_path do
    plugins_dir = Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("plugins"))
    Path.join([plugins_dir, "feishu", "initial_user_bindings.yaml"])
  end

  defp write_real_seed_file!(content) do
    path = seed_file_path()
    previous = File.read(path)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    on_exit(fn ->
      case previous do
        {:ok, body} -> File.write!(path, body)
        {:error, :enoent} -> File.rm(path)
      end
    end)
  end

  describe "path resolution" do
    test "FsResolver returns a real path" do
      path = seed_file_path()
      assert is_binary(path) and path != ""
      assert String.ends_with?(path, "feishu/initial_user_bindings.yaml")
    end
  end

  describe "missing file → no-op" do
    test "UserBindingSeed.run/1 on a nonexistent path returns {:ok, :absent}" do
      nonexistent = "/tmp/nonexistent-feishu-seed-#{System.unique_integer([:positive])}.yaml"
      assert {:ok, :absent} = UserBindingSeed.run(nonexistent)
    end
  end

  describe "Application.after_boot/0 configured seed without boot authorization" do
    test "raises an explicit fail-closed executor/authorization error" do
      write_real_seed_file!("""
      bindings:
        - open_id: "ou_boot_auth_deferred"
          user_uri: "entity://team-alpha/user/alice"
      """)

      Application.delete_env(:ezagent_plugin_feishu, :seed_executor_port)

      assert_raise RuntimeError, ~r/seed executor\/boot authorization is not configured/, fn ->
        EzagentPluginFeishu.Application.after_boot()
      end
    end
  end

  describe "present valid → bind planned" do
    test "a well-formed seed file plans one bind" do
      open_id = "ou_bootwiring_#{System.unique_integer([:positive])}"

      dir =
        Path.join(System.tmp_dir!(), "feishu-bootwiring-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "initial_user_bindings.yaml")
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(path, """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/newcomer"
      """)

      assert {:ok, %{bound: [1], same: [], total: 1}} = UserBindingSeed.run(path)
      assert FakeExecutor.bind_count() == 1
    end
  end

  describe "present invalid → structured error" do
    test "malformed YAML returns {:error, {:malformed_yaml, _}}" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "feishu-bootwiring-bad-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      path = Path.join(dir, "initial_user_bindings.yaml")
      on_exit(fn -> File.rm_rf(dir) end)
      File.write!(path, "bindings: [\n  broken: :")
      assert {:error, {:malformed_yaml, _}} = UserBindingSeed.run(path)
    end

    test "unknown field fails before any bind is planned" do
      open_id = "ou_bootwiring_extra_#{System.unique_integer([:positive])}"

      dir =
        Path.join(
          System.tmp_dir!(),
          "feishu-bootwiring-extra-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      path = Path.join(dir, "initial_user_bindings.yaml")
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(path, """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
          note: "unexpected field"
      """)

      assert {:error, {:invalid_row, 1, _}} = UserBindingSeed.run(path)
      assert FakeExecutor.bind_count() == 0
    end
  end
end
