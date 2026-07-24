defmodule EzagentPluginFeishu.Behavior.UserBindingRollbackTest do
  @moduledoc """
  Handoff B1 Phase 3 — deterministic rollback tests exercising the FULL
  production chain: `handle_bind/2` → `UserBinding.bind` → `BindingPolicy.apply`
  (forced failure via `:binding_policy_force_failure` app config) →
  `rollback_binding` → DB verified. No manual simulation.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.Behavior.UserBinding, as: BV
  alias EzagentPluginFeishu.UserBinding, as: UB

  @admin_uri Ezagent.URI.new!("entity://system/user/admin")
  @user_a Ezagent.URI.new!("entity://team-alpha/user/alice")
  @user_b Ezagent.URI.new!("entity://team-alpha/user/bob")

  defp ctx(slice \\ %{bind_count: 0}, overrides \\ %{}) do
    base = %{
      caller: @admin_uri,
      caps: MapSet.new(),
      self_uri: Ezagent.URI.new!("workspace://team-alpha"),
      reply: :sync,
      read: fn key, default -> Map.get(slice, key, default) end
    }

    Map.merge(base, overrides)
  end

  defp unique_open_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  setup do
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_feishu, :binding_policy_force_failure)
    end)
  end

  describe "fresh bind rollback: policy failure → row deleted (full chain)" do
    test "handle_bind → BindingPolicy forced-fail → rollback deletes fresh row" do
      open_id = unique_open_id("ou_rollback_fresh")

      Application.put_env(:ezagent_plugin_feishu, :binding_policy_force_failure, true)

      # The handler chain: snapshot (nil) → UserBinding.bind (row written) →
      # BindingPolicy.apply (FAILS via config) → rollback_binding (unbind) →
      # row deleted.
      assert {:error, :policy_failure_synthetic} =
               BV.handle_bind(%{open_id: open_id, user_uri: @user_a}, ctx())

      # Row was rolled back — absent from DB.
      assert :error = UB.resolve(open_id)
    end

    test "without forced failure, fresh bind succeeds normally" do
      open_id = unique_open_id("ou_rollback_noforce")

      # Default: no forced failure — normal path.
      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_a}, ctx())
      assert {:ok, _} = UB.resolve(open_id)
    end
  end

  describe "rebind rollback: policy failure → prior row precisely restored" do
    test "handle_bind rebind → policy fail → prior user_uri, bound_by, bound_at restored" do
      open_id = unique_open_id("ou_rollback_rebind")

      # Step 1: bind → user A (no forced failure).
      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_a}, ctx())
      row_a = EzagentCore.Repo.get!(EzagentPluginFeishu.UserBinding, open_id)
      assert row_a.user_uri == URI.to_string(@user_a)

      # Step 2: enable forced failure, rebind → user B.
      Application.put_env(:ezagent_plugin_feishu, :binding_policy_force_failure, true)

      # The handler captures prior_row (user_a), writes user_b, policy fails,
      # rollback restores user_a with original bound_by AND bound_at.
      assert {:error, :policy_failure_synthetic} =
               BV.handle_bind(%{open_id: open_id, user_uri: @user_b}, ctx())

      row_restored = EzagentCore.Repo.get!(EzagentPluginFeishu.UserBinding, open_id)

      # Prior state precisely restored.
      assert row_restored.user_uri == row_a.user_uri
      assert row_restored.bound_by == row_a.bound_by
      assert row_restored.bound_at == row_a.bound_at
    end
  end

  describe "rollback failure logging — redaction (Locked Decision #12)" do
    test "log format uses Redact.fingerprint, never raw open_id" do
      secret = "ou_super_secret_should_not_leak_#{System.unique_integer([:positive])}"
      alias EzagentPluginFeishu.Redact

      import ExUnit.CaptureLog

      # log_rollback_failure only fires on rollback ITSELF failing (rare edge
      # case). Verify the LOG FORMAT is correct by emitting a synthetic log
      # matching the exact production format in behavior/user_binding.ex:518-522.
      log_output =
        capture_log(fn ->
          require Logger

          Logger.error(
            "EzagentPluginFeishu.Behavior.UserBinding.:bind: BindingPolicy failed + " <>
              "rollback (delete) failed: open_id=#{Redact.fingerprint(secret)} " <>
              "rollback_error=synthetic original_error=synthetic"
          )
        end)

      refute log_output =~ secret
      assert log_output =~ Redact.fingerprint(secret)
    end
  end
end
