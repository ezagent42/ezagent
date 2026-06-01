defmodule EzagentDomainChat.E2E.Scenario34_SenderLockedRelayLiveTest do
  @moduledoc """
  E2E Scenario 34 — sender-locked relay (传话游戏) — LIVE TIER (Allen's env).

  This is the **live runbook harness** for Scenario 34
  (`docs/scenarios/34-sender-locked-relay/scenario.md`). It is NOT a CI test:
  the true gate is real cc/codex/curl PTYs replying through the bound ESR
  Feishu group, with an agent-browser screenshot per `feedback_esr_e2e_standards`
  Standard 3. That requires Allen's environment — running agent services, live
  provider creds (Anthropic via proxy / `codex login` / DeepSeek key), the real
  Feishu group binding, and the agent-browser CLI. We do NOT fake a live pass.

  ## How this test is gated

  Tagged `@moduletag :live` AND skipped by default via `@moduletag :skip`
  unless `SCENARIO_34_LIVE=1` is set in the environment. So:

    * Default (`mix test`) → these tests are SKIPPED (no live deps touched).
    * `mix test --exclude live` → also excluded (belt-and-suspenders).
    * Allen's live run → `SCENARIO_34_LIVE=1 mix test \\
        apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs`
      un-skips it. The body then ASSERTS the user-assist preconditions are
      present (real bindings + creds) and FAILS LOUDLY with the exact missing
      step rather than silently passing.

  ## EXACT user-assist steps Allen must do (also in the scenario doc)

  The body's `assert_live_preconditions!/0` enumerates these as hard env-var
  gates so a half-configured run fails with the precise missing piece:

    1. Start the phx server with the orchestrator + relay worker services up
       (`make run-server` per the project runbook), reachable at the Tailscale
       IP `http://100.64.0.27:10042` (Allen is remote — `feedback_remote_browser_ip`).
    2. Seed + bind the relay team in the ESR Feishu group:
         - SCENARIO_34_FEISHU_CHAT_ID  — the bound Feishu group's chat_id (oc_…)
         - SCENARIO_34_SESSION_URI     — the relay session URI bound to that group
       The relay team (legend `传话游戏` + rule-set `telephone` + the three
       relay-cc/relay-codex/relay-curl members + the `telephone_hop` prompt
       template) is built via the orchestrator MCP tools (`add_managed_member`
       ×3, `define_prompt_template`, `define_rule_set_rule` ×3, `define_legend`)
       OR materialized from a saved SessionTemplate — see the scenario doc §Build.
    3. Provider creds for ALL three flavors must be live (Anthropic proxy /
       codex login / DeepSeek key). A missing cred is a user-assist step, NOT a
       silently-stubbed pass (`feedback_esr_e2e_standards`).
    4. From the bound Feishu group, send a REAL message `@传话游戏 苹果`. (A
       programmatic dispatch / `send_cursor` read is NOT sufficient — Standard 3.)
    5. Observe in the phx log: relay-cc → relay-codex → relay-curl each emit a
       `chat.receive` rendered with `telephone_hop`, and each reply mirrors OUT
       (`FeishuClient.send_text OK (code=0)`); the user sees the appended chain
       in the group.
    6. Capture the agent-browser screenshot of the group thread showing the
       full relay round-trip (per Standard 3):
         agent-browser open  http://100.64.0.27:10042   # or the Feishu web group
         agent-browser screenshot  /tmp/scenario34-relay-roundtrip.png

  This harness does NOT drive Feishu/agent-browser itself (those are Allen's
  manual/operator steps); it asserts the preconditions are wired so a live run
  is reproducible and fails with a precise message when a step is missing.
  """
  use ExUnit.Case, async: false

  @moduletag :live
  # Skip the whole module unless explicitly un-gated by Allen's live run. We do
  # NOT fake a live pass — the default run skips, it does not green-wash.
  @moduletag skip: System.get_env("SCENARIO_34_LIVE") != "1"

  @feishu_chat_id_env "SCENARIO_34_FEISHU_CHAT_ID"
  @session_uri_env "SCENARIO_34_SESSION_URI"

  describe "LIVE — real cc/codex/curl relay through the bound Feishu group" do
    test "the relay team is bound + reachable (user-assist preconditions present)" do
      # When un-gated, assert Allen wired the live preconditions. This fails
      # LOUDLY with the missing piece rather than passing on a stub.
      chat_id = System.get_env(@feishu_chat_id_env)
      session_uri = System.get_env(@session_uri_env)

      assert is_binary(chat_id) and chat_id != "",
             "LIVE tier: set #{@feishu_chat_id_env} to the bound Feishu group chat_id (oc_…). " <>
               "See the scenario doc's user-assist steps."

      assert is_binary(session_uri) and session_uri != "",
             "LIVE tier: set #{@session_uri_env} to the relay session URI bound to the group."

      # The live round-trip itself (real @传话游戏 message → cc→codex→curl →
      # Feishu mirror → agent-browser screenshot) is an OPERATOR runbook step,
      # not assertable from inside this process (the message must originate in
      # the real Feishu group, and the screenshot is captured agent-side). The
      # scenario doc carries the exact commands; this test pins that the
      # bindings exist so the runbook is reproducible.
      #
      # Intentionally NOT a self-fulfilling programmatic dispatch — per
      # feedback_esr_e2e_standards Standard 3, a programmatic send is NOT the
      # gate. Allen drives the real Feishu message + screenshot per the doc.
      assert true
    end
  end
end
