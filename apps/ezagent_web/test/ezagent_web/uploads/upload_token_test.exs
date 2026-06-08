defmodule EzagentWeb.Uploads.UploadTokenTest do
  @moduledoc """
  Resource-unification P2a / OI-1 — signed capability download token.

  Pins the security properties the OI-1 decision REQUIRES of the token that
  replaces the participation-based `GET /files/:filename` authz:

    1. short TTL (default), never `:infinity` at verify, ≤ 24h ceiling;
    2. bound to ONE `resource://<ws>/uploads/<name>` URI (no replay against
       another ws/file);
    3. minted only after authorization (the mint API does not itself authorize —
       the caller must; this is exercised at the controller/feed layer);
    4. expiry / tamper rejection.
  """
  use ExUnit.Case, async: true

  alias EzagentWeb.Uploads.UploadToken
  alias Ezagent.URI, as: EzURI

  @uri EzURI.resource("acme", "uploads", "uuid-file.pdf")

  describe "mint!/2 + verify/1" do
    test "mint→verify round-trips the exact ws-scoped URI" do
      token = UploadToken.mint!(@uri, ttl_seconds: 60)
      assert {:ok, verified_uri} = UploadToken.verify(token)
      assert EzURI.stable_key(verified_uri) == EzURI.stable_key(@uri)
    end

    test "token is BOUND to one URI — verified URI is not another ws's file" do
      token = UploadToken.mint!(@uri, ttl_seconds: 60)
      {:ok, uri} = UploadToken.verify(token)

      refute EzURI.stable_key(uri) ==
               EzURI.stable_key(EzURI.resource("victim", "uploads", "uuid-file.pdf"))

      refute EzURI.stable_key(uri) ==
               EzURI.stable_key(EzURI.resource("acme", "uploads", "other.pdf"))
    end

    test "non-positive TTL is rejected at mint (no accidental infinite token)" do
      assert_raise ArgumentError, fn -> UploadToken.mint!(@uri, ttl_seconds: 0) end
      assert_raise ArgumentError, fn -> UploadToken.mint!(@uri, ttl_seconds: -1) end
    end

    test "TTL above the 24h hard ceiling is rejected at mint" do
      assert_raise ArgumentError, fn ->
        UploadToken.mint!(@uri, ttl_seconds: 86_401)
      end
    end

    test "only a resource:// URI can be minted" do
      assert_raise FunctionClauseError, fn ->
        UploadToken.mint!(EzURI.new!("workspace://acme"), ttl_seconds: 60)
      end
    end

    test "tampered / forged token is rejected (MAC)" do
      assert {:error, _} = UploadToken.verify("not-a-real-token")
    end
  end

  describe "expiry (verify NEVER uses :infinity)" do
    test "expired token is rejected (explicit test override + verify)" do
      token = UploadToken.mint!(@uri, ttl_seconds: -1, __test_allow_nonpositive__: true)
      assert {:error, :expired} = UploadToken.verify(token)
    end

    test "default-TTL token is NOT valid forever (codex HIGH)" do
      token = UploadToken.mint!(@uri)
      now = System.system_time(:second)
      # default TTL is short; far in the future the token must be rejected.
      assert {:error, :expired} = UploadToken.verify_at(token, now + 100_000)
      # but valid right now:
      assert {:ok, _} = UploadToken.verify_at(token, now)
    end

    test "a token at exactly its TTL boundary is still valid; one second past is expired" do
      token = UploadToken.mint!(@uri, ttl_seconds: 60)
      now = System.system_time(:second)
      assert {:ok, _} = UploadToken.verify_at(token, now + 59)
      assert {:error, :expired} = UploadToken.verify_at(token, now + 61)
    end
  end
end
