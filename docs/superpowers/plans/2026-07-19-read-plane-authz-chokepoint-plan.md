# Read-Plane Authz Chokepoint — Implementation Plan v2 (PR-split, directional)

> **For the implementer (codex):** implement PR-by-PR; each PR is independently mergeable + has ONE acceptance gate. **Directional** (per Allen: don't over-detail) — this fixes PR boundaries, the **reader→PR map (zero orphans)**, the **incremental gate**, and the acceptance; code shape is yours within the spec constraints (§5/§9). **Spec:** `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md` (SOUND-WITH-FIXES).
> **Base:** `origin/main` @ `70ffafa85`. Branch: `feat/read-plane-authz-chokepoint`.

**Two pillars:** (A) acceptance criteria (spec §7); (B) drift-prevention = the module-boundary gate (spec §1/§3.3/§9). **Completeness rule (codex plan-review): EVERY principal-facing reader maps to a PR — an orphan = a gate hole** (gate either compiles-red early, or leaves a reader naked).

## The gate is INCREMENTAL, not "full every PR" (codex plan-review round-1 fix)
Each PR gates **exactly the readers it migrates** — a growing module/function allowlist. Call-sites owned by a *later* PR are **explicitly left legal** until their PR. Only **PR-5** installs the complete cross-plane two-sided gate + acyclic. So PR-1's gate must NOT forbid the feeds' or `UploadsController`'s existing direct store reads (those land in PR-2/PR-3).

## The gate primitive spans EVERY store-access verb, not just `Repo` (codex plan-review round-2 fix #1/#2)
"Direct store read" is the **union of every read primitive by plane** — a gate that only bans `Repo`/`MessageStore` leaves the members and delivery planes able to drift back:
- **message** plane → `MessageStore.recent_*/older_*/chat_*/committed_*`
- **members/session-slice** plane → `Kind.get_slice(_, :session|:members)` (+ session-slice helpers)
- **delivery** plane → direct `DeliveryOutbox` queries (`committed_deliveries_since`, `committed_surface_version`, …)
- **registry/global** plane → `KindRegistry.list_all`
- raw `Repo`/`Ecto` in any presenter/web/plugin-tier module

PR-5's complete gate = **every** one of these, called from **outside** {its chokepoint, the store-owner module, `InternalReads`} → CI red. Only this makes "full gate compiles ⇒ zero-orphan" actually hold **across all planes** (a `Repo`-only gate would silently exempt the session-slice + delivery readers).

## Reader → PR inventory (zero orphans — codex plan-review fix #2)
| plane | principal-facing reader (code) | PR |
|---|---|---|
| messages | `ConversationData` initial recent load (`conversation_data.ex:427`) | **PR-1** |
| messages | `ConversationData.load_older` + `ConversationActions chat.load_older` dispatcher (`conversation_data.ex:362-388,433-438`; `conversation_actions.ex:41-43,163-166,238-247` — **currently no authz**) | **PR-1** |
| members | `ConversationData` member/options reads; `KanbanShareController.session_assistant` direct session-slice read | **PR-1** |
| messages | `ChatFeed` / `ExternalFeed` message views (incl. replay-by-IDs, approved-attachment scan) | **PR-2** |
| delivery | `ExternalFeed` direct `DeliveryOutbox` reads: `committed_deliveries_since/2` (`external_feed.ex:116,164,205`) + `committed_surface_version/1` (`external_feed.ex:462,478`) — principal join/replay/snapshot | **PR-2** |
| attachments | authenticated `UploadsController` message-participation queries (`uploads_controller.ex:129-209`); conversation/kanban token mint; **public `ExternalFeedController` attachment serving** | **PR-3** |
| sessions (list) | workspace session-lists: `ConversationSessionState`/`WorldLive`, `HomeLive` (`home_live.ex:76` caller-less `list_sessions/1`, `listing.ex:20`), `KanbanShareController`; `UI.UriOptions.sessions`/`entities_and_sessions` (global `KindRegistry.list_all`) | **PR-4** |
| agents (list) | `AdminData` global registry/KPI; `ConversationData.snapshot_agent_options`; `IdentityData.list_entities/2` (`identity_data.ex:323`, caller-less); `UI.UriOptions.entities` | **PR-4** |
| templates (list) | `WorkspacePluginData.live_session_template_rows/1` → `KindRegistry.list_all` `template://` rows (`workspace_plugin_data.ex:220,417`) — principal workspace template list | **PR-4** |
| internal | `Delivery.replay_messages_since/3` (`delivery.ex:381-395`); reconcile/GC/boot | **PR-5** (`InternalReads`) |
| members (internal-convergence) | `ConversationActions.uninstall_socialware` session-slice read (`conversation_actions.ex:944`) + `AnonTakeover.member?/verify_convergence` (`anon_takeover.ex:179,192`) — `Kind.get_slice(_, :session)` for reconcile, **presenter/web-tier** | **PR-5** (`InternalReads`, split-then-relocate) |

---

## PR-1 — `SessionReads` (whole conversation read surface) + narrow message gate  → closes the info-disclosure
**Scope:** `SessionReads`∈socialware: `messages(caller, session, view \\ :conversation, page_opts)` covering **initial AND older/pagination**, `members(caller, session)`. Live-first `Membership.authorize/3`; chokepoint owns `:read_unfiltered` row-policy; `:conversation` view routes to existing `recent_visible/recent/older_visible/older` store fns. Migrate: `ConversationData` (all message + member reads), the `chat.load_older` **dispatcher (add authz — currently none)**, `KanbanShareController.session_assistant`. **Narrow gate:** ban direct `MessageStore.recent_*/older_*` + message `Repo` reads **from `ezagent_plugin_world`/presenter**, EXCEPT explicitly-deferred feed/uploads modules (PR-2/PR-3).
**Acceptance (§7):** #1 deep-link non-member denied (initial AND load_older); #2 observe-degrade; #3 fresh-join; #6 row-policy; #7(partial) direct message read in migrated world modules → CI red; #8 no per-row actor round-trip.
**Lands ALONE** (info-disclosure closed) — feeds/uploads keep their reads until their PRs.

## PR-2 — Route feeds through `SessionReads` (fold public-view + view shapes + DeliveryOutbox plane)
**Scope:** `ChatFeed`/`ExternalFeed` → `SessionReads.messages(view: :chat_feed|:external_feed)`; fold `PublicView.web_anon_access?/1` open-policy INTO `SessionReads`; view routes to `chat_visible_recent` / `committed_external_visible[_by_ids]`. **Also cover the delivery plane:** `ExternalFeed`'s direct `DeliveryOutbox` reads (`committed_deliveries_since/2`, `committed_surface_version/1`) reached from principal `join`/`replay`/snapshot — route them through the chokepoint OR declare the `DeliveryOutbox` store-owner functions as the allowlisted delivery chokepoint (these reads already sit behind `snapshot(session,caller)`'s auth gate; the gate just must have an owner so PR-5's full sweep isn't forced to exempt `ExternalFeed`). Extend the gate to forbid feed-module direct `MessageStore` **and** `DeliveryOutbox` reads.
**Acceptance (§7):** #4 public-session anon read via chokepoint policy; #10 feed byte-identical (message + delivery/settlement rows).

## PR-3 — Attachment plane: person-bound `DownloadToken` (auth'd + public serve) + kanban-403
**Scope:** `DownloadToken` optional `grantee` (serve-time `caller==grantee`; absent→legacy recheck); mint inside the cap-gated read; `UploadsController` AND public `ExternalFeedController` attachment serving both verify grantee; remove the legacy message-participation recheck. Extend gate to uploads modules.
**Acceptance (§7):** #9 legit member downloads kanban attachment (403 gone); leaked token by non-grantee rejected (both serve paths).

## PR-4 — Workspace + global LIST reads: `WorkspaceReads` / `AgentReads` / `OperatorReads`
**Scope:** `WorkspaceReads.{sessions,templates}`∈workspace (migrate `HomeLive`/`WorldLive`/`KanbanShareController` session-lists + `UriOptions.sessions` + `WorkspacePluginData.live_session_template_rows` template list); `AgentReads`∈workspace (migrate `snapshot_agent_options`/`IdentityData.list_entities`/`UriOptions.entities`); `OperatorReads`∈identity+ (migrate `AdminData` global `KindRegistry`/KPI/external-mirror — authorize an operator cap). All off direct `Repo`/`KindRegistry.list_all`. **Thread `caller` into every list read** (`list_sessions/1`, `list_entities/2`, `live_session_template_rows/1` are currently caller-less → they filter by workspace only and cannot enforce per-row visibility). Chokepoint applies **workspace-membership authz + per-row container-visibility filter** (multi-container query-scope, spec §3 taxonomy). Extend gate to these modules.
**Acceptance (§7):** #5 non-operator denied on registry list-all; **#6-list (per-row visibility): a caller who IS a workspace member but is NOT visible on session/agent X gets X ABSENT from `list_sessions`/`list_entities` — wrapping the read without per-row filter must FAIL this test** (closes the "same-workspace over-return" hole); #7 direct `Repo.all`/`KindRegistry.list_all` in `AdminData`/list readers → CI red.

## PR-5 — `InternalReads` gateway + complete two-sided gate + acyclic
**Scope:** `InternalReads` for `Delivery.replay_messages_since/3` + reconcile/GC/boot + the **internal-convergence session-slice reads** (`uninstall_socialware`, `AnonTakeover.member?/verify_convergence`) — these are `Kind.get_slice(_,:session)` reconcile reads currently in **presenter/web-tier** modules, so **split-then-relocate**: move the internal read behind `InternalReads` in a framework-tier module (else criterion #12 fails — a presenter module calling `InternalReads` is CI-red). Install the **complete** gate as two module allowlists over the **full primitive set** (§ gate-primitive: `MessageStore.*`, `Kind.get_slice(_,:session|:members)`, `DeliveryOutbox.*`, `KindRegistry.list_all`, raw `Repo`): (a) direct-store reads ⊆ {chokepoints, store-owner, `InternalReads`}; (b) `InternalReads` callers ⊆ {framework tier}.
**Acceptance (§7):** #7 full gate **across all planes** (a direct `Kind.get_slice(_,:session)` or `DeliveryOutbox` read added to any presenter module → CI red, proving members+delivery planes can't drift back); #11 arch acyclic green at §5 placements; #12 principal-facing module calling `InternalReads` → CI red. **Zero-orphan is proven here:** full gate compiles green ⇒ no un-chokepointed principal read of any plane remains.

---

## Sequencing & review
- **PR-1 first** — user-visible security fix, lands standalone. PR-2→5 extend coverage; the gate tightens each PR; **PR-5 proves zero-orphan** (full gate compiles ⇒ no un-chokepointed principal read remains).
- Each PR: affected-app `mix test` + `mix ezagent.check_invariants` + arch acyclic before merge; watch push-to-main full-suite (a `DBConnection.OwnershipError`-class red = known #184 flake — re-run, don't assume). Each PR gets a codex adversarial review before merge; merge only clean.

## Out of scope (spec §6): in-VM defense; at-rest field-crypto (Path-B); write-plane side-table consolidation (STRETCH).
