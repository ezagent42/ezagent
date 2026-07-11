defmodule Mix.Tasks.Ezagent.Agent.GrantRecipeCapsProposalTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :test, :recipe_cap_proposal]

  test "proposes canonical self-scoped caps with sentinel provenance by default" do
    agent_uri =
      Ezagent.URI.agent("team-alpha", "proposal-agent")
      |> Map.put(:query, "action=identity.list_caps")

    recipe = %{
      requested_caps: [
        %{behavior: Ezagent.ActionSet.ApiKeys, action: :put_api_key},
        %{behavior: "Ezagent.ActionSet.Identity", action: "list_caps"}
      ]
    }

    assert {:ok, [api_key_cap, identity_cap]} =
             GrantRecipeCaps.propose_recipe_caps(agent_uri, recipe, @telemetry_prefix)

    own_instance = Ezagent.URI.instance(agent_uri)
    own_workspace = Ezagent.Capability.workspace_of(agent_uri)

    assert %Capability{
             kind: :agent,
             behavior: Ezagent.ActionSet.ApiKeys,
             action: :put_api_key,
             instance: ^own_instance,
             workspace_uri: ^own_workspace,
             granted_by: :plugin_declared,
             granted_at: :compile_time
           } = api_key_cap

    assert %Capability{
             kind: :agent,
             behavior: Ezagent.ActionSet.Identity,
             action: :list_caps,
             instance: ^own_instance,
             workspace_uri: ^own_workspace,
             granted_by: :plugin_declared,
             granted_at: :compile_time
           } = identity_cap
  end

  test "scopes only an overridden behavior to the target instance and workspace" do
    agent_uri = Ezagent.URI.agent("team-alpha", "proposal-agent")

    board_uri =
      Ezagent.URI.agent("team-beta", "board-agent")
      |> Map.put(:query, "action=api_keys.put_api_key")

    recipe = %{
      requested_caps: [
        %{behavior: "Ezagent.ActionSet.ApiKeys", action: "put_api_key"},
        %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
      ]
    }

    assert {:ok, [board_cap, own_cap]} =
             GrantRecipeCaps.propose_recipe_caps(
               agent_uri,
               recipe,
               @telemetry_prefix,
               %{Ezagent.ActionSet.ApiKeys => board_uri}
             )

    board_instance = Ezagent.URI.instance(board_uri)
    board_workspace = Ezagent.Capability.workspace_of(board_uri)
    own_instance = Ezagent.URI.instance(agent_uri)
    own_workspace = Ezagent.Capability.workspace_of(agent_uri)

    assert %Capability{
             behavior: Ezagent.ActionSet.ApiKeys,
             instance: ^board_instance,
             workspace_uri: ^board_workspace
           } = board_cap

    assert %Capability{
             behavior: Ezagent.ActionSet.Identity,
             instance: ^own_instance,
             workspace_uri: ^own_workspace
           } = own_cap
  end

  test "fails loudly without returning a partial proposal when any behavior cannot resolve" do
    handler_id = {__MODULE__, self(), make_ref()}
    event = @telemetry_prefix ++ [:behavior_not_loaded]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn event_name, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    missing_behavior = "Ezagent.ActionSet.DoesNotExistForRecipeProposal"

    recipe = %{
      requested_caps: [
        %{behavior: Ezagent.ActionSet.Identity, action: :list_caps},
        %{behavior: missing_behavior, action: :list_caps}
      ]
    }

    assert {:error, {:behavior_not_loaded, ^missing_behavior}} =
             GrantRecipeCaps.propose_recipe_caps(
               Ezagent.URI.agent("team-alpha", "proposal-agent"),
               recipe,
               @telemetry_prefix
             )

    assert_receive {:telemetry, ^event, %{count: 1}, %{behavior: ^missing_behavior}}
  end

  test "fails closed without returning a partial proposal when any action cannot resolve" do
    missing_action = "does_not_exist_for_recipe_cap_proposal"

    recipe = %{
      requested_caps: [
        %{behavior: Ezagent.ActionSet.Identity, action: :list_caps},
        %{behavior: Ezagent.ActionSet.ApiKeys, action: missing_action}
      ]
    }

    assert {:error, {:invalid_cap_action, ^missing_action}} =
             GrantRecipeCaps.propose_recipe_caps(
               Ezagent.URI.agent("team-alpha", "proposal-agent"),
               recipe,
               @telemetry_prefix
             )
  end
end
