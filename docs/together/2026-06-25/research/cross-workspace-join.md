# Cross-workspace join for hello (#982) — research findings

Code-grounded against `origin/main` (7c9d3569) and `origin/feat/hello-jsonrender-align` (PR #982).

## The discriminator: a join cap ≠ the cross-workspace gate

There are TWO independent checks on a `session.join` / `session.merge_member` dispatch:

1. **CapBAC (step 5.5)** — does the caller hold a cap authorizing the action on this session?
   The join cap is minted **scoped to the session's workspace**
   (`Membership.do_grant_join_cap`, `workspace_uri = Capability.workspace_of(session_uri)`).
2. **Workspace isolation (step 5.6, `do_workspace_isolation_check`, `runtime.ex:664`)** — a
   SEPARATE check that derives the **caller's** workspace from the caller's **URI**
   (`workspace_of_caller/1`, `entity://<ws>/user/<name>` → `<ws>`) and compares it to the
   target's workspace. It bypasses ONLY when: `caller_ws == target_ws`, OR a cap in
   `ctx.caps` is `workspace_uri: :any`, OR the caller is a `workspace://system` member.

A registered preview viewer is `entity://<their-home-ws>/user/<name>` (registration bakes the
chosen workspace into the URI; `alice@acme` and `alice@beta` are *distinct principals* —
`registration.ex:36-46`). For a hello app at `session://<app-ws>/…` where `their-home-ws ≠
app-ws`, step 5.6 returns `:cross_workspace_denied` — **regardless of the join cap**, because
the join cap is session-workspace-scoped, not `:any`.

This is exactly what #982's deferral comment says (`customer_channel.ex:86-90`).

## Current state (what works, what's blocked)

- **Read is already solved, cross-workspace-safe.** Anonymous viewing mints a read-only anon
  principal **in the session's own workspace** (`anon_user.ex:119 mint_for_public_session`,
  URI `entity://<viewed-ws>/user/anon-<rand>`). The anon's `caller_ws == target_ws` by
  construction, so step 5.6 never fires. "Join" only buys **write**-participation
  (`post` / auto-`@hello`) in an already-public session — a much narrower surface.
- **Same-workspace logged-in join works** — the seam (`customer_channel.ex:91 handle_in("join")`):
  brings the viewer's User Kind live, calls
  `Membership.provision_invited_join_authority/3` (mints a session-ws-scoped `:join` cap via
  the owner/admin), `dispatch_join` with `ctx.caller = viewer_principal`, then
  `mount_participation_caps`. Works iff `viewer_principal`'s home ws == the session's ws.
- **Cross-workspace join is NOT built** — `dispatch_join` (`customer_channel.ex:234`) sets
  `ctx: %{caller: principal}` with NO `ws: :any` cap → step 5.6 denies.
- **The anon→login takeover shares the SAME gap** (the most important finding).
  `AnonTakeover.takeover/3` → `dispatch_merge_member` (`anon_takeover.ex:154`) dispatches
  `session.merge_member` with `caller: confirmed_uri` and an `inline_merge_member_cap` that is
  **session-ws-scoped** (`anon_takeover.ex:174`). If the registering user's confirmed account
  lives in another workspace, the takeover ALSO hits `:cross_workspace_denied`. The whole anon
  machinery currently assumes same-workspace: `AnonBinding.touch` enforces
  `validate_same_workspace(entity_uri, workspace_uri)` (`anon_binding.ex:101-123`, invariant
  #14), and `do_merge_member` has no cross-workspace identity link. **Fix BOTH at the shared
  provisioning point, not just the hello join button.**

## Options (POLICY vs MECHANISM — the (a)–(e) list conflates them)

**Policy question** (lead's product call): *may any logged-in user write-participate in a
`public_view` session whose workspace isn't theirs?* For a public preview app, plausibly yes —
the session is already world-readable; join only adds posting.

**Mechanism question** (how, without breaking tenant isolation). Two real mechanisms:

| | Mechanism | Clears step 5.6? | Multi-host safe? | Effort | Notes |
|--|--|--|--|--|--|
| **M1** | A `public_view`-keyed hole in step 5.6: let `entity://A/user/bob` dispatch `:join`/`:post`/`:merge_member` into a `public_view` `session://B`. | Yes (new bypass) | **No** — `entity://A/user/bob`'s Kind may not be live/registered on B's node | Low-med | Punches the first per-action hole in the Phase-9 isolation invariant; gate test (`cross_workspace_isolation_test`) + invariant #13 must be amended; security review surface. |
| **M2** (recommended) | Give the cross-ws viewer a **guest principal IN the session's workspace** linked to their home account — generalize `mint_for_public_session` + the anon/binding/merge path to a non-anon "linked guest". | Yes (`caller_ws == target_ws` by construction) | **Yes** — guest lives where the session lives | Med-high | Reuses anon mint + AnonBinding + merge_member machinery; preserves the isolation invariant; needs a NEW guest→home-account cross-workspace identity link (today none exists). |

The (a)–(e) phrasings map onto these:
- **(a) cross-workspace guest membership grant** = M2 (the recommendation).
- **(b) workspace-scoped invite/cap** — does NOT clear step 5.6; its cap is ws-scoped, not
  `:any`. A non-starter on its own.
- **(c) "public session = anyone-logged-in can join"** — that's the *policy* (yes for
  `public_view`), still needs M1 or M2 as mechanism.
- **(d) auto-add the user to the session's workspace member list** — does NOT clear step 5.6:
  membership in B's member list doesn't change bob's URI-derived `caller_ws`. Only a *second
  principal* `entity://B/user/bob` would — which is exactly M2's guest, and collides with
  "alice@acme ≠ alice@beta". So (d) collapses into either M2 or a no-op.
- **(e) reject + require explicit invite** — the status-quo fallback; the invited-join path
  exists (`provision_invited_join_authority/3`) but still fails step 5.6 cross-workspace, so
  even an invite needs M1/M2 underneath.

**Shortcut to pre-empt:** `Behavior.workspace_scoped?/0` (`runtime.ex:652`) can disable
isolation per-Behavior — but that's far too coarse (kills isolation for ALL `Session` joins,
including private ones). A public-only exemption must key on the **target's `public_view`
flag**, not the Behavior. Also do NOT route preview viewers through `workspace://system`
membership — that is admin-grade promotion, wrong for an anonymous-turned-registered viewer.

## Recommendation: M2 — linked guest principal in the session's workspace

**Rationale.** The tie-breaker is the architecture's own thesis: **a workspace is a deployment
unit** (Decision #145, GLOSSARY §965 — workspaces are separately host-able). Under multi-host,
M1 is fragile: `entity://A/user/bob` may not be live/registered on B's node, and the
session-actor lives on B. M2 is the only mechanism that survives, and the system ALREADY does
exactly this for anonymous viewers — minting the principal in the *session's* workspace
(`anon_user.ex` moduledoc: "the anon-User can never be used cross-workspace"). M2 generalizes
the proven anon path from "anonymous" to "linked to a home account," preserving the
`caller_ws == target_ws` invariant that step 5.6 enforces and never punching a hole in
tenant isolation. Because read is already solved and join only adds *write* in an
already-public session, the marginal security surface is small.

**The concrete seam it would touch** (single shared provisioning point, fixes both gaps):
- `apps/ezagent_web/lib/ezagent_web/socialware/customer_channel.ex:91` `handle_in("join")` —
  when `viewer_principal`'s home ws ≠ `session_uri`'s ws, mint/resolve a guest principal in
  the session's ws (instead of dispatching `:join` as the foreign `viewer_principal`).
- `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex:119`
  `mint_for_public_session/1` — generalize to a "linked guest" variant (carries a link to the
  home account; still minted in the session's ws).
- `apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex:154` `dispatch_merge_member`
  + `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:136`
  `do_merge_member` — the same flow used at login takeover; extend it to link
  guest→home-account *across workspaces* (today `AnonBinding` and merge are same-workspace by
  `validate_same_workspace`, `anon_binding.ex:101-123`).
- `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_binding.ex` — the binding schema
  currently forbids a foreign workspace; a guest→home link is the new cross-workspace identity
  edge that has to live somewhere (binding is the natural home, but it would need a
  `home_entity_uri` distinct from the session-ws guest `entity_uri`).

**Honest cost (the lead's real call).** M2 is not free: it gives every cross-workspace viewer
a **per-workspace guest footprint** (a guest User row in each app's workspace they join), and
it requires a NEW guest→home-account identity link that the binding/merge model does not have
today (the whole anon path is same-workspace by construction). The decision is therefore
**M2 (preserves isolation, multi-host-safe, more machinery) vs M1 (a `public_view`-only
isolation hole — less code, breaks the deployment-unit invariant and is fragile under
multi-host).** Don't pretend M2 is cheap; pretend M1 is principled.

## Open questions for the lead

1. **Policy:** is write-participation by *any* logged-in user in a `public_view` session
   desired, or should cross-workspace join require an explicit invite from the session owner?
   (Read is already open to everyone; this only governs posting / `@hello`.)
2. **Identity model:** is a per-workspace **guest footprint + cross-workspace link**
   acceptable, or do you want one canonical principal that can act across workspaces? The
   latter contradicts the current "`alice@acme` ≠ `alice@beta`" design and the deployment-unit
   thesis — confirm before anyone builds it.
3. **What does a cross-workspace guest's home account *get* from joining?** Does the post/page
   need to show up in their home-workspace history, or is participation purely in the app's
   workspace? (Decides whether the guest→home link must carry message provenance, i.e. how far
   the merge_member relabel logic must reach.)
4. **Is the same-workspace anon→login takeover even correct today** for a user whose confirmed
   account is in another workspace? Current code would `:cross_workspace_denied` the
   merge_member — confirm whether that's an accepted limitation or a latent bug to fix
   alongside #982 (it is the same root cause).
5. **Scope:** fix the cross-workspace gap as part of #982, or as a follow-up epic? It touches
   the socialware identity model (anon/binding/merge), not just the hello plugin.
