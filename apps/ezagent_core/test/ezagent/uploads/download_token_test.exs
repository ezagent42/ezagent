defmodule Ezagent.Uploads.DownloadTokenTest do
  @moduledoc """
  Resource-unification P2a / OI-1 — signed capability download token.

  Pins the security properties the OI-1 decision REQUIRES of the token that
  is the SOLE authorization carrier for upload downloads (the legacy
  participation-based `GET /files/:filename` route is fully retired — no shim):

    1. short TTL (default), never `:infinity` at verify, ≤ 24h ceiling;
    2. bound to ONE `resource://<ws>/uploads/<name>` URI (no replay against
       another ws/file);
    3. type-locked to `uploads` (cannot name a config-dir / other type);
    4. minted only after authorization (the mint API does not itself authorize —
       the caller must; this is exercised at the controller/LiveView/feed layer);
    5. expiry / tamper rejection.

  The module lives in `ezagent_core` (not `ezagent_web`) so BOTH the web
  controllers AND operator surfaces can mint/verify the SAME token without a
  plugin depending on `ezagent_web` (three-tier isolation).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Uploads.DownloadToken
  alias Ezagent.URI, as: EzURI

  @uri EzURI.resource("acme", "uploads", "uuid-file.pdf")

  describe "mint!/2 + verify/1" do
    test "mint→verify round-trips the exact ws-scoped URI" do
      token = DownloadToken.mint!(@uri, ttl_seconds: 60)
      assert {:ok, verified_uri} = DownloadToken.verify(token)
      assert EzURI.stable_key(verified_uri) == EzURI.stable_key(@uri)
    end

    test "token is BOUND to one URI — verified URI is not another ws's file" do
      token = DownloadToken.mint!(@uri, ttl_seconds: 60)
      {:ok, uri} = DownloadToken.verify(token)

      refute EzURI.stable_key(uri) ==
               EzURI.stable_key(EzURI.resource("victim", "uploads", "uuid-file.pdf"))

      refute EzURI.stable_key(uri) ==
               EzURI.stable_key(EzURI.resource("acme", "uploads", "other.pdf"))
    end

    test "non-positive TTL is rejected at mint (no accidental infinite token)" do
      assert_raise ArgumentError, fn -> DownloadToken.mint!(@uri, ttl_seconds: 0) end
      assert_raise ArgumentError, fn -> DownloadToken.mint!(@uri, ttl_seconds: -1) end
    end

    test "TTL above the 24h hard ceiling is rejected at mint" do
      assert_raise ArgumentError, fn ->
        DownloadToken.mint!(@uri, ttl_seconds: 86_401)
      end
    end

    test "only a resource:// URI can be minted" do
      assert_raise FunctionClauseError, fn ->
        DownloadToken.mint!(EzURI.new!("workspace://acme"), ttl_seconds: 60)
      end
    end

    test "a non-uploads resource type is rejected at mint (codex MEDIUM)" do
      # A token must never name a config-dir / other FsResolver type, so the
      # uploads download surface cannot be turned into a generic file reader.
      assert_raise ArgumentError, ~r/uploads resource/, fn ->
        DownloadToken.mint!(EzURI.resource("acme", "cc-agents", "secret"), ttl_seconds: 60)
      end
    end

    test "tampered / forged token is rejected (MAC)" do
      assert {:error, _} = DownloadToken.verify("not-a-real-token")
    end
  end

  describe ":grantee person binding (read-plane PR-3)" do
    @alice EzURI.new!("entity://acme/user/alice")
    @bob EzURI.new!("entity://acme/user/bob")

    test "mint with :grantee → verify_payload returns the SAME principal bound to the token" do
      token = DownloadToken.mint!(@uri, ttl_seconds: 60, grantee: @alice)

      assert {:ok, %{uri: uri, grantee: grantee}} = DownloadToken.verify_payload(token)
      assert EzURI.stable_key(uri) == EzURI.stable_key(@uri)
      assert grantee == @alice
    end

    test "mint WITHOUT :grantee → verify_payload grantee is nil (legacy unbound token)" do
      token = DownloadToken.mint!(@uri, ttl_seconds: 60)
      assert {:ok, %{grantee: nil}} = DownloadToken.verify_payload(token)
    end

    test "verify/1 is unchanged by the binding (still returns just the URI)" do
      token = DownloadToken.mint!(@uri, ttl_seconds: 60, grantee: @alice)
      assert {:ok, uri} = DownloadToken.verify(token)
      assert EzURI.stable_key(uri) == EzURI.stable_key(@uri)
    end

    test "grantee_match?/2 — true only for the exact bound principal" do
      assert DownloadToken.grantee_match?(@alice, @alice)
      refute DownloadToken.grantee_match?(@alice, @bob)
      refute DownloadToken.grantee_match?(@alice, nil)
      refute DownloadToken.grantee_match?(nil, @alice)
      refute DownloadToken.grantee_match?(@alice, "entity://acme/user/alice")
    end

    test "a non-%URI{} :grantee raises at mint (fail LOUD, never silently unbound)" do
      assert_raise ArgumentError, ~r/:grantee/, fn ->
        DownloadToken.mint!(@uri, ttl_seconds: 60, grantee: "alice")
      end
    end

    test "the binding survives the TTL/expiry machinery (expired bound token still rejected)" do
      token =
        DownloadToken.mint!(@uri,
          ttl_seconds: -1,
          __test_allow_nonpositive__: true,
          grantee: @alice
        )

      assert {:error, :expired} = DownloadToken.verify_payload(token)
    end
  end

  describe "expiry (verify NEVER uses :infinity)" do
    test "expired token is rejected (explicit test override + verify)" do
      token = DownloadToken.mint!(@uri, ttl_seconds: -1, __test_allow_nonpositive__: true)
      assert {:error, :expired} = DownloadToken.verify(token)
    end

    test "default-TTL token is NOT valid forever (codex HIGH)" do
      token = DownloadToken.mint!(@uri)
      now = System.system_time(:second)
      # default TTL is short; far in the future the token must be rejected.
      assert {:error, :expired} = DownloadToken.verify_at(token, now + 100_000)
      # but valid right now:
      assert {:ok, _} = DownloadToken.verify_at(token, now)
    end

    test "a token at exactly its TTL boundary is still valid; one second past is expired" do
      token = DownloadToken.mint!(@uri, ttl_seconds: 60)
      now = System.system_time(:second)
      assert {:ok, _} = DownloadToken.verify_at(token, now + 59)
      assert {:error, :expired} = DownloadToken.verify_at(token, now + 61)
    end
  end
end
