defmodule EzagentPluginFeishu.Integration.BootSeedWiringTest do
  @moduledoc """
  Handoff B1 Phase 2 — the after_boot seed path now routes through
  `EzagentPluginFeishu.UserBindingSeed.run/1` (formal dispatch), never
  raw storage. This test verifies the wiring contract:

  - The seed path resolves to a real filesystem path (same FsResolver
    seam the production after_boot uses).
  - Missing file → no-op (`{:ok, :absent}`).
  - Valid file → structured summary.
  - Invalid file → structured error.

  The importer's own logic (parse, preflight, dispatch, rollback) is
  covered by `user_binding_seed_test.exs`; this file only covers the
  Application-level path resolution and return handling.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.UserBindingSeed
  alias EzagentPluginFeishu.UserBindingSeed.DispatchAdapter

  setup do
    Application.put_env(:ezagent_plugin_feishu, :seed_enabled, true)
    Application.put_env(:ezagent_plugin_feishu, :seed_auth_integrated, true)
    Application.put_env(:ezagent_plugin_feishu, :seed_executor, EzagentPluginFeishu.UserBindingSeed.DispatchAdapter)
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_feishu, :seed_enabled)
      Application.delete_env(:ezagent_plugin_feishu, :seed_auth_integrated)
      Application.delete_env(:ezagent_plugin_feishu, :seed_executor)
    end)
    :ok
  end

  defp seed_file_path do
    # Mirror the EXACT path resolution `Application.do_seed_initial_user_bindings/0`
    # uses: system://plugins → real dir + feishu/initial_user_bindings.yaml.
    plugins_dir = Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("plugins"))
    Path.join([plugins_dir, "feishu", "initial_user_bindings.yaml"])
  end

  defp workspace!(ws_name) do
    {:ok, _pid} = Ezagent.Workspace.create(ws_name)
    Ezagent.URI.new!("workspace://#{ws_name}")
  end

  describe "path resolution parity with current after_boot" do
    test "FsResolver returns a real path for the seed file (existence is NOT required)" do
      path = seed_file_path()
      assert is_binary(path) and path != ""
      assert String.ends_with?(path, "feishu/initial_user_bindings.yaml")
    end
  end

  describe "missing file → no-op (Locked Decision #5)" do
    test "UserBindingSeed.run/1 on a nonexistent path returns {:ok, :absent}" do
      nonexistent = "/tmp/nonexistent-feishu-seed-#{System.unique_integer([:positive])}.yaml"
      assert {:ok, :absent} = UserBindingSeed.run(nonexistent)
    end
  end

  describe "present valid → structured redacted summary" do
    test "a well-formed seed file creates bindings, returns bound row numbers" do
      ws_name = "bootwiring-happy-#{System.unique_integer([:positive])}"
      workspace!(ws_name)

      open_id = "ou_bootwiring_#{System.unique_integer([:positive])}"
      user_uri_str = "entity://#{ws_name}/user/newcomer"

      dir =
        Path.join(System.tmp_dir!(), "feishu-bootwiring-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "initial_user_bindings.yaml")
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(path, """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "#{user_uri_str}"
      """)

      assert {:ok, %{bound: [1], same: [], total: 1}} = UserBindingSeed.run(path)

      row = EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id)
      assert row.user_uri == user_uri_str
      assert row.bound_by == URI.to_string(Ezagent.Entity.User.admin_uri())
    end
  end

  describe "present invalid → structured error (Locked Decision #6)" do
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

    test "unknown field fails before any mutation" do
      ws_name = "bootwiring-invalid-#{System.unique_integer([:positive])}"
      workspace!(ws_name)

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
          user_uri: "entity://#{ws_name}/user/alice"
          note: "unexpected field"
      """)

      assert {:error, {:invalid_row, 1, _}} = UserBindingSeed.run(path)
      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end
  end
end
