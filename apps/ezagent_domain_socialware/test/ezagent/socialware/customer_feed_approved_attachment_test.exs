defmodule Ezagent.Socialware.CustomerFeedApprovedAttachmentTest do
  @moduledoc """
  Resource-unification P2a / OI-1 — the external customer-feed approved-only
  download gate + serve-time re-validation.

  A feed viewer has no session/caps, so the ONLY authority for serving an
  attachment is "is this attachment part of an APPROVED (committed,
  customer_visible) message in this session?". `CustomerFeed.approved_attachment?/2`
  is that gate; `mint_approved_token/3` mints a signed token ONLY when it passes;
  and because the gate is re-checked at serve time, flipping the message back to
  `operator_only` revokes an already-minted token (a lever beyond TTL).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed, Settlement}
  alias Ezagent.URI, as: EzURI

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "approved-att-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)
    %{session: session, workspace: workspace, token: token}
  end

  defp upload_uri(ws_name, name), do: EzURI.resource(ws_name, "uploads", name)

  defp commit_message_with_attachment(ctx, upload_uri, visibility) do
    msg =
      Message.new(sender_uri(), %{text: "see attached", attachments: [upload_uri]},
        visibility: visibility
      )

    {:ok, written} = MessageStore.write(msg, ctx.session)
    turn_id = "turn-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Settlement.begin(%{
        turn_id: turn_id,
        session_uri: ctx.session,
        workspace_uri: ctx.workspace,
        target_message_ids: [written.id],
        target_surface_version: nil,
        expected_prior_approved: nil
      })

    {:ok, _} = Settlement.mark_committed_for_test(turn_id)
    written
  end

  test "approved_attachment? is TRUE for a committed customer-visible attachment", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-approved.pdf")

    _ = commit_message_with_attachment(ctx, upload, :customer_visible)

    assert CustomerFeed.approved_attachment?(ctx.session, upload)
  end

  test "approved_attachment? is FALSE for an operator-only (not-approved) attachment", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-secret.pdf")

    _ = commit_message_with_attachment(ctx, upload, :operator_only)

    refute CustomerFeed.approved_attachment?(ctx.session, upload)
  end

  test "approved_attachment? is FALSE for an attachment not in this session", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    refute CustomerFeed.approved_attachment?(ctx.session, upload_uri(ws_name, "never.pdf"))
  end

  test "approved_attachment? is FALSE for a non-uploads resource URI", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)

    refute CustomerFeed.approved_attachment?(
             ctx.session,
             EzURI.resource(ws_name, :avatar, "x.png")
           )
  end

  test "mint_approved_token mints ONLY for an approved attachment (mint-after-authz)", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    approved = upload_uri(ws_name, "uuid-ok.pdf")
    not_approved = upload_uri(ws_name, "uuid-no.pdf")

    _ = commit_message_with_attachment(ctx, approved, :customer_visible)

    mint = fn uri -> "tok:" <> EzURI.stable_key(uri) end

    assert {:ok, "tok:" <> _} = CustomerFeed.mint_approved_token(ctx.session, approved, mint)

    assert {:error, :not_approved} =
             CustomerFeed.mint_approved_token(ctx.session, not_approved, mint)
  end

  test "serve-time re-validation: flipping to operator_only revokes approval", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-revoke.pdf")

    written = commit_message_with_attachment(ctx, upload, :customer_visible)
    assert CustomerFeed.approved_attachment?(ctx.session, upload)

    # Operator flips visibility back — an already-minted token must stop working
    # because the serve-time check now returns false.
    {:ok, _} = MessageStore.mark_visibility([written.id], :operator_only)
    refute CustomerFeed.approved_attachment?(ctx.session, upload)
  end
end
