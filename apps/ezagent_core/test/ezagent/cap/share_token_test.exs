defmodule Ezagent.Cap.ShareTokenTest do
  @moduledoc """
  URI-share unification — signed **stateless pointer** share token (A1).

  The token is a tamper-resistant, expiring pointer at a `target` URI. It carries
  NO authority and NO grant intent — whether it grants anything is decided at
  claim time by the target's `Ezagent.Socialware.ShareSetting` (owner-controlled).
  So this module only round-trips + tamper/expiry-guards the target pointer.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Cap.ShareToken
  alias Ezagent.URI, as: EzURI

  @board EzURI.new!("entity://acme/agent/board-1")

  describe "mint_link!/2 + verify_link/1" do
    test "round-trips the exact target" do
      token = ShareToken.mint_link!(@board, ttl_seconds: 60)
      assert {:ok, %{target: target}} = ShareToken.verify_link(token)
      assert EzURI.stable_key(target) == EzURI.stable_key(@board)
    end

    test "is URI-agnostic — any target scheme mints + verifies (not uploads-locked)" do
      for target <- [
            EzURI.new!("entity://acme/agent/board-9"),
            EzURI.session("acme", "chat", "s1"),
            EzURI.resource("acme", "uploads", "f.pdf")
          ] do
        token = ShareToken.mint_link!(target, ttl_seconds: 60)
        assert {:ok, %{target: verified}} = ShareToken.verify_link(token)
        assert EzURI.stable_key(verified) == EzURI.stable_key(target)
      end
    end

    test "carries NO authority/intent — only the target pointer" do
      token = ShareToken.mint_link!(@board, ttl_seconds: 60)
      assert {:ok, payload} = ShareToken.verify_link(token)
      assert Map.keys(payload) == [:target]
      refute Map.has_key?(payload, :issuer)
      refute Map.has_key?(payload, :grantee)
      refute Map.has_key?(payload, :behavior)
    end

    test "token is BOUND to one target — no replay against another URI" do
      token = ShareToken.mint_link!(@board, ttl_seconds: 60)
      {:ok, %{target: target}} = ShareToken.verify_link(token)

      refute EzURI.stable_key(target) ==
               EzURI.stable_key(EzURI.new!("entity://victim/agent/board-1"))
    end

    test "non-positive / over-ceiling TTL is rejected at mint" do
      assert_raise ArgumentError, fn -> ShareToken.mint_link!(@board, ttl_seconds: 0) end
      assert_raise ArgumentError, fn -> ShareToken.mint_link!(@board, ttl_seconds: 2_592_001) end
    end

    test "tampered token is rejected" do
      token = ShareToken.mint_link!(@board, ttl_seconds: 60)
      assert {:error, _} = ShareToken.verify_link(token <> "x")
    end

    test "expired token is rejected (clock seam)" do
      token = ShareToken.mint_link!(@board, ttl_seconds: 60)
      future = System.system_time(:second) + 61
      assert {:error, :expired} = ShareToken.verify_link_at(token, future)
    end
  end
end
