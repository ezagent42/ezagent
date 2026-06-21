defmodule Ezagent.SystemPrincipalEliminationTest do
  @moduledoc """
  NORTH-STAR ratchet, TERMINAL state (Allen 2026-06-17; genesis collapse 2026-06-20).

  `system://` principals were an artifact of not having modeled the real authority.
  The program collapsed `SystemPrincipal.Catalog` to a SINGLE genesis primitive
  (`system://bootstrap`) and then, in the final step, collapsed even that into the
  admin ENTITY (`entity://system/user/admin`) self-authority. Every authority now
  traces to a real accountable entity (the actor's own held caps, a rule attributed
  to a real configurer, or the genesis admin entity).

  This was the broader sibling of `no_unowned_system_principal_grant_test.exs` (which
  only ratchets the GRANT-MINTERS). This gate ratcheted the ENTIRE principal set to
  ZERO.

  ## Terminal invariants (literal ratchet 0)

  1. The closed `Catalog` is EMPTY — no `system://` URI is an authorization principal.
  2. The genesis authority traces to a REAL ENTITY: the canonical genesis cap
     (`Ezagent.Capability.admin_genesis_cap/0`) is the all-`:any` wildcard whose
     `granted_by` is `entity://system/user/admin` (scheme `entity`, NOT `system`),
     and `Ezagent.Capability.admin_invariant?/1` recognizes it as the revoke-protected
     genesis cap.

  Adding ANY entry back to the Catalog fails invariant (1) — a Decision-#154 review
  surface. Re-pointing the genesis cap's `granted_by` to a `system://` URI fails
  invariant (2). Together they are the standing guard against re-introducing a
  `system://` principal.

  Per-class collapse history — see
  `.claude/skills/ezagent-developer/references/capbac.md` §7 "NORTH STAR".
  """

  use ExUnit.Case, async: true

  alias Ezagent.SystemPrincipal.Catalog

  @admin_uri Ezagent.URI.user(:system, :admin)

  test "the closed Catalog is EMPTY — literal ratchet 0, no system:// authorization principal" do
    assert Catalog.uris() == [],
           "The north star is ZERO system principals. Catalog still has: " <>
             "#{inspect(Catalog.uris())}. Every authority must trace to a real entity " <>
             "(self-held caps / a rule with a configurer / the genesis admin entity). " <>
             "Re-adding a Catalog entry is a Decision-#154 violation. See capbac.md §7."
  end

  test "genesis authority traces to the admin ENTITY, not a system:// principal" do
    cap = Ezagent.Capability.admin_genesis_cap()

    # (a) It is the all-:any wildcard (the Decision #81 admin invariant shape).
    assert cap.kind == :any and cap.behavior == :any and cap.action == :any and
             cap.instance == :any and cap.workspace_uri == :any,
           "genesis cap must be the all-:any wildcard, got: #{inspect(cap)}"

    # (b) Its granter is a REAL ENTITY (scheme `entity`), specifically the admin
    #     entity — NOT the eliminated `system://bootstrap` principal.
    assert %URI{scheme: "entity"} = cap.granted_by,
           "genesis cap granted_by must be an entity:// URI, got: #{inspect(cap.granted_by)}"

    assert URI.to_string(cap.granted_by) == URI.to_string(@admin_uri),
           "genesis cap granted_by must be the admin entity #{URI.to_string(@admin_uri)}, " <>
             "got: #{URI.to_string(cap.granted_by)}"

    # (c) The revoke-protection recognizer still identifies it as the genesis cap.
    assert Ezagent.Capability.admin_invariant?(cap),
           "admin_invariant?/1 must recognize the admin-granted genesis cap as " <>
             "revoke-protected; the recognizer + minter must not drift."
  end

  test "north-star reached — 0 system principals remain (+ genesis collapsed to admin entity)" do
    assert length(Catalog.uris()) == 0

    IO.puts(
      "\n[north-star] system principals remaining to eliminate: 0 (genesis collapsed to entity://system/user/admin)\n"
    )
  end
end
