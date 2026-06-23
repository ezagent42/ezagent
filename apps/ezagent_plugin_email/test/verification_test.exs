defmodule Ezagent.Email.VerificationTest do
  @moduledoc """
  #88 PR-2 (SPEC §3 / §4.4 / plan D4) — the email bind wrapper's
  alias-generation + verification handshake (the parts unit-testable
  without the full cap-gated bind facade, which external_mirror tests).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Email.{InboundBinding, Verification}
  alias Ezagent.ExternalMirror.BindingRow

  @target "human@example.com"
  @ws "workspace://system"

  # The wrapper records meta keyed by the binding row id, which it derives
  # from the session; the FK needs the parent row to exist first.
  defp parent_binding!(session_uri, target \\ @target) do
    {:ok, _} =
      BindingRow.insert(%{
        id: BindingRow.row_id(session_uri, "email", target),
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @ws
      })

    :ok
  end

  defp session_uri do
    Ezagent.URI.new!("session://system/default/ver-#{System.unique_integer([:positive])}")
  end

  describe "record_inbound_meta/2" do
    test "records a pending row with a unique @ezagent.chat alias, resolvable by reverse lookup" do
      su = session_uri()
      parent_binding!(su)

      assert {:ok, {row, raw}} = Verification.record_inbound_meta(su, @target)
      assert String.ends_with?(row.local_address, "@ezagent.chat")
      assert row.verification_status == "pending_verification"
      assert is_binary(raw) and String.starts_with?(raw, "esr_ev_")

      # Reverse lookup resolves the alias to this binding.
      found = InboundBinding.by_local_address(row.local_address)
      assert found.binding_row_id == BindingRow.row_id(su, "email", @target)
      assert found.session_uri == URI.to_string(su)
    end

    test "alias hint reflects the workspace name" do
      su = session_uri()
      parent_binding!(su)

      {:ok, {row, _}} = Verification.record_inbound_meta(su, @target)
      assert String.starts_with?(row.local_address, "system-")
    end

    test "two distinct sessions get distinct aliases" do
      su1 = session_uri()
      su2 = session_uri()
      parent_binding!(su1)
      parent_binding!(su2)

      {:ok, {r1, _}} = Verification.record_inbound_meta(su1, @target)
      {:ok, {r2, _}} = Verification.record_inbound_meta(su2, @target)
      refute r1.local_address == r2.local_address
    end

    test "a second email binding on the SAME session is rejected (not retried forever)" do
      su = session_uri()
      parent_binding!(su, "a@example.com")
      parent_binding!(su, "b@example.com")

      {:ok, {_r1, _}} = Verification.record_inbound_meta(su, "a@example.com")

      # session_uri is unique on the email-meta table (§6.1) — the second
      # record hits a NON-local_address error → not retryable.
      assert {:error, {:inbound_binding_insert_failed, _}} =
               Verification.record_inbound_meta(su, "b@example.com")
    end
  end

  describe "confirm/1" do
    test "flips a pending binding to verified" do
      su = session_uri()
      parent_binding!(su)
      {:ok, {_row, raw}} = Verification.record_inbound_meta(su, @target)

      row_id = BindingRow.row_id(su, "email", @target)
      refute InboundBinding.verified?(row_id)

      assert {:ok, _} = Verification.confirm(raw)
      assert InboundBinding.verified?(row_id)
    end

    test "rejects an invalid token" do
      assert {:error, :invalid} = Verification.confirm("esr_ev_nope")
    end
  end
end
