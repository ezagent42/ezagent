defmodule Mix.Tasks.Ezagent.Feishu.LegacyWrappersTest do
  @moduledoc """
  Handoff B1 permission-avoidance pivot — legacy task wrappers now only
  normalise arguments, print deprecation notices (via IO.puts), and exit.
  No dispatch, no auth, no mutation.
  """
  use ExUnit.Case, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "bind: normalises positional args, prints canonical replacement" do
    test "prints deprecation notice with canonical command" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.Feishu.Bind.run(["ou_abc123", "entity://team-alpha/user/alice"])
        end)

      assert output =~ "DEPRECATED"
      assert output =~ "workspace bind"
      assert output =~ "ou_abc123"
    end

    test "missing positional args prints usage and fails" do
      assert_raise Mix.Error, ~r/usage:/, fn ->
        Mix.Tasks.Ezagent.Feishu.Bind.run([])
      end
    end

    test "invalid user_uri fails with clear message" do
      assert_raise Mix.Error, ~r/invalid user URI/, fn ->
        Mix.Tasks.Ezagent.Feishu.Bind.run(["ou_x", "not-a-uri"])
      end
    end

    test "non-entity user_uri fails" do
      assert_raise Mix.Error, ~r/user entity/, fn ->
        Mix.Tasks.Ezagent.Feishu.Bind.run(["ou_x", "workspace://team-alpha"])
      end
    end

    test "--admin flag is rejected" do
      assert_raise Mix.Error, ~r/--admin/, fn ->
        Mix.Tasks.Ezagent.Feishu.Bind.run([
          "ou_x",
          "entity://team-alpha/user/x",
          "--admin",
          "entity://system/user/admin"
        ])
      end
    end
  end

  describe "unbind: requires --workspace, prints canonical replacement" do
    test "prints deprecation notice" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.Feishu.Unbind.run(["ou_abc123", "--workspace", "team-alpha"])
        end)

      assert output =~ "DEPRECATED"
      assert output =~ "workspace unbind"
    end

    test "missing --workspace fails loud" do
      assert_raise Mix.Error, ~r/--workspace/, fn ->
        Mix.Tasks.Ezagent.Feishu.Unbind.run(["ou_x"])
      end
    end

    test "missing positional open_id fails" do
      assert_raise Mix.Error, ~r/usage:/, fn ->
        Mix.Tasks.Ezagent.Feishu.Unbind.run(["--workspace", "team-alpha"])
      end
    end
  end

  describe "list: requires --workspace, prints canonical replacement" do
    test "prints deprecation notice" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Ezagent.Feishu.List.run(["--workspace", "team-alpha"])
        end)

      assert output =~ "DEPRECATED"
      assert output =~ "list_feishu_bindings"
    end

    test "missing --workspace fails loud" do
      assert_raise Mix.Error, ~r/--workspace/, fn ->
        Mix.Tasks.Ezagent.Feishu.List.run([])
      end
    end
  end
end
