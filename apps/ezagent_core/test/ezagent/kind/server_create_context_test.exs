defmodule Ezagent.Kind.ServerCreateContextTest do
  @moduledoc """
  #533 5a (§3.10.3) — `Kind.Server.init/1` threads an optional `created_by`
  create-arg into the server state (the path `owner_uri` already takes for
  Session) and records the create-vs-activate freshness from the **Lifecycle**
  signal (`Ezagent.Lifecycle.fresh_create?/1`), NOT from a snapshot/save
  return. PR-5c reads both off this state to fire the manage-cap grant
  exactly once for the true creator (on `:created`).
  """
  use Ezagent.LifecycleCase

  alias Ezagent.TestSupport.LifecycleFixtureKind

  defp fixture_uri do
    URI.new!("system://lifecycle_fixture/cc-#{System.unique_integer([:positive])}")
  end

  test "init records created_by and create_freshness=:created on a fresh spawn" do
    creator = URI.new!("entity://user/team-alpha/registrar-#{System.unique_integer([:positive])}")
    uri = fixture_uri()

    {:ok, pid} =
      Ezagent.Kind.spawn(LifecycleFixtureKind, %{
        uri: uri,
        counter: 0,
        label: "fx",
        created_by: creator
      })

    state = :sys.get_state(pid)

    assert state.created_by == creator
    assert state.create_freshness == :created
  end

  test "init defaults created_by to nil and freshness is still :created when arg absent" do
    uri = fixture_uri()

    {:ok, pid} =
      Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: uri, counter: 0, label: "fx"})

    state = :sys.get_state(pid)

    assert state.created_by == nil
    assert state.create_freshness == :created
  end

  # Codex review P2 regression — a snapshot-rehydrated Lifecycle Kind must
  # classify as :existed (NOT :unknown). Proves `hosts_lifecycle_slice?`
  # still holds after `load_or_init` re-coerces the loaded slice to the
  # two-container shape on cold restart, so `Lifecycle.fresh_create?/1`
  # (marker=true) correctly yields :existed.
  test "init records create_freshness=:existed on rehydrate (cold restart of an existing Lifecycle Kind)" do
    uri = fixture_uri()

    {:ok, pid1} =
      Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: uri, counter: 0, label: "fx"})

    assert :sys.get_state(pid1).create_freshness == :created

    # Terminate the process; the snapshot row (ever_created=true) persists
    # — this is a cold restart, not a destroy.
    :ok = Ezagent.Kind.terminate(uri)

    {:ok, pid2} =
      Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: uri, counter: 0, label: "fx"})

    assert :sys.get_state(pid2).create_freshness == :existed
  end
end
