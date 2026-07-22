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

  test "ownership closure crosses owned sessions but not child users or hosted workspaces" do
    root = user("ownership-root")
    child_user = user("child-user")
    child_users_agent = agent("child-users-agent")
    owned_session = session("owned-session")
    owned_agent = agent("owned-agent")
    hosted_workspace = workspace("hosted")
    hosted_agent = agent("hosted-agent")

    assert :ok = DerivationEdges.record_derivation_edge(child_user, root, :created_by, "o1")

    assert :ok =
             DerivationEdges.record_derivation_edge(
               child_users_agent,
               child_user,
               :creation_root,
               "o2"
             )

    assert :ok = DerivationEdges.record_derivation_edge(owned_session, root, :created_by, "o3")

    assert :ok =
             DerivationEdges.record_derivation_edge(
               owned_agent,
               owned_session,
               :creation_root,
               "o4"
             )

    assert :ok =
             DerivationEdges.record_derivation_edge(
               hosted_workspace,
               root,
               :workspace_ownership,
               "o5"
             )

    assert :ok =
             DerivationEdges.record_derivation_edge(
               hosted_agent,
               hosted_workspace,
               :creation_root,
               "o6"
             )

    assert MapSet.new(DerivationEdges.ownership_descendants(root)) ==
             MapSet.new([child_user, owned_session, owned_agent])

    assert MapSet.new(DerivationEdges.descendants(root)) ==
             MapSet.new([
               child_user,
               child_users_agent,
               owned_session,
               owned_agent,
               hosted_workspace,
               hosted_agent
             ])
  end

  test "the latest ownership transfer supersedes historical created_by for revocation" do
    original_owner = user("original-owner")
    next_owner = user("next-owner")
    newest_owner = user("newest-owner")
    owned_session = session("transferred-session")
    session_agent = agent("transferred-session-agent")

    assert :ok =
             DerivationEdges.record_derivation_edge(
               owned_session,
               original_owner,
               :created_by,
               "t1"
             )

    assert :ok =
             DerivationEdges.record_derivation_edge(
               session_agent,
               owned_session,
               :creation_root,
               "t2"
             )

    assert :ok =
             DerivationEdges.record_derivation_edge(
               owned_session,
               next_owner,
               "ownership_transfer:next",
               "t3"
             )

    assert :ok =
             DerivationEdges.record_derivation_edge(
               owned_session,
               newest_owner,
               "ownership_transfer:newest",
               "t4"
             )

    refute owned_session in DerivationEdges.ownership_descendants(original_owner)
    refute owned_session in DerivationEdges.ownership_descendants(next_owner)

    assert MapSet.new(DerivationEdges.ownership_descendants(newest_owner)) ==
             MapSet.new([owned_session, session_agent])
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

  defp session(name),
    do:
      Ezagent.URI.session(
        "derivation-edges",
        "ownership",
        "#{name}-#{System.unique_integer([:positive])}"
      )

  defp workspace(name),
    do: Ezagent.URI.workspace("#{name}-#{System.unique_integer([:positive])}")
end
