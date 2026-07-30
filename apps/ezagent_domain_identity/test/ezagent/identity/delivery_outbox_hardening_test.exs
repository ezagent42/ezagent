defmodule Ezagent.Identity.DeliveryOutboxHardeningTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5]

  alias Ezagent.Cap.Delivery
  alias Ezagent.Cap.DeliveryOutbox
  alias Ezagent.Cap.DeliveryOutbox.Sweeper
  alias Ezagent.Invocation
  alias EzagentCore.Repo

  test "producer idempotency retries reuse one durable row and re-attempt it" do
    {target, pid} = spawn_target("idem-retry")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    key = "cap-delivery-#{System.unique_integer([:positive])}"
    invocation = absorb_invocation(target, capability(target), idempotency_key: key)

    assert :ok = Invocation.dispatch(invocation)
    first = one_delivery!(target)
    assert first.attempts == 1

    assert :ok = Invocation.dispatch(invocation)
    second = Repo.get!(Delivery, first.id)

    assert second.attempts == 2
    assert delivery_count(target) == 1

    terminate(target, pid)
  end

  test "failed durable acceptance does not consume the generic idempotency key" do
    target = Ezagent.URI.user("team-alpha", unique("invalid-envelope"))
    key = "cap-delivery-invalid-#{System.unique_integer([:positive])}"
    cap = capability(target)

    invocation = %Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :identity, :revoke_cap),
      mode: :cast,
      args: %{cap: cap},
      ctx: %{
        caller: Ezagent.URI.user("team-alpha", unique("caller")),
        authenticated_principal: Ezagent.URI.user("team-alpha", unique("holder")),
        caps: MapSet.new([self()]),
        reply: :ignore,
        idempotency_key: key,
        cap_delivery_producer: :identity_revoke
      }
    }

    result = Invocation.dispatch(invocation)

    refute Ezagent.Idempotency.seen?(key)
    assert {:error, :invalid_delivery_envelope} = result
    assert delivery_count(target) == 0
  end

  test "same durable idempotency key with a different payload is rejected" do
    {target, pid} = spawn_target("idem-conflict")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    key = "cap-delivery-conflict-#{System.unique_integer([:positive])}"
    cap = capability(target)

    assert :ok = Invocation.dispatch(absorb_invocation(target, cap, idempotency_key: key))

    conflicting = %{cap | action: :has_cap?}

    assert {:error, :idempotency_conflict} =
             Invocation.dispatch(absorb_invocation(target, conflicting, idempotency_key: key))

    assert delivery_count(target) == 1
    terminate(target, pid)
  end

  test "same cap and idempotency key with a different authenticated presenter is rejected" do
    {target, pid} = spawn_target("idem-authorization-conflict")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    key = "cap-delivery-authorization-conflict-#{System.unique_integer([:positive])}"
    cap = capability(target)
    first_presenter = Ezagent.URI.user("team-alpha", unique("first-presenter"))
    second_presenter = Ezagent.URI.user("team-alpha", unique("second-presenter"))

    first = revoke_invocation(target, cap, first_presenter, key)
    conflicting = revoke_invocation(target, cap, second_presenter, key)

    assert :ok = Invocation.dispatch(first)
    assert {:error, :idempotency_conflict} = Invocation.dispatch(conflicting)
    assert delivery_count(target) == 1

    terminate(target, pid)
  end

  test "same semantic caps in different insertion order have one canonical envelope" do
    {target, pid} = spawn_target("idem-caps-order")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    key = "cap-delivery-caps-order-#{System.unique_integer([:positive])}"
    cap = capability(target)

    authorization_caps =
      for offset <- 1..40 do
        %{cap | granted_at: DateTime.add(cap.granted_at, offset, :microsecond)}
      end

    ascending = MapSet.new(authorization_caps)
    descending = authorization_caps |> Enum.reverse() |> MapSet.new()

    assert :ok =
             Invocation.dispatch(
               absorb_invocation(target, cap, idempotency_key: key, caps: ascending)
             )

    delivery = one_delivery!(target)
    envelope = :erlang.binary_to_term(delivery.payload, [:safe])

    assert envelope.caps ==
             Enum.sort_by(authorization_caps, &:erlang.term_to_binary(&1, [:deterministic]))

    assert :ok =
             Invocation.dispatch(
               absorb_invocation(target, cap, idempotency_key: key, caps: descending)
             )

    assert delivery_count(target) == 1
    terminate(target, pid)
  end

  test "the persisted envelope is versioned, allowlisted, and contains no reply pid" do
    {target, pid} = spawn_target("canonical-envelope")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)

    invocation =
      target
      |> absorb_invocation(capability(target))
      |> put_in([Access.key!(:ctx), :reply], {:caller_inbox, self()})
      |> put_in([Access.key!(:ctx), :trace_id], "must-not-persist")

    assert :ok = Invocation.dispatch(invocation)
    delivery = one_delivery!(target)
    envelope = :erlang.binary_to_term(delivery.payload, [:safe])

    assert Map.keys(envelope) |> Enum.sort() ==
             [
               :authenticated_principal,
               :caller,
               :cap,
               :caps,
               :op,
               :presenter,
               :producer,
               :target_uri,
               :version
             ]

    assert envelope.version == Ezagent.Cap.DeliveryOutbox.Envelope.version()
    assert envelope.producer == :identity_absorb
    assert envelope.target_uri == URI.to_string(target)
    assert envelope.caller == :vm_internal
    assert envelope.authenticated_principal == target
    assert envelope.caps == []
    refute contains_pid?(envelope)

    terminate(target, pid)
  end

  test "matching action names without the internal producer marker stay on normal delivery" do
    {target, pid} = spawn_target("marker")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    before = Ezagent.PendingDelivery.buffer_size(target)

    invocation =
      target
      |> absorb_invocation(capability(target))
      |> update_in([Access.key!(:ctx)], &Map.delete(&1, :cap_delivery_producer))

    assert :ok = Invocation.dispatch(invocation)
    assert delivery_count(target) == 0
    assert Ezagent.PendingDelivery.buffer_size(target) == before + 1

    _ = Ezagent.PendingDelivery.flush(target)
    terminate(target, pid)
  end

  test "two concurrent workers atomically claim one pending delivery" do
    {target, pid} = spawn_target("concurrent-claim")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    assert :ok = Ezagent.Identity.absorb_cap(target, capability(target))
    delivery = one_delivery!(target)
    make_due!(delivery.id)

    :ok = Ezagent.ReadyGate.mark_ready(target)
    :ok = :sys.suspend(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :sys.resume(pid)
    end)

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          receive do
            :go -> DeliveryOutbox.attempt(delivery.id)
          end
        end)
      end

    Enum.each(tasks, fn task ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
      send(task.pid, :go)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :claimed_elsewhere})) == 1
    assert Repo.get!(Delivery, delivery.id).attempts == delivery.attempts + 1

    :ok = :sys.resume(pid)

    assert eventually(fn -> raw_status(delivery.id) == "applied" end)
    terminate(target, pid)
  end

  test "an expired claimant cannot overwrite a newer lease, whose claimant can converge" do
    {target, pid} = spawn_target("stale-claim")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    cap = capability(target)
    assert :ok = Ezagent.Identity.absorb_cap(target, cap)
    delivery = one_delivery!(target)
    lease_until = DateTime.add(DateTime.utc_now(), 60, :second)

    Repo.query!(
      "UPDATE cap_delivery_outbox SET claim_token = $1, lease_until = $2 WHERE id = $3",
      ["new-claim", lease_until, delivery.id]
    )

    stale = replay_invocation(target, cap, delivery.id, "old-claim")
    current = replay_invocation(target, cap, delivery.id, "new-claim")

    assert {:error, :stale_claim} = DeliveryOutbox.mark_applied(delivery.id, stale)
    assert raw_status(delivery.id) == "pending"
    assert claim_token(delivery.id) == "new-claim"

    assert :ok = DeliveryOutbox.mark_applied(delivery.id, current)
    assert raw_status(delivery.id) == "applied"
    terminate(target, pid)
  end

  test "a transient handler commit failure releases its claim with an audited retry" do
    {target, pid} = spawn_target("transient-handler")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    cap = capability(target)
    assert :ok = Ezagent.Identity.absorb_cap(target, cap)
    delivery = one_delivery!(target)
    lease_until = DateTime.add(DateTime.utc_now(), 60, :second)

    Repo.query!(
      "UPDATE cap_delivery_outbox SET claim_token = $1, lease_until = $2 WHERE id = $3",
      ["transient-claim", lease_until, delivery.id]
    )

    replay = replay_invocation(target, cap, delivery.id, "transient-claim")

    assert :ok =
             DeliveryOutbox.record_handler_failure(
               replay,
               {:persistence_failed, :database_unavailable}
             )

    refreshed = Repo.get!(Delivery, delivery.id)
    assert refreshed.status == :pending
    assert refreshed.claim_token == nil
    assert refreshed.lease_until == nil
    assert DateTime.compare(refreshed.next_retry_at, DateTime.utc_now()) == :gt
    assert refreshed.last_error =~ "database_unavailable"
    terminate(target, pid)
  end

  test "poison envelopes become dead without stopping the sweeper or later rows" do
    {target, pid} = spawn_target("poison")
    cap = capability(target)
    poison_target = Ezagent.URI.user("team-alpha", unique("poison-row"))
    now = DateTime.add(DateTime.utc_now(), -1, :second)

    poison =
      insert_raw_delivery!(
        poison_target,
        %{
          version: Ezagent.Cap.DeliveryOutbox.Envelope.version(),
          producer: :identity_absorb,
          target_uri: URI.to_string(poison_target),
          op: :absorb_cap,
          cap: capability(poison_target),
          caller: :vm_internal,
          presenter: :vm_internal,
          caps: [],
          extra: :must_be_rejected
        },
        now
      )

    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    assert :ok = Ezagent.Identity.absorb_cap(target, cap)
    good = one_delivery!(target)
    make_due!(good.id)
    :ok = Ezagent.ReadyGate.mark_ready(target)

    sweeper = start_supervised!({Sweeper, interval_ms: 60_000})

    assert eventually(fn ->
             Process.alive?(sweeper) and
               raw_status(poison.id) == "dead" and
               raw_status(good.id) == "applied"
           end)

    terminate(target, pid)
  end

  test "pending absorb view returns only validated pending absorb artifacts" do
    {target, pid} = spawn_target("pending-absorb-view")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    cap = capability(target)

    assert :ok = Ezagent.Identity.absorb_cap(target, cap)
    pending = one_delivery!(target)

    insert_raw_delivery!(
      target,
      %{version: :ignored_revoke_envelope},
      DateTime.utc_now(),
      op: :revoke_cap
    )

    assert {:ok, [loaded]} = DeliveryOutbox.list_pending_absorb_caps(target)
    assert Ezagent.Capability.identity_key(loaded) == Ezagent.Capability.identity_key(cap)

    pending
    |> Ecto.Changeset.change(status: :applied, applied_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, []} = DeliveryOutbox.list_pending_absorb_caps(target)
    terminate(target, pid)
  end

  test "a malformed pending envelope makes the pending absorb view fail closed" do
    target = Ezagent.URI.user("team-alpha", unique("malformed-pending-view"))

    delivery =
      insert_raw_delivery!(
        target,
        %{version: :not_a_valid_envelope},
        DateTime.utc_now()
      )

    assert {:error, {:invalid_pending_delivery, id, _reason}} =
             DeliveryOutbox.list_pending_absorb_caps(target)

    assert id == delivery.id
  end

  test "a permanent authorization failure is audited as dead by the target handler" do
    {target, pid} = spawn_target("permanent-auth")
    cap = capability(target)
    caller = Ezagent.URI.user("team-alpha", unique("unauthorized"))
    assert {:ok, _user} = Ezagent.Users.create(caller, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)

    invocation = %Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :identity, :revoke_cap),
      mode: :cast,
      args: %{cap: cap},
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: MapSet.new(),
        reply: :ignore,
        cap_delivery_producer: :identity_revoke
      }
    }

    assert :ok = Invocation.dispatch(invocation)
    delivery = one_delivery!(target)

    assert eventually(fn ->
             raw_status(delivery.id) == "dead" and
               String.contains?(last_error(delivery.id), "missing_cap")
           end)

    terminate(target, pid)
  end

  test "cold boot rehydrates empty ETS hints from DB before successful delivery" do
    {target, pid} = spawn_target("cold-hints")
    :ok = Ezagent.ReadyGate.put(target, :not_ready)
    assert :ok = Ezagent.Identity.absorb_cap(target, capability(target))
    delivery = one_delivery!(target)
    assert DeliveryOutbox.pending_target?(target)

    :ets.delete_all_objects(DeliveryOutbox.table())
    refute DeliveryOutbox.pending_target?(target)

    assert :ok = DeliveryOutbox.rehydrate_hints()
    assert DeliveryOutbox.pending_target?(target)

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(target),
               pid
             )

    assert eventually(fn -> raw_status(delivery.id) == "applied" end)
    terminate(target, pid)
  end

  defp absorb_invocation(target, cap, opts \\ []) do
    ctx = %{
      caller: :vm_internal,
      caps: Keyword.get(opts, :caps, MapSet.new()),
      reply: :ignore,
      cap_delivery_producer: :identity_absorb
    }

    ctx =
      Enum.reduce([:idempotency_key], ctx, fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    %Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :identity, :absorb_cap),
      mode: :cast,
      args: %{artifact: cap},
      ctx: ctx
    }
  end

  defp revoke_invocation(target, cap, presenter, idempotency_key) do
    %Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :identity, :revoke_cap),
      mode: :cast,
      args: %{cap: cap},
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new(),
        reply: :ignore,
        idempotency_key: idempotency_key,
        cap_delivery_producer: :identity_revoke
      }
    }
  end

  defp replay_invocation(target, cap, delivery_id, claim_token) do
    invocation = absorb_invocation(target, cap)

    %{
      invocation
      | ctx:
          invocation.ctx
          |> Map.put(:cap_delivery_id, delivery_id)
          |> Map.put(:cap_delivery_claim_token, claim_token)
    }
  end

  defp spawn_target(prefix) do
    target = Ezagent.URI.user("team-alpha", unique(prefix))
    {:ok, _user} = Ezagent.Users.create(target, nil, [])
    {:ok, pid} = Ezagent.SpawnRegistry.spawn(target)
    assert :ok = Ezagent.ReadyGate.await(target, 2_000)
    {target, pid}
  end

  defp capability(target) do
    signed_fixture_cap!(
      target,
      :user,
      Ezagent.ActionSet.Identity,
      :list_caps,
      target
    )
  end

  defp one_delivery!(target) do
    Repo.one!(
      from(delivery in Delivery,
        where: delivery.target_uri == ^URI.to_string(target),
        order_by: [desc: delivery.id],
        limit: 1
      )
    )
  end

  defp delivery_count(target) do
    Repo.aggregate(
      from(delivery in Delivery, where: delivery.target_uri == ^URI.to_string(target)),
      :count
    )
  end

  defp insert_raw_delivery!(target, envelope, next_retry_at, opts \\ []) do
    attrs = %{
      workspace_uri: Ezagent.Persistence.workspace_uri_for!(target),
      target_uri: URI.to_string(target),
      op: Keyword.get(opts, :op, :absorb_cap),
      payload: :erlang.term_to_binary(envelope),
      payload_identity: "poison-#{System.unique_integer([:positive])}",
      status: :pending,
      attempts: 0,
      next_retry_at: next_retry_at
    }

    %Delivery{}
    |> Delivery.changeset(attrs)
    |> Repo.insert!()
  end

  defp make_due!(delivery_id) do
    Delivery
    |> Repo.get!(delivery_id)
    |> Ecto.Changeset.change(next_retry_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()
  end

  defp raw_status(delivery_id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM cap_delivery_outbox WHERE id = $1", [delivery_id])

    status
  end

  defp claim_token(delivery_id) do
    %{rows: [[token]]} =
      Repo.query!("SELECT claim_token FROM cap_delivery_outbox WHERE id = $1", [delivery_id])

    token
  end

  defp last_error(delivery_id) do
    %{rows: [[error]]} =
      Repo.query!("SELECT last_error FROM cap_delivery_outbox WHERE id = $1", [delivery_id])

    error || ""
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp terminate(target, pid) do
    if Process.alive?(pid), do: Ezagent.Kind.terminate(target)
  end

  defp contains_pid?(term) when is_pid(term), do: true
  defp contains_pid?(%_{} = term), do: term |> Map.from_struct() |> contains_pid?()
  defp contains_pid?(term) when is_map(term), do: Enum.any?(term, &contains_pid?/1)
  defp contains_pid?(term) when is_list(term), do: Enum.any?(term, &contains_pid?/1)
  defp contains_pid?(term) when is_tuple(term), do: term |> Tuple.to_list() |> contains_pid?()
  defp contains_pid?(_term), do: false

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
