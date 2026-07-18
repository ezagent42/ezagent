defmodule Ezagent.ActionSet.CurlAgentTest do
  @moduledoc """
  Phase 2-g r3 migration: tests exercise the new-contract
  `handle_<action>/2` + effects vocabulary instead of `invoke/4`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.CurlAgent

  describe "macro-derived metadata" do
    # PR-6 (im/session/agent decomposition §3.5) — `:receive` is GONE
    # (receive flows through `agent.receive` → curl `:in_process_sync`
    # adapter); `:sync_result` (the post-HTTP persist step) replaces it.
    test "exactly the 3 documented actions (PR-6: receive→sync_result)" do
      assert MapSet.new(CurlAgent.actions()) ==
               MapSet.new([:sync_result, :reset_conversation, :configure])

      assert Map.keys(CurlAgent.interface()) |> Enum.sort() ==
               [:configure, :reset_conversation, :sync_result]
    end

    test "state_slice is :curl_agent" do
      assert CurlAgent.state_slice() == :curl_agent
    end

    test "every action has a description" do
      iface = CurlAgent.interface()

      for {action, spec} <- iface do
        assert is_binary(spec[:description]),
               "action #{inspect(action)} is missing a description"
      end
    end

    # PR-6 — the reparented Behavior lives on `Entity.Agent` (type_name
    # :agent), so its cap subjects key on the `:agent` axis (was
    # `:curl_agent` on the standalone Kind; the cap-axis migration for
    # EXISTING agents is PR-7).
    test "required_caps/0 uses :agent kind axis (PR-6 reparent onto Entity.Agent)" do
      caps = CurlAgent.required_caps()
      assert caps.sync_result.kind == :agent
      assert caps.reset_conversation.kind == :agent
      assert caps.configure.kind == :agent
    end

    test "reads_siblings/0 declares [:api_keys] (post ApiKeys-to-Agent flip)" do
      assert CurlAgent.reads_siblings() == [:api_keys]
    end

    test "Behavior.new_style?/1 detects the new contract" do
      assert Ezagent.ActionSet.new_style?(CurlAgent)
    end
  end

  # Phase B (2026-05-29): `init_slice/1` → `create/1`. `create/1` returns
  # `{:ok, state}` — the PERSISTENT container (no transients here). Same
  # field assertions, new accessor (`create` tuple instead of the old
  # flat `init_slice` map).
  describe "create/1" do
    test "defaults to deepseek/chat with empty conversation" do
      assert {:ok, state} = CurlAgent.create(%{})

      assert state.provider == "deepseek"
      assert state.api_url == "https://api.deepseek.com/chat/completions"
      assert state.model == "deepseek-chat"
      assert state.max_history == 20
      assert state.conversation == []
      assert state.last_error == nil
    end

    test "accepts per-instance overrides (Allen 2026-05-26 — owner_uri gone)" do
      assert {:ok, state} =
               CurlAgent.create(%{
                 provider: "openai",
                 api_url: "https://api.openai.com/v1/chat/completions",
                 model: "gpt-4o-mini",
                 system_prompt: "You are pirate.",
                 max_history: 10
               })

      assert state.provider == "openai"
      assert state.model == "gpt-4o-mini"
      assert state.system_prompt == "You are pirate."
      assert state.max_history == 10
      refute Map.has_key?(state, :owner_uri)
    end
  end

  describe "handle_reset_conversation/2" do
    test "emits :set effects clearing conversation + last_error" do
      assert {:ok, %{ok: true}, effects} =
               CurlAgent.handle_reset_conversation(%{}, %{})

      assert {:set, :conversation, []} in effects
      assert {:set, :last_error, nil} in effects
    end
  end

  describe "handle_configure/2" do
    test "emits :set effects for provider/model/system_prompt/max_history" do
      ctx = %{
        read: fn
          :provider, _ -> "deepseek"
          :api_url, _ -> "https://api.deepseek.com/chat/completions"
          :model, _ -> "deepseek-chat"
          :system_prompt, _ -> nil
          :max_history, _ -> 20
          _, d -> d
        end
      }

      args = %{
        provider: "openai",
        api_url: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o",
        system_prompt: "concise",
        max_history: 5
      }

      assert {:ok, %{ok: true}, effects} = CurlAgent.handle_configure(args, ctx)

      assert {:set, :provider, "openai"} in effects
      assert {:set, :api_url, "https://api.openai.com/v1/chat/completions"} in effects
      assert {:set, :model, "gpt-4o"} in effects
      assert {:set, :system_prompt, "concise"} in effects
      assert {:set, :max_history, 5} in effects
    end

    test "preserves existing values when args omit them" do
      ctx = %{
        read: fn
          :provider, _ -> "openai"
          :api_url, _ -> "https://api.openai.com/v1"
          :model, _ -> "gpt-4"
          :system_prompt, _ -> "preserved"
          :max_history, _ -> 30
          _, d -> d
        end
      }

      assert {:ok, %{ok: true}, effects} = CurlAgent.handle_configure(%{}, ctx)

      assert {:set, :provider, "openai"} in effects
      assert {:set, :model, "gpt-4"} in effects
      assert {:set, :system_prompt, "preserved"} in effects
      assert {:set, :max_history, 30} in effects
    end
  end

  # PR-6 (im/session/agent decomposition §3.5 / §9 tension 3) — the
  # post-HTTP persist step. `agent.receive` re-dispatches the curl adapter's
  # `:in_process_sync` result here; this Behavior owns the durable
  # conversation/token/error mutation + the session reply.
  describe "handle_sync_result/2 — success" do
    test "appends user + assistant turns, sets tokens, replies into the session" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_ok")
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

      usage = %{prompt: 3, completion: 5, total: 8}

      ctx = %{
        read: fn
          :max_history, _ ->
            20

          :conversation, _ ->
            [%{role: "user", content: "earlier"}, %{role: "assistant", content: "ok"}]

          _, d ->
            d
        end,
        self_uri: agent_uri,
        caller: session_uri
      }

      args = %{
        result: {:ok, %{content: "hello back", usage: usage}},
        source_session: session_uri,
        user_text: "hello"
      }

      assert {:ok, %{ok: true, tokens: 8}, effects} =
               CurlAgent.handle_sync_result(args, ctx)

      assert {:set, :last_tokens, ^usage} =
               Enum.find(effects, &match?({:set, :last_tokens, _}, &1))

      assert {:set, :last_error, nil} in effects

      {:set, :conversation, conv} = Enum.find(effects, &match?({:set, :conversation, _}, &1))
      # The new user turn + the assistant reply are appended after the history.
      assert List.last(conv) == %{role: "assistant", content: "hello back"}
      assert Enum.at(conv, -2) == %{role: "user", content: "hello"}

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] = dispatches
      assert cmd.action == :send
      assert %Ezagent.Message{body: %{text: "hello back"}} = cmd.args.message
    end
  end

  describe "handle_sync_result/2 — no API key" do
    test "appends only the user turn, sets last_error + dispatches a STRUCTURED error reply" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_x")
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

      ctx = %{
        read: fn
          :max_history, _ -> 20
          :conversation, _ -> []
          _, d -> d
        end,
        self_uri: agent_uri,
        caller: session_uri
      }

      args = %{
        result: {:error, {:no_api_key, "deepseek"}},
        source_session: session_uri,
        user_text: "hi"
      }

      assert {:ok, %{ok: false, error: :no_api_key}, effects} =
               CurlAgent.handle_sync_result(args, ctx)

      assert {:set, :last_error, {:no_api_key, "deepseek"}} in effects

      {:set, :conversation, conv} = Enum.find(effects, &match?({:set, :conversation, _}, &1))
      assert conv == [%{role: "user", content: "hi"}]

      # G5 source 2 — the reply carries the STRUCTURED error payload (pure
      # reason data; the world side matches + renders per viewer), plus the
      # uniform minimal fallback text for degraded surfaces. No hand-written
      # prose.
      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] = dispatches
      assert cmd.action == :send
      assert %Ezagent.Message{body: body} = cmd.args.message
      assert body.error == %{"reason" => ["no_api_key", "deepseek"]}
      assert body.text == "[agent error] no_api_key"
      assert body.attachments == []
    end
  end

  describe "handle_sync_result/2 — upstream error" do
    test "sets last_error + dispatches a structured error reply (no prose)" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_x")
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

      ctx = %{
        read: fn
          :max_history, _ -> 20
          :conversation, _ -> []
          _, d -> d
        end,
        self_uri: agent_uri,
        caller: session_uri
      }

      args = %{
        result: {:error, {:http, 502, "bad gateway"}},
        source_session: session_uri,
        user_text: "hi"
      }

      assert {:ok, %{ok: false, error: :http_error}, effects} =
               CurlAgent.handle_sync_result(args, ctx)

      assert {:set, :last_error, {:http, 502, "bad gateway"}} in effects

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] = dispatches
      assert %Ezagent.Message{body: body} = cmd.args.message
      assert body.error == %{"reason" => ["http", 502, "bad gateway"]}
      assert body.text == "[agent error] http"
    end
  end

  describe "data_owner/1" do
    test "returns :any for :any" do
      assert CurlAgent.data_owner(:any) == :any
    end

    test "returns :no_owner for non-entity-agent" do
      assert CurlAgent.data_owner(Ezagent.URI.new!("session://x/y/z")) == :no_owner
    end
  end
end
