defmodule Ezagent.EntityCapsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cap, Capability, EntityCaps, SnapshotStore}

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

    on_exit(&Ezagent.EntityCapsReadyBarrier.clear/0)
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

      assert {:ok, _user} = Ezagent.Users.create(user, nil, [user_cap])

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([agent_cap])}}},
                 kind_type: :agent
               )

      assert identity_keys(EntityCaps.load(user)) == identity_keys([user_cap])
      assert identity_keys(EntityCaps.load(agent)) == identity_keys([agent_cap])
      assert identity_keys(EntityCaps.load_persisted(user)) == identity_keys([user_cap])
      assert identity_keys(EntityCaps.load_persisted(agent)) == identity_keys([agent_cap])
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
                 %{identity: %{state: %{caps: MapSet.new([persisted_cap])}}},
                 kind_type: :agent
               )

      assert cap_present?(EntityCaps.load(agent), live_cap)
      refute cap_present?(EntityCaps.load(agent), persisted_cap)
      refute cap_present?(EntityCaps.load(agent), wrong_receiver)
      assert identity_keys(EntityCaps.load_persisted(agent)) == identity_keys([persisted_cap])

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
                 %{identity: %{state: %{caps: MapSet.new([bound, wrong_receiver])}}},
                 kind_type: :agent
               )

      with_signature_enforced(fn ->
        loaded = EntityCaps.load(agent)
        assert cap_present?(loaded, bound)
        refute cap_present?(loaded, wrong_receiver)
      end)
    end

    test "a transient live read fails closed instead of falling back to stale durable caps" do
      agent = agent_uri("transient")
      stale = issued_cap(agent, :history)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([stale])}}},
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

    test "grant rejects an unsigned legacy cap even when signature enforcement is disabled" do
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
      assert {:error, :invalid_cap_artifact} = EntityCaps.grant(user, forged)
      assert {:error, :invalid_cap_artifact} = EntityCaps.persist(user, [forged])
      assert EntityCaps.load_persisted(user) == []
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
                 %{identity: %{state: %{caps: MapSet.new([remove_a, remove_b])}}},
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

    {:ok, artifact} = Cap.issue({:genesis, @issuer}, receiver, unsigned)
    artifact
  end

  defp user_uri(suffix),
    do: URI.new!("entity://entity-caps/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp agent_uri(suffix),
    do: URI.new!("entity://entity-caps/agent/#{suffix}-#{System.unique_integer([:positive])}")

  defp identity_keys(caps) do
    caps
    |> Enum.map(&Capability.identity_key/1)
    |> MapSet.new()
  end

  defp cap_present?(caps, cap),
    do: Capability.identity_key(cap) in identity_keys(caps)

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
