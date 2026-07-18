# Read-Plane Authz Chokepoint — Implementation Plan (PR-split, directional)

> **For the implementer (codex):** implement PR-by-PR; each PR is independently mergeable + has ONE acceptance gate. This plan is **directional** (per Allen: don't over-detail) — it fixes the PR boundaries, the acceptance, and the drift-gate; the code shape is yours to choose within the spec's constraints (§5/§9). **Spec:** `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md` (SOUND-WITH-FIXES).
> **Base:** `origin/main` @ `70ffafa85`. Branch: `feat/read-plane-authz-chokepoint`. Target: one branch, PRs stacked/sequential onto it.

**The two pillars every PR serves:** (A) the chokepoint's **acceptance criteria** (spec §7); (B) **drift-prevention** = the module-boundary gate that makes a future bypass a red CI build (spec §1/§3.3/§9). Do not let a PR add a new principal read that isn't behind a chokepoint.

**Global constraints (spec §9 — honor in every PR):**
- Chokepoint placement: `SessionReads`∈`ezagent_domain_socialware`, `AgentReads`∈`ezagent_domain_workspace`, `OperatorReads`∈`ezagent_domain_identity`(+); composition only from `world`.
- `view` is a fixed enum (`:conversation`/`:chat_feed`/`:external_feed`) + typed pagination; NEVER a caller-supplied predicate. Row **visibility** (`:read_unfiltered`) is chokepoint-owned, never caller-selectable.
- `Membership.authorize/3` is **live-first** — reuse as-is; do not switch to persisted-only.
- Gate is **module-keyed** (not path allowlists): two allowlists — raw-store reads callable only from {chokepoints, `InternalReads`}; `InternalReads` callable only from {framework-internal tier}.

---

## PR-1 — `SessionReads.messages/members` + close the conversation-read hole + message-read gate

**Goal:** the info-disclosure fix + the first chokepoint + the first slice of the drift-gate.
**Scope:** new `SessionReads` (in `ezagent_domain_socialware`) — `messages(caller, session, view \\ :conversation, opts)`, `members(caller, session)`: live-first `Membership.authorize/3` → deny fail-loud; chokepoint sources the caller's `:read_unfiltered` authority (moved out of `conversation_data.ex:425-446`) and picks visible-vs-unfiltered; `:conversation` view → the existing `MessageStore.recent_visible_in_session`/`recent_in_session`. Migrate the world loader (`conversation_data.ex:427`) to call `SessionReads`. Turn on the arch-gate rule: **no `MessageStore.recent_*` and no `EzagentCore.Repo` read of messages from `ezagent_plugin_world` / presenter modules** — only `SessionReads`.
**Acceptance (spec §7):** #1 deep-link non-member → denied; #2 observe-degrade → cannot read; #3 fresh async-join member → can read; #6 `:read_unfiltered` holder still unfiltered, non-holder cannot obtain by any flag; #7 a direct `MessageStore.recent_in_session`/`Repo.all(messages)` added in a presenter module → CI red; #8 no per-row actor round-trip added.
**Drift-gate:** message-read boundary live.

## PR-2 — Route the feeds through `SessionReads` (fold public-view + view shapes)

**Goal:** single home for session-message reads; no "leave feeds in place."
**Scope:** `ChatFeed`/`ExternalFeed` call `SessionReads.messages(..., view: :chat_feed | :external_feed)`; fold `PublicView.web_anon_access?/1` open-policy INTO `SessionReads`' access-policy step (so public sessions authorize through the chokepoint, not a feed-local fallback). `view` routes to the exact existing store queries (`chat_visible_recent`, `committed_external_visible[_by_ids]`).
**Acceptance (spec §7):** #4 anon/non-member on a public session → can read via the chokepoint's open policy; #10 feed output byte-identical.

## PR-3 — Attachment plane: `DownloadToken` person-bind + kanban-403 fix

**Goal:** the 403 symptom + token-leak, as the attachment instance of the principle (jjkysy `uploads-person-token`).
**Scope:** `DownloadToken` optional person-bound `grantee` (serve-time `caller == grantee`; absent → legacy recheck, zero-breakage); mint the token **inside** the cap-gated read; `uploads_controller` verifies grantee.
**Acceptance (spec §7):** #9 legit member downloads kanban attachment (403 gone); leaked token by non-grantee → rejected.

## PR-4 — `OperatorReads` (global/operator) + `AgentReads` (workspace) + migrate `AdminData`

**Goal:** cover the query scopes with no container anchor + the workspace-list scope.
**Scope:** `OperatorReads` (in `ezagent_domain_identity`+) for `AdminData`'s global `KindRegistry`/external-mirror list-all (authorize an **operator cap**, `behavior/identity.ex:877-905`); `AgentReads` (in `ezagent_domain_workspace`) for workspace agent lists (workspace-membership). Migrate `AdminData` (`admin_data.ex:64-73,201-225,297-310`) off direct `Repo`/`KindRegistry` onto these.
**Acceptance (spec §7):** #5 non-operator principal denied on a registry list-all; #7 direct `Repo.all` in `AdminData` → CI red.

## PR-5 — `InternalReads` gateway + finalize the two-sided gate + acyclic

**Goal:** close the last bypass class + lock the drift-gate.
**Scope:** `InternalReads` for framework-internal raw reads (`Delivery.replay_messages_since/3` `delivery.ex:381-395`, reconcile/GC/boot). Finalize the gate as **two module allowlists** ((a) raw-store reads ⊆ {chokepoints, `InternalReads`}; (b) `InternalReads` callers ⊆ {framework tier}) in `mix ezagent.check_invariants` (or `Boundary`). Split any module that mixes principal + internal reads before allowlisting.
**Acceptance (spec §7):** #7 full gate (no direct raw-store/`Repo` read outside owners); #11 arch acyclic green at the §5 placements; #12 a principal-facing module calling `InternalReads` → CI red.

---

## Sequencing & review
- PR-1 lands the user-visible security fix + the first gate slice → highest priority, independently valuable.
- PR-2–5 extend coverage + lock the gate. Each: full affected-app `mix test` + `mix ezagent.check_invariants` + arch acyclic before merge (watch push-to-main full-suite; a `DBConnection.OwnershipError`-class red is the known #184 flake — re-run, don't assume).
- Each PR gets a codex adversarial review before merge (per Allen); merge only clean.

## Out of scope (spec §6)
In-VM malicious defense; data-at-rest field-crypto (separate Path-B track); write-plane side-table consolidation (STRETCH follow-on).
