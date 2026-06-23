defmodule Ezagent.Email.InboundBindingTest do
  @moduledoc """
  #88 PR-2 (SPEC §3/§4.4/§6 / plan D4) — email-owned inbound metadata:
  reverse lookup, verification gate, binding-scoped token, CASCADE.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Email.InboundBinding
  alias Ezagent.ExternalMirror.BindingRow

  @ws "workspace://system"

  # Insert a parent binding row so the FK holds. Returns {binding_row_id,
  # session_uri}.
  defp parent_binding!(target \\ "human@example.com") do
    session_uri =
      Ezagent.URI.new!("session://system/default/ib-#{System.unique_integer([:positive])}")

    id = BindingRow.row_id(session_uri, "email", target)

    {:ok, _} =
      BindingRow.insert(%{
        id: id,
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @ws
      })

    {id, session_uri}
  end

  defp record!(id, session_uri, local_address, target, opts \\ %{}) do
    {:ok, {row, raw}} =
      InboundBinding.record(
        Map.merge(
          %{
            binding_row_id: id,
            local_address: local_address,
            session_uri: URI.to_string(session_uri),
            target_id: target,
            workspace_uri: @ws
          },
          opts
        )
      )

    {row, raw}
  end

  describe "record/1 + reverse lookup" do
    test "starts pending and resolves by local_address" do
      {id, su} = parent_binding!()
      {row, _raw} = record!(id, su, "acme-1@ezagent.chat", "human@example.com")

      assert row.verification_status == "pending_verification"

      found = InboundBinding.by_local_address("acme-1@ezagent.chat")
      assert found.binding_row_id == id
      assert found.session_uri == URI.to_string(su)
      assert found.target_id == "human@example.com"
    end

    test "by_local_address returns nil for an unknown alias" do
      assert InboundBinding.by_local_address("nope@ezagent.chat") == nil
    end

    test "local_address is unique (collision → {:error, changeset})" do
      {id1, su1} = parent_binding!("a@example.com")
      {_id2, su2} = parent_binding!("b@example.com")
      {id2, _} = parent_binding!("c@example.com")

      record!(id1, su1, "dup@ezagent.chat", "a@example.com")

      assert {:error, %Ecto.Changeset{}} =
               InboundBinding.record(%{
                 binding_row_id: id2,
                 local_address: "dup@ezagent.chat",
                 session_uri: URI.to_string(su2),
                 target_id: "c@example.com",
                 workspace_uri: @ws
               })
    end
  end

  describe "verification gate" do
    test "verified? is false while pending and for an absent row (fail-closed)" do
      {id, su} = parent_binding!()
      record!(id, su, "v1@ezagent.chat", "human@example.com")

      refute InboundBinding.verified?(id)
      refute InboundBinding.verified?("no-such-binding")
    end

    test "confirm/1 with a valid token flips to verified (single-use)" do
      {id, su} = parent_binding!()
      {_row, raw} = record!(id, su, "v2@ezagent.chat", "human@example.com")

      assert {:ok, _} = InboundBinding.confirm(raw)
      assert InboundBinding.verified?(id)

      # single-use: token cleared → replay fails
      assert {:error, :invalid} = InboundBinding.confirm(raw)
    end

    test "confirm/1 rejects an invalid token" do
      assert {:error, :invalid} = InboundBinding.confirm("esr_ev_bogus")
    end

    test "confirm/1 rejects an expired token, status stays pending" do
      {id, su} = parent_binding!()
      {_row, raw} = record!(id, su, "v3@ezagent.chat", "human@example.com", %{ttl_seconds: -10})

      assert {:error, :expired} = InboundBinding.confirm(raw)
      refute InboundBinding.verified?(id)
    end

    test "mark_verified/1 flips status directly (E2E/admin path)" do
      {id, su} = parent_binding!()
      record!(id, su, "v4@ezagent.chat", "human@example.com")

      assert {:ok, _} = InboundBinding.mark_verified(id)
      assert InboundBinding.verified?(id)
      assert {:error, :not_found} = InboundBinding.mark_verified("missing")
    end
  end

  describe "session uniqueness + CASCADE" do
    test "session_uri is unique (one email binding per session, §6.1)" do
      {id1, su} = parent_binding!("a@example.com")
      record!(id1, su, "s1@ezagent.chat", "a@example.com")

      # A second binding row for the SAME session (different target) — the
      # email inbound-meta unique index on session_uri rejects it.
      id2 = BindingRow.row_id(su, "email", "b@example.com")

      {:ok, _} =
        BindingRow.insert(%{
          id: id2,
          session_uri: URI.to_string(su),
          adapter_id: "email",
          target_id: "b@example.com",
          opts_json: "{}",
          bound_by: "entity://system/user/admin",
          bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          workspace_uri: @ws
        })

      assert {:error, %Ecto.Changeset{}} =
               InboundBinding.record(%{
                 binding_row_id: id2,
                 local_address: "s2@ezagent.chat",
                 session_uri: URI.to_string(su),
                 target_id: "b@example.com",
                 workspace_uri: @ws
               })
    end

    test "deleting the parent binding CASCADE-deletes the inbound-meta row" do
      {id, su} = parent_binding!("cascade@example.com")
      record!(id, su, "casc@ezagent.chat", "cascade@example.com")
      assert InboundBinding.by_binding_row_id(id) != nil

      {:ok, :deleted} = BindingRow.delete_by_natural_key(su, "email", "cascade@example.com")

      assert InboundBinding.by_binding_row_id(id) == nil
    end
  end
end
