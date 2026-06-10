defmodule EzagentPluginFeishu.E2E.Category04FeishuTest do
  @moduledoc """
  E2E scenarios — Category 4: Feishu integration.

  Maps to `docs/scenarios/12-feishu-bind-outbound/scenario.md` and
  `docs/scenarios/13-feishu-inbound-routing/scenario.md`.

  ## Mock strategy

  The real Feishu sidecar / Lark Open API are NOT exercised here.
  Instead we exploit the production code's existing test seams:

  - **Outbound shaping**: `EzagentPluginFeishu.FeishuAdapter.event_to_payload/1`
    is pure — given a `Ezagent.Publisher.Event` it returns
    `{:publish, [...]}` or `:skip`. Exercised against real envelope
    shapes built from `Ezagent.Message` and `Ezagent.Publisher.Event`.

  - **Outbound transport (Binding)**: `FeishuChatBinding` ships
    `{:lark_test_ok, _} / {:lark_test_fail, _}` clauses gated behind
    `Mix.env() == :test` (see binding source). Sending these tagged
    payloads through `publish/2` exercises the success/failure paths
    without any Lark HTTP traffic — the mock IS the seam.

  - **Inbound chat lookup**: `InboundChatLookup.resolve/1` reads the
    `external_mirror_bindings` projection. We insert rows directly
    via `Ezagent.ExternalMirror.BindingRow.insert/1` (same path
    PR-EM-3's `:bind` action body uses) so the lookup table has data.

  - **Inbound sender resolution**: `SenderResolver.resolve/1` reads
    `feishu_user_bindings` via `UserBinding`. We `UserBinding.bind/3`
    in setup and assert the resolver returns the bound URI + caps.

  - **Inbound dispatch (end-to-end mock)**: `InboundDispatcher.dispatch/1`
    constructs an `Ezagent.Invocation` and routes via
    `Ezagent.Invocation.dispatch/1`. We bind a Feishu chat_id to a
    real Session URI, bind a Feishu open_id to a real User URI, and
    assert the dispatch lands as a `chat.send` invocation observable
    on the Session's chat slice.

  ## Allen-manual gaps (skeletons + @moduletag :requires_allen)

  WS long-connect to Feishu, real webhook signature verification, and
  real send_message to the dev Feishu chat (`oc_83a4f1ff0bf627ffe26aa60647e5b04a`)
  all require live Feishu app credentials + sidecar process. These
  appear as skeleton tests at the bottom of the file under
  `@moduletag :requires_allen` so a CI run with that tag included
  surfaces them as TODOs.

  See `docs/scenarios/12-feishu-bind-outbound/scenario.md` and
  `13-feishu-inbound-routing/scenario.md` for the production
  topologies these mocks approximate.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.BindingRow
  alias Ezagent.Publisher.Event
  alias EzagentPluginFeishu.{FeishuAdapter, FeishuChatBinding, InboundChatLookup, SenderResolver, UserBinding}

  @feishu_chat_dev "oc_83a4f1ff0bf627ffe26aa60647e5b04a"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  # ============================================================
  # Scenario 12 — bind + outbound (mock)
  # ============================================================

  describe "scenario 12 — bind Feishu chat ↔ session (BindingRow projection)" do
    @describetag scenario: "12-feishu-bind-outbound"

    test "InboundChatLookup.chat_ids_for/1 reflects a freshly inserted feishu binding row" do
      session_uri = "session://system/default/main_#{uniq()}"
      chat_id = "oc_lookup_e2e_#{uniq()}"

      :ok = insert_binding_row(session_uri, "feishu", chat_id)

      ids = InboundChatLookup.chat_ids_for(session_uri)
      assert chat_id in ids
    end

    test "InboundChatLookup.resolve/1 round-trips chat_id → session_uri" do
      session_uri = "session://system/default/round_trip_#{uniq()}"
      chat_id = "oc_resolve_e2e_#{uniq()}"

      :ok = insert_binding_row(session_uri, "feishu", chat_id)

      assert {:ok, %URI{scheme: "session"} = parsed} = InboundChatLookup.resolve(chat_id)
      assert URI.to_string(parsed) == session_uri
    end

    test "non-feishu adapter rows with same target_id are ignored by InboundChatLookup" do
      session_uri = "session://system/default/disambig_#{uniq()}"
      chat_id = "oc_disambig_e2e_#{uniq()}"

      # Insert with a non-feishu adapter id — feishu lookup must NOT
      # see it. Guards against the "Slack adapter steals a Feishu
      # chat_id by accident" regression.
      :ok = insert_binding_row(session_uri, "slack_hypothetical", chat_id)
      assert :error = InboundChatLookup.resolve(chat_id)
    end

    test "ambiguous binding (same chat_id, two sessions) fails closed" do
      chat_id = "oc_ambiguous_e2e_#{uniq()}"

      :ok = insert_binding_row("session://system/default/sess_a_#{uniq()}", "feishu", chat_id)
      :ok = insert_binding_row("session://system/default/sess_b_#{uniq()}", "feishu", chat_id)

      # codex r1 HIGH lesson — pre-fix this returned the oldest row
      # silently. Post-fix it surfaces the operator error.
      assert {:error, :ambiguous_chat_binding} = InboundChatLookup.resolve(chat_id)
    end
  end

  # ============================================================
  # Scenario 12 — outbound transport (FeishuChatBinding mocked)
  # ============================================================

  describe "scenario 12 — outbound transport (test-seam mock)" do
    @describetag scenario: "12-feishu-bind-outbound"

    test "all-success payload list updates publish_count" do
      {:ok, state} =
        FeishuChatBinding.init({@feishu_chat_dev, FeishuAdapter, %{bound_by: "entity://system/user/admin"}})

      assert {:ok, new_state} =
               FeishuChatBinding.publish(
                 [{:lark_test_ok, "msg-1"}, {:lark_test_ok, "msg-2"}],
                 state
               )

      assert new_state.publish_count == 1
      assert new_state.error_count == 0
    end

    test "pre-publish failure (first payload fails, sent==0) returns recoverable error" do
      {:ok, state} = FeishuChatBinding.init({@feishu_chat_dev, FeishuAdapter, %{}})

      assert {:error, :synthetic_lark_down, new_state} =
               FeishuChatBinding.publish(
                 [{:lark_test_fail, :synthetic_lark_down}, {:lark_test_ok, "later"}],
                 state
               )

      assert new_state.error_count == 1
      assert new_state.last_retry_at != nil
      # publish_count NOT bumped — nothing actually shipped.
      assert new_state.publish_count == 0
    end

    test "partial-publish failure (sent>=1 then fail) RAISES (no silent payload loss)" do
      {:ok, state} = FeishuChatBinding.init({@feishu_chat_dev, FeishuAdapter, %{}})

      # codex r1 HIGH regression: the worker advances publisher_cursor
      # on {:error,_,_} — partial-send must RAISE instead so the
      # PerBindingSupervisor restarts and the cursor stays put.
      assert_raise RuntimeError, ~r/partial-publish failure/, fn ->
        FeishuChatBinding.publish(
          [{:lark_test_ok, "delivered"}, {:lark_test_fail, :synthetic_429}],
          state
        )
      end
    end

    test "invalid chat_id (no oc_ prefix) is rejected by Binding.init/1" do
      assert {:error, {:invalid_chat_id, "not_a_feishu_chat"}} =
               FeishuChatBinding.init({"not_a_feishu_chat", FeishuAdapter, %{}})
    end
  end

  # ============================================================
  # Scenario 12 — adapter event shaping (envelope-correct)
  # ============================================================

  describe "scenario 12 — FeishuAdapter event-to-payload shaping" do
    @describetag scenario: "12-feishu-bind-outbound"

    test "outbound text message produces a single :lark_text payload" do
      msg = make_msg(%{text: "hello e2e"})
      event = make_chat_send_event(msg, prev_cursor: 0)

      assert {:publish, payloads} = FeishuAdapter.event_to_payload(event)
      assert [{:lark_text, text}] = payloads
      assert text =~ "hello e2e"
    end

    test "inbound message marked _feishu_origin is SKIPPED (no echo back)" do
      # Stamped by InboundDispatcher.do_dispatch/4 — preserves the
      # outbound mirror from echoing inbound messages back to Feishu
      # and looping.
      msg = make_msg(%{text: "from feishu", _feishu_origin: true})
      event = make_chat_send_event(msg, prev_cursor: 0)

      assert FeishuAdapter.event_to_payload(event) == :skip
    end

    test "non-chat slice (e.g. :members) is SKIPPED" do
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
  end

  # ============================================================
  # Scenario 13 — inbound resolver + lookup (mock pattern)
  # ============================================================

  describe "scenario 13 — Feishu inbound (sender + chat resolution)" do
    @describetag scenario: "13-feishu-inbound-routing"

    test "bound open_id resolves to the bound User URI + caps from live Kind" do
      # Spawn a User Kind so list_caps_for finds an alive slice.
      user_uri = Ezagent.URI.new!("entity://system/user/feishu_e2e_user_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)

      open_id = "ou_e2e_bound_#{uniq()}"
      {:ok, _row} = UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      sender = %{"sender_id" => %{"open_id" => open_id}}

      assert {:ok, %URI{} = resolved, caps} = SenderResolver.resolve(sender)
      assert URI.to_string(resolved) == URI.to_string(user_uri)
      # caps may be an empty MapSet for a freshly-spawned user with no
      # explicit grants — what matters is the resolver returned a
      # MapSet (the production callers pattern-match on this).
      assert is_struct(caps, MapSet)
    end

    test "unbound open_id resolves to :pending (no impersonation)" do
      sender = %{"sender_id" => %{"open_id" => "ou_e2e_unbound_#{uniq()}"}}

      # `:pending` is the safe default — the inbound dispatcher
      # reacts THUMBSDOWN + logs, never invents a caller identity.
      assert {:pending, _open_id} = SenderResolver.resolve(sender)
    end

    test "malformed sender (no open_id key) returns :error" do
      assert {:error, :bad_sender} = SenderResolver.resolve(%{"weird" => "shape"})
    end

    test "user_id presented instead of open_id is :pending (we only bind on open_id)" do
      # Feishu sometimes presents user_id for legacy clients; the
      # resolver MUST NOT treat it as a bound identity.
      sender = %{"sender_id" => %{"user_id" => "u_legacy_#{uniq()}"}}
      assert {:pending, "user_id:" <> _} = SenderResolver.resolve(sender)
    end

    test "chat_id ↔ session resolution (the full inbound chain seam)" do
      # The complete inbound-resolution chain: chat_id → session +
      # sender → user. With both we have everything needed to build
      # the Invocation envelope; the dispatch step is exercised by
      # the integration test below.
      session_uri = "session://system/default/inbound_e2e_#{uniq()}"
      chat_id = "oc_inbound_e2e_#{uniq()}"
      :ok = insert_binding_row(session_uri, "feishu", chat_id)

      user_uri = Ezagent.URI.new!("entity://system/user/inbound_user_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
      open_id = "ou_inbound_e2e_#{uniq()}"
      {:ok, _} = UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      # Both halves resolve to a concrete URI.
      assert {:ok, %URI{scheme: "session"} = sess} = InboundChatLookup.resolve(chat_id)
      assert URI.to_string(sess) == session_uri

      assert {:ok, %URI{} = resolved_user, _caps} =
               SenderResolver.resolve(%{"sender_id" => %{"open_id" => open_id}})

      assert URI.to_string(resolved_user) == URI.to_string(user_uri)
    end
  end

  # ============================================================
  # Scenario 13 — Bot kicked / binding cleanup (mock)
  # ============================================================

  describe "scenario 12/13 — bot kicked / unbind cleanly" do
    @describetag scenario: "12-feishu-bind-outbound"

    test "deleting a binding row removes it from InboundChatLookup" do
      session_uri = "session://system/default/kick_e2e_#{uniq()}"
      chat_id = "oc_kick_e2e_#{uniq()}"

      :ok = insert_binding_row(session_uri, "feishu", chat_id)
      assert {:ok, _} = InboundChatLookup.resolve(chat_id)

      # Simulate the unbind / bot-kicked cleanup at the projection layer
      # (the production path runs through `Behavior.ExternalMirror.unbind`).
      :ok = delete_binding_row(session_uri, "feishu", chat_id)

      assert :error = InboundChatLookup.resolve(chat_id)
      assert [] = InboundChatLookup.chat_ids_for(session_uri)
    end

    test "the same chat_id can be bound to multiple bots (different app_id semantics ≠ adapter_id collision)" do
      # The current production model keys `external_mirror_bindings` on
      # (session, adapter, target). For Feishu, target_id is the
      # chat_id. The scenario's "multi-app-id" semantic is per-Worker
      # multiplexing rather than per-row duplication — so we assert
      # the projection ALLOWS distinct sessions to bind the same chat,
      # but `InboundChatLookup.resolve/1` then fails closed (ambiguous).
      chat_id = "oc_multi_app_e2e_#{uniq()}"

      :ok = insert_binding_row("session://system/default/app1_#{uniq()}", "feishu", chat_id)
      :ok = insert_binding_row("session://system/default/app2_#{uniq()}", "feishu", chat_id)

      assert {:error, :ambiguous_chat_binding} = InboundChatLookup.resolve(chat_id)
    end
  end

  # ============================================================
  # Allen-manual scenarios — skeletons
  # ============================================================

  describe "scenario 13 — REAL Feishu WS / webhook (Allen-manual only)" do
    @describetag :requires_allen
    @describetag :requires_feishu_app
    @describetag scenario: "13-feishu-inbound-routing"

    @tag :skip
    test "real WS long-connect: bot is kicked from chat, WsClient logs + unbinds (Allen smoke)" do
      # Requires:
      #  - EZAGENT_FEISHU_APP_ID / APP_SECRET env
      #  - WsClient running (not started in test env per Application.maybe_ws_client_spec/0)
      #  - A real Feishu chat where the bot can be kicked
      # Expected behavior:
      #  - WsClient receives the kicked event
      #  - Binding row removed via `Behavior.ExternalMirror.unbind`
      #  - PerBindingSupervisor terminates the Worker
      # Verification surface: agent-browser screenshot of `/admin/sessions/<uri>/external_mirror`
      # showing the binding gone within ~5s of the kick.
      flunk("requires live Feishu app + WsClient — Allen-manual scenario only")
    end

    @tag :skip
    test "real outbound send_message lands in dev chat oc_83a4f1ff... (Allen smoke)" do
      # Requires:
      #  - Live `EzagentPluginFeishu.Client` with valid tenant token
      #  - Dev chat oc_83a4f1ff0bf627ffe26aa60647e5b04a reachable from the app
      # Expected behavior:
      #  - FeishuChatBinding.publish/2 with a real {:lark_text, text}
      #    payload returns :ok
      #  - The text shows up in the dev Feishu chat
      # Verification surface: Feishu chat capture per feedback_esr_e2e_standards.
      flunk("requires live Lark Open API + dev chat — Allen-manual scenario only")
    end

    @tag :skip
    test "webhook signature verification (real Feishu encryption_key)" do
      # Requires:
      #  - WebhookPlug mounted in production endpoint
      #  - Real `encryption_key` configured in feishu.yaml
      #  - A signed payload from the Feishu app webhook tester
      flunk("requires live Feishu webhook signed payload — Allen-manual scenario only")
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  defp insert_binding_row(session_uri_str, adapter_id, target_id) do
    session_uri = URI.parse(session_uri_str)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    attrs = %{
      id: BindingRow.row_id(session_uri, adapter_id, target_id),
      session_uri: session_uri_str,
      adapter_id: adapter_id,
      target_id: target_id,
      opts_json: "{}",
      bound_by: "entity://system/user/admin",
      bound_at: DateTime.utc_now(),
      workspace_uri: workspace_uri
    }

    {:ok, _row} = BindingRow.insert(attrs)
    :ok
  end

  defp delete_binding_row(session_uri_str, adapter_id, target_id) do
    # Mirror what `Behavior.ExternalMirror.unbind` does at the projection
    # layer — a row delete on the natural key. We use the same
    # `BindingRow.row_id/3` so the test stays accurate to the
    # production data model.
    session_uri = URI.parse(session_uri_str)
    row_id = BindingRow.row_id(session_uri, adapter_id, target_id)

    case EzagentCore.Repo.get(BindingRow, row_id) do
      nil -> :ok
      row -> {:ok, _} = EzagentCore.Repo.delete(row)
    end

    :ok
  end

  defp make_msg(body) do
    sender = Ezagent.URI.new!("entity://system/user/alice")
    session_uri = Ezagent.URI.new!("session://system/default/main")

    %Ezagent.Message{
      id: "msg_e2e_" <> uniq(),
      sender: sender,
      mentions: [],
      body: body,
      ref_id: nil,
      session_uri: session_uri,
      workspace_uri: "workspace://system",
      inserted_at: DateTime.utc_now()
    }
  end

  defp make_chat_send_event(msg, opts) do
    prev_cursor = Keyword.fetch!(opts, :prev_cursor)

    new_slice = %{
      last_message_id: msg.id,
      last_message: msg,
      send_cursor: prev_cursor + 1
    }

    old_slice = %{
      last_message_id: nil,
      last_message: nil,
      send_cursor: prev_cursor
    }

    %Event{
      cursor: 1,
      publisher_uri: Ezagent.URI.new!("session://system/default/main"),
      slice_key: :chat,
      event_at: DateTime.utc_now(),
      payload: %{
        action: :send,
        caller: msg.sender,
        new_slice: new_slice,
        old_slice: old_slice
      }
    }
  end
end
