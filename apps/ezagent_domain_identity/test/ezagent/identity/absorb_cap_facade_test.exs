defmodule Ezagent.Identity.AbsorbCapFacadeTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4, signed_fixture_cap!: 5]

  alias Ezagent.Cap.Delivery
  alias Ezagent.Cap.DeliveryOutbox
  alias Ezagent.Cap.DeliveryOutbox.Sweeper
  alias Ezagent.Capability
  alias EzagentCore.Repo

  test "absorb persists in the durable outbox, bypasses ETS, and applies after ready" do
    unique = System.unique_integer([:positive])
    user_uri = Ezagent.URI.user("team-alpha", "absorb-not-ready-#{unique}")
    issuer = Ezagent.URI.user("team-alpha", "issuer-#{unique}")

    {:ok, _user} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, pid} = Ezagent.SpawnRegistry.spawn(user_uri)

    on_exit(fn ->
      _ = Ezagent.PendingDelivery.flush(user_uri)
      if Process.alive?(pid), do: Ezagent.Kind.terminate(user_uri)
    end)

    proposal = %Capability{
      kind: :user,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: Ezagent.URI.instance(user_uri),
      workspace_uri: Ezagent.Capability.workspace_of(user_uri),
      granted_by: issuer,
      granted_at: DateTime.utc_now()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(user_uri, :user)
    artifact = authority_signed_cap_as!(authority, issuer, user_uri, proposal)

    :ok = Ezagent.ReadyGate.put(user_uri, :not_ready)
    buffer_size_before = Ezagent.PendingDelivery.buffer_size(user_uri)

    queried_target = Ezagent.URI.with_action(user_uri, :identity, :list_caps)
    task = Task.async(fn -> Ezagent.Identity.absorb_cap(queried_target, artifact) end)

    assert {:ok, :ok} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert Ezagent.PendingDelivery.buffer_size(user_uri) == buffer_size_before

    delivery =
      Repo.one!(
        from(delivery in Delivery,
          where: delivery.target_uri == ^URI.to_string(user_uri),
          where: delivery.op == :absorb_cap
        )
      )

    assert delivery.status == :pending
    assert delivery.attempts >= 1
    assert delivery.workspace_uri == "workspace://team-alpha"

    assert {:ok, before_slice} = Ezagent.Kind.read(user_uri, :identity, spawn: :never)
    before_caps = before_slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)
    refute Enum.member?(before_caps, artifact)

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(user_uri),
               pid
             )

    assert eventually(fn ->
             with {:ok, slice} <- Ezagent.Kind.read(user_uri, :identity, spawn: :never) do
               caps = slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)

               Enum.member?(caps, artifact) and
                 Repo.get!(Delivery, delivery.id).status == :applied
             else
               _ -> false
             end
           end)

    # Simulate the crash window where the handler committed but the outbox
    # status update was lost. Replaying the same serialized artifact is
    # idempotent in the real Identity handler and converges back to applied.
    delivery
    |> Ecto.Changeset.change(status: :pending, applied_at: nil, next_retry_at: DateTime.utc_now())
    |> Repo.update!()

    assert :ok = DeliveryOutbox.attempt(delivery.id)

    assert eventually(fn ->
             with {:ok, slice} <- Ezagent.Kind.read(user_uri, :identity, spawn: :never) do
               caps = slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)

               Repo.get!(Delivery, delivery.id).status == :applied and
                 Enum.count(caps, &(&1 == artifact)) == 1
             else
               _ -> false
             end
           end)
  end

  test "periodic sweeper retries a pending row again after worker restart" do
    unique = System.unique_integer([:positive])
    missing_uri = Ezagent.URI.user("team-alpha", "missing-cap-target-#{unique}")

    artifact =
      signed_fixture_cap!(
        missing_uri,
        :user,
        Ezagent.ActionSet.Identity,
        :list_caps,
        missing_uri
      )

    assert :ok = Ezagent.Identity.absorb_cap(missing_uri, artifact)

    delivery =
      Repo.one!(
        from(delivery in Delivery,
          where: delivery.target_uri == ^URI.to_string(missing_uri),
          where: delivery.op == :absorb_cap
        )
      )

    assert delivery.status == :pending
    assert delivery.attempts == 1
    assert Ezagent.PendingDelivery.buffer_size(missing_uri) == 0

    make_due!(delivery.id)
    first_sweeper = start_supervised!({Sweeper, interval_ms: 60_000})
    assert eventually(fn -> Repo.get!(Delivery, delivery.id).attempts >= 2 end)
    _state = :sys.get_state(first_sweeper)

    stop_supervised(Sweeper)
    make_due!(delivery.id)
    second_sweeper = start_supervised!({Sweeper, interval_ms: 60_000})

    assert eventually(fn -> Repo.get!(Delivery, delivery.id).attempts >= 3 end)
    _state = :sys.get_state(second_sweeper)
    assert Repo.get!(Delivery, delivery.id).status == :pending
  end

  test "future synchronous acknowledgement hook is default-off and has no waiter API" do
    assert DeliveryOutbox.require_sync_ack() == []
    refute function_exported?(DeliveryOutbox, :await_applied, 1)
    refute function_exported?(DeliveryOutbox, :await_applied, 2)
  end

  defp make_due!(delivery_id) do
    Delivery
    |> Repo.get!(delivery_id)
    |> Ecto.Changeset.change(next_retry_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
