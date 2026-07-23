defmodule Ezagent.Socialware.ExternalFeedApprovedAttachmentTest do
  @moduledoc """
  Resource-unification P2a / OI-1 — the external-feed approved-only
  download gate + serve-time re-validation.

  A feed viewer reads as a read-only member, so the authority for serving an
  attachment is "is this attachment part of an APPROVED (committed,
  external_visible) message in this session?". `ExternalFeed.approved_attachment?/3`
  is that gate; `mint_approved_token/4` mints a signed token ONLY when it passes;
  and because the gate is re-checked at serve time, flipping the message back to
  `internal` revokes an already-minted token (a lever beyond TTL).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ExternalFeed, Settlement}
  alias Ezagent.URI, as: EzURI

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "approved-att-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "approved-att-owner")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner(),
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, workspace: workspace, caller: owner()}
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

  test "approved_attachment? is TRUE for a committed external-visible attachment", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-approved.pdf")

    _ = commit_message_with_attachment(ctx, upload, :external_visible)

    assert ExternalFeed.approved_attachment?(ctx.caller, ctx.session, upload)
  end

  test "approved_attachment? is FALSE for an internal (not-approved) attachment", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-secret.pdf")

    _ = commit_message_with_attachment(ctx, upload, :internal)

    refute ExternalFeed.approved_attachment?(ctx.caller, ctx.session, upload)
  end

  test "approved_attachment? is FALSE for an attachment not in this session", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)

    refute ExternalFeed.approved_attachment?(
             ctx.caller,
             ctx.session,
             upload_uri(ws_name, "never.pdf")
           )
  end

  test "approved_attachment? is FALSE for a non-uploads resource URI", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)

    refute ExternalFeed.approved_attachment?(
             ctx.caller,
             ctx.session,
             EzURI.resource(ws_name, :avatar, "x.png")
           )
  end

  test "a PRIVATE-session NON-MEMBER is REJECTED at mint (approved_attachment? denies)", ctx do
    # Codex's missing negative case: even when the attachment IS approved
    # (committed, external-visible), a caller with NO read authority over the
    # session must not mint — the gate routes the message scan through the
    # SessionReads chokepoint, which fails closed for a non-member.
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    approved = upload_uri(ws_name, "uuid-private.pdf")

    _ = commit_message_with_attachment(ctx, approved, :external_visible)

    non_member =
      EzURI.entity(:team_alpha, :user, "non-member-#{System.unique_integer([:positive])}")

    refute ExternalFeed.approved_attachment?(non_member, ctx.session, approved)

    assert {:error, :not_approved} =
             ExternalFeed.mint_approved_token(
               non_member,
               ctx.session,
               approved,
               &Ezagent.Uploads.DownloadToken.mint!/2
             )
  end

  test "mint_approved_token mints ONLY for an approved attachment (mint-after-authz)", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    approved = upload_uri(ws_name, "uuid-ok.pdf")
    not_approved = upload_uri(ws_name, "uuid-no.pdf")

    _ = commit_message_with_attachment(ctx, approved, :external_visible)

    mint = fn uri, opts -> "tok:" <> EzURI.stable_key(uri) <> ":" <> inspect(opts) end

    assert {:ok, "tok:" <> _} =
             ExternalFeed.mint_approved_token(ctx.caller, ctx.session, approved, mint)

    assert {:error, :not_approved} =
             ExternalFeed.mint_approved_token(ctx.caller, ctx.session, not_approved, mint)
  end

  test "mint_approved_token binds the token to the CALLER as grantee (PR-3 person binding)",
       ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    approved = upload_uri(ws_name, "uuid-bound.pdf")

    _ = commit_message_with_attachment(ctx, approved, :external_visible)

    # The injected signer receives `grantee: caller` — the token is bound to the
    # ONE principal the approved-only gate authorized.
    mint = fn _uri, opts -> {:bound, Keyword.get(opts, :grantee)} end

    assert {:ok, {:bound, grantee}} =
             ExternalFeed.mint_approved_token(ctx.caller, ctx.session, approved, mint)

    assert grantee == ctx.caller
  end

  test "a minted grantee-bound token verifies to grantee == caller (round-trip via DownloadToken)",
       ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    approved = upload_uri(ws_name, "uuid-roundtrip.pdf")

    _ = commit_message_with_attachment(ctx, approved, :external_visible)

    assert {:ok, token} =
             ExternalFeed.mint_approved_token(
               ctx.caller,
               ctx.session,
               approved,
               &Ezagent.Uploads.DownloadToken.mint!/2
             )

    assert {:ok, %{uri: uri, grantee: grantee}} =
             Ezagent.Uploads.DownloadToken.verify_payload(token)

    assert EzURI.stable_key(uri) == EzURI.stable_key(approved)
    assert grantee == ctx.caller
    assert Ezagent.Uploads.DownloadToken.grantee_match?(grantee, ctx.caller)

    refute Ezagent.Uploads.DownloadToken.grantee_match?(
             grantee,
             EzURI.entity(:team_alpha, :user, "someone-else")
           )
  end

  test "serve-time re-validation: flipping to internal revokes approval", ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-revoke.pdf")

    written = commit_message_with_attachment(ctx, upload, :external_visible)
    assert ExternalFeed.approved_attachment?(ctx.caller, ctx.session, upload)

    # Operator flips visibility back — an already-minted token must stop working
    # because the serve-time check now returns false.
    {:ok, _} = MessageStore.mark_visibility([written.id], :internal)
    refute ExternalFeed.approved_attachment?(ctx.caller, ctx.session, upload)
  end

  describe "authorized_attachment_path/4 (external bearer path, codex HIGH)" do
    # A fake resolver that returns a deterministic path for the upload URI under
    # the given scope — stands in for `Ezagent.Uploads.resolve/2` so the test
    # focuses on the AUTHORIZATION wiring (session-token + approved recheck +
    # session-workspace scope), not the FS layout.
    defp fake_resolve(uri, %{workspace: ws}) do
      {:ok, "/fake/#{ws}/" <> Ezagent.URI.name!(uri)}
    end

    test "a member + approved attachment resolves under the session ws", ctx do
      ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
      upload = upload_uri(ws_name, "uuid-ok.pdf")
      _ = commit_message_with_attachment(ctx, upload, :external_visible)

      assert {:ok, path} =
               ExternalFeed.authorized_attachment_path(
                 ctx.session,
                 ctx.caller,
                 upload,
                 &fake_resolve/2
               )

      assert path == "/fake/#{ws_name}/uuid-ok.pdf"
    end

    test "an invalid / forged caller is unauthorized", ctx do
      ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
      upload = upload_uri(ws_name, "uuid-ok.pdf")
      _ = commit_message_with_attachment(ctx, upload, :external_visible)

      assert {:error, :unauthorized} =
               ExternalFeed.authorized_attachment_path(
                 ctx.session,
                 "forged-caller",
                 upload,
                 &fake_resolve/2
               )
    end

    test "a not-approved attachment is unauthorized even for a member", ctx do
      ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
      upload = upload_uri(ws_name, "uuid-secret.pdf")
      _ = commit_message_with_attachment(ctx, upload, :internal)

      assert {:error, :unauthorized} =
               ExternalFeed.authorized_attachment_path(
                 ctx.session,
                 ctx.caller,
                 upload,
                 &fake_resolve/2
               )
    end

    test "serve-time revocation: flipping to internal denies a previously-OK path", ctx do
      ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
      upload = upload_uri(ws_name, "uuid-revoke.pdf")
      written = commit_message_with_attachment(ctx, upload, :external_visible)

      assert {:ok, _} =
               ExternalFeed.authorized_attachment_path(
                 ctx.session,
                 ctx.caller,
                 upload,
                 &fake_resolve/2
               )

      {:ok, _} = MessageStore.mark_visibility([written.id], :internal)

      assert {:error, :unauthorized} =
               ExternalFeed.authorized_attachment_path(
                 ctx.session,
                 ctx.caller,
                 upload,
                 &fake_resolve/2
               )
    end

    test "resolves a committed attachment with NO WorkspaceRegistry binding (cold reconnect; codex P2.5a rev5)",
         ctx do
      ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
      upload = upload_uri(ws_name, "uuid-cold.pdf")
      _ = commit_message_with_attachment(ctx, upload, :external_visible)

      # Drop the volatile registry binding (== restart with empty ETS).
      :ok = Ezagent.WorkspaceRegistry.unbind(ctx.session)
      assert Ezagent.WorkspaceRegistry.lookup(ctx.session) == :error

      # workspace/1 must yield a %URI{} that EzURI.workspace_name/1 accepts (no
      # FunctionClauseError) AND auth (live membership) must pass while the
      # workspace is derived STRUCTURALLY (not from the dropped registry binding).
      assert {:ok, path} =
               ExternalFeed.authorized_attachment_path(
                 ctx.session,
                 ctx.caller,
                 upload,
                 &fake_resolve/2
               )

      assert String.contains?(path, ws_name)
      assert String.ends_with?(path, "uuid-cold.pdf")
    end
  end
end
