defmodule Ezagent.Agent.RecipeResolverDurableKeyTest do
  @moduledoc """
  `recipe_from_durable_snapshot/1` — the durable `:recipe` provenance read behind
  the `:recipe`/`:role` UriQuery cold fallback.

  C2 KEPT this on the FULL-state durable read (`SnapshotStore.latest` +
  `role_of_state/1`), NOT `Kind.read_durable(:sandbox)`: the resolver must tolerate
  a LEGACY string-keyed `"sandbox"` TOP-LEVEL state map, and `read_durable/3`'s
  single ATOM-key projection (`Map.get(state, :sandbox)`) cannot reach it — the
  same full-state limitation that defers `AgentFlavorResolver`. This test pins the
  atom-OR-string parity so the fallback never silently regresses `{:ok, recipe}` →
  `:none` on a cold-booted legacy row.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeResolver
  alias Ezagent.SnapshotStore

  defp agent_uri,
    do: Ezagent.URI.entity(:team_alpha, :agent, "rr-#{System.unique_integer([:positive])}")

  test "modern ATOM-keyed :sandbox slice → {:ok, recipe}" do
    uri = agent_uri()

    {:ok, _} =
      SnapshotStore.write(uri, %{sandbox: %{state: %{recipe: "kanban-manager"}}},
        kind_type: :agent
      )

    assert {:ok, "kanban-manager"} = RecipeResolver.recipe_from_durable_snapshot(uri)
  end

  test "LEGACY string-keyed \"sandbox\" top-level → {:ok, recipe} (dual-key parity)" do
    uri = agent_uri()

    # A legacy row whose DECODED state is STRING-keyed at the top level.
    # `Kind.read_durable(uri, :sandbox)` (atom-key projection) would MISS this and
    # regress to `:none`; the full-state dual-key read preserves it.
    {:ok, _} =
      SnapshotStore.write(uri, %{"sandbox" => %{state: %{recipe: "kanban-manager"}}},
        kind_type: :agent
      )

    assert {:ok, "kanban-manager"} = RecipeResolver.recipe_from_durable_snapshot(uri)
  end

  test "no snapshot → :none" do
    assert :none = RecipeResolver.recipe_from_durable_snapshot(agent_uri())
  end

  test "a row with no :recipe → :none" do
    uri = agent_uri()
    {:ok, _} = SnapshotStore.write(uri, %{sandbox: %{state: %{}}}, kind_type: :agent)
    assert :none = RecipeResolver.recipe_from_durable_snapshot(uri)
  end
end
