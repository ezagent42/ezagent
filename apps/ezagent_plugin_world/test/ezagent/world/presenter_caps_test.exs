defmodule Ezagent.World.PresenterCapsTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.World.PresenterCaps
  alias Ezagent.World.PresenterCaps.EphemeralCaps

  # No presenter in assigns → fresh `EntityCaps.load` is []; this isolates the
  # ephemeral-tag behavior without a DB. The DB-backed fresh-vs-ephemeral union
  # (and the staleness fail-before/pass-after) live in `presenter_caps_fresh_test.exs`.
  @no_presenter %{assigns: %{}}

  test "load_with_ephemeral admits TAGGED JIT caps (unioned over the fresh set)" do
    jit = ephemeral_cap(:send)

    loaded = PresenterCaps.load_with_ephemeral(@no_presenter, %EphemeralCaps{caps: [jit]})

    assert MapSet.member?(loaded, jit)
  end

  test "load_with_ephemeral REJECTS an untagged/arbitrary cap (no stale-cap reservoir)" do
    # A fabricated mount-style artifact. Pre-C1 the mount-snapshot merge admitted
    # any %Capability{}; the ephemeral union now REQUIRES the explicit EphemeralCaps
    # tag, so a bare enumerable of caps is refused — there is no reservoir for a
    # future stale/forged cap to ride in on.
    fabricated =
      ephemeral_cap(:join) |> Map.merge(%{key_id: "mount", signature: "mount"})

    assert_raise FunctionClauseError, fn ->
      PresenterCaps.load_with_ephemeral(@no_presenter, MapSet.new([fabricated]))
    end

    assert_raise FunctionClauseError, fn ->
      PresenterCaps.load_with_ephemeral(@no_presenter, [fabricated])
    end
  end

  test "the ephemeral tag carries only %Capability{} structs into the set" do
    jit = ephemeral_cap(:send)

    loaded =
      PresenterCaps.load_with_ephemeral(@no_presenter, %EphemeralCaps{caps: [jit, :not_a_cap]})

    assert loaded == MapSet.new([jit])
  end

  test "EphemeralCaps requires its :caps field" do
    assert_raise ArgumentError, fn -> struct!(EphemeralCaps, %{}) end
  end

  defp ephemeral_cap(action) do
    session = Ezagent.URI.session(:system, :generic, "presenter-caps")

    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      action,
      session,
      Capability.workspace_of(session)
    )
  end
end
