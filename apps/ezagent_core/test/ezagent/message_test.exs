defmodule Ezagent.MessageTest do
  use ExUnit.Case, async: true
  alias Ezagent.Message

  @sender Ezagent.URI.new!("entity://system/user/admin")
  @body %{text: "hello", attachments: []}

  describe "new/3" do
    test "minimal — sender + body required, others default" do
      msg = Message.new(@sender, @body)

      assert msg.sender == @sender
      assert msg.body == @body
      assert msg.mentions == []
      assert msg.ref_id == nil
      assert %DateTime{} = msg.inserted_at
      # PR #149 (SPEC v2 §5.13): id is a plain UUID hex string, no
      # `message://` prefix.
      assert is_binary(msg.id)
      refute String.starts_with?(msg.id, "message://")
    end

    test "id auto-gen format is 16 lowercase hex chars" do
      msg = Message.new(@sender, @body)
      assert Regex.match?(~r/^[0-9a-f]{16}$/, msg.id)
    end

    test "id auto-gen unique across constructions" do
      ids = for _ <- 1..20, do: Message.new(@sender, @body).id
      assert length(Enum.uniq(ids)) == 20
    end

    test ":mentions opt fills mentions field" do
      mentions = [Ezagent.URI.new!("entity://team-alpha/agent/test_cc-builder")]
      msg = Message.new(@sender, @body, mentions: mentions)
      assert msg.mentions == mentions
    end

    test ":ref_id opt fills ref_id (plain id string) field" do
      ref_id = "deadbeef00000000"
      msg = Message.new(@sender, @body, ref_id: ref_id)
      assert msg.ref_id == ref_id
    end

    test ":inserted_at opt overrides default DateTime.utc_now" do
      fixed = ~U[2026-01-01 00:00:00Z]
      msg = Message.new(@sender, @body, inserted_at: fixed)
      assert msg.inserted_at == fixed
    end

    test ":id opt overrides auto-gen (for replay / tests)" do
      msg = Message.new(@sender, @body, id: "test-fixed-id")
      assert msg.id == "test-fixed-id"
    end

    test "body without :attachments defaults to empty list" do
      msg = Message.new(@sender, %{text: "no attachments key"})
      assert msg.body.attachments == []
      assert msg.body.text == "no attachments key"
    end

    test "body with :attachments preserves caller-provided list" do
      attachments = [URI.parse("file://abc.pdf")]
      msg = Message.new(@sender, %{text: "with attach", attachments: attachments})
      assert msg.body.attachments == attachments
    end
  end

  describe "Jason.Encoder for %URI{}" do
    test "URI struct serializes to its string form" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_cc-builder")
      assert Jason.encode!(uri) == ~s("entity://team-alpha/agent/test_cc-builder")
    end

    test "URI inside a list (mentions field) serializes as JSON array of strings" do
      uris = [
        Ezagent.URI.new!("entity://team-alpha/agent/test_cc"),
        Ezagent.URI.new!("entity://system/user/admin")
      ]

      assert Jason.encode!(uris) ==
               ~s(["entity://team-alpha/agent/test_cc","entity://system/user/admin"])
    end
  end

  describe "Jason.Encoder for %Ezagent.Message{}" do
    test "round-trip — encode + decode keeps logical fields" do
      msg =
        Message.new(@sender, @body,
          mentions: [Ezagent.URI.new!("entity://team-alpha/agent/test_cc")]
        )

      encoded = Jason.encode!(msg)
      assert is_binary(encoded)
      decoded = Jason.decode!(encoded)

      assert decoded["sender"] == "entity://system/user/admin"
      assert decoded["mentions"] == ["entity://team-alpha/agent/test_cc"]
      assert decoded["body"]["text"] == "hello"
      assert decoded["body"]["attachments"] == []
      assert is_binary(decoded["inserted_at"])
      assert is_binary(decoded["id"])
      assert is_nil(decoded["ref_id"])
      # __struct__ should NOT leak into JSON
      refute Map.has_key?(decoded, "__struct__")
    end
  end
end
