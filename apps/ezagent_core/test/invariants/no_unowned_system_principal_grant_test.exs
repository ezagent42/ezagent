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
  it cannot honestly own — i.e. it holds a cap that AUTHORIZES `grant_cap` /
  `revoke_cap` on `IdentityAdmin` (including wildcard-shaped caps). Such a grant's
  `granted_by` points at the abstract `system://…` principal rather than the real
  configurer entity (session owner / agent creator / rule configurer). Per the
  audit + Allen's final ruling (2026-06-16), two principals are **confirmed-B**
  today: `system://template-materialize` and `system://feishu-binding-policy`.

  Note the distinction the gate is built on: `grant_minting_cap?/1` identifies
  grant-*minters* (a STRUCTURAL fact — the principal holds a cap that AUTHORIZES
  `grant_cap`/`revoke_cap` on `IdentityAdmin` under the runtime matcher). It does
  NOT, by itself, decide "confirmed-B": that is a human judgment layered on top
  (Allen rules each minter → A or → B). So the honest invariant is *"every
  grant-minter must be EXPLICITLY classified"* — in `@confirmed_b_allowlist` OR in
  `@needs_allen`. A minter may never be silently parked in `@category_a` ("conforms,
  nothing to see"). After PR-2 of the no-unowned-caps program (2026-06-17) only
  ONE principal mints: `feishu-binding-policy` — confirmed-B (PR-3 converts it →
  allowlist 0). `template-materialize` was confirmed-B but PR-2 dropped its grant
  caps (its grants now route through `Ezagent.Identity.Grant` under real-entity
  rule/bootstrap tags), neutering it to category A (the gate's tooth-3 path).
  `@needs_allen` is empty.

  ## Why detection uses the RUNTIME matcher (codex P2 fix, 2026-06-16)

  The earlier predicate matched ONLY the EXACT shape
  `cap(:user, IdentityAdmin, :grant_cap | :revoke_cap)`. That missed
  WILDCARD-shaped caps that STILL authorize minting at runtime, because a
  HELD-side `:any` wildcard matches a concrete need: `cap(:user, IdentityAdmin,
  :any)`, `cap(:user, :any, :grant_cap)`, or `cap(:any, IdentityAdmin, :grant_cap)`
  all PASS step 5.5 for a concrete `identity.grant_cap` dispatch yet slipped past
  the exact-match predicate. The predicate now builds the NEEDED `grant_cap`/
  `revoke_cap` cap on `IdentityAdmin` and asks `Capability.matches?(held, needed)`
  — the same decision dispatch uses — so wildcard-shaped minters are caught.

  The ONE exclusion: the full bootstrap-wildcard sentinel (all five axes `:any`)
  is NOT counted here. `system://bootstrap`, `system://mix-task`, `system://chat-router`
  and `system://chat-reply` hold that sentinel; it authorizes minting at runtime,
  but those four are governed by `no_wildcard_system_principals_test.exs` (only
  bootstrap + mix-task + chat-router + chat-reply may hold it) and the audit's
  fan-out / operator-trust rationale puts them in category A. Counting the full
  sentinel here would force chat-router/chat-reply out of A — contradicting Allen's
  ruling — so this gate scopes to the PARTIAL/grant-shaped wildcards codex P2
  cares about and defers the full sentinel to its dedicated gate. (Mirrors the
  `wildcard_cap?/1` predicate in that sibling test.)

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

  # ── classification of the 15 named Catalog principals (audit 2026-06-16,
  #    Allen's FINAL ruling on all 6 prior needs-Allen entries) ──

  # (A) Conforms — boot/operator infra, self-authority, fan-out proxy, or
  # empty-cap audit identity (no authority ⇒ nothing to be unowned). Allen
  # ruled chat-router / chat-reply / orchestrator-tools / session-internal → A
  # (fan-out / self-authority), and agent-internal → A by DROPPING its vestigial
  # grant_cap (no live grant_cap/revoke_cap caller ran under it — its only live
  # use is sandbox.write_path self-authority; git-grep confirmed 2026-06-16).
  @category_a [
    "system://boot-reconciler",
    "system://adapter-install",
    "system://chat-router",
    "system://chat-reply",
    "system://worker-publish",
    "system://orchestrator-tools",
    "system://session-internal",
    "system://agent-internal",
    "system://workspace-loader",
    "system://mix-task",
    "system://lv-anon-mount",
    "system://credential-materializer",
    "system://socialware-gc",
    # 2026-06-17 (PR-2 of the no-unowned-caps program) — template-materialize
    # was B (the §1 spec-named workaround). Its grant caps are now DROPPED
    # (Catalog) and every grant routes through `Ezagent.Identity.Grant` under
    # a real-entity tag (`{:rule, …}` for bounded caps, `{:system, bootstrap}`
    # for the `behavior: :any` orchestrator scoped caps). It is now a
    # NON-minter retaining only NON-grant template read/write/session-spawn
    # authority → category A (the gate's tooth-3 neuter path, same as the
    # 2026-06-16 agent-internal grant_cap drop).
    "system://template-materialize"
  ]

  # (B) CONFIRMED violates — principals that MINT permissions a real configurer
  # entity should own. Allen ruled (2026-06-16): template-materialize (the §1
  # spec-named workaround owner/manager-delegation #153 replaces) AND
  # feishu-binding-policy (granter should be the binding configurer/admin —
  # `admin_uri` already flows in; conversion is a later PR). The allowlist
  # ratchets toward 0 as conversions land (#808 anon-access + #811 cap#2 are the
  # first removals; feishu + template are the next).
  @confirmed_b_allowlist [
    # PR-2 (2026-06-17) shrank this from
    # ["system://template-materialize", "system://feishu-binding-policy"] to
    # feishu-only: template-materialize's grant caps were dropped → it is no
    # longer a minter (moved to @category_a). feishu-binding-policy is the
    # last confirmed-B minter (PR-3 converts it → allowlist reaches 0).
    "system://feishu-binding-policy"
  ]

  # needs-Allen — EMPTY. Allen ruled all 6 prior entries on 2026-06-16:
  # chat-router/chat-reply/orchestrator-tools/session-internal → A;
  # agent-internal → A (via grant_cap drop); feishu-binding-policy → B.
  @needs_allen []

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

  test "live grant-minters are EXACTLY feishu-binding-policy (post PR-2 template-materialize neuter)" do
    # Locks the PR-2 reconciliation: after template-materialize's grant caps
    # were dropped (its grants now route through `Ezagent.Identity.Grant` under
    # real-entity rule/bootstrap tags), the only remaining minter is
    # feishu-binding-policy (PR-3 converts it → empty). If
    # chat-router/chat-reply/mix-task/bootstrap appear here the sentinel
    # exclusion has regressed (the full wildcard is leaking into minter
    # detection); if template-materialize reappears its grant caps were
    # re-introduced.
    assert Enum.sort(live_grant_minters()) == ["system://feishu-binding-policy"]
  end

  describe "wildcard-shaped grant-minter detection (codex P2)" do
    test "exact cap(:user, IdentityAdmin, :grant_cap) is a minter" do
      assert grant_minting_cap?(Capability.cap(:user, Ezagent.Behavior.IdentityAdmin, :grant_cap))
    end

    test "exact cap(:user, IdentityAdmin, :revoke_cap) is a minter" do
      assert grant_minting_cap?(Capability.cap(:user, Ezagent.Behavior.IdentityAdmin, :revoke_cap))
    end

    test "action-wildcard cap(:user, IdentityAdmin, :any) is a minter (the codex-P2 miss)" do
      # Old exact-match predicate missed this; held :any action matches the
      # concrete :grant_cap need at runtime.
      assert grant_minting_cap?(Capability.cap(:user, Ezagent.Behavior.IdentityAdmin, :any))
    end

    test "behavior-wildcard cap(:user, :any, :grant_cap) is a minter" do
      assert grant_minting_cap?(Capability.cap(:user, :any, :grant_cap))
    end

    test "kind-wildcard cap(:any, IdentityAdmin, :grant_cap) is a minter" do
      assert grant_minting_cap?(Capability.cap(:any, Ezagent.Behavior.IdentityAdmin, :grant_cap))
    end

    test "full bootstrap-wildcard sentinel is NOT counted (governed by no_wildcard gate)" do
      # The exact shape system://bootstrap / mix-task / chat-router / chat-reply
      # hold (all five axes :any). It authorizes minting at runtime but is scoped
      # out of this gate — see moduledoc.
      sentinel = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.system(:bootstrap, :default),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      refute grant_minting_cap?(sentinel)
    end

    test "an unrelated narrow cap (Sandbox :write_path) is NOT a minter" do
      refute grant_minting_cap?(Capability.cap(:agent, Ezagent.Behavior.Sandbox, :write_path))
    end

    test "a non-IdentityAdmin grant_cap action (different behavior) is NOT a minter" do
      # action axis alone is not enough — the behavior must resolve to IdentityAdmin.
      refute grant_minting_cap?(Capability.cap(:user, Ezagent.Behavior.Identity, :grant_cap))
    end
  end

  # ── the runtime-semantic grant-minter predicate (codex P2 fix) ─────────────
  # A grant-MINTER mints permissions == holds a cap that AUTHORIZES a concrete
  # `identity.grant_cap` or `identity.revoke_cap` dispatch on `IdentityAdmin`
  # under the SAME matcher dispatch step 5.5 uses. This catches wildcard-shaped
  # minters (`cap(:user, IdentityAdmin, :any)`, `cap(:user, :any, :grant_cap)`,
  # `cap(:any, IdentityAdmin, :grant_cap)`) the old exact-match predicate missed.
  # This is a STRUCTURAL fact, NOT the "confirmed-B" judgment (Allen rules each
  # minter → A-drop or → B-allowlist). See moduledoc.
  #
  # The full bootstrap-wildcard sentinel (all five axes `:any`) is EXCLUDED — it
  # is governed by `no_wildcard_system_principals_test.exs` (only bootstrap +
  # mix-task + chat-router + chat-reply may hold it) and the audit ranks those
  # category A. Counting it here would mis-flag chat-router/chat-reply. See
  # moduledoc "Why detection uses the RUNTIME matcher".

  # Concrete NEEDED caps for an `identity.grant_cap` / `identity.revoke_cap`
  # dispatch on a User entity (the shape `IdentityAdmin.required_caps/0` pins:
  # kind: :user, behavior: IdentityAdmin). Concrete instance + workspace so a
  # held-side `:any` wildcard is what authorizes, never a needed-side `:any`.
  @grant_needs (for action <- [:grant_cap, :revoke_cap] do
                  %{
                    kind: :user,
                    behavior: Ezagent.Behavior.IdentityAdmin,
                    action: action,
                    instance: Ezagent.URI.new!("entity://system/user/some-user"),
                    workspace_uri: Ezagent.URI.new!("workspace://system")
                  }
                end)

  defp live_grant_minters do
    for {uri, caps} <- Catalog.entries(),
        Enum.any?(caps, &grant_minting_cap?/1),
        do: uri
  end

  # Full bootstrap-wildcard sentinel — excluded (mirrors `wildcard_cap?/1` in
  # no_wildcard_system_principals_test.exs; checks the five wildcard axes).
  defp grant_minting_cap?(%Capability{
         kind: :any,
         behavior: :any,
         action: :any,
         instance: :any,
         workspace_uri: :any
       }),
       do: false

  defp grant_minting_cap?(%Capability{} = cap) do
    Enum.any?(@grant_needs, &Capability.matches?(cap, &1))
  end
end
