defmodule Ezagent.EntityCapsTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.{Cap, Capability, EntityCaps, SnapshotStore}
  alias Ezagent.Cap.RevocationLedger
  alias Ezagent.EntityCaps.{Store, UserStore}
  alias EzagentCore.Repo

  @workspace URI.new!("workspace://entity-caps")
  @issuer URI.new!("entity://entity-caps/user/issuer")

  defmodule IdentityHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :agent

    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.IdentityAdmin]

    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  setup do
    Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
    :ok = Ezagent.ReadyGate.register_external_gate(Ezagent.EntityCapsReadyBarrier)
    :ok = Ezagent.EntityCapsReadyBarrier.clear()

    for action <- [:list_caps, :has_cap?, :persist_caps, :store_cap, :remove_cap] do
      :ok =
        Ezagent.CapabilityRegistry.register(
          IdentityHostKind,
          action,
          if(action in [:persist_caps, :store_cap, :remove_cap],
            do: Ezagent.ActionSet.IdentityAdmin,
            else: Ezagent.ActionSet.Identity
          )
        )
    end

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
      Ezagent.EntityCapsReadyBarrier.clear()
    end)

    :ok
  end

  describe "load/1 and load_persisted/1" do
    test "missing user rows and non-user snapshots are empty" do
      assert EntityCaps.load(user_uri("missing")) == []
      assert EntityCaps.load(agent_uri("missing")) == []
      assert EntityCaps.load_persisted(user_uri("missing-persisted")) == []
      assert EntityCaps.load_persisted(agent_uri("missing-persisted")) == []
    end

    test "cold users load from caps_json and cold agents load from the identity snapshot" do
      user = user_uri("cold")
      agent = agent_uri("cold")
      user_cap = issued_cap(user, :send)
      agent_cap = issued_cap(agent, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [user_cap]))

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [agent_cap]))}}},
                 kind_type: :agent
               )

      assert identity_keys(non_license_caps(EntityCaps.load(user))) == identity_keys([user_cap])
      assert identity_keys(non_license_caps(EntityCaps.load(agent))) == identity_keys([agent_cap])

      assert identity_keys(non_license_caps(EntityCaps.load_persisted(user))) ==
               identity_keys([user_cap])

      assert identity_keys(non_license_caps(EntityCaps.load_persisted(agent))) ==
               identity_keys([agent_cap])
    end

    test "load is live-first and filters artifacts issued to another receiver" do
      agent = agent_uri("live-read")
      other = agent_uri("other")
      live_cap = issued_cap(agent, :send)
      wrong_receiver = issued_cap(other, :join)
      persisted_cap = issued_cap(agent, :history)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{
                 uri: agent,
                 initial_caps: [live_cap, wrong_receiver]
               })

      wait_until_ready(agent)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{
                   identity: %{
                     state: %{caps: MapSet.new(licensed_caps(agent, [persisted_cap]))}
                   }
                 },
                 kind_type: :agent
               )

      assert cap_present?(EntityCaps.load(agent), live_cap)
      refute cap_present?(EntityCaps.load(agent), persisted_cap)
      refute cap_present?(EntityCaps.load(agent), wrong_receiver)

      assert identity_keys(non_license_caps(EntityCaps.load_persisted(agent))) ==
               identity_keys([persisted_cap])

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "under signature enforcement load admits the bound grantee and excludes a retargeted cap" do
      # Proves the retargeting hole stays closed at the EntityCaps.load/1
      # boundary once enforce flips: a signed cap materialized under holder A
      # is loaded for A but a cap issued to another holder is filtered out.
      # Both the admit and the exclude run under the same require_signature:
      # true config against the same durable snapshot, so the exclusion is
      # non-vacuous (the bound cap is proven to still load).
      agent = agent_uri("enforce-retarget")
      bound = issued_cap(agent, :send)
      wrong_receiver = issued_cap(agent_uri("enforce-other"), :join)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{
                   identity: %{
                     state: %{
                       caps: MapSet.new(licensed_caps(agent, [bound, wrong_receiver]))
                     }
                   }
                 },
                 kind_type: :agent
               )

      with_signature_enforced(fn ->
        loaded = EntityCaps.load(agent)
        assert cap_present?(loaded, bound)
        refute cap_present?(loaded, wrong_receiver)
      end)
    end

    test "live and durable reads filter a v2 artifact after its grant_id is revoked" do
      agent = agent_uri("per-cap-revoked")
      cap = v2_issued_cap(agent, :send)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{
                 uri: agent,
                 initial_caps: [cap]
               })

      wait_until_ready(agent)
      assert cap_present?(EntityCaps.load(agent), cap)
      assert cap_present?(EntityCaps.load_persisted(agent), cap)

      assert {:ok, _marker} = RevocationLedger.mark(revocation_attrs(agent, cap))

      refute cap_present?(EntityCaps.load(agent), cap)
      refute cap_present?(EntityCaps.load_persisted(agent), cap)

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "a transient live read fails closed instead of falling back to stale durable caps" do
      agent = agent_uri("transient")
      stale = issued_cap(agent, :history)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [stale]))}}},
                 kind_type: :agent
               )

      parent = self()

      pid =
        spawn(fn ->
          :ok = Ezagent.KindRegistry.put_new(agent)
          send(parent, :registered)

          receive do
            {:"$gen_call", _from, _request} -> exit(:transient_read_failure)
          end
        end)

      assert_receive :registered
      assert EntityCaps.load(agent) == []
      refute Process.alive?(pid)
      assert cap_present?(EntityCaps.load_persisted(agent), stale)
    end
  end

  describe "effective_caps/1 and effective_caps_persisted/1" do
    test "merges held and pending caps and deduplicates by semantic identity" do
      agent = agent_uri("effective-held-pending")
      held = issued_cap(agent, :history)
      pending = issued_cap(agent, :send)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{
                 uri: agent,
                 initial_caps: [held]
               })

      wait_until_ready(agent)
      :ok = Ezagent.ReadyGate.put(agent, :not_ready)

      assert :ok = Ezagent.Identity.absorb_cap(agent, pending)
      assert :ok = Ezagent.Identity.absorb_cap(agent, pending)

      assert {:ok, effective} = EntityCaps.effective_caps(agent)
      assert cap_present?(effective, held)
      assert cap_present?(effective, pending)

      assert Enum.count(
               effective,
               &(Capability.identity_key(&1) == Capability.identity_key(pending))
             ) == 1

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "excludes a held artifact whose target authority generation is stale" do
      agent = agent_uri("effective-stale-held")
      stale = issued_cap(agent, :send)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{
                 uri: agent,
                 initial_caps: [stale]
               })

      wait_until_ready(agent)
      assert {:ok, _generation_two} = Ezagent.Cap.Authority.regenesis(stale.instance, :session)

      assert {:ok, effective} = EntityCaps.effective_caps(agent)
      refute artifact_present?(effective, stale)

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "filters stale pending artifacts before deduplicating equal capability identities" do
      agent = agent_uri("effective-pending-generations")
      generation_one = issued_cap(agent, :send)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{
                 uri: agent,
                 initial_caps: [generation_one]
               })

      wait_until_ready(agent)
      :ok = Ezagent.ReadyGate.put(agent, :not_ready)
      assert :ok = Ezagent.Identity.absorb_cap(agent, generation_one)

      assert {:ok, generation_two_authority} =
               Ezagent.Cap.Authority.regenesis(generation_one.instance, :session)

      generation_two = reissue_cap(generation_two_authority, agent, generation_one)

      assert Capability.identity_key(generation_one) == Capability.identity_key(generation_two)
      refute generation_one.key_id == generation_two.key_id
      assert :ok = Ezagent.Identity.absorb_cap(agent, generation_two)

      assert {:ok, effective} = EntityCaps.effective_caps(agent)
      refute artifact_present?(effective, generation_one)
      assert artifact_present?(effective, generation_two)

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "cold missing entities return a successful empty effective view" do
      assert {:ok, []} = EntityCaps.effective_caps_persisted(agent_uri("effective-empty"))
    end

    test "an active authoritative-store read error is a tagged effective-read failure" do
      agent = agent_uri("effective-store-error")
      cap = issued_cap(agent, :send)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [cap]))}}},
                 kind_type: :agent
               )

      Application.put_env(:ezagent_domain_identity, :p2_forced_read_error_uris, [
        store_key(agent)
      ])

      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :p2_forced_read_error_uris)
      end)

      assert EntityCaps.load_persisted(agent) == []

      assert {:error, :effective_caps_read_failed} =
               EntityCaps.effective_caps_persisted(agent)
    end

    test "an unreadable cutover epoch is a tagged effective-read failure" do
      agent = agent_uri("effective-epoch-unknown")
      cap = issued_cap(agent, :send)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [cap]))}}},
                 kind_type: :agent
               )

      Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)

      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :identity_cutover_force_read_error)

        Application.put_env(
          :ezagent_domain_identity,
          :identity_cutover_active_override,
          true
        )
      end)

      assert Ezagent.Identity.Cutover.status() == :unknown
      assert EntityCaps.load_persisted(agent) == []

      assert {:error, :effective_caps_read_failed} =
               EntityCaps.effective_caps_persisted(agent)
    end

    test "a malformed inactive-epoch identity snapshot fails the effective read closed" do
      agent = agent_uri("effective-corrupt-snapshot")

      assert {:ok, _snapshot} =
               SnapshotStore.write(agent, %{identity: :not_a_map}, kind_type: :agent)

      Application.put_env(
        :ezagent_domain_identity,
        :identity_cutover_active_override,
        false
      )

      on_exit(fn ->
        Application.put_env(
          :ezagent_domain_identity,
          :identity_cutover_active_override,
          true
        )
      end)

      assert {:error, :effective_caps_read_failed} =
               EntityCaps.effective_caps_persisted(agent)
    end

    test "malformed caps JSON in an active store row fails checked and effective reads closed" do
      agent = agent_uri("effective-corrupt-store")

      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      assert Store.status(agent) == :active

      assert {:ok, _row} =
               agent
               |> Store.fetch()
               |> Ecto.Changeset.change(caps_json: "null")
               |> Repo.update()

      assert {:ok, []} = Store.fetch_durable_caps(agent)

      assert {:ok, _row} =
               agent
               |> Store.fetch()
               |> Ecto.Changeset.change(caps_json: "{malformed")
               |> Repo.update()

      assert {:error, :invalid_caps_json} = Store.fetch_durable_caps(agent)

      assert {:error, :effective_caps_read_failed} =
               EntityCaps.effective_caps_persisted(agent)
    end

    test "malformed legacy user caps JSON fails checked and effective reads closed" do
      user = user_uri("effective-corrupt-user")

      assert {:ok, _user} =
               Ezagent.Users.create(user, nil, licensed_caps(user, [issued_cap(user, :send)]))

      assert {:ok, _row} =
               Ezagent.Users
               |> Repo.get_by(uri: URI.to_string(user))
               |> Ecto.Changeset.change(caps_json: "null")
               |> Repo.update()

      assert {:ok, []} = UserStore.load_checked(user)

      assert {:ok, _row} =
               Ezagent.Users
               |> Repo.get_by(uri: URI.to_string(user))
               |> Ecto.Changeset.change(caps_json: "{malformed")
               |> Repo.update()

      Application.put_env(
        :ezagent_domain_identity,
        :identity_cutover_active_override,
        false
      )

      on_exit(fn ->
        Application.put_env(
          :ezagent_domain_identity,
          :identity_cutover_active_override,
          true
        )
      end)

      assert {:error, :invalid_caps_json} = UserStore.load_checked(user)

      assert {:error, :effective_caps_read_failed} =
               EntityCaps.effective_caps_persisted(user)
    end
  end

  describe "persist/2, grant/2, and revoke/2" do
    test "fresh-user concurrent mutations wait for startup and survive restart" do
      user = user_uri("startup-race")
      first = issued_cap(user, :send)
      second = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create_read_only(user, [])
      assert :error = Ezagent.KindRegistry.lookup(user)
      assert :ok = Ezagent.EntityCapsReadyBarrier.arm(user)

      first_task = Task.async(fn -> EntityCaps.grant(user, first) end)
      assert_receive {:entity_caps_barrier_waiting, barrier}, 2_000
      second_task = Task.async(fn -> EntityCaps.grant(user, second) end)

      send(barrier, :release_entity_caps_barrier)
      assert :ok = Task.await(first_task, 5_000)
      assert :ok = Task.await(second_task, 5_000)

      assert {:ok, pid1} = Ezagent.KindRegistry.lookup(user)
      assert cap_present?(EntityCaps.load(user), first)
      assert cap_present?(EntityCaps.load(user), second)

      Process.exit(pid1, :kill)

      wait_until(fn ->
        case Ezagent.KindRegistry.lookup(user) do
          {:ok, pid2} when pid2 != pid1 -> Ezagent.ReadyGate.status(user) == :ready
          _ -> false
        end
      end)

      assert cap_present?(EntityCaps.load(user), first)
      assert cap_present?(EntityCaps.load(user), second)
      :ok = Ezagent.Kind.terminate(user)
    end

    test "a live user without a users row cannot acquire snapshot-only authority" do
      user = user_uri("rowless-live")
      cap = issued_cap(user, :send)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{uri: user, initial_caps: []})

      wait_until_ready(user)

      assert {:error, :not_found} = EntityCaps.grant(user, cap)
      refute cap_present?(EntityCaps.load(user), cap)
      assert EntityCaps.load_persisted(user) == []
      :ok = Ezagent.Kind.terminate(user)
    end

    test "storage rejects unsigned legacy caps and keeps signed-looking tamper opaque" do
      user = user_uri("unsigned")

      unsigned = %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.Session,
        action: :send,
        instance: URI.new!("session://entity-caps/default/main"),
        workspace_uri: @workspace,
        granted_by: @issuer,
        granted_at: DateTime.utc_now(),
        grantee_uri: user
      }

      assert {:ok, _user} = Ezagent.Users.create_read_only(user, [])
      previous = Application.get_env(:ezagent_core, Cap)
      cap_config = previous || []
      signing = cap_config |> Keyword.get(:signing, []) |> Keyword.put(:require_signature, false)
      Application.put_env(:ezagent_core, Cap, Keyword.put(cap_config, :signing, signing))

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:ezagent_core, Cap)
        else
          Application.put_env(:ezagent_core, Cap, previous)
        end
      end)

      forged = %{issued_cap(user, :join) | signature: :binary.copy(<<0>>, 64)}

      assert {:error, :invalid_cap_artifact} = EntityCaps.grant(user, unsigned)
      assert {:error, :invalid_cap_artifact} = EntityCaps.persist(user, [unsigned])
      assert :ok = EntityCaps.grant(user, forged)
      assert :ok = EntityCaps.persist(user, [forged])
      assert cap_present?(EntityCaps.load_persisted(user), forged)
      assert Enum.any?(EntityCaps.load_persisted(user), &self_license?/1)
    end

    test "cold user persist replaces caps_json; grant and revoke round-trip durably" do
      user = user_uri("cold-write")
      first = issued_cap(user, :send)
      second = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, [first])
      assert :ok = EntityCaps.persist(user, [second])
      assert cap_present?(EntityCaps.load(user), second)
      refute cap_present?(EntityCaps.load(user), first)

      assert :ok = EntityCaps.grant(user, first)
      assert cap_present?(EntityCaps.load(user), first)
      assert cap_present?(EntityCaps.load(user), second)

      assert :ok = EntityCaps.revoke(user, first)
      assert cap_present?(EntityCaps.load(user), second)
      refute cap_present?(EntityCaps.load(user), first)
    end

    test "cold agent persist, grant, and revoke preserve the snapshot wrapper" do
      agent = agent_uri("cold-write")
      first = issued_cap(agent, :send)
      second = issued_cap(agent, :join)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent, initial_caps: [first]})

      wait_until_ready(agent)
      assert {:ok, %{state: before_state}} = SnapshotStore.latest(agent)
      preserved_slices = Map.drop(before_state, [:identity])
      assert map_size(preserved_slices) > 0
      :ok = Ezagent.Kind.terminate(agent)
      wait_until(fn -> Ezagent.KindRegistry.lookup(agent) == :error end)

      assert :ok = EntityCaps.persist(agent, [second])
      loaded = EntityCaps.load(agent)
      assert cap_present?(loaded, second)
      refute cap_present?(loaded, first)

      assert {:ok, %{state: state}} = SnapshotStore.latest(agent)
      assert Map.take(state, Map.keys(preserved_slices)) == preserved_slices
      assert %{state: %{caps: persisted}} = state.identity
      assert cap_present?(persisted, second)
      refute cap_present?(persisted, first)

      assert :ok = EntityCaps.grant(agent, first)
      assert :ok = EntityCaps.revoke(agent, second)
      assert cap_present?(EntityCaps.load(agent), first)
      refute cap_present?(EntityCaps.load(agent), second)
    end

    test "live non-user persist mutates the live identity slice and survives restart" do
      agent = agent_uri("live-write")
      first = issued_cap(agent, :send)
      second = issued_cap(agent, :join)

      assert {:ok, pid1} =
               Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [first]})

      wait_until_ready(agent)

      structural_keys =
        EntityCaps.load(agent)
        |> Enum.reject(&(Capability.identity_key(&1) == Capability.identity_key(first)))
        |> identity_keys()

      assert :ok = EntityCaps.persist(agent, [second])
      assert cap_present?(EntityCaps.load(agent), second)
      refute cap_present?(EntityCaps.load(agent), first)
      assert MapSet.subset?(structural_keys, identity_keys(EntityCaps.load(agent)))

      Process.exit(pid1, :kill)

      wait_until(fn ->
        case Ezagent.KindRegistry.lookup(agent) do
          {:ok, pid2} when pid2 != pid1 -> Ezagent.ReadyGate.status(agent) == :ready
          _ -> false
        end
      end)

      assert cap_present?(EntityCaps.load(agent), second)
      refute cap_present?(EntityCaps.load(agent), first)
      assert MapSet.subset?(structural_keys, identity_keys(EntityCaps.load(agent)))
      :ok = Ezagent.Kind.terminate(agent)
    end

    test "live user grant and revoke update caps_json and do not resurrect after restart" do
      user = user_uri("live-user")
      first = issued_cap(user, :send)
      second = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, [first])

      assert {:ok, pid1} =
               Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user, initial_caps: [first]})

      wait_until_ready(user)

      assert :ok = EntityCaps.grant(user, second)
      assert :ok = EntityCaps.revoke(user, first)
      assert cap_present?(EntityCaps.load(user), second)
      refute cap_present?(EntityCaps.load(user), first)
      assert cap_present?(Ezagent.EntityCaps.UserStore.load(user), second)
      refute cap_present?(Ezagent.EntityCaps.UserStore.load(user), first)

      Process.exit(pid1, :kill)

      wait_until(fn ->
        case Ezagent.KindRegistry.lookup(user) do
          {:ok, pid2} when pid2 != pid1 -> Ezagent.ReadyGate.status(user) == :ready
          _ -> false
        end
      end)

      assert cap_present?(EntityCaps.load(user), second)
      refute cap_present?(EntityCaps.load(user), first)
      :ok = Ezagent.Kind.terminate(user)
    end

    test "persist and grant reject artifacts issued to another receiver" do
      agent = agent_uri("receiver")
      wrong = issued_cap(agent_uri("wrong-receiver"), :send)

      assert {:ok, _snapshot} =
               SnapshotStore.write(agent, %{identity: %{caps: MapSet.new()}}, kind_type: :agent)

      assert {:error, :invalid_cap_artifact} = EntityCaps.persist(agent, [wrong])
      assert {:error, :invalid_cap_artifact} = EntityCaps.grant(agent, wrong)
      assert EntityCaps.load(agent) == []
    end

    test "concurrent hot grants and revokes are atomic inside the Kind" do
      agent = agent_uri("hot-concurrent")

      [remove_a, remove_b, grant_a, grant_b] =
        Enum.map([:send, :join, :history, :publish], &issued_cap(agent, &1))

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{
                 uri: agent,
                 initial_caps: [remove_a, remove_b]
               })

      wait_until_ready(agent)

      assert [:ok, :ok, :ok, :ok] ==
               run_concurrent_mutations(agent, [remove_a, remove_b], [grant_a, grant_b])

      loaded = EntityCaps.load(agent)
      refute cap_present?(loaded, remove_a)
      refute cap_present?(loaded, remove_b)
      assert cap_present?(loaded, grant_a)
      assert cap_present?(loaded, grant_b)
      :ok = Ezagent.Kind.terminate(agent)
    end

    test "concurrent cold user grants and revokes serialize under the row lock" do
      user = user_uri("cold-user-concurrent")

      [remove_a, remove_b, grant_a, grant_b] =
        Enum.map([:send, :join, :history, :publish], &issued_cap(user, &1))

      assert {:ok, _user} = Ezagent.Users.create(user, nil, [remove_a, remove_b])

      assert [:ok, :ok, :ok, :ok] ==
               run_concurrent_mutations(user, [remove_a, remove_b], [grant_a, grant_b])

      loaded = EntityCaps.load(user)
      refute cap_present?(loaded, remove_a)
      refute cap_present?(loaded, remove_b)
      assert cap_present?(loaded, grant_a)
      assert cap_present?(loaded, grant_b)
    end

    test "concurrent cold snapshot grants and revokes serialize through one rehydrated Kind" do
      agent = agent_uri("cold-agent-concurrent")

      [remove_a, remove_b, grant_a, grant_b] =
        Enum.map([:send, :join, :history, :publish], &issued_cap(agent, &1))

      assert {:ok, %{version: initial_version}} =
               SnapshotStore.write(
                 agent,
                 %{
                   identity: %{
                     state: %{
                       caps: MapSet.new(licensed_caps(agent, [remove_a, remove_b]))
                     }
                   }
                 },
                 kind_type: :agent,
                 version: 0
               )

      assert [:ok, :ok, :ok, :ok] ==
               run_concurrent_mutations(agent, [remove_a, remove_b], [grant_a, grant_b])

      loaded = EntityCaps.load(agent)
      refute cap_present?(loaded, remove_a)
      refute cap_present?(loaded, remove_b)
      assert cap_present?(loaded, grant_a)
      assert cap_present?(loaded, grant_b)

      assert {:ok, %{version: version}} = SnapshotStore.latest(agent)
      assert version == initial_version
    end

    test "user delete-first and mutation-first races cannot revive provisioning or Kind state" do
      for first <- [:delete, :mutation] do
        user = user_uri("user-transition-#{first}")
        cap = issued_cap(user, :send)
        assert {:ok, _user} = Ezagent.Users.create_read_only(user, [])

        operations = %{
          delete: fn -> Ezagent.Users.delete(user) end,
          mutation: fn -> EntityCaps.grant(user, cap) end
        }

        {first_result, second_result} =
          run_ordered_transitions(user, operations[first], operations[opposite(first)])

        case first do
          :delete ->
            assert first_result == :ok
            assert second_result == {:error, :not_found}

          :mutation ->
            assert first_result == :ok
            assert second_result == :ok
        end

        assert is_nil(Ezagent.Users.get_by_uri(user))
        assert is_nil(Ezagent.Ecto.KindSnapshot.get(URI.to_string(user)))
        wait_until(fn -> Ezagent.KindRegistry.lookup(user) == :error end)
      end
    end

    test "snapshot-backed delete-first and mutation-first races cannot revive durable or live state" do
      for first <- [:delete, :mutation] do
        agent = agent_uri("snapshot-transition-#{first}")
        cap = issued_cap(agent, :send)

        assert {:ok, _snapshot} =
                 SnapshotStore.write(
                   agent,
                   %{identity: %{state: %{caps: MapSet.new()}}},
                   kind_type: :agent,
                   version: 0
                 )

        operations = %{
          delete: fn -> Ezagent.Lifecycle.destroy(agent, :transition_test) end,
          mutation: fn -> EntityCaps.grant(agent, cap) end
        }

        {first_result, second_result} =
          run_ordered_transitions(agent, operations[first], operations[opposite(first)])

        case first do
          :delete ->
            assert first_result == :ok
            assert second_result == {:error, :not_found}

          :mutation ->
            assert first_result == :ok
            assert second_result == :ok
        end

        assert {:error, :not_found} = SnapshotStore.latest(agent)
        wait_until(fn -> Ezagent.KindRegistry.lookup(agent) == :error end)
      end
    end
  end

  describe "#189 PR-3 anti-resurrection (regenesis → gen-gated denial; restart ≠ re-creation)" do
    test "a regenesis'd ephemeral principal's durable store row is gen-gated to [] on the persisted read" do
      worker = worker_uri("regenesis-no-resurrection")

      # Genuine creation: mint a CURRENT-generation self-license and make it
      # DURABLE in the store (`active`) — the cutover state after a genuine
      # `:created` spawn of an ephemeral worker.
      license = self_license(worker)
      assert :ok = Ezagent.EntityCaps.Store.persist(worker, [license])
      assert Ezagent.EntityCaps.Store.status(worker) == :active

      # Read-flip: the store is now the AUTHORITATIVE durable holder source, so the
      # cold/self persisted read — what the self-dispatch principal gate consults —
      # is non-empty. DISCRIMINATOR: on the pre-cutover read plane this is EMPTY
      # (`load_persisted` read the ephemeral snapshot, NOT the store), so this step
      # proves the fix — it is NOT a trivial "revoked → denied" that passes anyway.
      refute EntityCaps.load_persisted(worker) == []

      # Revoke by rotating the signing-authority generation. This touches ONLY the
      # authority; the store row is left `active` with the now stale-generation
      # self-license (regenesis never writes the store).
      assert {:ok, _new_authority} = Ezagent.Cap.Authority.regenesis(worker, :worker)
      assert Ezagent.EntityCaps.Store.status(worker) == :active

      # ...yet the durable persisted read is EMPTY: `EntityCaps.verified/2`
      # gen-gates the stale-generation self-license. The denial comes SOLELY from
      # the READ result, never the (misleadingly still-`active`) status.
      assert EntityCaps.load_persisted(worker) == []

      # The durable row remains the ever-created signal, so a cold restart is
      # classified `:existed` (not `:created`) → the principal RE-READS the stale
      # license and is NOT re-minted a fresh-generation one. Restart ≠ re-creation.
      assert Ezagent.EntityCaps.Store.ever_created_signal?(worker)
    end
  end

  describe "#189 PR-3 FIX 2 (post-epoch: a store READ ERROR denies, never falls back)" do
    test "a forced store read error denies even with a valid legacy self-license present" do
      agent = agent_uri("read-error-deny")
      license = self_license(agent)
      legacy_cap = issued_cap(agent, :send)

      # LEGACY (the durable snapshot) carries a CURRENT-valid self-license + cap,
      # so the legacy fallback, if taken, WOULD authorize. (Writing the snapshot
      # also PR-1 dual-writes an `active` store row — that is expected.)
      assert {:ok, _snap} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([license, legacy_cap])}}},
                 kind_type: :agent
               )

      # CONTROL (non-vacuous): PRE-EPOCH the read is legacy-authoritative and the
      # valid legacy license AUTHORIZES (non-empty). This proves the read-error
      # DENY below is the discriminator — the legacy source really would grant.
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, false)
      refute EntityCaps.load_persisted(agent) == []
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)

      # Now the AUTHORITATIVE store row is non-active (a store-only provisioning
      # revocation): a successful post-epoch read denies via status.
      assert :ok = Ezagent.EntityCaps.Store.revoke_provisioning(agent)
      assert Ezagent.EntityCaps.Store.status(agent) == :revoked_unprovisioned
      assert EntityCaps.load_persisted(agent) == []

      # DISCRIMINATOR — force the store read to ERROR. Pre-FIX-2 the error
      # collapsed to `:absent` and fell back to the VALID legacy license,
      # authorizing the revoked principal. Post-FIX-2 `{:error, _}` DENIES.
      Application.put_env(:ezagent_domain_identity, :p2_forced_read_error_uris, [store_key(agent)])

      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :p2_forced_read_error_uris)
      end)

      assert {:error, _} = Ezagent.EntityCaps.Store.fetch_durable_caps(agent)
      assert EntityCaps.load_persisted(agent) == []
    end
  end

  describe "#189 PR-3 FINAL ITEM 3 (an UNREADABLE epoch fails CLOSED, never to legacy)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :identity_cutover_force_read_error)
        # Restore the suite-wide active override the rest of the suite relies on.
        Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
      end)

      :ok
    end

    test "a fresh node with an UNREADABLE epoch DENIES reads — never the legacy fallback" do
      agent = agent_uri("epoch-unknown-read")
      license = self_license(agent)
      legacy_cap = issued_cap(agent, :send)

      # LEGACY (the durable snapshot) carries a CURRENT-valid self-license + cap,
      # so the legacy fallback, if taken, WOULD authorize.
      assert {:ok, _snap} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([license, legacy_cap])}}},
                 kind_type: :agent
               )

      # CONTROL (non-vacuous): a DEFINITIVE pre-cutover `:inactive` reads
      # legacy-authoritative, so the valid legacy license AUTHORIZES. This proves
      # the DENY below is the discriminator — the legacy source really would grant.
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, false)
      refute EntityCaps.load_persisted(agent) == []

      # DISCRIMINATOR — a FRESH post-cutover node (no cached sticky `true`) whose
      # epoch read ERRORS: clearing the override forces the DB-backed `status/0`,
      # the forced read error resolves it to `:unknown`, and the read DENIES
      # rather than falling back to the still-valid legacy license. Pre-ITEM-3
      # this fell through `active?/0 == false` to the legacy plane and RE-AUTHORIZED.
      Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)

      assert Ezagent.Identity.Cutover.status() == :unknown
      assert EntityCaps.load_persisted(agent) == []
    end

    test "a fresh node with an UNREADABLE epoch REJECTS identity mutations — never a legacy write" do
      user = user_uri("epoch-unknown-mutate")
      base = licensed_caps(user, [issued_cap(user, :send)])
      assert {:ok, _user} = Ezagent.Users.create(user, nil, base)

      # CONTROL (non-vacuous): a DEFINITIVE `:inactive` performs the
      # legacy-authoritative write (`:ok`).
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, false)
      assert :ok = Ezagent.EntityCaps.UserStore.persist(user, base)

      # DISCRIMINATOR — an unreadable epoch REJECTS the mutation with an explicit
      # reason: neither the legacy plane nor the store is written on `:unknown`.
      Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)

      assert Ezagent.Identity.Cutover.status() == :unknown

      assert {:error, :identity_epoch_unreadable} =
               Ezagent.EntityCaps.UserStore.persist(user, base)
    end

    test "a fresh node with an UNREADABLE epoch reports ever-created TRUE — no re-mint / resurrection" do
      agent = agent_uri("epoch-unknown-evercreated")
      # No store row, no authority history — under a definitive epoch this is a
      # genuine first-creation candidate (`ever_created_signal? == false`).
      refute Ezagent.EntityCaps.Store.has_row?(agent)

      Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)

      assert Ezagent.Identity.Cutover.status() == :unknown

      # Fail-CLOSED: an UNREADABLE epoch reports ever-created TRUE (⇒ `:existed`,
      # NO re-mint), so an ephemeral principal is never resurrected on an
      # unreadable epoch. Pre-ITEM-3 the `not active?()` gate returned `false`
      # here (⇒ `:created`), a fail-OPEN re-mint that bumps the authority
      # generation — resurrecting a revoked ephemeral.
      assert Ezagent.EntityCaps.Store.ever_created_signal?(agent)
    end
  end

  defp with_signature_enforced(fun) do
    previous = Application.get_env(:ezagent_core, Cap)
    cap_config = previous || []
    signing = cap_config |> Keyword.get(:signing, []) |> Keyword.put(:require_signature, true)
    Application.put_env(:ezagent_core, Cap, Keyword.put(cap_config, :signing, signing))

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:ezagent_core, Cap)
      else
        Application.put_env(:ezagent_core, Cap, previous)
      end
    end
  end

  defp issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://entity-caps/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp v2_issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://entity-caps/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now(),
      signing_version: 2,
      grant_id: Ecto.UUID.generate()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp revocation_attrs(receiver, cap) do
    %{
      grant_id: cap.grant_id,
      workspace_uri: receiver |> Ezagent.URI.workspace_of() |> Ezagent.URI.stable_key(),
      holder_uri: Ezagent.URI.stable_key(receiver),
      cap_identity_key:
        :crypto.hash(:sha256, :erlang.term_to_binary(Capability.identity_key(cap))),
      revoked_at: DateTime.utc_now(),
      target_uri: Ezagent.URI.stable_key(cap.instance),
      key_id: cap.key_id
    }
  end

  defp reissue_cap(authority, receiver, cap) do
    requested = %{cap | granted_by: nil, granted_at: nil, key_id: nil, signature: nil}
    authority_signed_cap_as!(authority, @issuer, receiver, requested)
  end

  defp licensed_caps(receiver, caps) do
    [self_license(receiver) | caps]
  end

  defp self_license(receiver) do
    {:ok, type} = Ezagent.URI.type(receiver)
    kind = String.to_existing_atom(type)
    {:ok, authority} = Ezagent.Cap.Authority.open(receiver, kind)

    requested =
      Capability.cap(
        kind,
        Ezagent.ActionSet.Identity,
        :self_license,
        receiver,
        Ezagent.URI.workspace_of(receiver)
      )

    intent = Ezagent.Cap.Grant.freeze(receiver, receiver, receiver, requested)

    {:ok, license} =
      Ezagent.Cap.Authority.with_current(authority, fn ->
        Ezagent.Cap.Authority.issue_self_license_current(intent)
      end)

    license
  end

  defp self_license?(cap), do: Capability.action_of(cap) == :self_license

  defp non_license_caps(caps), do: Enum.reject(caps, &self_license?/1)

  defp user_uri(suffix),
    do: URI.new!("entity://entity-caps/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp agent_uri(suffix),
    do: URI.new!("entity://entity-caps/agent/#{suffix}-#{System.unique_integer([:positive])}")

  defp worker_uri(suffix),
    do: URI.new!("entity://entity-caps/worker/#{suffix}-#{System.unique_integer([:positive])}")

  # The store's canonical URI-string key form (`instance |> to_string`) — matches
  # `Ezagent.EntityCaps.Store`'s `key/1` so the forced-read-error URI list keys
  # align with the store's row keys.
  defp store_key(uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()

  defp identity_keys(caps) do
    caps
    |> Enum.map(&Capability.identity_key/1)
    |> MapSet.new()
  end

  defp cap_present?(caps, cap),
    do: Capability.identity_key(cap) in identity_keys(caps)

  defp artifact_present?(caps, artifact),
    do: Enum.any?(caps, &(&1 == artifact))

  defp run_concurrent_mutations(uri, revoke_caps, grant_caps) do
    operations =
      Enum.map(revoke_caps, &{:revoke, &1}) ++
        Enum.map(grant_caps, &{:grant, &1})

    operations
    |> Task.async_stream(
      fn
        {:grant, cap} -> EntityCaps.grant(uri, cap)
        {:revoke, cap} -> EntityCaps.revoke(uri, cap)
      end,
      max_concurrency: length(operations),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp run_ordered_transitions(uri, first_operation, second_operation) do
    parent = self()
    ref = make_ref()

    first =
      Task.async(fn ->
        Ezagent.Lifecycle.with_entity_transition(uri, fn ->
          send(parent, {ref, :first_locked, self()})

          receive do
            {^ref, :run_first} -> first_operation.()
          end
        end)
      end)

    assert_receive {^ref, :first_locked, first_pid}, 1_000

    second =
      Task.async(fn ->
        assert transition_lock_available?(uri) == false
        send(parent, {ref, :second_observed_lock})
        result = second_operation.()
        send(parent, {ref, :second_done})
        result
      end)

    assert_receive {^ref, :second_observed_lock}, 1_000
    send(first_pid, {ref, :run_first})

    first_result = Task.await(first, 10_000)
    second_result = Task.await(second, 10_000)
    assert_receive {^ref, :second_done}
    {first_result, second_result}
  end

  defp opposite(:delete), do: :mutation
  defp opposite(:mutation), do: :delete

  defp transition_lock_available?(uri) do
    stable_key = uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key()
    lock_id = {{:ezagent_entity_transition, stable_key}, self()}

    if :global.set_lock(lock_id, [node()], 0) do
      :global.del_lock(lock_id, [node()])
      true
    else
      false
    end
  end

  defp wait_until_ready(uri),
    do: wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
