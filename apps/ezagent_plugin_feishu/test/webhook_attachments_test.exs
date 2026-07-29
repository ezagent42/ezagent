defmodule EzagentPluginFeishu.WebhookAttachmentsTest do
  @moduledoc """
  Phase 6 PR 14 — Feishu webhook builds attachments for every
  message_type, even when Ezagent can't natively render the type.
  """
  use ExUnit.Case, async: true

  # We exercise the private build_message_body via send/3 on a copy
  # of the module's call/2 - but easier: just call the private fn via
  # apply since this is a test.

  test "text message → text body, no attachments" do
    body =
      build(%{
        "message_type" => "text",
        "content" => ~s({"text":"hello"}),
        "message_id" => "om_test_text_001"
      })

    assert body.text == "hello"
    assert body.attachments == []
  end

  test "image message → empty text + image attachment with file_key" do
    body =
      build(%{
        "message_type" => "image",
        "content" => ~s({"image_key":"img_v3_xyz"}),
        "message_id" => "om_test_image_001"
      })

    assert body.text == ""
    assert [att] = body.attachments
    assert att.type == :image
    assert att.source == "feishu"
    assert att.file_key == "img_v3_xyz"
    assert String.contains?(att.name, "image")
    assert att.mime == "image/jpeg"
  end

  test "file message → file attachment with name + size" do
    body =
      build(%{
        "message_type" => "file",
        "content" => ~s({"file_key":"file_v3_abc","file_name":"report.pdf","file_size":1024}),
        "message_id" => "om_test_file_001"
      })

    assert body.text == ""
    assert [att] = body.attachments
    assert att.type == :file
    assert att.name == "report.pdf"
    assert att.size_bytes == 1024
    assert att.file_key == "file_v3_abc"
  end

  test "audio message → audio attachment with duration" do
    body =
      build(%{
        "message_type" => "audio",
        "content" => ~s({"file_key":"audio_key","duration":42}),
        "message_id" => "om_test_audio_001"
      })

    assert body.text == ""
    assert [att] = body.attachments
    assert att.type == :audio
    assert att.duration == 42
  end

  test "media (video) message → video attachment with duration" do
    body =
      build(%{
        "message_type" => "media",
        "content" => ~s({"file_key":"media_key","duration":99}),
        "message_id" => "om_test_media_001"
      })

    assert body.text == ""
    assert [att] = body.attachments
    assert att.type == :video
    assert att.duration == 99
  end

  # P1 test-supplement (security triage) — malformed-input rejection at
  # the EventDecoder boundary. `content` is attacker/Feishu-controlled;
  # it must never crash the webhook, only degrade gracefully.
  test "content that is not valid JSON degrades to an empty content map (no crash)" do
    body =
      build(%{
        "message_type" => "text",
        "content" => "{not valid json",
        "message_id" => "om_test_badjson_001"
      })

    assert body.text == ""
    assert body.attachments == []
  end

  test "content that is not even a string (e.g. already a map) degrades to an empty content map (no crash)" do
    body =
      build(%{
        "message_type" => "text",
        "content" => %{"text" => "already-a-map-not-a-json-string"},
        "message_id" => "om_test_maptype_001"
      })

    assert body.text == ""
    assert body.attachments == []
  end

  test "missing message_type entirely defaults to \"unknown\" → text breadcrumb, no crash" do
    body =
      build(%{
        "content" => ~s({"foo":"bar"}),
        "message_id" => "om_test_notype_001"
      })

    assert String.contains?(body.text, "message_type=unknown")
    assert body.attachments == []
  end

  test "unknown message_type → text breadcrumb (so CC sees the attempt)" do
    body =
      build(%{
        "message_type" => "sticker",
        "content" => ~s({"sticker_key":"sk_xyz"}),
        "message_id" => "om_test_sticker_001"
      })

    assert String.contains?(body.text, "message_type=sticker")
    assert String.contains?(body.text, "unhandled")
    assert body.attachments == []
  end

  defp build(msg) do
    EzagentPluginFeishu.EventDecoder.build_body(msg)
  end
end
