defmodule Ezagent.Invariants.DerivationEdgeChokepointTest do
  @moduledoc "D-1/MF6 creation-source completeness gate with an empty allowlist."

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @allowlist []

  @creation_sources [
    {"apps/ezagent_core/lib/ezagent/agent_lineage.ex", "agent spawned_by"},
    {"apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory.ex",
     "agent creation inventory"},
    {"apps/ezagent_domain_identity/lib/ezagent/users.ex", "user create"},
    {"apps/ezagent_domain_workspace/lib/ezagent/workspace.ex", "workspace create"},
    {"apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/derivation.ex",
     "session materialize"},
    {"apps/ezagent_domain_session/lib/ezagent/behavior/template.ex", "template fork"}
  ]

  test "every reviewed principal/structural creation source routes through the edge writer" do
    violations =
      Enum.flat_map(@creation_sources, fn {relative, label} ->
        source = File.read!(Path.join(@root, relative))

        if source =~ "record_derivation_edge" do
          []
        else
          ["#{relative}: #{label}"]
        end
      end)

    assert @allowlist == []

    assert violations == [],
           """
           derivation-edge creation bypasses (empty allowlist):
           #{Enum.map_join(violations, "\n", &"  - #{&1}")}
           """
  end

  test "the append-only writer and no-cutoff all-kind closure remain present" do
    source =
      File.read!(Path.join(@root, "apps/ezagent_core/lib/ezagent/provenance/derivation_edges.ex"))

    assert source =~ "def record_derivation_edge"
    assert source =~ "def descendants"
    assert source =~ "edge.parent_uri in ^frontier"
    refute source =~ "max_depth"
    refute source =~ "Repo.delete"
    refute source =~ "Repo.update"
  end
end
