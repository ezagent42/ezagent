defmodule Ezagent.Cap.ShareTokenTest do
  @moduledoc """
  URI-share unification — signed BEARER share token (A1).

  Sibling of `Ezagent.Uploads.DownloadToken` (same MAC/Phoenix.Token signer +
  core-owned `secret_key_base`, so both web AND plugins mint/verify the SAME
  token without depending on `ezagent_web`), but with the OPPOSITE binding
  semantics — a **bearer** link:

    1. NO grantee at mint — the clicker is unknown at share time; whoever holds
       the link claims it (`/socialware/claim` fills grantee = the authed
       clicker, then mints a grantee-bound cap). cap-as-truth `甲`: bearer →
       mint.
    2. **URI-agnostic** — carries ANY `target` URI (entity / session / resource),
       NOT type-locked to `uploads` (that lock is DownloadToken's, not ours).
    3. Carries the **intent** — `behavior` (the ActionSet) + `actions` (read /
       operate) — so the claim landing knows exactly which cap to mint.
    4. Same safety envelope as DownloadToken: bounded TTL (30-day ceiling for a
       pasteable link), one-target binding (no replay against another URI),
       expiry + tamper rejection.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Cap.ShareToken
  alias Ezagent.URI, as: EzURI

  # An agent-URI board target (kanban board = entity://.../agent/...), a session
  # target, and a resource target — the point is scheme-agnostic.
  @issuer EzURI.new!("entity://acme/user/sharer-1")
  @board EzURI.new!("entity://acme/agent/board-1")
  @actionset Ezagent.ActionSet.ApiKeys
  @read_actions [:get_tree, :export_markmap]

  describe "mint_link!/5 + verify_link/1" do
    test "round-trips the exact issuer + target + behavior + actions" do
      token = ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 60)

      assert {:ok, %{issuer: issuer, target: target, behavior: behavior, actions: actions}} =
               ShareToken.verify_link(token)

      assert EzURI.stable_key(issuer) == EzURI.stable_key(@issuer)
      assert EzURI.stable_key(target) == EzURI.stable_key(@board)
      assert behavior == @actionset
      assert actions == @read_actions
    end

    test "issuer is MAC-bound — a tampered issuer fails verification" do
      token = ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 60)
      # Flipping any signed byte (incl. the issuer segment) breaks the MAC.
      assert {:error, _} = ShareToken.verify_link(String.slice(token, 0..-2//1) <> "Z")
    end

    test "is URI-agnostic — any target scheme mints + verifies (not uploads-locked)" do
      for target <- [
            EzURI.new!("entity://acme/agent/board-9"),
            EzURI.session("acme", "chat", "s1"),
            EzURI.resource("acme", "uploads", "f.pdf")
          ] do
        token = ShareToken.mint_link!(@issuer, target, @actionset, @read_actions, ttl_seconds: 60)
        assert {:ok, %{target: verified}} = ShareToken.verify_link(token)
        assert EzURI.stable_key(verified) == EzURI.stable_key(target)
      end
    end

    test "is BEARER — mint needs NO grantee (unknown clicker at share time)" do
      # Unlike DownloadToken (grantee REQUIRED), a share link is minted before
      # the clicker is known; verify carries no grantee — the claim landing binds.
      token = ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 60)
      assert {:ok, payload} = ShareToken.verify_link(token)
      refute Map.has_key?(payload, :grantee)
    end

    test "token is BOUND to one target — no replay against another URI" do
      token = ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 60)
      {:ok, %{target: target}} = ShareToken.verify_link(token)

      refute EzURI.stable_key(target) ==
               EzURI.stable_key(EzURI.new!("entity://acme/agent/board-2"))

      refute EzURI.stable_key(target) ==
               EzURI.stable_key(EzURI.new!("entity://victim/agent/board-1"))
    end

    test "non-positive / over-ceiling TTL is rejected at mint" do
      assert_raise ArgumentError, fn ->
        ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 0)
      end

      assert_raise ArgumentError, fn ->
        ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 2_592_001)
      end
    end

    test "empty actions is rejected at mint (a link must carry an intent)" do
      assert_raise ArgumentError, fn ->
        ShareToken.mint_link!(@issuer, @board, @actionset, [], ttl_seconds: 60)
      end
    end

    test "tampered token is rejected" do
      token = ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 60)
      assert {:error, _} = ShareToken.verify_link(token <> "x")
    end

    test "expired token is rejected (clock seam)" do
      token = ShareToken.mint_link!(@issuer, @board, @actionset, @read_actions, ttl_seconds: 60)
      {:ok, issued} = ShareToken.verify_link(token)
      assert %{} = issued
      # 61s later → past the 60s TTL.
      future = System.system_time(:second) + 61
      assert {:error, :expired} = ShareToken.verify_link_at(token, future)
    end
  end
end
