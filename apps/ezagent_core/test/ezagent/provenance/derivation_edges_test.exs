defmodule Ezagent.Provenance.DerivationEdgesTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Provenance.DerivationEdges

  test "append-only multi-provenance edges close over every kind to a fixpoint" do
    root = user("root")
    independent = user("independent")
    child = agent("child")
    grandchild = agent("grandchild")
    great_grandchild = agent("great-grandchild")
    template = template("source")

    assert :ok = DerivationEdges.record_derivation_edge(child, root, :created_by, "a1")
    assert :ok = DerivationEdges.record_derivation_edge(child, template, :parent_template, "a2")
    assert :ok = DerivationEdges.record_derivation_edge(grandchild, child, :spawned_by, "a3")

    assert :ok =
             DerivationEdges.record_derivation_edge(
               great_grandchild,
               grandchild,
               :spawned_by,
               "a4"
             )

    assert MapSet.new(DerivationEdges.descendants(root)) ==
             MapSet.new([child, grandchild, great_grandchild])

    assert DerivationEdges.descendants(independent) == []

    assert MapSet.new(DerivationEdges.descendants(template)) ==
             MapSet.new([child, grandchild, great_grandchild])
  end

  test "same child and edge kind is idempotent only for the exact immutable fact" do
    child = agent("immutable")
    parent = user("parent")

    assert :ok = DerivationEdges.record_derivation_edge(child, parent, :created_by, "same")
    assert :ok = DerivationEdges.record_derivation_edge(child, parent, :created_by, "same")
    assert :ok = DerivationEdges.record_derivation_edge(child, parent, :created_by, "retry")

    assert {:error, :derivation_edge_conflict} =
             DerivationEdges.record_derivation_edge(child, user("other"), :created_by, "other")
  end

  test "cycles terminate without a depth cutoff or duplicate descendants" do
    a = agent("cycle-a")
    b = agent("cycle-b")
    c = agent("cycle-c")

    assert :ok = DerivationEdges.record_derivation_edge(b, a, :spawned_by, "c1")
    assert :ok = DerivationEdges.record_derivation_edge(c, b, :spawned_by, "c2")
    assert :ok = DerivationEdges.record_derivation_edge(a, c, :spawned_by, "c3")

    assert MapSet.new(DerivationEdges.descendants(a)) == MapSet.new([b, c])
  end

  test "the agent-lineage compatibility writer records the durable spawned_by edge" do
    root = user("lineage-root")
    child = agent("lineage-child")

    assert :ok = Ezagent.AgentLineage.record(child, root)
    assert DerivationEdges.descendants(root) == [child]
  end

  defp user(name),
    do: Ezagent.URI.user("derivation-edges", "#{name}-#{System.unique_integer([:positive])}")

  defp agent(name),
    do: Ezagent.URI.agent("derivation-edges", "#{name}-#{System.unique_integer([:positive])}")

  defp template(name),
    do:
      Ezagent.URI.template(
        "derivation-edges",
        :agent,
        "#{name}-#{System.unique_integer([:positive])}"
      )
end
