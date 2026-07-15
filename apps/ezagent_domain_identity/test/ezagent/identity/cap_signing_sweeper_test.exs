defmodule Ezagent.Identity.CapSigningSweeperTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.EntityCaps.UserStore
  alias Ezagent.Identity.{CapSigningAudit, CapSigningSweeper}

  test "a failed enqueue leaves the exact durable candidate eligible for the next pass" do
    holder = user_uri("retry")
    legacy = legacy_identity_cap(holder)

    entries = %{
      users_caps_json: [entry(:users_caps_json, holder, legacy)],
      kind_snapshots: [entry(:kind_snapshots, holder, legacy)],
      recipe_cap_bindings: [],
      cap_quarantine: [%{status: :open}]
    }

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    enqueue = fn ^holder, plan ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})
      assert length(plan.reissue) == 1
      if call == 0, do: {:error, :outbox_unavailable}, else: :ok
    end

    first = CapSigningSweeper.sweep_entries(entries, enqueue)
    assert first.candidates == 1
    assert first.holders == 1
    assert first.enqueued_holders == 0
    assert first.enqueue_errors == [{holder, :outbox_unavailable}]
    assert first.open_quarantined == 1

    second = CapSigningSweeper.sweep_entries(entries, enqueue)
    assert second.candidates == 1
    assert second.enqueued_holders == 1
    assert second.enqueue_errors == []
    assert Agent.get(calls, & &1) == 2
  end

  test "a never-activated user drains from unsigned in both durable homes to strict-clean" do
    holder = user_uri("cold")
    legacy = legacy_identity_cap(holder)

    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [legacy])
    insert_snapshot!(holder, legacy)

    assert :error = Ezagent.KindRegistry.lookup(holder)
    assert holder_unsigned_count(holder) == 2

    result = CapSigningSweeper.sweep()
    assert result.candidates == 1
    assert result.enqueue_errors == []
    assert result.enqueued_holders == 1

    assert_eventually(fn -> holder_unsigned_count(holder) == 0 end)

    assert [user_artifact] = UserStore.load(holder)
    assert Ezagent.Cap.signed_and_valid?(user_artifact, holder)

    entries = CapSigningAudit.collect_entries()

    assert Enum.any?(entries.kind_snapshots, fn
             %{holder_uri: ^holder, cap: cap} -> Ezagent.Cap.signed_and_valid?(cap, holder)
             _entry -> false
           end)
  end

  test "a caps_json-only User with no snapshot is cold-spawned and drained" do
    holder = user_uri("seed-only")
    legacy = legacy_identity_cap(holder)

    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [legacy])

    assert :error = Ezagent.KindRegistry.lookup(holder)
    assert is_nil(Ezagent.Ecto.KindSnapshot.get(URI.to_string(holder)))
    assert holder_unsigned_count(holder) == 1

    result = CapSigningSweeper.sweep()
    assert result.enqueue_errors == []
    assert result.enqueued_holders == 1

    assert_eventually(fn -> holder_unsigned_count(holder) == 0 end)
    assert [artifact] = UserStore.load(holder)
    assert Ezagent.Cap.signed_and_valid?(artifact, holder)
  end

  defp entry(source, holder, cap), do: %{source: source, holder_uri: holder, cap: cap}

  defp user_uri(prefix) do
    Ezagent.URI.user("team-alpha", "#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp legacy_identity_cap(holder) do
    %Capability{
      kind: :user,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: holder,
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp insert_snapshot!(holder, cap) do
    state = %{identity: %{state: %{caps: MapSet.new([cap])}, transients: %{}}}

    {:ok, _row} =
      Ezagent.Test.SnapshotFixtures.upsert_kind_snapshot(
        URI.to_string(holder),
        "user",
        :erlang.term_to_binary(state),
        0,
        "workspace://team-alpha"
      )
  end

  defp holder_unsigned_count(holder) do
    CapSigningAudit.collect_entries()
    |> Map.take([:users_caps_json, :kind_snapshots, :recipe_cap_bindings])
    |> Map.values()
    |> List.flatten()
    |> Enum.count(fn
      %{holder_uri: ^holder, cap: %Capability{} = cap} ->
        not Ezagent.Cap.signed_and_valid?(cap, holder)

      %{holder_uri: ^holder, error: _reason} ->
        true

      _entry ->
        false
    end)
  end

  defp assert_eventually(fun, attempts \\ 150)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("signing sweeper did not drain before timeout")
end
