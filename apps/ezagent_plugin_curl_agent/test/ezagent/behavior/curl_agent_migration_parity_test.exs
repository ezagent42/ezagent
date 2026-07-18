defmodule Ezagent.ActionSet.CurlAgentMigrationParityTest do
  @moduledoc """
  Phase 2-g r3 migration parity test for `Ezagent.ActionSet.CurlAgent`.

  Asserts the new-contract Behavior preserves the OUTCOMES the
  legacy `invoke/4`-based implementation provided:

  - `:reset_conversation` clears `conversation` and `last_error`
  - `:configure` updates provider/api_url/model/system_prompt/max_history
  - `:receive` from self is a no-op (loop guard)
  - Missing api_key surfaces a chat-visible operator-help reply
  - The full action set is unchanged
  - Sibling slice declaration `[:api_keys]` preserved
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.CurlAgent

  describe ":reset_conversation parity" do
    test "produces effects that, when applied, clear conversation + last_error" do
      {:ok, base} = CurlAgent.create(%{})

      slice =
        base
        |> Map.put(:conversation, [%{role: "user", content: "hi"}])
        |> Map.put(:last_error, {:http, 429, "rate limited"})

      assert {:ok, %{ok: true}, effects} =
               CurlAgent.handle_reset_conversation(%{}, %{})

      assert {:ok, %{state: new_state}} = Ezagent.ActionSet.apply_effects(effects, slice)
      assert new_state.conversation == []
      assert new_state.last_error == nil
    end
  end

  describe ":configure parity" do
    test "mutates all 5 configurable fields through apply_effects" do
      {:ok, slice} = CurlAgent.create(%{})
      ctx = %{read: fn k, d -> Map.get(slice, k, d) end}

      args = %{
        provider: "openai",
        api_url: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o",
        system_prompt: "concise",
        max_history: 5
      }

      assert {:ok, %{ok: true}, effects} = CurlAgent.handle_configure(args, ctx)

      assert {:ok, %{state: new_state}} = Ezagent.ActionSet.apply_effects(effects, slice)
      assert new_state.provider == "openai"
      assert new_state.model == "gpt-4o"
      assert new_state.system_prompt == "concise"
      assert new_state.max_history == 5
    end

    test "stray owner_uri (legacy field) does NOT leak into the slice" do
      {:ok, slice} = CurlAgent.create(%{})
      ctx = %{read: fn k, d -> Map.get(slice, k, d) end}

      args = %{
        provider: "openai",
        # Legacy field that no longer exists on the slice; must be silently
        # ignored (the handler only emits :set effects for the 5 known
        # config fields).
        owner_uri: Ezagent.URI.new!("entity://team-alpha/user/attacker")
      }

      assert {:ok, %{ok: true}, effects} = CurlAgent.handle_configure(args, ctx)
      assert {:ok, %{state: new_state}} = Ezagent.ActionSet.apply_effects(effects, slice)
      refute Map.has_key?(new_state, :owner_uri)
    end
  end

  # PR-6 (im/session/agent decomposition §3.5) — `:receive` parity is now
  # `:sync_result` parity: the post-HTTP persist step owns the durable
  # conversation/error mutation + the session reply (the in-process HTTP
  # round-trip moved to the curl `:in_process_sync` adapter).
  describe ":sync_result parity" do
    test "missing api_key emits a structured error reply + sets last_error" do
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
        result: {:error, {:no_api_key, "openai"}},
        source_session: session_uri,
        user_text: "hi"
      }

      assert {:ok, %{ok: false, error: :no_api_key}, effects} =
               CurlAgent.handle_sync_result(args, ctx)

      assert {:set, :last_error, {:no_api_key, "openai"}} in effects

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, cmd}] = dispatches
      assert cmd.action == :send
      # G5 source 2 (#1456) — the no-key error reply is now a STRUCTURED
      # ErrorSignal body (pure reason data under `error` + a uniform minimal
      # fallback `text`), not hand-written prose. The world side renders the
      # per-viewer operator-help card from this payload.
      assert %Ezagent.Message{body: body} = cmd.args.message
      assert body.error == %{"reason" => ["no_api_key", "openai"]}
      assert body.text == "[agent error] no_api_key"
      assert body.attachments == []
    end

    test "success path appends user+assistant turns through apply_effects" do
      {:ok, base} = CurlAgent.create(%{})
      ctx = %{read: fn k, d -> Map.get(base, k, d) end, self_uri: nil, caller: nil}

      usage = %{prompt: 1, completion: 2, total: 3}

      args = %{
        result: {:ok, %{content: "world", usage: usage}},
        source_session: nil,
        user_text: "hello"
      }

      assert {:ok, %{ok: true, tokens: 3}, effects} = CurlAgent.handle_sync_result(args, ctx)
      assert {:ok, %{state: new_state}} = Ezagent.ActionSet.apply_effects(effects, base)

      assert new_state.conversation == [
               %{role: "user", content: "hello"},
               %{role: "assistant", content: "world"}
             ]

      assert new_state.last_tokens == usage
      assert new_state.last_error == nil
    end
  end

  describe "macro-derived legacy callbacks (backwards-compat parity)" do
    # PR-6 — `:receive` replaced by `:sync_result`.
    test "actions/0 matches the PR-6 set" do
      assert MapSet.new(CurlAgent.actions()) ==
               MapSet.new([:sync_result, :reset_conversation, :configure])
    end

    test "interface/0 keys cover all 3 actions with descriptions" do
      iface = CurlAgent.interface()

      for action <- [:sync_result, :reset_conversation, :configure] do
        assert Map.has_key?(iface, action)
        assert is_binary(iface[action][:description])
      end
    end

    # PR-6 — reparented onto Entity.Agent → `:agent` cap axis (was `:curl_agent`).
    test "required_caps/0 uses the :agent kind axis (PR-6 reparent)" do
      caps = CurlAgent.required_caps()

      for action <- [:sync_result, :reset_conversation, :configure] do
        assert %Ezagent.Capability{kind: :agent} = caps[action]
      end
    end

    test "reads_siblings/0 returns [:api_keys]" do
      assert CurlAgent.reads_siblings() == [:api_keys]
    end
  end
end
