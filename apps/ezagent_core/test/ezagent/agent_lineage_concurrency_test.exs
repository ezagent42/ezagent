defmodule Ezagent.AgentLineageConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ezagent.AgentLineage
  alias Ezagent.Provenance.DerivationEdges
  alias EzagentCore.Repo

  test "direct derivation records succeed on an independent non-transaction connection" do
    unique = System.unique_integer([:positive])
    child = Ezagent.URI.agent("lineage-direct", "agent-#{unique}")
    parent = Ezagent.URI.user("lineage-direct", "owner-#{unique}")
    owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)

    try do
      refute Repo.in_transaction?()

      assert :ok =
               DerivationEdges.record_derivation_edge(
                 child,
                 parent,
                 :spawned_by,
                 DerivationEdges.new_attempt_id()
               )

      assert %DerivationEdges{} =
               Repo.get_by(DerivationEdges,
                 child_uri: URI.to_string(child),
                 edge_kind: "spawned_by"
               )
    after
      Repo.delete_all(
        from(edge in DerivationEdges,
          where: edge.child_uri == ^URI.to_string(child),
          where: edge.edge_kind == "spawned_by"
        )
      )

      Sandbox.stop_owner(owner)
    end
  end

  test "concurrent exact records recover from the derivation-edge unique race" do
    unique = System.unique_integer([:positive])
    agent = Ezagent.URI.agent("lineage-race", "agent-#{unique}")
    parent = Ezagent.URI.user("lineage-race", "owner-#{unique}")
    barrier_ref = make_ref()
    handler_id = {__MODULE__, barrier_ref}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent_core, :repo, :query],
        &__MODULE__.pause_after_derivation_lookup/4,
        {self(), barrier_ref}
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      Sandbox.unboxed_run(Repo, fn ->
        AgentLineage.forget(agent)

        Repo.delete_all(
          from(edge in DerivationEdges,
            where: edge.child_uri == ^URI.to_string(agent),
            where: edge.edge_kind == "spawned_by"
          )
        )
      end)
    end)

    workers =
      for _ <- 1..2 do
        spawn_monitor(fn ->
          owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)

          result =
            try do
              AgentLineage.record(agent, parent)
            rescue
              exception -> {:raised, exception}
            catch
              kind, reason -> {:caught, kind, reason}
            end

          Sandbox.stop_owner(owner)
          send(test_pid, {barrier_ref, self(), {:result, result}})
        end)
      end

    Enum.each(workers, fn {pid, _monitor} ->
      assert_receive {^barrier_ref, ^pid, :derivation_lookup_complete}, 2_000
    end)

    Enum.each(workers, fn {pid, _monitor} ->
      send(pid, {barrier_ref, :continue})
    end)

    results =
      Enum.map(workers, fn {pid, monitor} ->
        assert_receive {^barrier_ref, ^pid, {:result, result}}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
        result
      end)

    assert results == [:ok, :ok]
    assert {:ok, ^parent} = AgentLineage.lookup(agent)
  end

  @doc false
  def pause_after_derivation_lookup(_event, _measurements, metadata, {parent, barrier_ref}) do
    query = to_string(metadata[:query] || "")

    if derivation_lookup?(query) and Process.get(barrier_ref) != :paused do
      Process.put(barrier_ref, :paused)
      send(parent, {barrier_ref, self(), :derivation_lookup_complete})

      receive do
        {^barrier_ref, :continue} -> :ok
      end
    end
  end

  defp derivation_lookup?(query) do
    String.starts_with?(query, "SELECT") and
      String.contains?(query, ~s(FROM "derivation_edges"))
  end
end
