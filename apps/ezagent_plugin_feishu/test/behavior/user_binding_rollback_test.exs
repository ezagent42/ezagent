defmodule EzagentPluginFeishu.Behavior.UserBindingRollbackTest do
  @moduledoc """
  Handoff B1 — rollback tests exercising the FULL production chain via DI seams.

  The Behavior delegates to configurable modules:
  - `:binding_policy_mod` (default: BindingPolicy)
  - `:user_binding_storage_mod` (default: UserBinding)

  Tests inject a fake policy (always returns error) to trigger the rollback
  path deterministically. The log-redaction test injects a fake storage where
  `unbind/1` fails, causing `log_rollback_failure/4` to fire in production code.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.Behavior.UserBinding, as: BV
  alias EzagentPluginFeishu.UserBinding, as: UB

  @admin_uri Ezagent.URI.new!("entity://system/user/admin")
  @user_a Ezagent.URI.new!("entity://team-alpha/user/alice")
  @user_b Ezagent.URI.new!("entity://team-alpha/user/bob")

  # Fake policy: always returns error, triggering rollback.
  defmodule FailingPolicy do
    def do_apply(_user_uri, _admin_uri), do: {:error, :policy_failure_synthetic}
  end

  # Fake storage: delegates bind/resolve/list_all to real UserBinding,
  # but unbind always fails, triggering log_rollback_failure.
  defmodule FailingUnbindStorage do
    defdelegate bind(oid, uuri, by), to: EzagentPluginFeishu.UserBinding
    defdelegate bind(oid, uuri, by, at), to: EzagentPluginFeishu.UserBinding
    def unbind(_oid), do: {:error, :synthetic_unbind_failure}
    defdelegate resolve(oid), to: EzagentPluginFeishu.UserBinding
    defdelegate list_all, to: EzagentPluginFeishu.UserBinding
  end

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
      Application.delete_env(:ezagent_plugin_feishu, :binding_policy_mod)
      Application.delete_env(:ezagent_plugin_feishu, :user_binding_storage_mod)
    end)
  end

  describe "fresh bind rollback: policy fail → full chain → row deleted" do
    test "handle_bind → policy fail → rollback deletes fresh row" do
      open_id = unique_open_id("ou_rb_fresh")

      Application.put_env(:ezagent_plugin_feishu, :binding_policy_mod, FailingPolicy)

      assert {:error, :policy_failure_synthetic} =
               BV.handle_bind(%{open_id: open_id, user_uri: @user_a}, ctx())

      assert :error = UB.resolve(open_id)
    end
  end

  describe "rebind rollback: policy fail → prior row restored with bound_at" do
    test "handle_bind rebind → policy fail → prior user_uri/bound_by/bound_at restored" do
      open_id = unique_open_id("ou_rb_rebind")

      {:ok, _, _} = BV.handle_bind(%{open_id: open_id, user_uri: @user_a}, ctx())
      row_a = EzagentCore.Repo.get!(EzagentPluginFeishu.UserBinding, open_id)
      assert row_a.user_uri == URI.to_string(@user_a)

      Application.put_env(:ezagent_plugin_feishu, :binding_policy_mod, FailingPolicy)

      assert {:error, :policy_failure_synthetic} =
               BV.handle_bind(%{open_id: open_id, user_uri: @user_b}, ctx())

      row_restored = EzagentCore.Repo.get!(EzagentPluginFeishu.UserBinding, open_id)
      assert row_restored.user_uri == row_a.user_uri
      assert row_restored.bound_by == row_a.bound_by
      assert row_restored.bound_at == row_a.bound_at
    end
  end

  describe "rollback failure log — real log_rollback_failure/4, redacted" do
    test "unbind failure → log_rollback_failure fires, open_id redacted" do
      secret = "ou_redact_log_#{System.unique_integer([:positive])}"
      alias EzagentPluginFeishu.Redact
      import ExUnit.CaptureLog

      Application.put_env(:ezagent_plugin_feishu, :user_binding_storage_mod, FailingUnbindStorage)
      Application.put_env(:ezagent_plugin_feishu, :binding_policy_mod, FailingPolicy)

      log_output =
        capture_log(fn ->
          BV.handle_bind(%{open_id: secret, user_uri: @user_a}, ctx())
        end)

      refute log_output =~ secret
      assert log_output =~ Redact.fingerprint(secret)
      assert log_output =~ "rollback_error="
      assert log_output =~ "synthetic"
    end
  end
end
