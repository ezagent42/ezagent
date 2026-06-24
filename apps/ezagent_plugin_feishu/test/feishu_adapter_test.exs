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
  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.{FeishuAdapter, FeishuChatBinding}
  alias EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, as: FeishuAllow
  alias Ezagent.Publisher.Event

  # Sandbox provided by EzagentCore.DataCase (#92).
  # `target_ownership_check/2` reads `feishu_user_bindings` via
  # `UserBinding.list_all/0`; the no-Feishu caller test triggers that
  # DB read, which DataCase's sandbox connection satisfies (returns []).

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

  # P3-4 — confirm the Feishu mirror is a conformant `:push` adapter on the
  # generalized push/pull `ExternalAdapter` contract (P3-1). P3-1 kept the push
  # axis byte-identical, so this is a no-op for behavior but pins the conformance
  # so a future change can't silently drift the mirror off the push contract.
  describe "P3-4 — generalized push/pull contract conformance" do
    setup do
      # `function_exported?/3` returns false for an UNLOADED module, which would
      # make the negative pins below (no adapter_kind/0, no render/2) pass
      # vacuously depending on test order (codex P3-4 MEDIUM). Force-load first.
      assert Code.ensure_loaded?(FeishuAdapter)
      :ok
    end

    test "resolves as a :push adapter (no adapter_kind/0 → default :push)" do
      refute function_exported?(FeishuAdapter, :adapter_kind, 0)
      assert Ezagent.ExternalMirror.Adapter.kind_of(FeishuAdapter) == :push
    end

    test "declares the FULL :push required-callback set (binding + transport + event)" do
      for {fun, arity} <- [
            binding_module: 0,
            cap_subject: 0,
            target_ownership_check: 2,
            event_to_payload: 1
          ] do
        assert function_exported?(FeishuAdapter, fun, arity),
               "push adapter must export #{fun}/#{arity}"
      end
    end

    test "is push-only — does NOT declare the :pull render/2 callback" do
      refute function_exported?(FeishuAdapter, :render, 2)
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
      assert FeishuAllow.data_owner(Ezagent.URI.new!("session://system/default/main")) == :any
    end
  end

  describe "target_ownership_check_timeout/0" do
    test "overrides the 5s default to 10s (Lark API can be slow)" do
      assert FeishuAdapter.target_ownership_check_timeout() == 10_000
    end
  end

  describe "event_to_payload/1 — skip paths (envelope-correct)" do
    test ":skip for non-chat slice changes (e.g. :members)" do
      # A members slice change carries the actual Publisher envelope
      # shape; the adapter must skip on slice_key regardless of payload.
      event = %Event{
        cursor: 1,
        publisher_uri: Ezagent.URI.new!("session://system/default/main"),
        slice_key: :members,
        event_at: DateTime.utc_now(),
        payload: %{
          action: :add_member,
          caller: Ezagent.URI.new!("entity://system/user/admin"),
          new_slice: %{joined: ["entity://system/user/alice"]},
          old_slice: %{joined: []}
        }
      }

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when chat slice mutates but last_message_id + send_cursor unchanged" do
      # Models a future non-send chat slice mutation (e.g. read-marker
      # bump, template_working_copy edit). last_message_id stays equal
      # to old_slice's, send_cursor stays equal — adapter must skip.
      msg = build_msg(%{text: "earlier message"})

      common = %{last_message_id: msg.id, last_message: msg, send_cursor: 5}

      event =
        chat_event(%{
          action: :update_template,
          caller: Ezagent.URI.new!("entity://system/user/admin"),
          # Mutate a different field; last_message_* untouched.
          new_slice: Map.put(common, :template_working_copy, %{x: 1}),
          old_slice: Map.put(common, :template_working_copy, %{x: 0})
        })

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when new_slice missing last_message (legacy slice shape)" do
      # Pre-PR-EM-6-PRE snapshot or a future intentional nil — defensive.
      event =
        chat_event(%{
          action: :send,
          caller: nil,
          new_slice: %{last_message_id: "msg_x", send_cursor: 1},
          old_slice: %{last_message_id: nil, send_cursor: 0}
        })

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when message body carries _feishu_origin (atom key)" do
      msg = build_msg(%{text: "hi", _feishu_origin: true})

      event = chat_send_event(msg, prev_cursor: 0)

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test ":skip when message body carries `_feishu_origin` (string key)" do
      msg = build_msg(%{"text" => "hi", "_feishu_origin" => true})

      event = chat_send_event(msg, prev_cursor: 0)

      assert FeishuAdapter.event_to_payload(event) == :skip
    end
  end

  describe "event_to_payload/1 — publish paths (envelope-correct)" do
    test "plain text message → single :lark_text payload" do
      msg = build_msg(%{text: "hello world"})

      event = chat_send_event(msg, prev_cursor: 0)

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)
      assert [{:lark_text, text}] = payloads
      assert text =~ "hello world"
      # Prefix includes session (from msg.session_uri) + sender
      assert text =~ "session://system/default/main"
      assert text =~ URI.to_string(msg.sender)
    end

    test "text + Feishu-origin image attachment → text + image_passthrough" do
      attachments = [
        %{type: :image, source: "feishu", file_key: "img_key_xyz", name: "photo.png"}
      ]

      msg = build_msg(%{text: "look at this", attachments: attachments})

      event = chat_send_event(msg, prev_cursor: 0)

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

      event = chat_send_event(msg, prev_cursor: 0)

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)

      assert Enum.any?(payloads, fn
               {:lark_image_upload, "/tmp/diagram.png", "diagram.png", prefix} ->
                 is_binary(prefix)

               _ ->
                 false
             end)
    end

    test "retry of same msg.id — cursor delta alone still publishes" do
      # MessageStore is idempotent on (msg.id, session_uri) — a retried
      # send returns the same row. PR-EM-6-PRE bumps :send_cursor on
      # every invocation so the slice still changes. The adapter must
      # honour this: same last_message_id, bumped send_cursor → publish.
      msg = build_msg(%{text: "retry me"})

      common = %{last_message_id: msg.id, last_message: msg}

      event =
        chat_event(%{
          action: :send,
          caller: nil,
          new_slice: Map.put(common, :send_cursor, 6),
          old_slice: Map.put(common, :send_cursor, 5)
        })

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)
      assert [{:lark_text, text}] = payloads
      assert text =~ "retry me"
    end

    test "first-ever event (old_slice == nil) with a real send → publishes" do
      # Cold-start: publisher's first emit could carry nil old_slice if
      # SliceChange's initial baseline is nil. The chat_send_occurred?/2
      # nil-clause treats new_slice's non-nil last_message_id as proof a
      # send happened.
      msg = build_msg(%{text: "first ever"})

      event =
        chat_event(%{
          action: :send,
          caller: nil,
          new_slice: %{last_message_id: msg.id, last_message: msg, send_cursor: 1},
          old_slice: nil
        })

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)
      assert [{:lark_text, text}] = payloads
      assert text =~ "first ever"
    end
  end

  describe "event_to_payload/1 — two-container Lifecycle slice (regression)" do
    # Post-2026-05-29 Lifecycle migration wraps the developer slice as
    # `%{state: <persistent>, transients: ...}`. The Publisher event carries
    # this nested shape. Before the unwrap fix, the adapter read the FLAT
    # shape (`new_slice.last_message_id`) → `chat_send_occurred?` always false
    # → EVERY chat send SILENTLY skipped (the post-lifecycle feishu-mirror
    # outage, Allen 2026-05-31). These pin that a nested slice still publishes.

    test "nested %{state: …} chat send → {:publish} (was silently skipped)" do
      msg = build_msg(%{text: "nested-state send"})

      event =
        chat_event(%{
          action: :send,
          caller: msg.sender,
          new_slice: %{state: %{last_message_id: msg.id, last_message: msg, send_cursor: 1}},
          old_slice: %{state: %{last_message_id: nil, last_message: nil, send_cursor: 0}}
        })

      assert {:publish, [{:lark_text, text}]} = FeishuAdapter.event_to_payload(event)
      assert text =~ "nested-state send"
    end

    test "nested string-keyed %{\"state\" => …} (post-JSON rehydrate) → {:publish}" do
      msg = build_msg(%{text: "string-key state"})

      event =
        chat_event(%{
          action: :send,
          caller: msg.sender,
          new_slice: %{"state" => %{last_message_id: msg.id, last_message: msg, send_cursor: 1}},
          old_slice: nil
        })

      assert {:publish, [{:lark_text, text}]} = FeishuAdapter.event_to_payload(event)
      assert text =~ "string-key state"
    end

    test "legacy FLAT slice still publishes (unwrap is passthrough)" do
      msg = build_msg(%{text: "flat slice still works"})
      event = chat_send_event(msg, prev_cursor: 0)
      assert {:publish, [{:lark_text, text}]} = FeishuAdapter.event_to_payload(event)
      assert text =~ "flat slice still works"
    end
  end

  describe "target_ownership_check/2 — no Feishu identity" do
    test "returns {:error, :no_feishu_identity} when caller has no open_id binding" do
      # The test caller is never bound (no row in feishu_user_bindings).
      # The adapter's caller_open_id/1 returns :no_feishu_identity
      # BEFORE touching the Lark API — no network call.
      caller = Ezagent.URI.new!("entity://system/user/bob_with_no_feishu_link")

      assert {:error, :no_feishu_identity} =
               FeishuAdapter.target_ownership_check(caller, "oc_some_chat")
    end

    test "returns {:error, :invalid_target} for a non-string target" do
      caller = Ezagent.URI.new!("entity://system/user/alice")
      assert {:error, :invalid_target} = FeishuAdapter.target_ownership_check(caller, 42)
    end
  end

  # ----- test helpers -------------------------------------------------------

  # Build a Message stamped with session_uri the way `MessageStore.write/2`
  # would — the adapter reads source label off `msg.session_uri`, not
  # off the event envelope.
  defp build_msg(body) do
    sender = Ezagent.URI.new!("entity://system/user/alice")
    session_uri = Ezagent.URI.new!("session://system/default/main")

    %Ezagent.Message{
      id: "msg_test_" <> Integer.to_string(System.unique_integer([:positive])),
      sender: sender,
      mentions: [],
      body: body,
      ref_id: nil,
      session_uri: session_uri,
      workspace_uri: "workspace://system",
      inserted_at: DateTime.utc_now()
    }
  end

  # Wrap an explicit (action, caller, new_slice, old_slice) payload in
  # a real Publisher.Event — used by the non-send and edge-case tests.
  defp chat_event(payload) when is_map(payload) do
    %Event{
      cursor: 1,
      publisher_uri: Ezagent.URI.new!("session://system/default/main"),
      slice_key: :session,
      event_at: DateTime.utc_now(),
      payload: payload
    }
  end

  # Convenience for the "normal :send mutation" envelope shape produced
  # by `Behavior.Session.invoke(:send, ...)` + `SessionImpl.build_payload/1`:
  # action=:send, both slices populated, send_cursor bumped, msg id
  # promoted into `:last_message_id` + full struct into `:last_message`.
  defp chat_send_event(msg, opts) do
    prev_cursor = Keyword.fetch!(opts, :prev_cursor)
    prev_msg_id = Keyword.get(opts, :prev_msg_id)
    prev_last_msg = Keyword.get(opts, :prev_last_msg)

    new_slice = %{
      last_message_id: msg.id,
      last_message: msg,
      send_cursor: prev_cursor + 1
    }

    old_slice = %{
      last_message_id: prev_msg_id,
      last_message: prev_last_msg,
      send_cursor: prev_cursor
    }

    chat_event(%{
      action: :send,
      caller: msg.sender,
      new_slice: new_slice,
      old_slice: old_slice
    })
  end
end
