defmodule Ezagent.Cap.VisibilityTest do
  @moduledoc """
  URI-share unification (A2-1) — `Cap.Visibility.caps_toward/2`.

  The generic forward visibility derivation: given a cap set, list the concrete
  target instances the holder has CURRENT caps toward for a given behavior —
  "what can I see of this kind". Generalizes kanban's private per-board
  derivation into a reusable, plugin-agnostic helper. Current-generation aware
  (H3): a revoked (generation-bumped) cap is excluded, so forward visibility
  matches the reverse `grantees_of/2` index and the dispatch-time current-gen
  check. The authorization chokepoint stays `Cap.authorize`; this only enumerates.
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.Cap.Visibility
  alias Ezagent.URI, as: EzURI

  @b1 Ezagent.ActionSet.ApiKeys
  @b2 Ezagent.ActionSet.Session
  @issuer EzURI.new!("entity://acme/user/issuer")
  @workspace EzURI.new!("workspace://acme")

  # A concrete agent target with a live cap authority (so a cap toward it can be
  # signed at the current generation). Returns {target_uri, authority}.
  defp target(suffix) do
    uri = EzURI.new!("entity://acme/agent/board-#{suffix}-#{System.unique_integer([:positive])}")
    {:ok, authority} = Ezagent.Cap.Authority.open(uri, :agent)
    {uri, authority}
  end

  # A cap toward `target` signed under its CURRENT authority generation (stamps
  # the active key_id) — the shape `list_caps_for` returns for a held cap.
  defp signed_cap({target, authority}, behavior, action \\ :get_tree) do
    cap = Capability.cap(:agent, behavior, action, EzURI.instance(target), @workspace)
    authority_signed_cap_as!(authority, @issuer, @issuer, cap)
  end

  defp keys(uris), do: uris |> Enum.map(&EzURI.stable_key/1) |> Enum.sort()

  test "returns the concrete target instances for the given behavior only" do
    t1 = target("t1")
    t2 = target("t2")
    caps = [signed_cap(t1, @b1), signed_cap(t2, @b1), signed_cap(t1, @b2)]

    assert keys(Visibility.caps_toward(caps, @b1)) ==
             keys([EzURI.instance(elem(t1, 0)), EzURI.instance(elem(t2, 0))])

    # b2 target is not included under b1's enumeration.
    assert keys(Visibility.caps_toward(caps, @b2)) == keys([EzURI.instance(elem(t1, 0))])
  end

  test "de-dupes multiple caps toward the same target (e.g. read + operate)" do
    t1 = target("dedup")
    caps = [signed_cap(t1, @b1, :get_tree), signed_cap(t1, @b1, :add_node)]

    assert keys(Visibility.caps_toward(caps, @b1)) == keys([EzURI.instance(elem(t1, 0))])
  end

  test "excludes wildcard / non-concrete instances (:any) — only real targets" do
    t1 = target("real")
    wildcard = Capability.cap(:agent, @b1, :any, :any, @workspace)

    assert keys(Visibility.caps_toward([wildcard, signed_cap(t1, @b1)], @b1)) ==
             keys([EzURI.instance(elem(t1, 0))])
  end

  test "accepts a MapSet as well as a list; empty → []" do
    t1 = target("mapset")

    assert keys(Visibility.caps_toward(MapSet.new([signed_cap(t1, @b1)]), @b1)) ==
             keys([EzURI.instance(elem(t1, 0))])

    assert Visibility.caps_toward([], @b1) == []
    assert Visibility.caps_toward(MapSet.new(), @b1) == []
  end

  test "H3: a revoked (generation-bumped) cap drops out of forward visibility" do
    {uri, _authority} = t1 = target("revoked")
    cap = signed_cap(t1, @b1)

    # Current generation → visible.
    assert keys(Visibility.caps_toward([cap], @b1)) == keys([EzURI.instance(uri)])

    # Revocation-by-generation bumps the target's authority; the held cap keeps
    # its old key_id → no longer the active generation → excluded (matches the
    # reverse grantees_of index, unlike the old pure list-filter).
    assert {:ok, _} = Ezagent.Cap.Authority.regenesis(uri, :agent)
    assert Visibility.caps_toward([cap], @b1) == []
  end

  test "H3: an unsigned/legacy cap (no key_id) is never surfaced as current" do
    {uri, _authority} = target("unsigned")
    unsigned = Capability.cap(:agent, @b1, :get_tree, EzURI.instance(uri), @workspace)

    assert unsigned.key_id == nil
    assert Visibility.caps_toward([unsigned], @b1) == []
  end
end
