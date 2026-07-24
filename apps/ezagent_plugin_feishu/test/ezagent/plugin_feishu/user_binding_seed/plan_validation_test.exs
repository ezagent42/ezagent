defmodule EzagentPluginFeishu.UserBindingSeed.PlanValidationTest do
  @moduledoc """
  Handoff B1 — plan-validation tests proving the A-layer (importer plan)
  works correctly with an injected FakeExecutor. No real dispatch, no
  CapBAC, no B-layer auth. The FakeExecutor records what would be
  requested — these tests assert the correct operations are planned.
  """
  use ExUnit.Case, async: false

  alias EzagentPluginFeishu.UserBindingSeed
  alias EzagentPluginFeishu.UserBindingSeed.FakeExecutor

  setup do
    FakeExecutor.start()
    Application.put_env(:ezagent_plugin_feishu, :seed_enabled, true)
    Application.put_env(:ezagent_plugin_feishu, :seed_executor, FakeExecutor)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_feishu, :seed_enabled)
      Application.delete_env(:ezagent_plugin_feishu, :seed_executor)
      FakeExecutor.stop()
    end)
  end

  defp write_tmp_file!(content) do
    dir = Path.join(System.tmp_dir!(), "feishu-fake-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "initial_user_bindings.yaml")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  describe "plan: absent rows → bind planned" do
    test "a single absent row plans one bind and one list_current" do
      open_id = "ou_fake_plan_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)

      assert {:ok, %{bound: [1], same: [], total: 1}} = UserBindingSeed.run(path)

      # Proves: one preflight list was requested.
      assert FakeExecutor.list_current_count() >= 1
      # Proves: one bind was planned for the absent row.
      assert FakeExecutor.bind_count() == 1
      [{:bind, ^open_id, _}] = FakeExecutor.binds()
    end
  end

  describe "plan: same rows → no bind planned" do
    test "an existing same-workspace binding is classified :same, no bind planned" do
      open_id = "ou_fake_same_#{System.unique_integer([:positive])}"
      uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
      uri_str = URI.to_string(uri)

      # Pre-populate the fake's "existing bindings" so the preflight
      # classifies this row as :same.
      FakeExecutor.stop()
      FakeExecutor.start(existing: [%{open_id: open_id, user_uri: uri_str}])
      Application.put_env(:ezagent_plugin_feishu, :seed_executor, FakeExecutor)

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "#{uri_str}"
      """

      path = write_tmp_file!(yaml)

      assert {:ok, %{bound: [], same: [1], total: 1}} = UserBindingSeed.run(path)

      assert FakeExecutor.list_current_count() >= 1
      # Proves: NO bind was planned for the :same row.
      assert FakeExecutor.bind_count() == 0
    end
  end

  describe "plan: conflict → whole-file fail, zero bind planned" do
    test "an existing same-workspace binding with DIFFERENT user_uri → conflict" do
      open_id = "ou_fake_conflict_#{System.unique_integer([:positive])}"

      # Pre-populate with a DIFFERENT user_uri — conflict trigger.
      FakeExecutor.stop()
      FakeExecutor.start(existing: [%{open_id: open_id, user_uri: "entity://team-alpha/user/bob"}])
      Application.put_env(:ezagent_plugin_feishu, :seed_executor, FakeExecutor)

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)

      assert {:error, {:conflict, 1, "team-alpha", _fingerprint}} = UserBindingSeed.run(path)

      assert FakeExecutor.list_current_count() >= 1
      # Proves: ZERO binds planned — whole-file conflict gate.
      assert FakeExecutor.bind_count() == 0
    end
  end

  describe "gate: executor not configured → fail loud" do
    test "seed_enabled but no executor → :seed_executor_not_configured" do
      Application.delete_env(:ezagent_plugin_feishu, :seed_executor)

      open_id = "ou_fake_nil_exec_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)

      assert {:error, :seed_executor_not_configured} = UserBindingSeed.run(path)
    end

    test "seed not enabled → :seed_not_enabled" do
      Application.delete_env(:ezagent_plugin_feishu, :seed_enabled)

      open_id = "ou_fake_disabled_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "entity://team-alpha/user/alice"
      """

      path = write_tmp_file!(yaml)

      assert {:error, :seed_not_enabled} = UserBindingSeed.run(path)
    end
  end
end
