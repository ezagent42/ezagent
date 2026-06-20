defmodule EzagentCore.Invariants.NoWildcardSystemPrincipalsTest do
  @moduledoc """
  PR-CC-2-v2 §5 — system principals must not carry the full-wildcard cap shape.

  The "full-wildcard" shape is `%Capability{kind: :any, behavior: :any,
  instance: :any, workspace_uri: :any}` — the structural admin invariant per
  Decision #81 + SPEC v3 §4.4.

  #154 genesis collapse (2026-06-20) — the LAST wildcard-holding principal,
  `system://bootstrap`, was collapsed into the admin ENTITY. The closed Catalog
  is now EMPTY, so NO `system://` principal holds a wildcard (the strongest form
  of this invariant). The genesis wildcard now lives on the admin entity, minted
  by `Ezagent.Capability.admin_genesis_cap/0` (granted_by
  `entity://system/user/admin`) — verified by `system_principal_elimination_test.exs`.

  (This gate is vestigial post-collapse — the empty Catalog makes the first test
  vacuous — and is slated for deletion in the follow-up cleanup; it is kept green
  here so the ratchet-0 commit stays green.)

  See SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §5.
  """

  use ExUnit.Case, async: true

  alias Ezagent.SystemPrincipal.Catalog

  test "NO system principal holds a wildcard cap (Catalog is empty post-collapse)" do
    offenders =
      for {uri, caps} <- Catalog.entries(),
          Enum.any?(caps, &wildcard_cap?/1),
          do: uri

    assert offenders == [],
           "system principals must not carry wildcard caps; the genesis wildcard " <>
             "now lives on the admin entity, not a `system://` principal. Offenders: " <>
             inspect(offenders)
  end

  test "the genesis wildcard now lives on the admin entity, not a system principal" do
    cap = Ezagent.Capability.admin_genesis_cap()
    assert wildcard_cap?(cap), "admin_genesis_cap/0 must be the all-:any wildcard"

    assert %URI{scheme: "entity"} = cap.granted_by,
           "the genesis wildcard's granted_by must be a real entity, got: " <>
             inspect(cap.granted_by)
  end

  defp wildcard_cap?(%Ezagent.Capability{
         kind: :any,
         behavior: :any,
         instance: :any,
         workspace_uri: :any
       }),
       do: true

  defp wildcard_cap?(%Ezagent.Capability{}), do: false
end
