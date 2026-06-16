defmodule EzagentCore.Invariants.NoUnownedSystemPrincipalGrantTest do
  @moduledoc """
  Ratchet invariant for GLOSSARY Decision #154 — **No unowned permissions**.

  > Every capability's `granted_by` MUST be a real entity. Auto-dispatched
  > permissions are driven by a RULE, and whoever configured the rule is the
  > granter of that permission. In the extreme case the granter is the
  > `entity://system/user/admin` entity. Abstract `system://…` Catalog principals
  > that are not real accountable entities violate this. (Allen, 2026-06-16.)

  SPEC `docs/superpowers/specs/2026-06-16-dynamic-mount-unmount-entity-model.md`;
  audit `docs/notes/2026-06-16-capbac-system-principal-audit.md`.

  ## What this gate ratchets

  A principal is **category-B ("unowned authority")** when it MINTS permissions
  it cannot honestly own — i.e. it holds a `cap(_, IdentityAdmin, :grant_cap |
  :revoke_cap)`. Such a grant's `granted_by` points at the abstract `system://…`
  principal rather than the real configurer entity (session owner / agent creator
  / rule configurer). Per the audit, exactly one principal is **confirmed-B**
  today: `system://template-materialize`.

  Note the distinction the gate is built on: `grant_minting_cap?/1` identifies
  grant-*minters* (a STRUCTURAL fact — the principal holds `grant_cap`/`revoke_cap`).
  It does NOT, by itself, decide "confirmed-B": that is a human judgment layered on
  top (Allen rules each minter → A or → B). So the honest invariant is *"every
  grant-minter must be EXPLICITLY classified"* — in `@confirmed_b_allowlist` OR in
  `@needs_allen`. A minter may never be silently parked in `@category_a` ("conforms,
  nothing to see"). Today three principals mint: `template-materialize`
  (confirmed-B), `agent-internal` + `feishu-binding-policy` (strong-B-lean,
  needs-Allen).

  The gate has FOUR teeth (none is a tautology):

    1. **Every grant-minter is classified** — the live Catalog's grant-minter set
       MUST be a subset of `@confirmed_b_allowlist ∪ @needs_allen`. A NEW
       grant-minting principal added without a classification (or worse, parked in
       `@category_a` as "benign") goes RED — a minter can never be silently called
       conforming. Adding a minter needs the SPEC + separate-PR review surface the
       Catalog moduledoc requires.

    2. **Allowlist only shrinks** — every URI in `@confirmed_b_allowlist` MUST
       still be a live `Catalog.uris()` member. When a conversion lands (#811
       cap#2 + #808 anon-access are the first removals → 0) the principal's
       grant-cap goes away (or the principal is deleted); the stale allowlist
       entry then goes RED and FORCES the shrink. This is what makes "allowlist
       only shrinks as conversions land" real rather than aspirational.

    3. **A converted minter forces the allowlist shrink** — an allowlisted
       principal that survives in the Catalog but loses its grant/revoke-cap (the
       shape a #153 manager-delegation conversion produces) drops out of the live
       minter set; the now-non-load-bearing allowlist entry goes RED.

    4. **Every principal is classified** — the union of the four buckets
       (`@category_a`, `@confirmed_b_allowlist`, `@needs_allen`, `@bootstrap`)
       MUST equal `Catalog.uris()` exactly. A new principal (a 17th catalog
       entry) FORCES a classification decision here — it cannot be silently added.

  `@needs_allen` is a SEPARATE bucket the gate tracks but does NOT conflate with
  B: Allen moves each → A (drop) or → B (add to the allowlist, then convert). The
  gate does NOT force `@needs_allen` to shrink — that is human-managed (only the
  confirmed-B allowlist ratchets, per teeth 2+3).

  This is `async: true` + NOT `:umbrella_only`: it reads only `Ezagent.Capability`
  + `Ezagent.SystemPrincipal.Catalog`, both in `ezagent_core` (modelled on its
  semantic siblings `no_wildcard_system_principals_test.exs` /
  `no_admin_caps_fallback_test.exs` in this directory).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.SystemPrincipal.Catalog

  @bootstrap "system://bootstrap"

  # ── classification of the 15 named Catalog principals (audit 2026-06-16) ──

  # (A) Conforms — boot/operator infra, self-authority, or empty-cap audit
  # identity (no authority ⇒ nothing to be unowned).
  @category_a [
    "system://boot-reconciler",
    "system://adapter-install",
    "system://worker-publish",
    "system://workspace-loader",
    "system://mix-task",
    "system://lv-anon-mount",
    "system://credential-materializer",
    "system://socialware-gc"
  ]

  # (B) CONFIRMED violates — the spec-named workaround (§1) that owner/manager-
  # delegation (#153) replaces. An allowlist of 1 that ratchets to 0.
  # Comment (per task): #808 anon-access + #811 cap#2 are the first removals → 0.
  @confirmed_b_allowlist [
    "system://template-materialize"
  ]

  # needs-Allen — evidence-grounded lean, Allen adjudicates → A or → B.
  # agent-internal + feishu-binding-policy are strong-B-lean (they hold
  # grant_cap); the rest are fan-out/proxy principals (lean A). See audit.
  @needs_allen [
    "system://chat-router",
    "system://chat-reply",
    "system://orchestrator-tools",
    "system://session-internal",
    "system://agent-internal",
    "system://feishu-binding-policy"
  ]

  test "every live grant-minter is explicitly classified (confirmed-B or needs-Allen, never benign)" do
    classified_minters = @confirmed_b_allowlist ++ @needs_allen
    unclassified_minters = live_grant_minters() -- classified_minters

    assert unclassified_minters == [],
           "Unclassified grant-MINTING system principal(s) — a principal that mints " <>
             "permissions (holds cap(_, IdentityAdmin, :grant_cap|:revoke_cap)) is neither " <>
             "in @confirmed_b_allowlist nor flagged @needs_allen: " <>
             "#{inspect(unclassified_minters)}.\n" <>
             "A grant-minter can NEVER be silently parked in @category_a as 'conforming'. " <>
             "Per GLOSSARY Decision #154 + the Catalog moduledoc, adding such a principal " <>
             "needs a SPEC entry + a separate PR (the 'are we adding unowned ambient " <>
             "authority?' review surface). Classify it: confirmed-B → @confirmed_b_allowlist, " <>
             "or pending Allen's ruling → @needs_allen (with the grant_cap evidence)."
  end

  test "every allowlisted principal is still live in the Catalog (allowlist only shrinks)" do
    live = MapSet.new(Catalog.uris())

    stale =
      Enum.reject(@confirmed_b_allowlist, fn uri -> MapSet.member?(live, uri) end)

    assert stale == [],
           "Stale @confirmed_b_allowlist entr(ies): #{inspect(stale)} — no longer a live " <>
             "Catalog principal (a conversion landed, OR the grant-cap was dropped). " <>
             "Remove the entry from @confirmed_b_allowlist; the allowlist ratchets toward 0 " <>
             "(#808 anon-access + #811 cap#2 are the first removals)."
  end

  test "a converted (no-longer-grant-minting) allowlisted principal forces the shrink" do
    # A principal that stays in the Catalog but loses its grant/revoke-cap (the
    # shape a #153 manager-delegation conversion produces for the non-deleted
    # principals) drops OUT of live_grant_minters/0. The allowlist entry is then
    # no longer load-bearing and MUST be removed — surfaced here so the ratchet
    # is observable even when the principal itself survives.
    converted = @confirmed_b_allowlist -- live_grant_minters()

    assert converted == [],
           "Allowlisted principal(s) #{inspect(converted)} no longer mint permissions " <>
             "(grant/revoke-cap removed) — the conversion landed. Remove them from " <>
             "@confirmed_b_allowlist (allowlist only shrinks)."
  end

  test "every Catalog principal is classified (a 16th forces a classification entry)" do
    classified =
      MapSet.new(@category_a ++ @confirmed_b_allowlist ++ @needs_allen ++ [@bootstrap])

    live = MapSet.new(Catalog.uris())

    unclassified = MapSet.difference(live, classified) |> MapSet.to_list()
    phantom = MapSet.difference(classified, live) |> MapSet.to_list()

    assert unclassified == [],
           "Unclassified Catalog principal(s): #{inspect(unclassified)} — a new principal " <>
             "was added without an audit classification. Classify it in " <>
             "docs/notes/2026-06-16-capbac-system-principal-audit.md and add it to the " <>
             "matching bucket here (@category_a / @confirmed_b_allowlist / @needs_allen)."

    assert phantom == [],
           "Classification bucket(s) reference a non-existent Catalog principal: " <>
             "#{inspect(phantom)} — a principal was renamed/removed. Update the bucket(s)."
  end

  # ── the structural grant-minter predicate ─────────────────────────────────
  # A grant-MINTER mints permissions == holds a cap whose behavior is
  # Ezagent.Behavior.IdentityAdmin and whose action is :grant_cap or :revoke_cap.
  # This is a STRUCTURAL fact, NOT the "confirmed-B" judgment (which is human:
  # Allen rules each minter → A-drop or → B-allowlist). See moduledoc.
  defp live_grant_minters do
    for {uri, caps} <- Catalog.entries(),
        Enum.any?(caps, &grant_minting_cap?/1),
        do: uri
  end

  defp grant_minting_cap?(%Capability{behavior: Ezagent.Behavior.IdentityAdmin} = cap) do
    Capability.action_of(cap) in [:grant_cap, :revoke_cap]
  end

  defp grant_minting_cap?(%Capability{}), do: false
end
