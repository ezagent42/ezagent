defmodule EzagentWeb.EmailBindingControllerTest do
  @moduledoc """
  #88 PR-2 (SPEC §4.4) — GET /auth/email/confirm/:token flips a pending
  email binding to :verified; invalid/expired tokens are refused.
  """
  use EzagentWeb.ConnCase

  alias Ezagent.Email.InboundBinding
  alias Ezagent.ExternalMirror.BindingRow

  @target "human@example.com"
  @ws "workspace://system"

  defp pending_binding!(opts \\ %{}) do
    session_uri =
      Ezagent.URI.new!("session://system/default/ebc-#{System.unique_integer([:positive])}")

    row_id = BindingRow.row_id(session_uri, "email", @target)

    {:ok, _} =
      BindingRow.insert(%{
        id: row_id,
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: @target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @ws
      })

    {:ok, {_row, raw}} =
      InboundBinding.record(
        Map.merge(
          %{
            binding_row_id: row_id,
            local_address: "ebc-#{System.unique_integer([:positive])}@ezagent.chat",
            session_uri: URI.to_string(session_uri),
            target_id: @target,
            workspace_uri: @ws
          },
          opts
        )
      )

    {row_id, raw}
  end

  test "valid token → 200 + binding flips to verified", %{conn: conn} do
    {row_id, raw} = pending_binding!()
    refute InboundBinding.verified?(row_id)

    body = conn |> get("/auth/email/confirm/#{raw}") |> html_response(200)
    assert body =~ "confirmed"
    assert InboundBinding.verified?(row_id)
  end

  test "invalid token → 404", %{conn: conn} do
    conn = get(conn, "/auth/email/confirm/esr_ev_bogus")
    assert html_response(conn, 404) =~ "Invalid"
  end

  test "expired token → 410, binding stays pending", %{conn: conn} do
    {row_id, raw} = pending_binding!(%{ttl_seconds: -10})

    conn = get(conn, "/auth/email/confirm/#{raw}")
    assert html_response(conn, 410) =~ "expired"
    refute InboundBinding.verified?(row_id)
  end
end
