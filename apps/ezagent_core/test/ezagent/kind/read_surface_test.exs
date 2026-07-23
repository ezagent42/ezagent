defmodule Ezagent.Kind.ReadSurfaceTest do
  @moduledoc """
  Unit tests for the SPEC 2026-07-23 §2.2 actor-extraction public read surface —
  the eight ADDITIVE `Ezagent.Kind` wrappers landed in C0. Each test proves the
  wrapper composes the correct internal with ZERO behavior change.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind
  alias Ezagent.Test.SnapshotFixtures

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp unique_uri do
    Ezagent.URI.new!("entity://team-alpha/agent/rs-#{System.unique_integer([:positive])}")
  end

  defp spawn_onchange(uri) do
    {:ok, pid} = Ezagent.Kind.Server.start_link({Ezagent.Test.OnChangeTestKind, %{uri: uri}})
    pid
  end

  # A cold-but-durable instance: a snapshot row exists, no live process. Seeds
  # through the sanctioned test writer (SnapshotFixtures), per the
  # test_snapshot_fixture_access gate.
  defp seed_durable(uri, state_map, version) do
    {:ok, _row} =
      SnapshotFixtures.upsert_kind_snapshot(
        URI.to_string(uri),
        "test",
        :erlang.term_to_binary(state_map),
        version,
        "workspace://team-alpha"
      )

    :ok
  end

  # ── read/3 ──────────────────────────────────────────────────────────────────

  describe "read/3" do
    test "live process → the normalized live slice (== get_slice/2)" do
      uri = unique_uri()
      spawn_onchange(uri)

      assert {:ok, %{count: 0, last_msg: nil}} = Kind.read(uri, :test)
      assert Kind.read(uri, :test) == Kind.get_slice(uri, :test)
    end

    test "spawn: :never on a cold URI → {:error, :not_live}" do
      uri = unique_uri()
      seed_durable(uri, %{test: %{count: 9, last_msg: "x"}}, 1)

      assert {:error, :not_live} = Kind.read(uri, :test, spawn: :never)
    end

    test "never durably created → {:error, :not_created}" do
      assert {:error, :not_created} = Kind.read(unique_uri(), :test)
    end
  end

  # ── read_classified/2 ───────────────────────────────────────────────────────

  describe "read_classified/2" do
    test "live slice → {:ok, value}" do
      uri = unique_uri()
      spawn_onchange(uri)

      assert {:ok, %{count: 0, last_msg: nil}} = Kind.read_classified(uri, :test)
    end

    test "never created → :absent (clean deny)" do
      assert :absent = Kind.read_classified(unique_uri(), :test)
    end

    test "delegates to SliceAccess.read_classified/2" do
      uri = unique_uri()
      spawn_onchange(uri)

      assert Kind.read_classified(uri, :test) ==
               Ezagent.Kind.SliceAccess.read_classified(uri, :test)
    end
  end

  # ── read_durable/3 ──────────────────────────────────────────────────────────

  describe "read_durable/3" do
    test "durable row → {:ok, value, meta} with version + updated_at" do
      uri = unique_uri()
      seed_durable(uri, %{test: %{count: 7, last_msg: "hi"}}, 3)

      assert {:ok, %{count: 7, last_msg: "hi"}, meta} = Kind.read_durable(uri, :test)
      assert meta.version == 3
      assert %DateTime{} = meta.updated_at
    end

    test "no durable row → {:error, :not_created}" do
      assert {:error, :not_created} = Kind.read_durable(unique_uri(), :test)
    end

    test "reads the DURABLE row, not the live process" do
      # Live slice is count: 0; the durable row we seed says count: 42. A durable
      # read must return the ROW, proving it never consults the live process.
      uri = unique_uri()
      spawn_onchange(uri)
      seed_durable(uri, %{test: %{count: 42, last_msg: "durable"}}, 8)

      assert {:ok, %{count: 42, last_msg: "durable"}, %{version: 8}} =
               Kind.read_durable(uri, :test)
    end
  end

  # ── read_durable_many/3 ─────────────────────────────────────────────────────

  describe "read_durable_many/3" do
    test "batch projection; missing URIs → {:error, :not_created}; agrees with read_durable/3" do
      u1 = unique_uri()
      u2 = unique_uri()
      u3 = unique_uri()
      seed_durable(u1, %{test: %{count: 1}}, 2)
      seed_durable(u2, %{test: %{count: 2}}, 5)

      result = Kind.read_durable_many([u1, u2, u3], :test)

      assert {:ok, %{count: 1}, %{version: 2}} = result[u1]
      assert {:ok, %{count: 2}, %{version: 5}} = result[u2]
      assert {:error, :not_created} = result[u3]

      # single + batch agree by construction (same row, same decode)
      assert result[u1] == Kind.read_durable(u1, :test)
      assert result[u2] == Kind.read_durable(u2, :test)
    end
  end

  # ── resolve_action_subject/2 ────────────────────────────────────────────────

  describe "resolve_action_subject/2" do
    test "live target → {:ok, {kind_module, behavior_module}} (only the atoms)" do
      uri = unique_uri()
      spawn_onchange(uri)

      assert {:ok, {Ezagent.Test.OnChangeTestKind, Ezagent.Test.TestBehavior}} =
               Kind.resolve_action_subject(uri, :noop)
    end

    test "accepts a pid directly" do
      uri = unique_uri()
      pid = spawn_onchange(uri)

      assert {:ok, {Ezagent.Test.OnChangeTestKind, Ezagent.Test.TestBehavior}} =
               Kind.resolve_action_subject(pid, :noop)
    end

    test "cold URI → {:error, :not_live} (does not spawn)" do
      assert {:error, :not_live} = Kind.resolve_action_subject(unique_uri(), :noop)
    end

    test "unknown action → {:error, {:unknown_action, _}}" do
      uri = unique_uri()
      spawn_onchange(uri)

      assert {:error, {:unknown_action, :nope}} = Kind.resolve_action_subject(uri, :nope)
    end
  end

  # ── alive? / self? / list_instances ─────────────────────────────────────────

  describe "alive?/1, self?/1, list_instances/0" do
    test "alive?/1 delegates to LocalRuntime.kind_alive?/1" do
      uri = unique_uri()
      assert Kind.alive?(uri) == false

      spawn_onchange(uri)
      assert Kind.alive?(uri) == Ezagent.LocalRuntime.kind_alive?(uri)
    end

    test "self?/1 is false from a foreign process; false when cold" do
      uri = unique_uri()
      assert Kind.self?(uri) == false

      spawn_onchange(uri)
      # the test process is NOT the Kind's own process
      assert {:ok, pid} = Ezagent.KindRegistry.lookup(uri)
      refute pid == self()
      assert Kind.self?(uri) == false
    end

    test "list_instances/0 wraps KindRegistry.list_all as {uri_string, %{pid: pid}}" do
      uri = unique_uri()
      pid = spawn_onchange(uri)

      instances = Kind.list_instances()
      assert {URI.to_string(uri), %{pid: pid}} in instances

      assert Enum.sort(instances) ==
               Ezagent.KindRegistry.list_all()
               |> Enum.map(fn {u, p} -> {u, %{pid: p}} end)
               |> Enum.sort()
    end
  end
end
