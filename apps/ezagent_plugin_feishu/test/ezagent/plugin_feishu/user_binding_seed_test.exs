defmodule EzagentPluginFeishu.UserBindingSeedTest do
  @moduledoc """
  Handoff B1 — A-layer (permission-neutral) importer tests with FakeExecutor.
  Verifies the importer logic: parser, preflight, classification, conflict gate.
  No real dispatch, no DB state — only planned operations are asserted.
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

  defp write_tmp_file!(content) do
    dir = Path.join(System.tmp_dir!(), "feishu-seed-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "initial_user_bindings.yaml")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  describe "missing / invalid file" do
    test "missing file is a normal no-op" do
      assert {:ok, :absent} =
               UserBindingSeed.run(
                 "/nonexistent/#{System.unique_integer([:positive])}/bindings.yaml"
               )
    end

    test "malformed YAML fails loud with zero mutation" do
      path = write_tmp_file!("bindings: [\n  broken")
      assert {:error, {:malformed_yaml, _}} = UserBindingSeed.run(path)
    end

    test "a present-but-invalid row fails loud; no binds planned" do
      fresh_open_id = "ou_seed_invalidrow_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{fresh_open_id}"
          user_uri: "entity://team-alpha/user/alice"
          note: "unexpected"
      """

      path = write_tmp_file!(yaml)
      assert {:error, {:invalid_row, 1, _}} = UserBindingSeed.run(path)
      assert FakeExecutor.bind_count() == 0
    end
  end

  describe "absent → bind planned" do
    test "absent rows → structured summary, bind recorded" do
      open_id = "ou_seed_plan_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)
      assert {:ok, %{bound: [1], same: [], total: 1}} = UserBindingSeed.run(path)
      assert FakeExecutor.bind_count() == 1
    end

    test "multiple absent rows → all planned" do
      open_id_a = "ou_seed_multi_a_#{System.unique_integer([:positive])}"
      open_id_b = "ou_seed_multi_b_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{open_id_a}"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "#{open_id_b}"
          user_uri: "entity://team-beta/user/bob"
      """

      path = write_tmp_file!(yaml)
      assert {:ok, %{bound: bound_rows, same: [], total: 2}} = UserBindingSeed.run(path)
      assert Enum.sort(bound_rows) == [1, 2]
      assert FakeExecutor.bind_count() == 2
    end
  end

  describe "same → pure no-op, no bind planned" do
    test "existing binding → classified :same, zero binds" do
      open_id = "ou_seed_same_#{System.unique_integer([:positive])}"
      uri_str = "entity://team-alpha/user/alice"
      FakeExecutor.stop()
      FakeExecutor.start(existing: [%{open_id: open_id, user_uri: uri_str}])
      Application.put_env(:ezagent_plugin_feishu, :seed_executor_port, FakeExecutor.port())

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "#{uri_str}"
      """

      path = write_tmp_file!(yaml)
      assert {:ok, %{bound: [], same: [1], total: 1}} = UserBindingSeed.run(path)
      assert FakeExecutor.bind_count() == 0
    end
  end

  describe "conflict → whole-file gate, zero binds" do
    test "existing open_id with DIFFERENT user_uri → conflict" do
      open_id = "ou_seed_conflict_#{System.unique_integer([:positive])}"
      FakeExecutor.stop()

      FakeExecutor.start(
        existing: [%{open_id: open_id, user_uri: "entity://team-alpha/user/bob"}]
      )

      Application.put_env(:ezagent_plugin_feishu, :seed_executor_port, FakeExecutor.port())

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)
      assert {:error, {:conflict, 1, "team-alpha", _fingerprint}} = UserBindingSeed.run(path)
      assert FakeExecutor.bind_count() == 0
    end
  end

  describe "duplicate open_id (parser-level)" do
    test "duplicate open_id in the file is rejected before any dispatch" do
      dup_open_id = "ou_seed_dup_importer_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{dup_open_id}"
          user_uri: "entity://team-alpha/user/alice"
        - open_id: "#{dup_open_id}"
          user_uri: "entity://team-beta/user/bob"
      """

      path = write_tmp_file!(yaml)
      assert {:error, {:duplicate_open_id, _fingerprint, [1, 2]}} = UserBindingSeed.run(path)
    end
  end

  describe "gate: seed disabled → fail loud" do
    test "seed not enabled → :seed_not_enabled" do
      Application.delete_env(:ezagent_plugin_feishu, :seed_enabled)

      yaml = """
      bindings:
        - open_id: "ou_disabled_#{System.unique_integer([:positive])}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)
      assert {:error, :seed_not_enabled} = UserBindingSeed.run(path)
    end
  end
end
