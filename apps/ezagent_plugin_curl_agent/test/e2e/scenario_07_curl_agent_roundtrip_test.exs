defmodule EzagentPluginCurlAgent.E2E.Scenario07CurlAgentRoundtripTest do
  @moduledoc """
  Scenario 07 — curl agent: spawn → DeepSeek round-trip.

  Cross-reference: `docs/scenarios/07-curl-agent-deepseek/scenario.md`.

  ## What this proves

  The curl agent message roundtrip works via the new contract WITHOUT
  calling the real DeepSeek (or OpenAI-compatible) HTTP API. We
  exercise the production code path by:

  1. Asserting the new-contract `handle_<action>/2` shape for
     `:configure`, `:reset_conversation`, and `:receive`
  2. Asserting the effect grammar (`:set` for slice mutations,
     `:dispatch` for the reply fan-out)
  3. Asserting the API-key path — no-key case dispatches an
     operator-help message; loop-guard ignores self-messages

  Per `feedback_let_it_crash_no_workarounds`, this is the REAL
  contract test (not a mock-of-everything). The HTTP boundary is
  exercised by the existing `Ezagent.PluginCurlAgent.ApiClient` —
  the moduledoc + integration test there covers the wire shape;
  we don't re-test `:httpc`.

  ## ALLEN MANUAL action

  - DeepSeek real-key smoke: `docs/notes/curl-agent-walkthrough.md`
    (operator-driven; requires a valid `sk-deepseek-*` key seeded
    via `/admin/users/<U>/api-keys`)
  - LiveView screenshot per `feedback_esr_e2e_standards`: open
    `/admin/sessions/<uri>` showing the curl agent reply line.
  """

  use ExUnit.Case, async: true

  @moduletag scenario: "07-curl-agent-deepseek"
  @moduletag :e2e

  alias Ezagent.Behavior.CurlAgent

  # ---------------------------------------------------------------
  # 1. Greenfield contract surface
  # ---------------------------------------------------------------

  describe "macro-derived metadata (new contract)" do
    test "all three actions are declared via the action/3 macro" do
      assert MapSet.new(CurlAgent.__action_names__()) ==
               MapSet.new([:receive, :reset_conversation, :configure])
    end

    test "each action has args + returns + description from action/3" do
      i = CurlAgent.interface()
      assert i[:receive].modes == [:cast]
      assert i[:reset_conversation].modes == [:call]
      assert i[:configure].modes == [:call]

      for {_action, spec} <- i do
        assert is_binary(spec.description)
        assert spec.description != ""
      end
    end

    test "`:any` kind axis is NOT used (manually overridden to `:curl_agent`)" do
      caps = CurlAgent.required_caps()
      assert caps.receive.kind == :curl_agent
      assert caps.configure.kind == :curl_agent
      assert caps.reset_conversation.kind == :curl_agent
    end

    test "reads_siblings/0 declares [:api_keys] (post ApiKeys-to-Agent flip)" do
      assert CurlAgent.reads_siblings() == [:api_keys]
    end
  end

  # ---------------------------------------------------------------
  # 2. handle_configure/2 — `:set` effects update slice fields
  # ---------------------------------------------------------------

  describe "handle_configure/2 — `:set` effects" do
    test "produces :set effects for each of the 5 configurable fields" do
      {:ok, slice} = CurlAgent.create(%{})
      ctx = %{read: fn k, d -> Map.get(slice, k, d) end}

      args = %{
        provider: "openai",
        api_url: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o-mini",
        system_prompt: "be concise",
        max_history: 5
      }

      assert {:ok, %{ok: true}, effects} = CurlAgent.handle_configure(args, ctx)

      assert {:set, :provider, "openai"} in effects
      assert {:set, :api_url, "https://api.openai.com/v1/chat/completions"} in effects
      assert {:set, :model, "gpt-4o-mini"} in effects
      assert {:set, :system_prompt, "be concise"} in effects
      assert {:set, :max_history, 5} in effects
    end

    test "framework-applies the effects to produce the new slice" do
      {:ok, slice} = CurlAgent.create(%{})
      ctx = %{read: fn k, d -> Map.get(slice, k, d) end}

      args = %{
        provider: "openai",
        api_url: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o",
        system_prompt: "system",
        max_history: 10
      }

      assert {:ok, %{ok: true}, effects} = CurlAgent.handle_configure(args, ctx)
      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)

      assert new_state.provider == "openai"
      assert new_state.api_url == "https://api.openai.com/v1/chat/completions"
      assert new_state.model == "gpt-4o"
      assert new_state.system_prompt == "system"
      assert new_state.max_history == 10
    end
  end

  # ---------------------------------------------------------------
  # 3. handle_reset_conversation/2 — clears slice fields
  # ---------------------------------------------------------------

  describe "handle_reset_conversation/2" do
    test "clears conversation + last_error via :set effects" do
      assert {:ok, %{ok: true}, effects} =
               CurlAgent.handle_reset_conversation(%{}, %{})

      assert {:set, :conversation, []} in effects
      assert {:set, :last_error, nil} in effects
    end

    test "framework-applies the reset against a populated slice" do
      {:ok, base} = CurlAgent.create(%{})

      slice =
        base
        |> Map.put(:conversation, [
          %{role: "user", content: "hi"},
          %{role: "assistant", content: "hello"}
        ])
        |> Map.put(:last_error, {:http, 429, "rate limited"})

      assert {:ok, _, effects} = CurlAgent.handle_reset_conversation(%{}, %{})
      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)

      assert new_state.conversation == []
      assert new_state.last_error == nil
    end
  end

  # ---------------------------------------------------------------
  # 4. handle_receive/2 — loop guard + no-key path
  # ---------------------------------------------------------------

  describe "handle_receive/2 — loop guard" do
    test "self-message returns identity result tuple with NO effects" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_self")
      msg = Ezagent.Message.new(agent_uri, %{text: "self-loop"})

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: Ezagent.URI.new!("session://team-alpha/default/main"),
        siblings: %{api_keys: %{keys: %{}}}
      }

      assert {:ok, %{ok: true, ignored: :self_message}, []} =
               CurlAgent.handle_receive(%{message: msg}, ctx)
    end
  end

  describe "handle_receive/2 — missing API key path" do
    test "emits :set last_error + dispatches operator-help reply" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_x")
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")
      sender_uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
      msg = Ezagent.Message.new(sender_uri, %{text: "hi"})

      ctx = %{
        read: fn
          :provider, _ -> "deepseek"
          :api_url, _ -> "https://api.deepseek.com/chat/completions"
          :model, _ -> "deepseek-chat"
          :system_prompt, _ -> nil
          :max_history, _ -> 20
          :conversation, _ -> []
          _, d -> d
        end,
        self_uri: agent_uri,
        caller: session_uri,
        siblings: %{api_keys: %{keys: %{}}}
      }

      assert {:ok, %{ok: false, error: :no_api_key}, effects} =
               CurlAgent.handle_receive(%{message: msg}, ctx)

      # Slice records the no_api_key error.
      assert {:set, :last_error, {:no_api_key, "deepseek"}} in effects

      # Dispatch effect carries an operator-help message back to the
      # session — this is the user-visible "configure your key" hint.
      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] = dispatches
      assert cmd.action == :send
      assert cmd.target.scheme == "session"

      reply_text = cmd.args.message.body[:text]
      assert reply_text =~ "no API key for provider `deepseek`"
      assert reply_text =~ "api-keys"

      # Reply runs under the SystemPrincipal `system://chat-reply` —
      # per SPEC caps-cleanup-v1 §4.4 (the agent reply path's
      # canonical principal).
      assert is_struct(cmd.ctx.caps, MapSet)
    end
  end

  # ---------------------------------------------------------------
  # 5. data_owner/1 — caps-data-ownership contract
  # ---------------------------------------------------------------

  describe "data_owner/1" do
    test "returns :any for :any" do
      assert CurlAgent.data_owner(:any) == :any
    end

    test "returns :no_owner for a non-agent URI" do
      assert CurlAgent.data_owner(Ezagent.URI.new!("session://team-alpha/default/x")) == :no_owner
    end

    test "returns :no_owner when the api_keys slice has no creator_uri" do
      # The data_owner/1 for a live agent URI reads its :api_keys
      # slice; a freshly-spawned URI with no live Kind returns
      # :no_owner per the post-#326 caps-data-ownership contract.
      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_no_creator_#{System.unique_integer([:positive])}"
        )

      assert CurlAgent.data_owner(agent_uri) == :no_owner
    end
  end

  # ---------------------------------------------------------------
  # 6. ApiClient HTTP boundary contract (structural)
  # ---------------------------------------------------------------

  describe "Ezagent.PluginCurlAgent.ApiClient request shape" do
    test "module exists + chat_completion/1 is the public entry" do
      # Structural confirmation that the HTTP boundary lives here.
      # Real HTTP wire test requires a live server (operator-driven
      # smoke); the moduledoc + Bypass-able stub is the test surface
      # for that — out of scope for the fast e2e contract gate here.
      assert Code.ensure_loaded?(Ezagent.PluginCurlAgent.ApiClient)
      assert function_exported?(Ezagent.PluginCurlAgent.ApiClient, :chat_completion, 1)
    end
  end

  # ---------------------------------------------------------------
  # 7. ALLEN MANUAL — real DeepSeek roundtrip (skeleton)
  # ---------------------------------------------------------------

  describe "real DeepSeek full roundtrip (ALLEN MANUAL)" do
    @tag :requires_allen
    @tag :skip
    test "user with sk-deepseek-* key → curl agent → DeepSeek → reply lands on session" do
      # Per `docs/runbook/curl-agent-walkthrough.md` + scenario 07:
      #
      # 1. Login as a non-admin user U (`feedback_e2e_prefers_non_admin_user`).
      # 2. Open `/admin/users/<U>/api-keys`; add `provider: deepseek`,
      #    `key: sk-deepseek-...`.
      # 3. Open `/admin/templates`; create curl.agent template with
      #    `owner_uri = entity://system/user/<U>`.
      # 4. Open `/admin/routing`; add `{:always} -> ["curl-agent://..."]`.
      # 5. In `/admin/sessions/<uri>`, send: "DeepSeek say hello".
      # 6. agent-browser screenshots the LV showing the agent reply.
      #
      # No automation — manual operator step.
      flunk("@tag :requires_allen — operator-driven; do not run in CI")
    end
  end
end
