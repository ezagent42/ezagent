defmodule Ezagent.Behavior.CurlAgentMigrationParityTest do
  @moduledoc """
  Phase 2-g r3 migration parity test for `Ezagent.Behavior.CurlAgent`.

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

  alias Ezagent.Behavior.CurlAgent

  describe ":reset_conversation parity" do
    test "produces effects that, when applied, clear conversation + last_error" do
      {:ok, base} = CurlAgent.create(%{})

      slice =
        base
        |> Map.put(:conversation, [%{role: "user", content: "hi"}])
        |> Map.put(:last_error, {:http, 429, "rate limited"})

      assert {:ok, %{ok: true}, effects} =
               CurlAgent.handle_reset_conversation(%{}, %{})

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)
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

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)
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
      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)
      refute Map.has_key?(new_state, :owner_uri)
    end
  end

  describe ":receive parity" do
    test "self-message returns identity tuple with no effects (loop guard)" do
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

    test "missing api_key emits operator-help reply dispatch + sets last_error" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_x")
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

      msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://team-alpha/user/alice"),
          %{text: "hi"}
        )

      ctx = %{
        read: fn
          :provider, _ -> "openai"
          :api_url, _ -> "https://api.openai.com/v1/chat/completions"
          :model, _ -> "gpt-4o"
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

      assert {:set, :last_error, {:no_api_key, "openai"}} in effects

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, cmd}] = dispatches
      assert cmd.action == :send
      assert %Ezagent.Message{body: %{text: text}} = cmd.args.message
      assert text =~ "no API key for provider `openai`"
    end
  end

  describe "macro-derived legacy callbacks (backwards-compat parity)" do
    test "actions/0 matches the legacy set" do
      assert MapSet.new(CurlAgent.actions()) ==
               MapSet.new([:receive, :reset_conversation, :configure])
    end

    test "interface/0 keys cover all 3 actions with descriptions" do
      iface = CurlAgent.interface()

      for action <- [:receive, :reset_conversation, :configure] do
        assert Map.has_key?(iface, action)
        assert is_binary(iface[action][:description])
      end
    end

    test "required_caps/0 preserves :curl_agent kind axis" do
      caps = CurlAgent.required_caps()

      for action <- [:receive, :reset_conversation, :configure] do
        assert %Ezagent.Capability{kind: :curl_agent} = caps[action]
      end
    end

    test "reads_siblings/0 returns [:api_keys]" do
      assert CurlAgent.reads_siblings() == [:api_keys]
    end
  end
end
