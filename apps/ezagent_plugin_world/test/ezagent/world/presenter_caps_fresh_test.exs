defmodule Ezagent.World.PresenterCapsFreshTest do
  @moduledoc """
  Actor-extraction C1 — PresenterCaps re-derives caps FRESH per action.

  Fail-before/pass-after for the PresenterCaps session-staleness bug
  (docs/futures/todo.md 2026-07-22): before C1, `load/1` merged the mount-time
  bootstrap snapshot (`assigns.current_caps`) over the live set, so a
  bootstrap-only authority artifact survived a mid-session demotion (a demoted
  admin kept publish/admin rights until re-login). After C1, `load/1` is exactly
  `EntityCaps.load(presenter)` — no mount snapshot is trusted, so the stale
  artifact is gone on the very next action.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, EntityCaps}
  alias Ezagent.World.PresenterCaps
  alias Ezagent.World.PresenterCaps.EphemeralCaps

  test "load re-derives fresh caps per action and drops the stale mount-snapshot artifact" do
    # A presenter whose FRESH held-cap set is whatever the durable/live Identity
    # store says right now (empty here — never granted / fully demoted).
    presenter =
      Ezagent.URI.agent("presenter-fresh", "demoted-#{System.unique_integer([:positive])}")

    fresh = MapSet.new(EntityCaps.load(presenter))

    # The mount-time bootstrap snapshot still carries an authority cap the
    # principal no longer holds. It must NOT survive into a later action.
    stale = stale_cap(presenter)
    refute MapSet.member?(fresh, stale)

    socket = %{
      assigns: %{
        current_entity_uri: presenter,
        current_caps: MapSet.new([stale])
      }
    }

    loaded = PresenterCaps.load(socket)

    # C1: load == the fresh set exactly (no mount merge). Pre-C1 this RED-fails
    # because `merge/2` keeps the mount-only `stale` artifact.
    assert loaded == fresh

    refute Enum.any?(
             loaded,
             &(Capability.identity_key(&1) == Capability.identity_key(stale))
           )
  end

  test "load_with_ephemeral carries a request-time JIT cap that fresh load alone drops" do
    # The C1 carve-out's live consumer: a JIT capability minted per request
    # (`Ezagent.Cap.issue/3`, e.g. the kanban published-read share path) that is
    # NEVER written to the principal's durable Identity slice, so fresh `load/1`
    # cannot (and must not) resurrect it — it is passed through the explicit
    # ephemeral narrow path instead.
    presenter =
      Ezagent.URI.agent("presenter-ephemeral", "jit-#{System.unique_integer([:positive])}")

    assert MapSet.new(EntityCaps.load(presenter)) == MapSet.new()

    jit = stale_cap(presenter)
    socket = %{assigns: %{current_entity_uri: presenter}}

    # Plain load correctly drops the un-persisted JIT cap (no mount snapshot).
    refute has_cap?(PresenterCaps.load(socket), jit)

    # The explicit, TAGGED ephemeral path unions it over the fresh set (carve-out).
    assert has_cap?(
             PresenterCaps.load_with_ephemeral(socket, %EphemeralCaps{caps: MapSet.new([jit])}),
             jit
           )
  end

  defp has_cap?(caps, cap),
    do: Enum.any?(caps, &(Capability.identity_key(&1) == Capability.identity_key(cap)))

  defp stale_cap(presenter) do
    session = Ezagent.URI.session(:system, :generic, "presenter-staleness")

    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :send,
      session,
      Capability.workspace_of(session)
    )
    |> Map.merge(%{grantee_uri: presenter, key_id: "mount", signature: "mount"})
  end
end
