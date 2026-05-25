defmodule EzagentPluginFeishu.FeishuAdapterTest do
  @moduledoc """
  PR-EM-6 unit tests for `EzagentPluginFeishu.FeishuAdapter`.

  Focus areas:

  - Grill-5 bidirectional declaration (adapter ↔ binding).
  - `cap_subject/0` shape (Cap 2 marker Behavior, dispatchable?=false).
  - `event_to_payload/1` `:skip` path for non-chat slice changes.
  - `event_to_payload/1` self-echo skip when body carries
    `_feishu_origin`.
  - `event_to_payload/1` text + attachment shaping for `:chat` events
    (V1 parity with the retired FeishuOutbound).
  - `target_ownership_check/2` denies when caller has no Feishu
    open_id binding (the realistic failure mode for an unbounded
    workspace caller).

  Network-touching behaviour (real Lark API calls in
  `target_ownership_check/2` and `check_chat_membership/3`) is NOT
  exercised here — that's the E2E test territory. These tests pin
  the pure-function and callback-shape contract.
  """

  # async: false because `target_ownership_check/2` reads the
  # `feishu_user_bindings` table via a sandboxed Repo connection;
  # shared-mode sandbox precludes async.
  use ExUnit.Case, async: false

  alias EzagentPluginFeishu.{FeishuAdapter, FeishuChatBinding}
  alias EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, as: FeishuAllow
  alias Ezagent.Publisher.Event

  setup do
    # `target_ownership_check/2` reads `feishu_user_bindings` via
    # `UserBinding.list_all/0`. Other tests are pure but the no-Feishu
    # caller test triggers the DB read — pull a sandboxed connection
    # so the read returns `[]` without crashing the test runner.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "Grill-5 declaration" do
    test "adapter_id is the stable string `feishu`" do
      assert FeishuAdapter.adapter_id() == "feishu"
    end

    test "binding_module/0 names FeishuChatBinding (bidirectional)" do
      assert FeishuAdapter.binding_module() == FeishuChatBinding
      assert FeishuChatBinding.adapter_module() == FeishuAdapter
    end

    test "adapter and binding are different modules (Grill-5 distinct check)" do
      refute FeishuAdapter == FeishuChatBinding
    end

    test "implements the Adapter behaviour" do
      attrs = FeishuAdapter.module_info(:attributes)
      behaviours = attrs |> Keyword.get_values(:behaviour) |> List.flatten()
      assert Ezagent.ExternalMirror.Adapter in behaviours
    end

    test "binding implements the Binding behaviour" do
      attrs = FeishuChatBinding.module_info(:attributes)
      behaviours = attrs |> Keyword.get_values(:behaviour) |> List.flatten()
      assert Ezagent.ExternalMirror.Binding in behaviours
    end
  end

  describe "cap_subject/0" do
    test "names the FeishuAllow marker Behavior (Cap 2)" do
      assert %{behavior_module: FeishuAllow, description: desc} = FeishuAdapter.cap_subject()
      assert is_binary(desc) and desc != ""
    end

    test "FeishuAllow is cap-only (dispatchable?/0 == false)" do
      assert FeishuAllow.dispatchable?() == false
    end

    test "FeishuAllow declares :allow_feishu action + cap subject" do
      assert FeishuAllow.actions() == [:allow_feishu]

      assert [{:allow_feishu, desc}] = FeishuAllow.cap_subjects()
      assert is_binary(desc) and desc != ""
    end

    test "FeishuAllow's data_owner is :any (workspace admin grants)" do
      assert FeishuAllow.data_owner(:any) == :any
      assert FeishuAllow.data_owner(URI.parse("session://default/default/main")) == :any
    end
  end

  describe "target_ownership_check_timeout/0" do
    test "overrides the 5s default to 10s (Lark API can be slow)" do
      assert FeishuAdapter.target_ownership_check_timeout() == 10_000
    end
  end

  describe "event_to_payload/1 — skip paths" do
    test ":skip for non-chat slice changes" do
      event = %Event{
        cursor: 1,
        publisher_uri: URI.parse("session://default/default/main"),
        slice_key: :members,
        event_at: DateTime.utc_now(),
        payload: %{joined: ["entity://user/default/alice"]}
      }

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when chat slice payload has no recognisable message field" do
      event = %Event{
        cursor: 1,
        publisher_uri: URI.parse("session://default/default/main"),
        slice_key: :chat,
        event_at: DateTime.utc_now(),
        payload: %{some_other_field: 42}
      }

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when message body carries _feishu_origin (atom key)" do
      msg = build_msg(%{text: "hi", _feishu_origin: true})

      event = chat_event(%{last_message: msg})

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when message body carries `_feishu_origin` (string key)" do
      msg = build_msg(%{"text" => "hi", "_feishu_origin" => true})

      event = chat_event(%{last_message: msg})

      assert FeishuAdapter.event_to_payload(event) == :skip
    end
  end

  describe "event_to_payload/1 — publish paths" do
    test "plain text message → single :lark_text payload" do
      msg = build_msg(%{text: "hello world"})

      event =
        chat_event(%{
          last_message: msg,
          session_uri: "session://default/default/main"
        })

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)
      assert [{:lark_text, text}] = payloads
      assert text =~ "hello world"
      # Prefix includes session + sender
      assert text =~ "session://default/default/main"
      assert text =~ URI.to_string(msg.sender)
    end

    test "text + Feishu-origin image attachment → text + image_passthrough" do
      attachments = [
        %{type: :image, source: "feishu", file_key: "img_key_xyz", name: "photo.png"}
      ]

      msg = build_msg(%{text: "look at this", attachments: attachments})

      event =
        chat_event(%{
          last_message: msg,
          session_uri: "session://default/default/main"
        })

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)

      assert Enum.any?(payloads, fn
               {:lark_text, t} -> t =~ "look at this"
               _ -> false
             end)

      assert Enum.any?(payloads, fn
               {:lark_image_passthrough, "img_key_xyz", "photo.png"} -> true
               _ -> false
             end)
    end

    test "outbound (local_path) image → image_upload payload" do
      attachments = [
        %{type: :image, local_path: "/tmp/diagram.png", name: "diagram.png"}
      ]

      # No body text — only attachment.
      msg = build_msg(%{text: "", attachments: attachments})

      event =
        chat_event(%{
          last_message: msg,
          session_uri: "session://default/default/main"
        })

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)

      assert Enum.any?(payloads, fn
               {:lark_image_upload, "/tmp/diagram.png", "diagram.png", prefix} ->
                 is_binary(prefix)

               _ ->
                 false
             end)
    end
  end

  describe "target_ownership_check/2 — no Feishu identity" do
    test "returns {:error, :no_feishu_identity} when caller has no open_id binding" do
      # The test caller is never bound (no row in feishu_user_bindings).
      # The adapter's caller_open_id/1 returns :no_feishu_identity
      # BEFORE touching the Lark API — no network call.
      caller = URI.parse("entity://user/default/bob_with_no_feishu_link")

      assert {:error, :no_feishu_identity} =
               FeishuAdapter.target_ownership_check(caller, "oc_some_chat")
    end

    test "returns {:error, :invalid_target} for a non-string target" do
      caller = URI.parse("entity://user/default/alice")
      assert {:error, :invalid_target} = FeishuAdapter.target_ownership_check(caller, 42)
    end
  end

  # ----- test helpers -------------------------------------------------------

  defp build_msg(body) do
    sender = URI.parse("entity://user/default/alice")

    %Ezagent.Message{
      id: "msg_test_" <> Integer.to_string(System.unique_integer([:positive])),
      sender: sender,
      mentions: [],
      body: body,
      ref_id: nil,
      inserted_at: DateTime.utc_now()
    }
  end

  defp chat_event(payload) do
    %Event{
      cursor: 1,
      publisher_uri: URI.parse("session://default/default/main"),
      slice_key: :chat,
      event_at: DateTime.utc_now(),
      payload: payload
    }
  end
end
