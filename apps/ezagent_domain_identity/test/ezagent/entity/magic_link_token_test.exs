defmodule Ezagent.Entity.MagicLinkTokenTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.MagicLinkToken

  test "mint/1 returns a raw token; consume/1 returns the email once" do
    {:ok, raw} = MagicLinkToken.mint("allen@example.com")
    assert is_binary(raw) and byte_size(raw) > 20

    assert {:ok, "allen@example.com"} = MagicLinkToken.consume(raw)
  end

  test "consume/1 is single-use — second call fails" do
    {:ok, raw} = MagicLinkToken.mint("x@example.com")
    assert {:ok, _} = MagicLinkToken.consume(raw)
    assert {:error, :consumed} = MagicLinkToken.consume(raw)
  end

  test "consume/1 rejects an expired token" do
    {:ok, raw} = MagicLinkToken.mint("y@example.com", ttl_seconds: -1)
    assert {:error, :expired} = MagicLinkToken.consume(raw)
  end

  test "consume/1 rejects an unknown / malformed token" do
    assert {:error, :invalid} = MagicLinkToken.consume("not-a-real-token")
  end

  describe "purpose (task #87)" do
    test "default purpose is login; consume/1 (default) accepts it" do
      {:ok, raw} = MagicLinkToken.mint("p@ex.com")
      assert {:ok, "p@ex.com"} = MagicLinkToken.consume(raw)
    end

    test "a reset token cannot be consumed as login (wrong_purpose), and is not burned" do
      {:ok, raw} = MagicLinkToken.mint("r@ex.com", purpose: "reset")
      assert {:error, :wrong_purpose} = MagicLinkToken.consume(raw, "login")
      # not burned → still consumable with the correct purpose
      assert {:ok, "r@ex.com"} = MagicLinkToken.consume(raw, "reset")
    end

    test "a confirm token consumes only with the confirm purpose" do
      {:ok, raw} = MagicLinkToken.mint("c@ex.com", purpose: "confirm")
      assert {:error, :wrong_purpose} = MagicLinkToken.consume(raw, "login")
      assert {:ok, "c@ex.com"} = MagicLinkToken.consume(raw, "confirm")
    end
  end
end
