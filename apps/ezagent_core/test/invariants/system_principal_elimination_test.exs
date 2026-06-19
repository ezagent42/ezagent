defmodule Ezagent.SystemPrincipalEliminationTest do
  @moduledoc """
  NORTH-STAR ratchet: eliminate `system://` principals entirely (Allen 2026-06-17).

  `system://` principals are an artifact of not having modeled the real authority. The
  goal is to collapse `SystemPrincipal.Catalog` to a SINGLE genesis primitive
  (`system://bootstrap`, itself slated to become `entity://system/user/admin` self-authority
  in the final step); every other authority must trace to a real accountable entity
  (the actor's own held caps, a rule attributed to a real configurer, or the genesis admin).

  This is the broader sibling of `no_unowned_system_principal_grant_test.exs` (which only
  ratchets the GRANT-MINTERS). This gate ratchets the ENTIRE principal set.

  Mechanism (mirrors the no_unowned idiom Allen accepted): `@remaining` is the named set of
  not-yet-eliminated principals; the live Catalog must equal `@remaining ++ [@genesis]`
  exactly. Any Catalog change FORCES an edit here — adding a principal grows `@remaining`
  (a review surface that contradicts the north star → reject), removing one shrinks it
  (the per-class elimination PR's job). The allowlist only shrinks; the terminal state is
  `@remaining == []`, then `@genesis` collapses to the admin entity (the last PR).

  Per-class collapse plan — see `.claude/skills/ezagent-developer/references/capbac.md` §7
  "NORTH STAR".
  """

  use ExUnit.Case, async: true

  alias Ezagent.SystemPrincipal.Catalog

  # The one genesis primitive — eliminated LAST (collapses to entity://system/user/admin).
  @genesis "system://bootstrap"

  # The principals still awaiting elimination. Each per-class PR REMOVES its entries.
  # Shrink-only: the north star is `@remaining == []`.
  @remaining [
    "system://chat-router",
    "system://chat-reply",
    # ELIMINATED: "system://worker-publish" — the ExternalMirrorWorker's two
    # internal self-dispatches now carry their OWN inline authorizer caps
    # (`caller: self_uri` + self-authority publish cap / admin-granted
    # subscribe cap) instead of borrowing this ambient principal.
    "system://template-materialize",
    "system://orchestrator-tools",
    "system://session-internal",
    "system://agent-internal",
    "system://workspace-loader",
    "system://mix-task",
    # ELIMINATED: "system://feishu-binding-policy" (#824 — last grant-minter;
    # redundant re-grant removed) and "system://credential-materializer"
    # (api-key materialization → agent self-authority; per-grant GrantCap remains).
    "system://lv-anon-mount",
    "system://socialware-gc"
  ]

  test "the live Catalog is EXACTLY the genesis primitive + the not-yet-eliminated allowlist" do
    live = MapSet.new(Catalog.uris())
    accounted = MapSet.new([@genesis | @remaining])

    unlisted = MapSet.difference(live, accounted) |> MapSet.to_list()
    stale = MapSet.difference(accounted, live) |> MapSet.to_list()

    assert unlisted == [],
           "New/unaccounted system principal(s): #{inspect(unlisted)} — the north star is to " <>
             "ELIMINATE system principals, not add them. If this is genuinely unavoidable, it is " <>
             "a Decision-#154 review surface; otherwise model the authority as a real entity " <>
             "(self-held caps / a rule with a configurer / the genesis admin). See capbac.md §7."

    assert stale == [],
           "Allowlist entr(ies) no longer in the Catalog: #{inspect(stale)} — an elimination PR " <>
             "removed the principal. Remove it from @remaining too (the allowlist only shrinks)."
  end

  test "the elimination ratchet is monotonic — count never exceeds the allowlist" do
    # A defensive companion to the exact-match test: even if someone swaps (removes one,
    # adds one) the total must not grow beyond the recorded allowlist size.
    assert length(Catalog.uris()) <= length(@remaining) + 1,
           "System-principal count grew. The north star is monotonic elimination; the only " <>
             "permitted Catalog change is REMOVAL (+ a matching @remaining shrink)."
  end

  test "north-star progress is observable" do
    remaining = length(@remaining)
    # Not an assertion on a target (the program lands across PRs) — a visible counter so the
    # ratchet's progress is legible in CI output. Terminal target: 0 remaining (+ genesis,
    # which the final PR collapses to entity://system/user/admin).
    assert remaining >= 0
    IO.puts("\n[north-star] system principals remaining to eliminate: #{remaining} (+ genesis)\n")
  end
end
