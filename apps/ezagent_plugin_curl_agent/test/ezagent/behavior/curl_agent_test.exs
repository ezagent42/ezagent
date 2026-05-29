defmodule Ezagent.Behavior.CurlAgentTest do
  @moduledoc """
  Phase 2-g r3 migration: tests exercise the new-contract
  `handle_<action>/2` + effects vocabulary instead of `invoke/4`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.CurlAgent

  describe "macro-derived metadata" do
    test "exactly the 3 documented actions" do
      assert MapSet.new(CurlAgent.actions()) ==
               MapSet.new([:receive, :reset_conversation, :configure])

      assert Map.keys(CurlAgent.interface()) |> Enum.sort() ==
               [:configure, :receive, :reset_conversation]
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

    test "required_caps/0 uses :curl_agent kind axis (not auto-derived :any)" do
      caps = CurlAgent.required_caps()
      assert caps.receive.kind == :curl_agent
      assert caps.reset_conversation.kind == :curl_agent
      assert caps.configure.kind == :curl_agent
    end

    test "reads_siblings/0 declares [:api_keys] (post ApiKeys-to-Agent flip)" do
      assert CurlAgent.reads_siblings() == [:api_keys]
    end

    test "Behavior.new_style?/1 detects the new contract" do
      assert Ezagent.Behavior.new_style?(CurlAgent)
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

  describe "handle_receive/2 — loop safety" do
    test "self-message returns identity result tuple with no effects" do
      agent_uri = URI.parse("entity://agent/team-alpha/curl_self")
      msg = Ezagent.Message.new(agent_uri, %{text: "self-loop"})

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: URI.parse("session://default/team-alpha/main"),
        siblings: %{api_keys: %{keys: %{}}}
      }

      assert {:ok, %{ok: true, ignored: :self_message}, []} =
               CurlAgent.handle_receive(%{message: msg}, ctx)
    end
  end

  describe "handle_receive/2 — no API key" do
    test "emits :set last_error + dispatches operator help reply" do
      agent_uri = URI.parse("entity://agent/team-alpha/curl_x")
      session_uri = URI.parse("session://default/team-alpha/main")
      sender_uri = URI.parse("entity://user/team-alpha/alice")
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
        # No keys for "deepseek" → no_api_key path.
        siblings: %{api_keys: %{keys: %{}}}
      }

      assert {:ok, %{ok: false, error: :no_api_key}, effects} =
               CurlAgent.handle_receive(%{message: msg}, ctx)

      assert {:set, :last_error, {:no_api_key, "deepseek"}} in effects

      # Reply dispatch present
      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] = dispatches
      assert cmd.action == :send
      assert %Ezagent.Message{body: %{text: text}} = cmd.args.message
      assert text =~ "no API key for provider `deepseek`"
    end
  end

  describe "data_owner/1" do
    test "returns :any for :any" do
      assert CurlAgent.data_owner(:any) == :any
    end

    test "returns :no_owner for non-entity-agent" do
      assert CurlAgent.data_owner(URI.parse("session://x/y/z")) == :no_owner
    end
  end
end
