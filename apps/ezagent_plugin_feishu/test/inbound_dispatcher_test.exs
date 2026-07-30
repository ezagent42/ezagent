defmodule EzagentPluginFeishu.InboundDispatcherTest do
  @moduledoc """
  P1 test-supplement (security triage) — `EzagentPluginFeishu.InboundDispatcher`
  is the single entry point shared by `WebhookPlug` and `WsClient` (both
  inbound Feishu transports). It had ZERO direct tests before this PR —
  `InboundDispatcher.dispatch/1` itself was never called anywhere in the
  test suite (only its dependencies, `SenderResolver` and
  `InboundChatLookup`, were tested in isolation).

  These tests exercise `dispatch/1`'s own orchestration/fail-closed logic:
  malformed sender, pending (unbound) sender, no chat binding, and
  ambiguous chat binding. Each of these returns BEFORE
  `do_dispatch/6`/`dispatch_to_session/6` — the branch that needs a LIVE
  Session Kind actor + real cap grants — so they're covered here without
  standing up that infra (an honest-coverage boundary, not a shortcut:
  the live-session happy path stays covered by the existing e2e suite's
  `InboundChatLookup`/`SenderResolver` chain tests plus (partially) the
  `category_04_feishu_test.exs` scenarios).

  `Client` (Feishu HTTP client) is alive in test env with no credentials
  configured (`credentials_not_configured`), so every `react`/`send_text`
  call this module makes fires-and-forgets safely without hitting the
  network — see `client_test.exs` for the direct contract pin.

  ## FINDING — read this before touching `origin:` anywhere in this file

  The "live session" `describe` block below pins a real, reproducible
  finding: the HTTP webhook transport's `origin: nil` (see
  `webhook_plug.ex`) makes EVERY webhook-sourced session dispatch fail
  closed with `{:error, :unstamped_origin}` at the umbrella's universal
  pre-delivery policy gate. That gate is, in effect, the ONLY thing
  currently preventing the webhook's missing signature verification
  (pinned separately in `webhook_plug_test.exs`) from being exploitable
  — an unauthenticated caller who knows a bound `open_id` + `chat_id`
  cannot presently make it all the way to a session send. The two gaps
  are one interacting pair, not two independent bugs, and the "obvious"
  one-line fix (stamp `:authenticated_external` in `WebhookPlug`) would
  REMOVE that protection and open real impersonation — see the detailed
  comment on the first test in that block. Pinned, not fixed, per the
  task's STOP rule; full write-up in the PR body.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentPluginFeishu.{InboundDispatcher, UserBinding}

  describe "dispatch/1 — malformed sender (fail-closed before any lookup)" do
    test "sender with neither open_id nor user_id -> {:error, :bad_sender}, never touches chat lookup" do
      assert {:error, :bad_sender} =
               InboundDispatcher.dispatch(
                 chat_id: "oc_#{uniq()}",
                 message_id: "om_#{uniq()}",
                 sender: %{"nonsense" => true},
                 body: %{text: "hi", attachments: []},
                 origin: nil
               )
    end
  end

  describe "dispatch/1 — unbound (pending) sender" do
    test "unbound open_id -> :ok (no impersonation), no session dispatch attempted" do
      chat_id = "oc_#{uniq()}"
      session_uri = "session://system/default/pending_test_#{uniq()}"
      # Even with a VALID chat binding present, an unbound sender must
      # never reach dispatch_to_session/6 — SenderResolver's :pending
      # short-circuits dispatch/1 before InboundChatLookup is consulted.
      insert_binding_row(session_uri, chat_id)

      open_id = "ou_dispatcher_pending_#{uniq()}"

      assert :ok =
               InboundDispatcher.dispatch(
                 chat_id: chat_id,
                 message_id: "om_#{uniq()}",
                 sender: %{"sender_id" => %{"open_id" => open_id}},
                 body: %{text: "hello", attachments: []},
                 origin: nil
               )
    end
  end

  describe "dispatch/1 — bound sender, chat routing failures (fail-closed)" do
    test "bound sender + chat_id with NO binding -> {:error, :no_chat_binding}" do
      user_uri = Ezagent.URI.new!("entity://system/user/dispatcher_test_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
      open_id = "ou_dispatcher_nobind_#{uniq()}"

      {:ok, _} =
        UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      assert {:error, :no_chat_binding} =
               InboundDispatcher.dispatch(
                 chat_id: "oc_never_bound_#{uniq()}",
                 message_id: "om_#{uniq()}",
                 sender: %{"sender_id" => %{"open_id" => open_id}},
                 body: %{text: "hello", attachments: []},
                 origin: nil
               )
    end

    test "bound sender + chat_id bound to 2+ sessions with no disambiguating mention -> {:error, :ambiguous_chat_binding}" do
      user_uri = Ezagent.URI.new!("entity://system/user/dispatcher_ambig_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
      open_id = "ou_dispatcher_ambig_#{uniq()}"

      {:ok, _} =
        UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      chat_id = "oc_ambig_#{uniq()}"
      insert_binding_row("session://system/default/ambig_a_#{uniq()}", chat_id)
      insert_binding_row("session://system/default/ambig_b_#{uniq()}", chat_id)

      assert {:error, :ambiguous_chat_binding} =
               InboundDispatcher.dispatch(
                 chat_id: chat_id,
                 message_id: "om_#{uniq()}",
                 sender: %{"sender_id" => %{"open_id" => open_id}},
                 body: %{text: "hello, which session?", attachments: []},
                 origin: nil
               )
    end
  end

  describe "dispatch/1 — single valid binding, target session never durably created" do
    test "stale/dangling binding (session row exists, Kind snapshot never created) -> {:error, :not_created}, error surfaced back to chat" do
      # A single unambiguous chat<->session binding is exactly the "happy
      # path" shape for InboundChatLookup, but the bound session_uri was
      # never actually created via the Session Kind lifecycle (no
      # KindSnapshot row) — e.g. an operator manually rebound a chat to a
      # session_uri that was later destroyed, or a binding row surviving
      # a partial rollback. `Ezagent.SpawnRegistry.ensure_live/1` REFUSES
      # to materialize an unowned Kind for a URI with no durable snapshot
      # (see its @doc: "never silently creates a fresh unowned one") —
      # exercises `do_dispatch/6`'s generic `{:error, reason}` branch and
      # `send_dispatch_error/4`'s THUMBSDOWN text-back path, without
      # needing a live Session actor + cap grants (the expensive
      # happy-path setup left out of this PR's honest-coverage scope —
      # see moduledoc).
      user_uri = Ezagent.URI.new!("entity://system/user/dispatcher_stale_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
      open_id = "ou_dispatcher_stale_#{uniq()}"

      {:ok, _} =
        UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      chat_id = "oc_stale_#{uniq()}"
      insert_binding_row("session://system/default/never_created_#{uniq()}", chat_id)

      assert {:error, :not_created} =
               InboundDispatcher.dispatch(
                 chat_id: chat_id,
                 message_id: "om_#{uniq()}",
                 sender: %{"sender_id" => %{"open_id" => open_id}},
                 body: %{text: "hello, is anyone there?", attachments: []},
                 origin: nil
               )
    end
  end

  describe "dispatch/1 — live session — FINDING pinned, see moduledoc + PR body" do
    test "bound sender + single valid binding + live session -> {:error, :unstamped_origin} (webhook-sourced dispatch is ALWAYS REJECTED)" do
      # Unlike the other describe blocks above (deliberately scoped to
      # dispatch/1's early fail-closed branches), this test pays the cost
      # of standing up a genuinely live `Ezagent.Entity.Session` Kind so
      # `do_dispatch/6` -> `dispatch_to_session/6` -> `Invocation.dispatch/1`
      # runs for real. Pattern copied from the existing PR-EM-3 acceptance
      # suite (`external_mirror_test.exs`'s `spawn_owner_and_session/2`) —
      # a plain core Session Kind spawn is synchronous and cheap (no
      # external-agent flavor resolution / `wait_for_kind_registry`
      # polling, unlike the protocol_api ChatCompletionsPlug agent-spawn
      # path left skipped in that app's test suite).
      #
      # FINDING (pinned by this test, NOT fixed here per the task's STOP
      # rule — and NOT to be "fixed" the obvious way either, see below):
      # `EzagentPluginFeishu.WebhookPlug`'s `handle_event/2` calls
      # `InboundDispatcher.dispatch(... origin: nil)` (see webhook_plug.ex).
      # `origin` flows UNCHANGED into `%Ezagent.Invocation{origin: origin}`
      # in `InboundDispatcher.dispatch_to_session/6`. The umbrella's
      # universal pre-delivery policy gate
      # (`Ezagent.Kind.Adapters.DispatchPolicyAdapter`, wired at core boot
      # — NOT test-only/feature-flagged) runs
      # `Ezagent.DispatchOrigin.validate/2` before every dispatch;
      # `validate(nil, _ctx)` hits the catch-all
      # `def validate(_origin, _ctx), do: {:error, :unstamped_origin}`
      # clause (only `:trusted_internal` and `:authenticated_external` are
      # accepted). Net effect: every webhook-sourced message dispatch
      # fails closed, surfaced to the human as "❌ Ezagent: dispatch 失败:
      # :unstamped_origin" + a THUMBSDOWN react — the HTTP webhook
      # transport cannot currently deliver ANY message into a session.
      #
      # WHY THE OBVIOUS FIX IS WRONG — read this before touching
      # WebhookPlug: `Ezagent.DispatchOrigin`'s own moduledoc defines
      # `:authenticated_external` as "`ctx.authenticated_principal` was
      # fixed from an authenticated session or bearer AT THE TRANSPORT
      # EDGE." The webhook authenticates NOTHING (see webhook_plug.ex's
      # own "unauthenticated at the network level" admission + this
      # app's `webhook_plug_test.exs`) — it trusts the payload's
      # `sender.open_id` outright. So having `WebhookPlug` simply stamp
      # `origin: :authenticated_external` to "fix" this would be a LIE
      # to a security-load-bearing gate, and would open real
      # impersonation: the companion test below shows that with
      # `:authenticated_external`, dispatch clears the origin gate and
      # proceeds to the cap check — for a session the bound user legitimately
      # has membership+caps on, it would SUCCEED. Combined with the
      # missing signature verification, an unauthenticated caller who
      # knows/guesses a bound `open_id` + a bound `chat_id` could send
      # AS that user. **These two findings are one interacting pair, not
      # two independent bugs**: the missing signature verification is
      # NOT currently exploitable via the HTTP webhook PRECISELY BECAUSE
      # `unstamped_origin` fails every dispatch closed first. The origin
      # gate is accidentally load-bearing. The correct remediation order
      # (a product decision, not this test-only PR's call) is signature
      # verification FIRST, only THEN stamp `:authenticated_external` —
      # never the reverse. See PR body for the full write-up.
      user_uri = Ezagent.URI.new!("entity://system/user/dispatcher_live_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
      open_id = "ou_dispatcher_live_#{uniq()}"

      {:ok, _} =
        UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      session_uri = Ezagent.URI.new!("session://system/default/live_#{uniq()}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          owner_uri: user_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      # Same workspace-binding step the PR-EM-3 suite performs — dispatch
      # step 5.6's cap check resolves `workspace_of(session_uri)`, which
      # needs this registration to return a real workspace URI.
      case Ezagent.Capability.workspace_of(session_uri) do
        %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
        :any -> :ok
      end

      chat_id = "oc_live_#{uniq()}"
      insert_binding_row(URI.to_string(session_uri), chat_id)

      assert {:error, :unstamped_origin} =
               InboundDispatcher.dispatch(
                 chat_id: chat_id,
                 message_id: "om_#{uniq()}",
                 sender: %{"sender_id" => %{"open_id" => open_id}},
                 body: %{text: "hello, real session!", attachments: []},
                 origin: nil
               )
    end

    test "SAME dispatch with WsClient's origin (:authenticated_external) clears the gate — NOT a recommendation to apply this to WebhookPlug, see comment" do
      # Companion to the test above: isolates the `origin` value as the
      # variable that flips `Ezagent.DispatchOrigin.validate/2`'s
      # outcome, backing the "why the obvious fix is wrong" note above
      # with a real, passing assertion rather than just prose. This is
      # NOT a product-code change, and — to be explicit — this test is
      # NOT a recommendation to make `WebhookPlug` pass this origin; see
      # the impersonation-surface warning in the test above.
      #
      # This does NOT assert `:ok`. A full session-membership + cap-grant
      # setup (the user must `session.join` before `session.send` is
      # authorized) is the SAME expensive, out-of-scope live-actor
      # archaeology this PR's moduledoc already declines for the
      # protocol_api ChatCompletionsPlug 202 test, for the same honest-
      # coverage reason. The load-bearing assertion is the `refute`
      # below (origin no longer rejected). The specific `:missing_cap`
      # value is documented as the CURRENT observed outcome, not
      # asserted as a stable contract — it comes from an unrelated authz
      # gate (this test's user was never joined to the session), so a
      # future change to that gate's error shape is not this test's
      # concern and shouldn't need to touch this file.
      user_uri = Ezagent.URI.new!("entity://system/user/dispatcher_live_ok_#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
      open_id = "ou_dispatcher_live_ok_#{uniq()}"

      {:ok, _} =
        UserBinding.bind(open_id, user_uri, Ezagent.URI.new!("entity://system/user/admin"))

      session_uri = Ezagent.URI.new!("session://system/default/live_ok_#{uniq()}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          owner_uri: user_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      case Ezagent.Capability.workspace_of(session_uri) do
        %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
        :any -> :ok
      end

      chat_id = "oc_live_ok_#{uniq()}"
      insert_binding_row(URI.to_string(session_uri), chat_id)

      result =
        InboundDispatcher.dispatch(
          chat_id: chat_id,
          message_id: "om_#{uniq()}",
          sender: %{"sender_id" => %{"open_id" => open_id}},
          body: %{text: "hello, real session via WS-shaped origin!", attachments: []},
          origin: :authenticated_external
        )

      # Load-bearing assertion: origin is no longer the rejection reason.
      refute match?({:error, :unstamped_origin}, result)
      # Non-load-bearing observation, current-behavior only (this test's
      # user was never `session.join`ed, so a DIFFERENT authz gate denies
      # it): as of this PR, `result` is `{:error, :missing_cap}`. Not
      # asserted — deliberately, so an unrelated future change to that
      # gate's error shape doesn't red this file.
      assert {:error, _not_unstamped_origin} = result
    end
  end

  # ----- helpers -------------------------------------------------------

  defp insert_binding_row(session_uri_str, chat_id) do
    session_uri = Ezagent.URI.new!(session_uri_str)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    attrs = %{
      id: BindingRow.row_id(session_uri, "feishu", chat_id),
      session_uri: session_uri_str,
      adapter_id: "feishu",
      target_id: chat_id,
      opts_json: "{}",
      bound_by: "entity://system/user/admin",
      bound_at: DateTime.utc_now(),
      workspace_uri: workspace_uri
    }

    {:ok, _row} = BindingRow.insert(attrs)
    :ok
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))
end
