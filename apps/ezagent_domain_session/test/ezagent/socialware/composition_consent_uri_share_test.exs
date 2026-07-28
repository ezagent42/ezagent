defmodule Ezagent.Socialware.CompositionConsentUriShareTest do
  @moduledoc """
  URI-share unification (A3) — the LOOSER case of the composition-consent
  mechanism, exercised through its generalized entry.

  `CompositionConsent.request/3` + `decide/4` reuse the SAME durable state
  machine + owner todo-box as composition, keyed by any `(target, grantee)` with
  `binding_id` NULL and the source side auto-satisfied (requester = recipient).
  The target owner approves/denies; a non-owner is refused; request + decide are
  idempotent. Composition's `sync`/`command` (binding + two-party) path is the
  constrained special case and is unaffected. This is the seam kanban's
  hand-rolled rule-8 approval migrates onto.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.CompositionConsent, as: Consent
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "request (no binding) → owner approve → approved?(:target); a non-owner cannot decide" do
    owner = user_uri("owner")
    grantee = live_agent("grantee", owner, [Target])
    target = live_agent("target", owner, [Target])
    stranger = user_uri("stranger")

    assert {:ok,
            %Consent{
              id: id,
              binding_id: nil,
              target_approval: :pending,
              source_approval: :approved,
              target_owner_uri: owner_uri
            }} = Consent.request(target, grantee, Target, [:get_tree])

    assert owner_uri == URI.to_string(Ezagent.URI.instance(owner))

    # A non-owner cannot approve.
    assert {:error, :consent_actor_not_target_owner} =
             Consent.decide(id, :approve, stranger, "k-stranger")

    # The owner approves → target side approved for that owner; leaves todo-box.
    assert {:ok, %Consent{target_approval: :approved} = c} =
             Consent.decide(id, :approve, owner, "k-approve")

    assert Consent.approved?(c, :target, owner)
    refute Consent.approved?(c, :target, stranger)
    refute Enum.any?(Consent.pending_for_owner(owner), &(&1.id == id))
  end

  test "deny leaves it un-approved" do
    owner = user_uri("owner2")
    grantee = live_agent("grantee2", owner, [Target])
    target = live_agent("target2", owner, [Target])

    {:ok, %Consent{id: id}} = Consent.request(target, grantee, Target, [:get_tree])

    assert {:ok, %Consent{target_approval: :denied} = c} =
             Consent.decide(id, :deny, owner, "k-deny")

    refute Consent.approved?(c, :target, owner)
  end

  test "request is idempotent by (target, grantee); decide replays idempotently" do
    owner = user_uri("owner3")
    grantee = live_agent("grantee3", owner, [Target])
    target = live_agent("target3", owner, [Target])

    {:ok, %Consent{id: id1}} = Consent.request(target, grantee, Target, [:get_tree])
    {:ok, %Consent{id: id2}} = Consent.request(target, grantee, Target, [:get_tree])
    assert id1 == id2

    {:ok, %Consent{target_approval: :approved}} = Consent.decide(id1, :approve, owner, "k-once")
    # Same idempotency key → replay, no double transition, still approved.
    assert {:ok, %Consent{target_approval: :approved}} =
             Consent.decide(id1, :approve, owner, "k-once")
  end

  test "request fails closed when the target has no resolvable owner" do
    grantee = user_uri("g4")
    orphan = orphan_agent("ownerless-target", [Target])

    assert {:error, :consent_target_owner_unresolvable} =
             Consent.request(orphan, grantee, Target, [:get_tree])
  end

  test "M3: the consent is bound to the requested (behavior, actions), not just (target, grantee)" do
    owner = user_uri("m3-owner")
    grantee = live_agent("m3-grantee", owner, [Target])
    target = live_agent("m3-target", owner, [Target])

    assert {:ok, %Consent{behavior: behavior, actions_json: actions_json}} =
             Consent.request(target, grantee, Target, [:get_tree, :add_node])

    # The specific access is recorded on the row, so an owner approval cannot
    # later be reinterpreted as broader authority than was asked for.
    assert behavior == inspect(Target)
    assert Jason.decode!(actions_json) == ["get_tree", "add_node"]
  end

  test "M3: an empty actions request is rejected (a consent must name its access)" do
    owner = user_uri("m3e-owner")
    grantee = live_agent("m3e-grantee", owner, [Target])
    target = live_agent("m3e-target", owner, [Target])

    assert {:error, :invalid_consent_request} = Consent.request(target, grantee, Target, [])
  end

  # --- fixture helpers (same CompositionGrantTargetBehavior fixture) ----------

  defp live_agent(name, owner, extra) do
    uri = agent_uri(name)

    {:ok, _} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra),
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri())
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp orphan_agent(name, extra) do
    uri = agent_uri(name)

    {:ok, _} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra),
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri())
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://composition")

  defp user_uri(name) do
    uri =
      Ezagent.URI.new!("entity://composition/user/#{name}-#{System.unique_integer([:positive])}")

    {:ok, _} =
      Ezagent.Users.create(uri, "test-password-#{System.unique_integer([:positive])}", [])

    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/agent/#{name}-#{System.unique_integer([:positive])}")
end
