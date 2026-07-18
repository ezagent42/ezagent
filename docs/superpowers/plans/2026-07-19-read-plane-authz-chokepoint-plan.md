# Read-Plane Authz Chokepoint — Implementation Plan v4 (PR-split, directional)

> **For the implementer (codex):** implement PR-by-PR; each PR is independently mergeable + has ONE acceptance gate. **Directional** (per Allen: don't over-detail) — this fixes PR boundaries, the **drift-prevention MECHANISM**, and the **acceptance**; code shape is yours within the spec constraints (§5/§9). **Spec:** `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md` (SOUND-WITH-FIXES).
> **Base:** `origin/main` @ `70ffafa85`. Branch: `feat/read-plane-authz-chokepoint`.

**Two pillars (Allen's steer):** (A) **acceptance criteria** per chokepoint; (B) **drift-prevention** = the module-boundary gate. v4 stops hand-enumerating readers (that spiralled — 3 review rounds each found one more: UserData, PageView, `:surface`, `KindSnapshot`). The completeness guarantee moves to the gate; the plan carries the *mechanism*, not a reader census.

---

## Pillar B — drift-prevention: the gate is the enumerator, anchored on 3 ROOTS

Do **not** hand-list every reader — that census is un-gettable-right (proven: it kept growing) and it's exactly the impl-detail Allen said to drop. Instead anchor the gate on the **root access primitives**, defined **semantically** so the set is closed by principle, not by enumeration:

> **A root = any primitive that returns persisted principal/container/config *content* and does not itself obtain that content through another root.** (Content = messages, members, session/agent/user/template rows, recipe bodies, surface/delivery rows. NOT runtime-liveness state.)

The root definition is the invariant; the **storage engines** below are its known manifestations (extensible — a new engine that returns content is a root by the definition above, and the gate's job is to force it through a chokepoint the same way):

| root (storage engine) | what it is | store-owners that wrap it (illustrative) |
|---|---|---|
| raw `Ecto`/`Repo` | every durable table bottoms out here | `MessageStore`, `KindSnapshot` (`ecto/kind_snapshot.ex` → `Repo.all`), `DeliveryOutbox`, `Users` (`Repo.get_by`), `ConfigStore` (`Repo.get ConfigObject`), workspace store |
| `Kind.get_slice/*` — **ALL slices** | live actor-state read (`:session`, `:members`, `:surface`, …) — ban regardless of slice atom | (the actor itself) |
| `KindRegistry` live reads (`list_all`/`list_in_workspace`/`lookup`) | the live-registry root | `AdminData`, `UriOptions`, `WorkspacePluginData.live_session_template_rows` |
| **content-caching `:ets`/`:persistent_term` tables** (round-4 fix) | a cache that returns **content** on a hit without re-touching Repo — e.g. `RecipeRegistry`'s `:public` `:n` table returns `%Recipe{}` (user-authored recipe/template body) direct from ETS (`recipe_registry.ex:150`) | `RecipeRegistry`/`Ezagent.Agent.n` (read-through over `ConfigStore`→`Repo`) |

**The `:public`-table subtlety:** `RecipeRegistry`'s ETS is `:public`+`:named_table` (`ets_owner.ex:31`), so store-owner containment (Layer 2) is *defeated* — any presenter can `:ets.lookup(:n, …)` around the owner. The gate closes this by **access, not re-architecture**: direct `:ets`/`:persistent_term` read of a content-caching table from **outside its owner module** → CI red (added to the Layer-1 banned set). No need to make the table `:private` (that would break the cross-process read fast-path).

*Genuinely out of scope (NOT roots):* `:ets`/`:persistent_term` that hold **runtime-liveness** state — transport-readiness, respawn backoff, rate-limit, nonce, pending-reply, event-catalogue tables. These return no persisted principal content. (The line is *content vs liveness*, not *Repo vs ETS* — that was the round-4 miss.)

**The gate = tier-scoped, two-sided module boundary** (NOT a global root ban — 248 modules touch `Repo`, 213 `KindRegistry`; most are legit store-owners/writers/framework):
- **Layer 1 (root containment):** a root may be touched only *inside* a content-store-owner module (a module whose job is wrapping that root).
- **Layer 2 (chokepoint containment):** a content-store-owner may be *called* only by {its chokepoint, `InternalReads`}. The **principal-facing read tier** — `ezagent_plugin_world` presenters, `ezagent_web` LV/controllers, socialware read surfaces — may reach container content ONLY through a chokepoint.

**Completeness = gate-as-enumerator, NOT a table.** The implementer turns a plane's gate on with an empty allowlist; **the red build IS the exhaustive reader worklist** for that plane. No hand-maintained census can drift stale, and a reader I never listed still gets caught. (The seed examples in the PR sections below are *illustrative, non-exhaustive* — the gate is the source of truth.)

**Rollout = incremental, per-plane** (avoids a 248-module big-bang and lets PR-1 land alone): each plane's gate tightens only when its chokepoint exists; call-sites owned by a later PR stay legal until then. PR-5 completes the two-sided gate across all content planes.

## Pillar A — acceptance: structural gate ⊕ per-chokepoint authz-REJECTION test

Two *different* guarantees; neither substitutes for the other:
1. **Structural (the gate):** a direct root/store-owner read from the principal tier → CI red. Proves *completeness* (every reader routes through a chokepoint).
2. **Behavioral (authz correctness):** "routed through a chokepoint" ≠ "the chokepoint authorized." **Every chokepoint MUST take a `caller`, authorize it, then delegate — and ship a test that a NON-authorized caller is REJECTED.** Byte-parity / structural-gate / "goes through the wrapper" tests do **NOT** substitute.

**Chokepoint contract (global, binding on every PR):** a chokepoint = `fn(caller, scope, …)` that authorizes `caller` for `scope` *before* reading. A caller-less store-owner function is **Layer-1-allowed** (may touch a root) but **never itself a chokepoint** (Layer-2-banned: only a real chokepoint may call it). Allowlisting a caller-less store fn AS the chokepoint is the round-3 finding-#4 hole — forbidden.

---

## PR-1 — `SessionReads` (conversation read surface) + narrow message gate → closes the info-disclosure
**Scope:** `SessionReads`∈socialware: `messages(caller, session, view \\ :conversation, page_opts)` covering **initial AND older/pagination**, `members(caller, session)`. Live-first `Membership.authorize/3`; chokepoint owns `:read_unfiltered` row-policy; `:conversation` view routes to existing `recent_visible/recent/older_visible/older` store fns. Migrate the known message readers: `ConversationData` (initial + `load_older` + member/options reads), the `chat.load_older` **dispatcher (add authz — currently NONE)**, `KanbanShareController.session_assistant`. **Narrow gate (message plane, presenter tier):** direct `MessageStore.*`/message-`Repo` read from `ezagent_plugin_world`/presenter → CI red, EXCEPT the not-yet-migrated feed/uploads modules (explicitly legal until PR-2/PR-3). Run the gate empty-allowlist once — the red build is the full message-reader list; migrate all it names, not just the seeds above.
**Acceptance:** #1 deep-link non-member REJECTED (initial AND load_older); #2 observe-degrade denied read; #3 fresh-join sees history; #6 row-policy (`:read_unfiltered` only for authorized internal view); **authz-rejection: `SessionReads.messages`/`members` with a non-member caller → `{:error, :unauthorized}`** (behavioral, not just "routed"); #8 no per-row actor round-trip; structural: migrated-module direct message read → CI red.
**Lands ALONE** — the actual security fix.

## PR-2 — Route feeds through `SessionReads` (public-view + view shapes + delivery/surface planes)
**Scope:** `ChatFeed`/`ExternalFeed` message views → `SessionReads.messages(view: :chat_feed|:external_feed)`; fold `PublicView.web_anon_access?/1` open-policy INTO the chokepoint. **Delivery + surface planes:** `ExternalFeed`'s direct `DeliveryOutbox` reads (`committed_deliveries_since/2`, `committed_surface_version/1`) and `Kind.get_slice(_, :surface)` page reads (`ExternalFeed.snapshot/2`, `PageView`) must route through a **caller-authorizing chokepoint** — NOT an allowlisted caller-less store fn (finding-#4: today these sit behind `snapshot(session,caller)`, but the store fn itself takes no caller; the chokepoint must). Extend the gate (feed tier) to forbid direct `MessageStore`/`DeliveryOutbox`/`get_slice(:surface)` reads.
**Acceptance:** #4 public-session anon read allowed via chokepoint policy; **authz-rejection: non-member delivery/surface read → rejected** (the caller-authorizing chokepoint, proven by a non-member test — closes finding #4); #10 feed byte-identical for authorized caller (message + delivery + surface).

## PR-3 — Attachment plane: person-bound `DownloadToken` (auth'd + public serve) + kanban-403
**Scope:** `DownloadToken` optional `grantee` (serve-time `caller==grantee`; absent→legacy recheck for zero-breakage); mint inside the cap-gated read; **both** `UploadsController` (authenticated) AND public `ExternalFeedController` attachment serving verify grantee; remove the legacy message-participation recheck. Extend gate to uploads/attachment modules.
**Acceptance:** #9 legit member downloads kanban attachment (403 gone); **authz-rejection: leaked token replayed by a non-grantee → rejected on BOTH serve paths.**

## PR-4 — Workspace + global LIST reads: `WorkspaceReads` / `AgentReads` / `OperatorReads`
**Scope:** three list chokepoints, each `fn(caller, scope)`: `WorkspaceReads.{sessions,templates}`∈workspace, `AgentReads`∈workspace, `OperatorReads`∈identity+ (operator-cap). **Thread `caller` into every currently caller-less list read** (`list_sessions/1`, `IdentityData.list_entities/2`, `WorkspacePluginData.live_session_template_rows/1`, `Users.list_in_workspace/list_all` behind `UserData`, `snapshot_agent_options`, `UriOptions.*`) — caller-less means workspace-filter-only, which over-returns. Each chokepoint applies **workspace-membership authz + per-row container-visibility filter** (multi-container scope, spec §3). Turn the list-plane gate on empty-allowlist to enumerate every list reader (this is where round-3's `UserData`/`snapshot_agent_options`/`live_session_template_rows` surface — the gate names them, you don't pre-list them).
**Acceptance:** #5 non-operator denied on registry list-all; **#6-list per-row visibility: a workspace-member caller NOT visible on session/agent/user X gets X ABSENT — a wrapper that authorizes workspace but skips per-row filter must FAIL this test** (closes the same-workspace over-return hole, incl. `UserData` email/disablement leak); structural: direct `Repo`/`KindRegistry.list_all` in a list reader → CI red.

## PR-5 — `InternalReads` gateway + complete two-sided gate + acyclic
**Scope:** `InternalReads` for framework-internal reads (`Delivery.replay_messages_since/3`, reconcile/GC/boot) **plus** the internal-convergence session-slice reads currently in presenter/web tier (`uninstall_socialware`, `AnonTakeover.member?/verify_convergence` — `Kind.get_slice(_,:session)` reconcile): **split-then-relocate** the internal read into a framework-tier module behind `InternalReads` (a presenter module calling `InternalReads` is itself CI-red, criterion #12). **Recipe/template content plane:** `Ezagent.Agent.n/1,2`(`RecipeRegistry.lookup`) is the store-owner accessor over the recipe content-cache; its framework spawn/render callers (`role_step`, `cc_agent`, `definition_agents`, `kanban_render`, `skill_reconcile`) route via `InternalReads`; the principal-facing presenter read (`KanbanData.stages` → UI board config) routes through a workspace-authz chokepoint (PR-4) OR `InternalReads` if it's already board-view-gated upstream — the gate flags it; the implementer picks based on whether an upstream chokepoint already authorized the board view. Install the **complete** two-sided gate over the **roots (incl. content-caching ETS) + content-store-owners**: (a) roots + store-owners reachable only from {chokepoints, store-owner, `InternalReads`} — **incl. direct `:ets`/`:persistent_term` read of a content-caching table (e.g. `:n`) outside `RecipeRegistry` → CI red**; (b) `InternalReads` callers ⊆ framework tier.
**Acceptance:** #7 full gate green across ALL planes — a direct `get_slice(_,:session|:surface)` / `DeliveryOutbox` / `Repo` / `KindRegistry` / `:ets.lookup(:n,…)` read added to any presenter module → CI red (proves members+delivery+surface+list+recipe planes can't drift back); #11 arch acyclic green at §5 placements; #12 presenter module calling `InternalReads` → CI red. **Zero-orphan is PROVEN here structurally:** the full gate compiling green ⇒ no un-chokepointed principal read of any plane remains — no census required.

---

## Exit criterion (when is the plan/review done?)
**Done = mechanism closed, NOT "codex names no more readers."** Against an adversarial reviewer a directional plan is never reader-empty — one can always name another caller. The mechanism is closed when: (1) the gate is anchored on the **semantically-defined root set** (a root = any primitive returning persisted content; known engines = `Repo`, `Kind.get_slice/*`, `KindRegistry`, content-caching ETS) + content-store-owners, and is self-completing (empty-allowlist red build = worklist); and (2) every chokepoint has a non-authorized-caller-REJECTED test. **Once closed, "here's another reader" CONFIRMS the mechanism** (the gate catches it at that plane's PR). A real defect is only one of two things: a **content-read primitive the root definition/gate doesn't cover** (a genuinely new storage engine — like round-4's content-ETS), or a **chokepoint that passes without authorizing**. A "reader I didn't list" is neither.

## Sequencing & review
- **PR-1 first** — user-visible security fix, lands standalone. PR-2→5 extend per-plane; the gate tightens each PR; PR-5 completes it (structural zero-orphan proof).
- Each PR: affected-app `mix test` + `mix ezagent.check_invariants` + arch acyclic before merge; watch push-to-main full-suite (a `DBConnection.OwnershipError`-class red = known #184 flake — re-run, don't assume). Each PR gets a codex adversarial review before merge (review the **mechanism**: is a root missed / a chokepoint un-authorizing? — not "name another reader"); merge only clean.

## Out of scope (spec §6): in-VM defense; at-rest field-crypto (Path-B); write-plane side-table consolidation (STRETCH); runtime `:ets`/liveness state (not container content).
