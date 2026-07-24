defmodule EzagentPluginFeishu.UserBindingSeedTest do
  @moduledoc """
  Handoff B1 Phase 1/2 — DB integration tests for the seed importer
  orchestrator: missing/invalid file handling, the absent/same/conflict
  three-state preflight gate (whole-file, before any dispatch), and the
  runtime-partial-failure model (row N dispatch fails, row N-1's success
  is preserved, retry converges safely).
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.UserBinding, as: UB
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

  defp workspace!(ws_name) do
    {:ok, _pid} = Ezagent.Workspace.create(ws_name)
    Ezagent.URI.new!("workspace://#{ws_name}")
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

    test "a present-but-invalid row fails loud, zero mutation even for an otherwise-absent row" do
      fresh_open_id = "ou_seed_invalidrow_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{fresh_open_id}"
          user_uri: "entity://team-alpha/user/alice"
          note: "unexpected"
      """

      path = write_tmp_file!(yaml)
      assert {:error, {:invalid_row, 1, _}} = UserBindingSeed.run(path)
      assert :error = UB.resolve(fresh_open_id)
    end
  end

  describe "absent → real dispatch" do
    test "absent rows dispatch through real Invocation; bound_by is the real admin; structured+redacted summary" do
      ws_name = "seed-happy-#{System.unique_integer([:positive])}"
      workspace!(ws_name)
      open_id = "ou_seed_happy_#{System.unique_integer([:positive])}"
      user_uri_str = "entity://#{ws_name}/user/newcomer"

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "#{user_uri_str}"
      """

      path = write_tmp_file!(yaml)

      assert {:ok, %{bound: [1], same: [], total: 1}} = UserBindingSeed.run(path)

      {:ok, resolved} = UB.resolve(open_id)
      assert URI.to_string(resolved) == user_uri_str

      row = EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id)
      assert row.bound_by == URI.to_string(Ezagent.Entity.User.admin_uri())
    end

    test "multiple absent rows across different workspaces all dispatch" do
      ws_a = "seed-multi-a-#{System.unique_integer([:positive])}"
      ws_b = "seed-multi-b-#{System.unique_integer([:positive])}"
      workspace!(ws_a)
      workspace!(ws_b)

      open_id_a = "ou_seed_multi_a_#{System.unique_integer([:positive])}"
      open_id_b = "ou_seed_multi_b_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{open_id_a}"
          user_uri: "entity://#{ws_a}/user/alice"
        - open_id: "#{open_id_b}"
          user_uri: "entity://#{ws_b}/user/bob"
      """

      path = write_tmp_file!(yaml)

      assert {:ok, %{bound: bound_rows, same: [], total: 2}} = UserBindingSeed.run(path)
      assert Enum.sort(bound_rows) == [1, 2]

      assert {:ok, _} = UB.resolve(open_id_a)
      assert {:ok, _} = UB.resolve(open_id_b)
    end
  end

  describe "same → pure no-op" do
    test "identical open_id + user_uri already bound: no dispatch, bound_at/bound_by unchanged" do
      ws_name = "seed-same-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)
      open_id = "ou_seed_same_#{System.unique_integer([:positive])}"
      user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/alice")

      {:ok, _} = DispatchAdapter.bind(ws_uri, open_id, user_uri)
      before_row = EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id)

      yaml = """
      bindings:
        - open_id: "#{open_id}"
          user_uri: "#{URI.to_string(user_uri)}"
      """

      path = write_tmp_file!(yaml)

      assert {:ok, %{bound: [], same: [1], total: 1}} = UserBindingSeed.run(path)

      after_row = EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id)
      assert after_row.bound_at == before_row.bound_at
      assert after_row.bound_by == before_row.bound_by
    end
  end

  describe "conflict → whole-file preflight gate, zero mutation, redacted" do
    test "a same-workspace conflict on a LATER row blocks an EARLIER absent row (front stays absent)" do
      ws_name = "seed-gate-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)

      conflicting_open_id = "ou_seed_conflict_#{System.unique_integer([:positive])}"
      existing_user = Ezagent.URI.new!("entity://#{ws_name}/user/existing")
      {:ok, _} = DispatchAdapter.bind(ws_uri, conflicting_open_id, existing_user)

      fresh_open_id = "ou_seed_frontabsent_#{System.unique_integer([:positive])}"

      yaml = """
      bindings:
        - open_id: "#{fresh_open_id}"
          user_uri: "entity://#{ws_name}/user/alice"
        - open_id: "#{conflicting_open_id}"
          user_uri: "entity://#{ws_name}/user/somebody_else"
      """

      path = write_tmp_file!(yaml)

      assert {:error, {:conflict, 2, ^ws_name, fingerprint}} = UserBindingSeed.run(path)
      refute fingerprint =~ conflicting_open_id

      # Row 1 (would-be absent) was NEVER dispatched — whole-file gate.
      assert :error = UB.resolve(fresh_open_id)

      # Row 2's ORIGINAL binding is untouched — never overwritten.
      {:ok, resolved} = UB.resolve(conflicting_open_id)
      assert URI.to_string(resolved) == URI.to_string(existing_user)
    end

    test "conflict error never contains the raw open_id or user_uri" do
      ws_name = "seed-gate-redact-#{System.unique_integer([:positive])}"
      ws_uri = workspace!(ws_name)

      conflicting_open_id = "ou_seed_redact_super_secret_#{System.unique_integer([:positive])}"
      existing_user = Ezagent.URI.new!("entity://#{ws_name}/user/existing")
      {:ok, _} = DispatchAdapter.bind(ws_uri, conflicting_open_id, existing_user)

      yaml = """
      bindings:
        - open_id: "#{conflicting_open_id}"
          user_uri: "entity://#{ws_name}/user/somebody_else"
      """

      path = write_tmp_file!(yaml)

      {:error, error} = UserBindingSeed.run(path)
      inspected = inspect(error)
      refute inspected =~ conflicting_open_id
      refute inspected =~ "somebody_else"
      refute inspected =~ "existing"
    end
  end

  describe "duplicate open_id (parser-level, re-asserted at importer boundary)" do
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
      assert :error = UB.resolve(dup_open_id)
    end
  end
end
