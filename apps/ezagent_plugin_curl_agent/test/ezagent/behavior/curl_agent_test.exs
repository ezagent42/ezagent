defmodule Ezagent.Behavior.CurlAgentTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.CurlAgent

  describe "init_slice/1" do
    test "defaults to deepseek/chat with empty conversation" do
      slice = CurlAgent.init_slice(%{})

      assert slice.provider == "deepseek"
      assert slice.api_url == "https://api.deepseek.com/chat/completions"
      assert slice.model == "deepseek-chat"
      assert slice.max_history == 20
      assert slice.conversation == []
      assert slice.last_error == nil
    end

    test "accepts per-instance overrides" do
      slice =
        CurlAgent.init_slice(%{
          provider: "openai",
          api_url: "https://api.openai.com/v1/chat/completions",
          model: "gpt-4o-mini",
          system_prompt: "You are pirate.",
          max_history: 10,
          owner_uri: URI.parse("entity://user/team-alpha/alice")
        })

      assert slice.provider == "openai"
      assert slice.model == "gpt-4o-mini"
      assert slice.system_prompt == "You are pirate."
      assert slice.max_history == 10
      assert URI.to_string(slice.owner_uri) == "entity://user/team-alpha/alice"
    end
  end

  describe "actions/0 + interface/0" do
    test "exactly the 3 documented actions" do
      assert CurlAgent.actions() == [:receive, :reset_conversation, :configure]
      assert Map.keys(CurlAgent.interface()) |> Enum.sort() == [:configure, :receive, :reset_conversation]
    end

    test "state_slice is :curl_agent" do
      assert CurlAgent.state_slice() == :curl_agent
    end
  end

  describe "invoke(:reset_conversation, ...)" do
    test "clears conversation + last_error" do
      slice =
        CurlAgent.init_slice(%{})
        |> Map.put(:conversation, [%{role: "user", content: "hi"}])
        |> Map.put(:last_error, {:http, 429, "rate limited"})

      assert {:ok, new_slice, %{ok: true}} = CurlAgent.invoke(:reset_conversation, slice, %{}, %{})
      assert new_slice.conversation == []
      assert new_slice.last_error == nil
    end
  end

  describe "invoke(:configure, ...)" do
    test "mutates provider/model/system_prompt/max_history but never owner_uri" do
      slice = CurlAgent.init_slice(%{owner_uri: URI.parse("entity://user/system/admin")})

      args = %{
        provider: "openai",
        api_url: "https://api.openai.com/v1/chat/completions",
        model: "gpt-4o",
        system_prompt: "concise",
        max_history: 5,
        # Deliberately try to change owner via configure — must be ignored.
        owner_uri: URI.parse("entity://user/team-alpha/attacker")
      }

      assert {:ok, new_slice, %{ok: true}} = CurlAgent.invoke(:configure, slice, args, %{})
      assert new_slice.provider == "openai"
      assert new_slice.model == "gpt-4o"
      assert new_slice.system_prompt == "concise"
      assert new_slice.max_history == 5
      # owner_uri unchanged — design lock per moduledoc.
      assert URI.to_string(new_slice.owner_uri) == "entity://user/system/admin"
    end
  end
end
