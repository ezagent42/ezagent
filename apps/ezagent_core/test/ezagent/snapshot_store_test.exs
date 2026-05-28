defmodule Ezagent.SnapshotStoreTest do
  @moduledoc """
  Phase 1C — `Ezagent.SnapshotStore` (SPEC
  `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §5.2).

  Covers:

  - write/latest round-trip across `term_to_binary`-encoded shapes.
  - delete is idempotent.
  - count tracks row total.
  - kind_type is required (write/3 contract).
  - version auto-increment when omitted; explicit version honoured.
  - snapshot_every_n_events reads app env + falls back to default.
  - workspace derivation: structural for entity URIs, inlined
    `workspace://system` for system://, raises for un-derivable schemes.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.SnapshotStore
  alias Ezagent.Ecto.KindSnapshot

  defp uniq, do: System.unique_integer([:positive])
  defp entity_uri, do: URI.parse("entity://user/team-alpha/snapstore-#{uniq()}")
  defp system_uri, do: URI.parse("system://bootstrap-#{uniq()}")

  test "write/3 then latest/1 round-trips state + version + kind_type" do
    uri = entity_uri()
    state = %{identity: %{caps: MapSet.new()}, slice_x: %{counter: 42}}

    assert {:ok, %{version: 1}} = SnapshotStore.write(uri, state, kind_type: :user)

    assert {:ok, %{state: ^state, version: 1, updated_at: %DateTime{}}} =
             SnapshotStore.latest(uri)
  end

  test "latest/1 returns {:error, :not_found} when no row exists" do
    uri = entity_uri()

    assert {:error, :not_found} = SnapshotStore.latest(uri)
  end

  test "write/3 returns {:error, :missing_kind_type} when kind_type opt is omitted" do
    uri = entity_uri()

    assert {:error, :missing_kind_type} = SnapshotStore.write(uri, %{}, [])
  end

  test "write/3 auto-increments version on repeat write" do
    uri = entity_uri()

    assert {:ok, %{version: 1}} = SnapshotStore.write(uri, %{x: 1}, kind_type: :user)
    assert {:ok, %{version: 2}} = SnapshotStore.write(uri, %{x: 2}, kind_type: :user)
    assert {:ok, %{version: 3}} = SnapshotStore.write(uri, %{x: 3}, kind_type: :user)

    # latest reports the most recent version.
    assert {:ok, %{state: %{x: 3}, version: 3}} = SnapshotStore.latest(uri)
  end

  test "write/3 honours explicit :version when supplied" do
    uri = entity_uri()

    assert {:ok, %{version: 7}} =
             SnapshotStore.write(uri, %{x: 1}, kind_type: :user, version: 7)

    assert {:ok, %{version: 7}} = SnapshotStore.latest(uri)

    # Subsequent auto-increment continues from explicit version.
    assert {:ok, %{version: 8}} = SnapshotStore.write(uri, %{x: 2}, kind_type: :user)
  end

  test "delete/1 is idempotent — :ok whether row existed or not" do
    uri = entity_uri()

    # No row yet.
    assert :ok = SnapshotStore.delete(uri)

    # Write, then delete.
    {:ok, _} = SnapshotStore.write(uri, %{x: 1}, kind_type: :user)
    assert {:ok, _} = SnapshotStore.latest(uri)
    assert :ok = SnapshotStore.delete(uri)
    assert {:error, :not_found} = SnapshotStore.latest(uri)

    # Delete-already-deleted.
    assert :ok = SnapshotStore.delete(uri)
  end

  test "count/0 reflects writes + deletes" do
    initial = SnapshotStore.count()

    uri_a = entity_uri()
    uri_b = entity_uri()

    {:ok, _} = SnapshotStore.write(uri_a, %{}, kind_type: :user)
    {:ok, _} = SnapshotStore.write(uri_b, %{}, kind_type: :user)

    assert SnapshotStore.count() == initial + 2

    :ok = SnapshotStore.delete(uri_a)
    assert SnapshotStore.count() == initial + 1
  end

  test "system:// URI lands in workspace://system (inlined literal, SPEC #324 rev 3)" do
    uri = system_uri()

    {:ok, _} = SnapshotStore.write(uri, %{x: 1}, kind_type: :system)

    row = KindSnapshot.get(URI.to_string(uri))
    assert row.workspace_uri == "workspace://system"
  end

  test "entity:// URI derives workspace structurally from URI path" do
    uri = URI.parse("entity://user/team-alpha/wsderive-#{uniq()}")

    {:ok, _} = SnapshotStore.write(uri, %{x: 1}, kind_type: :user)

    row = KindSnapshot.get(URI.to_string(uri))
    assert row.workspace_uri == "workspace://team-alpha"
  end

  test "explicit :workspace_uri opt overrides structural derivation" do
    uri = entity_uri()

    {:ok, _} =
      SnapshotStore.write(uri, %{x: 1},
        kind_type: :user,
        workspace_uri: "workspace://override-#{uniq()}"
      )

    row = KindSnapshot.get(URI.to_string(uri))
    assert String.starts_with?(row.workspace_uri, "workspace://override-")
  end

  test "snapshot_every_n_events/0 reads app env + falls back to default 100" do
    # Default (no app env override).
    Application.delete_env(:ezagent_core, :snapshot_every_n_events)
    assert SnapshotStore.snapshot_every_n_events() == 100

    # Override via env.
    Application.put_env(:ezagent_core, :snapshot_every_n_events, 42)

    on_exit(fn -> Application.delete_env(:ezagent_core, :snapshot_every_n_events) end)

    assert SnapshotStore.snapshot_every_n_events() == 42
  end

  test "term_to_binary survives MapSet round-trip (lossless encoding)" do
    uri = entity_uri()
    caps = MapSet.new([:cap_a, :cap_b, :cap_c])

    {:ok, _} = SnapshotStore.write(uri, %{caps: caps}, kind_type: :user)

    {:ok, %{state: %{caps: loaded_caps}}} = SnapshotStore.latest(uri)
    assert %MapSet{} = loaded_caps
    assert loaded_caps == caps
  end

  test ":written telemetry fires on successful write" do
    test_pid = self()
    ref = make_ref()
    handler_id = "snapstore-written-#{uniq()}"

    :telemetry.attach(
      handler_id,
      [:ezagent, :snapshot_store, :written],
      fn _e, _m, meta, _config -> send(test_pid, {ref, :seen, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    uri = entity_uri()
    {:ok, _} = SnapshotStore.write(uri, %{x: 1}, kind_type: :user)

    assert_receive {^ref, :seen, %{uri: _, kind_type: "user", version: 1}}, 500
  end
end
