defmodule Ezagent.SpawnFenceTest do
  @moduledoc """
  Unit tests for `Ezagent.SpawnFence` — the core-owned registry of
  principal-tombstone spawn predicates (task #180 / codex F1).

  Registry semantics: registered predicates run at every Kind start /
  registry return; `:ok` requires ALL predicates to admit; the first
  refusal wins; a crashing or misbehaving predicate fails CLOSED (a fence
  that cannot say "admit" must never admit).

  NB: in the umbrella test env the identity app registers its
  `:identity_tombstone` predicate at boot — these tests use their own
  predicate names (and clean them up), and use entity URIs with no
  tombstone records so the identity predicate admits throughout.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — the identity app's boot registration is
  # part of the fixture; resolves only in the umbrella.
  @moduletag :umbrella_only

  alias Ezagent.SpawnFence

  @admit_uri URI.parse("entity://team-alpha/user/fence-unit-admit")
  @refuse_uri URI.parse("entity://team-alpha/user/fence-unit-refuse")

  setup do
    on_exit(fn ->
      SpawnFence.unregister(:unit_fence_a)
      SpawnFence.unregister(:unit_fence_b)
      SpawnFence.unregister(:unit_fence_crash)
      SpawnFence.unregister(:unit_fence_bad_return)
    end)

    :ok
  end

  test "a registry whose predicates all admit returns :ok" do
    :ok = SpawnFence.register(:unit_fence_a, fn _uri -> :ok end)
    :ok = SpawnFence.register(:unit_fence_b, fn _uri -> :ok end)

    assert :ok = SpawnFence.check(@admit_uri)
    assert :ok = SpawnFence.check(@refuse_uri)
  end

  test "the FIRST refusing predicate's error is returned; unregister re-admits" do
    :ok =
      SpawnFence.register(:unit_fence_a, fn uri ->
        if uri == @refuse_uri, do: {:error, {:principal_tombstoned, uri}}, else: :ok
      end)

    assert {:error, {:principal_tombstoned, @refuse_uri}} = SpawnFence.check(@refuse_uri)
    assert :ok = SpawnFence.check(@admit_uri)

    # Non-tuple contract violations are not silently admitted either.
    :ok = SpawnFence.unregister(:unit_fence_a)
    assert :ok = SpawnFence.check(@refuse_uri)
  end

  test "a crashing predicate fails CLOSED (never silently admits)" do
    :ok =
      SpawnFence.register(:unit_fence_crash, fn _uri ->
        raise "fence exploded"
      end)

    assert {:error, {:spawn_fence_error, :unit_fence_crash, _detail}} =
             SpawnFence.check(@admit_uri)
  end

  test "an exiting predicate fails CLOSED" do
    :ok =
      SpawnFence.register(:unit_fence_crash, fn _uri ->
        exit(:fence_down)
      end)

    assert {:error, {:spawn_fence_error, :unit_fence_crash, {:exit, :fence_down}}} =
             SpawnFence.check(@admit_uri)
  end

  test "a predicate with a non-contract return fails CLOSED" do
    :ok = SpawnFence.register(:unit_fence_bad_return, fn _uri -> :yes end)

    assert {:error, {:spawn_fence_error, :unit_fence_bad_return, {:bad_return, :yes}}} =
             SpawnFence.check(@admit_uri)
  end

  test "re-registering the same name overwrites (late-binding wins)" do
    :ok = SpawnFence.register(:unit_fence_a, fn _uri -> {:error, :first} end)
    assert {:error, :first} = SpawnFence.check(@admit_uri)

    :ok = SpawnFence.register(:unit_fence_a, fn _uri -> :ok end)
    assert :ok = SpawnFence.check(@admit_uri)
  end
end
