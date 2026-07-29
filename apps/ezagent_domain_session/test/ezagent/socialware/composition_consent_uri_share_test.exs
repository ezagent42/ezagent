defmodule Ezagent.Socialware.CompositionConsentUriShareTest do
  @moduledoc """
  URI-share unification (A3) — the LOOSER case of the composition-consent
  mechanism, exercised through its generalized entry.

  `CompositionConsent.request/5` + `decide/4` reuse the SAME durable state
  machine + owner todo-box as composition, keyed by `(target, grantee, behavior,
  actions)` with `binding_id` NULL and the source side auto-satisfied (requester =
  recipient). The requester must equal the authenticated principal (M3); the
  consent identity includes the granted scope so an approval of one access is not
  reusable for another (M3). The target owner approves/denies; a non-owner is
  refused; request + decide are idempotent. Composition's `sync`/`command`
  (binding + two-party) path is the constrained special case and is unaffected.
  This is the seam kanban's hand-rolled rule-8 approval migrates onto.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.CompositionConsent, as: Consent
  alias Ezagent.Socialware.CompositionConsentCommand
  alias EzagentCore.Repo
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
            }} = Consent.request(target, grantee, Target, [:get_tree], grantee)

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

    {:ok, %Consent{id: id}} = Consent.request(target, grantee, Target, [:get_tree], grantee)

    assert {:ok, %Consent{target_approval: :denied} = c} =
             Consent.decide(id, :deny, owner, "k-deny")

    refute Consent.approved?(c, :target, owner)
  end

  test "request is idempotent by (target, grantee, scope); decide replays idempotently" do
    owner = user_uri("owner3")
    grantee = live_agent("grantee3", owner, [Target])
    target = live_agent("target3", owner, [Target])

    {:ok, %Consent{id: id1}} = Consent.request(target, grantee, Target, [:get_tree], grantee)
    {:ok, %Consent{id: id2}} = Consent.request(target, grantee, Target, [:get_tree], grantee)
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
             Consent.request(orphan, grantee, Target, [:get_tree], grantee)
  end

  test "M3: the consent is bound to the requested (behavior, actions), not just (target, grantee)" do
    owner = user_uri("m3-owner")
    grantee = live_agent("m3-grantee", owner, [Target])
    target = live_agent("m3-target", owner, [Target])

    assert {:ok, %Consent{behavior: behavior, actions_json: actions_json}} =
             Consent.request(target, grantee, Target, [:get_tree, :add_node], grantee)

    # The specific access is recorded on the row, so an owner approval cannot
    # later be reinterpreted as broader authority than was asked for.
    assert behavior == inspect(Target)
    assert Jason.decode!(actions_json) == ["get_tree", "add_node"]
  end

  test "M3: an empty actions request is rejected (a consent must name its access)" do
    owner = user_uri("m3e-owner")
    grantee = live_agent("m3e-grantee", owner, [Target])
    target = live_agent("m3e-target", owner, [Target])

    assert {:error, :invalid_consent_request} =
             Consent.request(target, grantee, Target, [], grantee)
  end

  test "M3: a requester that is NOT the authenticated principal is rejected (no third-party fabrication)" do
    owner = user_uri("m3a-owner")
    victim = user_uri("m3a-victim")
    attacker = user_uri("m3a-attacker")
    target = live_agent("m3a-target", owner, [Target])

    # The attacker (the authenticated caller) files a consent NAMING `victim` as
    # the requester — if accepted, an owner approval would elevate `victim` who
    # never asked. The authenticated-principal check refuses it, nothing is
    # written, and there is no pending request for the owner to mis-approve.
    assert {:error, :consent_requester_not_authenticated} =
             Consent.request(target, victim, Target, [:get_tree], attacker)

    assert Consent.pending_for_owner(owner) == []

    # The honest path (requester == authenticated principal) still works.
    assert {:ok, %Consent{}} = Consent.request(target, victim, Target, [:get_tree], victim)
  end

  test "M3: same (target, grantee) but a different action-set is a DISTINCT consent (no approval reuse)" do
    owner = user_uri("m3s-owner")
    grantee = live_agent("m3s-grantee", owner, [Target])
    target = live_agent("m3s-target", owner, [Target])

    {:ok, %Consent{id: read_id}} =
      Consent.request(target, grantee, Target, [:get_tree], grantee)

    {:ok, %Consent{id: write_id}} =
      Consent.request(target, grantee, Target, [:add_node], grantee)

    # A different access set = a different consent identity.
    assert read_id != write_id

    # Approving the read consent does NOT approve the write consent — the write
    # scope stays pending in the owner's todo-box, needing its own decision.
    assert {:ok, %Consent{target_approval: :approved}} =
             Consent.decide(read_id, :approve, owner, "k-read")

    pending_ids = owner |> Consent.pending_for_owner() |> Enum.map(& &1.id)
    assert write_id in pending_ids
    refute read_id in pending_ids
  end

  test "M4 (command side): the DB CHECK rejects a command with neither binding nor consent" do
    # The production paths (apply_command / apply_decide) always set exactly one
    # of binding_id/consent_id via the changeset guard — assert that guard first.
    both =
      CompositionConsentCommand.changeset(%CompositionConsentCommand{}, %{
        idempotency_key: "cs-both-#{u()}",
        workspace_uri: "workspace://composition",
        binding_id: "b-1",
        consent_id: "c-1",
        side: :target,
        command: :approve,
        actor_uri: "entity://composition/user/x",
        result_state: :approved,
        inserted_at: DateTime.utc_now()
      })

    refute both.valid?

    neither =
      CompositionConsentCommand.changeset(%CompositionConsentCommand{}, %{
        idempotency_key: "cs-neither-#{u()}",
        workspace_uri: "workspace://composition",
        side: :target,
        command: :approve,
        actor_uri: "entity://composition/user/x",
        result_state: :approved,
        inserted_at: DateTime.utc_now()
      })

    refute neither.valid?

    # DB backstop: a raw insert bypassing the changeset is still rejected by the
    # DB CHECK itself (the FK-free `neither` case isolates our constraint, so the
    # rejection is provably ours and not a foreign-key error).
    assert_raise Postgrex.Error, ~r/consent_command_binding_xor_consent/, fn ->
      Repo.query!(
        """
        INSERT INTO socialware_composition_consent_commands
          (idempotency_key, workspace_uri, binding_id, consent_id, side, command,
           actor_uri, result_state, inserted_at)
        VALUES ($1, $2, NULL, NULL, 'target', 'approve', $3, 'approved', now())
        """,
        ["cs-raw-neither-#{u()}", "workspace://composition", "entity://composition/user/x"]
      )
    end
  end

  # --- fixture helpers (same CompositionGrantTargetBehavior fixture) ----------

  defp u, do: System.unique_integer([:positive])

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
