defmodule EzagentPluginKanban.PmCoordinatorSeedTest do
  @moduledoc """
  `EzagentPluginKanban.PmCoordinatorSeed` — the kanban-aware half of the
  `pm-coordinator` default agent (Phase 3 ③ refactor 2026-06-30): the
  per-session materialize trigger + the board-scoping cap grant.

  pm's role-as-data + boot template-seed moved to the generic
  `Ezagent.Agent.DefaultRecipes` / `DefaultRecipeSeed` (covered by their own
  domain-agent tests). What this pins is the kanban-specific landing:

    * `role_name/0` — the role name the relay-back wiring derives pm's per-session
      URI from.
    * board-scoping — the load-bearing cross-check that pm's recipe (kanban caps
      named by STRING `"Ezagent.Behavior.Kanban"`) still board-scopes via the
      override map keyed by the MODULE atom `Ezagent.Behavior.Kanban`. The string
      resolves to the module at the `GrantRecipeCaps` chokepoint BEFORE the
      override match, so the kanban caps land on the BOARD instance while the
      github gateway caps stay self-scoped.

  Run from the UMBRELLA ROOT so the sibling `Ezagent.Behavior.Github` module
  (named by string in the recipe) is compiled + loadable for the full-recipe grant.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.DefaultRecipes
  alias EzagentPluginKanban.PmCoordinatorSeed
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :kanban, :pm_coordinator_seed]

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp spawn_bare_agent do
    uri = Ezagent.URI.agent(:system, "pm_seed_test_#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    wait_ready(uri)
    uri
  end

  defp wait_ready(uri, attempts \\ 200)
  defp wait_ready(_uri, 0), do: flunk("agent never became ready")

  defp wait_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready -> :ok
      _ -> Process.sleep(10) && wait_ready(uri, attempts - 1)
    end
  end

  defp caps_for(agent_uri), do: Ezagent.Identity.list_caps_for(agent_uri)

  defp cap_for(caps, behavior),
    do: Enum.find(caps, &match?(%Ezagent.Capability{behavior: ^behavior}, &1))

  describe "role_name/0" do
    test "is \"pm-coordinator\" (the relay-back wiring derives pm's per-session URI from it)" do
      assert PmCoordinatorSeed.role_name() == "pm-coordinator"
    end
  end

  describe "board-scoping — STRING recipe behavior + MODULE-atom override still match" do
    test "pm's kanban caps land on the BOARD instance; github gateway caps stay self-scoped" do
      assert Code.ensure_loaded?(Ezagent.Behavior.Github),
             "this case requires the sibling github behavior loaded — run from the " <>
               "umbrella root, not per-app"

      agent_uri = spawn_bare_agent()
      board_uri = Ezagent.URI.agent(:system, "pm_board_#{uniq()}")

      # The REAL pm recipe (kanban caps named by STRING) + the kanban-side override
      # map keyed by the MODULE atom — exactly what PmCoordinatorSeed.materialize/4
      # supplies to SessionAgentMaterialize → GrantRecipeCaps.
      assert :ok =
               GrantRecipeCaps.grant_recipe_caps(
                 agent_uri,
                 DefaultRecipes.pm_coordinator_recipe(),
                 @telemetry_prefix,
                 %{Ezagent.Behavior.Kanban => board_uri}
               )

      caps = caps_for(agent_uri)

      # kanban string cap RESOLVED to the module AND board-scoped (proves the
      # string→module resolution matched the module-atom override key).
      board_instance = Ezagent.URI.instance(board_uri)
      board_ws = Ezagent.Capability.workspace_of(board_uri)

      kanban_cap = cap_for(caps, Ezagent.Behavior.Kanban)
      assert %Ezagent.Capability{instance: ^board_instance, workspace_uri: ^board_ws} = kanban_cap
      refute kanban_cap.instance == :any

      # github gateway cap stays self-scoped (NOT in the override map).
      self_instance = Ezagent.URI.instance(agent_uri)

      assert %Ezagent.Capability{instance: ^self_instance} =
               cap_for(caps, Ezagent.Behavior.Github)
    end
  end
end
