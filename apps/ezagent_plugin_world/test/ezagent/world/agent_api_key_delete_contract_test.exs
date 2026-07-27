defmodule Ezagent.World.AgentApiKeyDeleteContractTest do
  @moduledoc """
  Regression contract for deleting an Agent API key from the World surface.

  The behavior assertion proves the server-side mutation removes exactly the
  selected provider. The bridge assertion pins the World event to the existing
  capability-gated Behavior action and requires a masked-state refresh.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.ApiKeys

  test "delete action removes only the selected provider and emits an audit-safe event" do
    ctx = %{
      read: fn
        :keys, _default -> %{"deepseek" => "sk-delete-me", "openai" => "sk-keep-me"}
      end
    }

    assert {:ok, %{ok: true, provider: "deepseek"}, effects} =
             ApiKeys.handle_delete_api_key(%{provider: "deepseek"}, ctx)

    assert {:set, :keys, %{"openai" => "sk-keep-me"}} in effects

    assert {:emit, :api_key_deleted, %{provider: "deepseek", at: %DateTime{}}} =
             Enum.find(effects, &match?({:emit, :api_key_deleted, _}, &1))
  end

  test "delete action rejects an incomplete provider payload" do
    assert {:error, {:bad_args, _message, %{}}} =
             ApiKeys.handle_delete_api_key(%{}, %{read: fn _, default -> default end})
  end

  test "World delete bridge dispatches the capability-gated action and refreshes masked state" do
    world_live =
      __DIR__
      |> Path.join("../../../lib/ezagent_plugin_world/world_live.ex")
      |> File.read!()

    delete_helper =
      world_live
      |> String.split("defp dispatch_api_key_delete", parts: 2)
      |> List.last()
      |> String.split("defp refresh_api_keys_state", parts: 2)
      |> List.first()

    assert world_live =~ ~s("action" => "agent.api_key.delete")
    assert delete_helper =~ "Ezagent.URI.with_action(agent_uri, :identity, :delete_api_key)"
    assert delete_helper =~ "refresh_api_keys_state(socket, agent_uri)"
    refute delete_helper =~ "args: %{provider: provider, key:"
  end
end
