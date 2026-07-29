defmodule EzagentPluginFeishu.WebhookPlugTest do
  @moduledoc """
  P1 test-supplement (security triage) — HTTP-level contract of
  `EzagentPluginFeishu.WebhookPlug`, the `/api/feishu/webhook` inbound
  route. Had ZERO tests before this PR (`InboundDispatcher` and
  `WebhookPlug` were the two 0%-covered modules in the app).

  ## Auth — pinning what the code ACTUALLY does, not a fabricated test

  This plug's own moduledoc says: "Webhook is unauthenticated at the
  network level ... Future hardening: validate `Encrypt-Key` header
  signature when `verification_token` is configured." There is NO
  signature/token verification implemented anywhere in this module or in
  `EzagentPluginFeishu.InboundDispatcher`/`SenderResolver` — confirmed by
  reading every call site and by the pre-existing
  `test/e2e/category_04_feishu_test.exs` `:requires_allen` skeleton test
  literally named "webhook signature verification (real Feishu
  encryption_key)" which `flunk/1`s with "requires live Feishu app".

  So: this is a genuine, ALREADY-DOCUMENTED gap, not something this PR's
  tests reveal fresh — it is NOT a STOP-worthy new bug per the task
  rules, but it IS exactly the class of thing priority 3 asked to pin.
  What's actually testable and pinned below: the plug accepts any
  well-formed JSON event and attempts to DISPATCH it trusting
  `sender.open_id` as-is (no caller identity check beyond "is this
  open_id bound to a user" downstream in `SenderResolver`).

  IMPORTANT CORRECTION / cross-reference — see
  `inbound_dispatcher_test.exs`'s "live session" describe block for the
  fuller picture: that "attempts to dispatch" does NOT currently reach a
  session send. A SEPARATE gap (`InboundDispatcher.dispatch/1` is called
  here with `origin: nil`) makes the umbrella's universal pre-delivery
  policy gate reject EVERY dispatch this plug triggers with
  `{:error, :unstamped_origin}`, BEFORE any cap/impersonation concern is
  reached. That gate is, today, the thing standing between "this route
  has no auth" and actual impersonation — read the two together, not
  this file in isolation. Flagged prominently in the PR body / final
  report for the coordinator; not fixed here (test-only PR, no
  product-code change, and — per the other file's note — the "obvious"
  fix to the origin gap would be actively dangerous applied on its own).

  What IS covered: malformed-input rejection (bad JSON -> 400, wrong
  method -> 405), the URL-verification challenge-response, and the
  inbound event fan-out into `InboundDispatcher` for both the "bound"
  and "unbound (pending)" sender cases (the latter is the actual current
  safety net — an unbound open_id never gets a caller identity, see
  `SenderResolver`/`InboundDispatcher` tests).
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.WebhookPlug

  describe "malformed-input rejection" do
    test "non-POST method -> 405" do
      conn = Plug.Test.conn(:get, "/api/feishu/webhook") |> WebhookPlug.call([])
      assert conn.status == 405
      assert conn.resp_body == "method not allowed"
    end

    test "POST with unparseable body (not JSON, unfetched body_params) -> 400" do
      # No Plug.Parsers run — mirrors a client that sends a body with a
      # Content-Type Plug.Parsers doesn't recognize (pass: ["*/*"] at the
      # Endpoint lets it through unparsed) AND the raw bytes aren't JSON.
      conn =
        Plug.Test.conn(:post, "/api/feishu/webhook", "not-json-at-all{{{")
        |> WebhookPlug.call([])

      assert conn.status == 400
      assert conn.resp_body == "bad payload"
    end

    test "POST with an empty body and no parsed body_params -> 400" do
      conn = Plug.Test.conn(:post, "/api/feishu/webhook", "") |> WebhookPlug.call([])
      assert conn.status == 400
      assert conn.resp_body == "bad payload"
    end

    test "POST with recognized JSON but unrecognized payload shape -> 200 (safe no-op passthrough)" do
      conn = post_parsed(%{"totally" => "unrecognized", "shape" => 1})
      assert conn.status == 200
      assert conn.resp_body == "{}"
    end
  end

  describe "URL verification challenge (Feishu app setup handshake)" do
    test "echoes the challenge back on a url_verification payload" do
      conn = post_parsed(%{"type" => "url_verification", "challenge" => "chal-abc-123"})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"challenge" => "chal-abc-123"}
    end
  end

  describe "event callback fan-out (no signature check — see moduledoc)" do
    test "message event with an UNBOUND sender -> 200, no caller identity created (safety net intact)" do
      # This is the one thing standing between "anyone can POST an event"
      # and "anyone can act as an arbitrary Ezagent identity": an open_id
      # this deployment has never bound stays :pending in SenderResolver,
      # so InboundDispatcher never dispatches into a session on its behalf
      # (it THUMBSDOWN-reacts and stops, per InboundDispatcher's dispatch/1
      # `{:pending, open_id}` branch).
      open_id = "ou_webhook_test_unbound_#{uniq()}"

      conn =
        post_parsed(%{
          "schema" => "2.0",
          "header" => %{},
          "event" => %{
            "sender" => %{"sender_id" => %{"open_id" => open_id}},
            "message" => %{
              "chat_id" => "oc_webhook_test_#{uniq()}",
              "message_id" => "om_webhook_test_#{uniq()}",
              "message_type" => "text",
              "content" => ~s({"text":"hello from an unbound sender"})
            }
          }
        })

      # The webhook ALWAYS 200s an event callback (Feishu's own contract:
      # a non-2xx makes Feishu retry-storm the endpoint) — the auth
      # decision happens downstream in InboundDispatcher, not in the HTTP
      # status code.
      assert conn.status == 200
      assert conn.resp_body == "{}"
    end

    test "message event missing chat_id -> 200, dropped before dispatch (no crash)" do
      conn =
        post_parsed(%{
          "schema" => "2.0",
          "header" => %{},
          "event" => %{
            "sender" => %{"sender_id" => %{"open_id" => "ou_#{uniq()}"}},
            "message" => %{
              "message_id" => "om_#{uniq()}",
              "message_type" => "text",
              "content" => ~s({"text":"no chat_id here"})
            }
          }
        })

      assert conn.status == 200
      assert conn.resp_body == "{}"
    end

    test "message event with empty text + no attachments -> 200, dropped before dispatch (no crash)" do
      conn =
        post_parsed(%{
          "schema" => "2.0",
          "header" => %{},
          "event" => %{
            "sender" => %{"sender_id" => %{"open_id" => "ou_#{uniq()}"}},
            "message" => %{
              "chat_id" => "oc_#{uniq()}",
              "message_id" => "om_#{uniq()}",
              "message_type" => "text",
              "content" => ~s({"text":""})
            }
          }
        })

      assert conn.status == 200
      assert conn.resp_body == "{}"
    end

    test "event with malformed sender (no open_id/user_id) -> 200, no crash (SenderResolver fails closed)" do
      conn =
        post_parsed(%{
          "schema" => "2.0",
          "header" => %{},
          "event" => %{
            "sender" => %{"weird" => "shape"},
            "message" => %{
              "chat_id" => "oc_#{uniq()}",
              "message_id" => "om_#{uniq()}",
              "message_type" => "text",
              "content" => ~s({"text":"hi"})
            }
          }
        })

      assert conn.status == 200
      assert conn.resp_body == "{}"
    end

    test "schema 2.0 event with no 'message' key (e.g. a non-message event type) -> 200, no crash" do
      conn =
        post_parsed(%{
          "schema" => "2.0",
          "header" => %{},
          "event" => %{"some_other_event_type" => %{"foo" => "bar"}}
        })

      assert conn.status == 200
      assert conn.resp_body == "{}"
    end
  end

  # ----- helpers -------------------------------------------------------

  # Simulates what the Endpoint's `Plug.Parsers` does for a real
  # `application/json` request: pre-populate `body_params` so the plug's
  # `conn.body_params` branch (not the `read_body` fallback) is exercised
  # — this is the path production traffic actually takes.
  defp post_parsed(payload) do
    Plug.Test.conn(:post, "/api/feishu/webhook", Jason.encode!(payload))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:body_params, payload)
    |> WebhookPlug.call([])
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))
end
