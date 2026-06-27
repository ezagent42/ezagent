# SPEC — Unified non-activating "read agent config/state" interface on `Entity.Agent`

**Status:** DRAFT (design doc — NOT implementation). 2026-06-26.
**Author:** Claude (lead-dispatched), `Skill: ezagent-developer`.
**Reviewed against:** `origin/main` @ `4a7a7bed`; in-flight per-site reads on `origin/fix/cc-folder-trust` @ `3ee9e3a5`.
**Replaces (consolidates):** the three PR #1028 per-site snapshot-read patches (config, caps, sandbox-in-flight).
**Does NOT touch:** the generic render transport, the dispatch chokepoint, the cap struct shape.

**Codex adversarial review (gpt-5.5, static):** initial verdict **REJECT** — 4 blocking issues, all
addressed in this revision. (1)+(2) "APIs don't exist / config+caps still dispatch" — codex read the
`origin/main` worktree where the #1028 reads aren't yet present; they live on `fix/cc-folder-trust`.
Fixed by the §0 ⚠ branch-provenance callout + OQ-6 sequencing (design unchanged — labels qualified).
(3) authz parity overclaim ("identical caller set") — corrected to a **bounded SUPERSET** on the
cold-caller axis (§3.2) + honest §8 test 6. (4) `CapCheckOnlyAtChokepointTest` p3 allowlists the whole
session dir so it can't PROVE the reader's discipline — §7 caveat added + §8 test 9 (module-scoped
grep) compensates. Codex CONFIRMED (non-blocking): `:api_keys` exclusion, `:sandbox` durable+cap-gated
classification, and the home/dep-DAG argument. See §10 for the resulting open questions.

---

## 0. The problem (lead's architectural observation)

Reading an agent's persisted config / caps / sandbox / status currently force-**ACTIVATES** a
cold agent. The world detail page (and other read surfaces) ask "what is this agent's config?"
by **dispatching** an action (`:call`) to the agent Kind. Dispatch lazy-spawns + activates the
Kind. A cold `cc` agent needs ~5–20s to launch claude and click its startup dialogs, blowing the
5s `ReadyGate` budget → `{:error, :activate_timeout}` (FP5 S5, #115). A pure *read of persisted
state* should never start a heavy subprocess.

PR #1028 patched this **per site**, three times, independently.

> **⚠ Branch provenance (read before verifying against the tree).** ALL of the #1028 work
> described below lives on **`fix/cc-folder-trust`** (HEAD `3ee9e3a5`), **NOT on `origin/main`**.
> Verified 2026-06-26: on `origin/main`, `Ezagent.Agent.Config.read_cascade/4` **still dispatches**
> (`config.ex:223 Invocation.dispatch`), and `Ezagent.Identity.read_entity_caps/1` +
> `Ezagent.Identity.caps_authorize?/2` **do not exist** (main's `identity.ex` has `read_held_caps/1`
> + a users-table fallback instead). So on main, NONE of the three reads is non-activating yet.
> "Landed" in the table below means "landed on `fix/cc-folder-trust`". This SPEC's worktree is off
> `origin/main`; a reviewer reading the worktree tree will not find the `fix/cc-folder-trust`
> symbols — read them via `git show origin/fix/cc-folder-trust:<path>`. **Consolidation
> sequencing (OQ-6):** this SPEC assumes `fix/cc-folder-trust` (the config+caps non-activating
> reads + their `Identity` owners) lands on main FIRST, or is rebased under, the unified reader.
> If the unified reader is built against main as-is, steps 1–2 of §9 must FIRST port the config/caps
> de-activation (not just "delegate to the landed owner").

| read | facade | how it was de-activated (on `fix/cc-folder-trust`) |
|------|--------|--------------------------|
| **config cascade** | `Ezagent.Agent.Config.read_cascade/4` | reads `ConfigEvolve.build_cascade/2` directly (pure DB projection), authorizes via `Identity.caps_authorize?/2` instead of dispatching `config_evolve.read_cascade`. **Landed on `fix/cc-folder-trust`** (main still dispatches). |
| **caps** | `Ezagent.Identity.read_entity_caps/1` (consumed by `World.IdentityData.list_entity_caps/3`) | reads the `:identity` slice via `Kind.get_slice/2`, **falls back to `SnapshotStore.latest/1`** for a cold entity, normalized via `normalize_slice_view/1`; authorizes via `caps_authorize?/2` instead of dispatching `identity.list_caps`. **Landed on `fix/cc-folder-trust`** (absent on main — main dispatches `identity.list_caps`). |
| **sandbox** | `World.IdentityData.sandbox_read/3` | **still `Invocation.dispatch(:sandbox/:read, :call)` → still activates,** on BOTH branches. In flight; not yet converted anywhere. |

Three separate snapshot-read patches in three apps = **local entropy** (memory
`feedback_systematic_fix_over_local_entropy`, `feedback_question_the_problem_when_fix_keeps_failing`).
Each re-derives the same machinery (read-persisted-slice, preserve-the-cap-gate-without-dispatching,
fall-back-to-snapshot-for-a-cold-entity) slightly differently, in a different tier, with a different
authz call shape. The sandbox site hasn't even been done. A fourth read surface added next month
will copy whichever of the three it finds first.

**The systematic fix:** ONE interface — "read agent X's config / caps / sandbox / status WITHOUT
activating it" — that every read surface (world detail page, console, future LiveViews, CLI display)
goes through. The de-activation machinery is written once, the cap gate is preserved once at one
chokepoint owner, and adding a read surface is "call the interface", not "re-derive the patch".

---

## 1. Where the interface lives

**Home: `Ezagent.Domain.Agent`** (`apps/ezagent_domain_session/lib/ezagent/domain/agent.ex`).

This is decided by the dependency DAG, not by preference:

```
ezagent_domain_session  →  {core, identity, agent, pty, workspace, external_mirror, agent_bridge}
ezagent_domain_agent    →  {core, identity, agent_bridge}          # NO pty, NO session
ezagent_domain_identity →  {core}
```

The unified reader must reach **all four** sources:

- config cascade → `Ezagent.Agent.Config` (lives in `ezagent_domain_agent`)
- caps → `Ezagent.Identity.read_entity_caps/1` (lives in `ezagent_domain_identity`)
- sandbox `:sandbox` slice → `Ezagent.Kind.get_slice/2` + `Ezagent.SnapshotStore` (core)
- status → `Ezagent.Domain.Pty` / `KindRegistry.lookup` (pty / core)

Only `ezagent_domain_session` sits above all of those in the DAG. `ezagent_domain_agent` (where
`Agent.Config` lives) is the *tempting* home but it **cannot reach pty/session** — putting the
reader there either breaks the DAG (new `agent → session` or `agent → pty` edge — arch-gate
violation, possible cycle `agent ↔ session`) or forces status out of the unified surface. Rejected.

`Ezagent.Domain.Agent` is **already** the sanctioned, flavor-agnostic, UI-facing Agent facade
(its moduledoc: *"Domain-layer single entry point … UI surfaces … call this instead of reaching
into plugin internals … the sanctioned boundary"*). It **already** hosts `lifecycle_status/1`
(status — already non-activating: `KindRegistry.lookup` then a guarded `Domain.Pty.status`). The
three other reads belong next to it. No new module, no new app, no new dep edge.

> **Decision D1.** The interface is a set of public functions on the existing `Ezagent.Domain.Agent`
> module. We do NOT introduce a new `Ezagent.Agent.View` / `Agent.Read` module — that would be a
> second UI-facing Agent facade competing with `Domain.Agent`, and `Domain.Agent` already owns this
> role and the only dep position that works. (Alternative considered + rejected: a dedicated
> `Agent.Read` in `ezagent_domain_agent` — fails the DAG as above.)

---

## 2. The interface (API)

All functions are **non-activating**: they read persisted state (live slice if the Kind happens to
be hot, else snapshot), preserve the same cap gate the live dispatch enforced, and NEVER spawn or
activate the target. Each takes an **authz context** that mirrors the live dispatch's `ctx`: the
authenticated **caller URI** plus the caller's optional **inline caps** (`ctx.caps`-shaped). Both
are needed because the live dispatch authorizes via *two permanent routes* — `ctx.caps` OR the
caller's slice-backed caps (§3.2).

```elixir
# Mirrors the slice of ctx the two-route authz consumes. `caps` defaults to []
# (most callers carry none; some — e.g. workers with inline self-authority — do).
@type read_ctx :: %{caller: URI.t(), caps: MapSet.t() | [Ezagent.Capability.t()]}

# Config cascade — delegates to the already-non-activating Ezagent.Agent.Config.read_cascade/4.
@spec read_config(agent :: URI.t(), read_ctx(), opts :: keyword()) ::
        {:ok, map()} | {:error, term()}

# One config key.
@spec read_config_key(agent :: URI.t(), key :: String.t(), read_ctx(), opts :: keyword()) ::
        {:ok, map()} | {:error, term()}

# Caps — delegates to Ezagent.Identity.read_entity_caps/1 after the list_caps gate.
@spec read_caps(entity :: URI.t(), read_ctx()) ::
        {:ok, [Ezagent.Capability.t()]} | {:error, term()}

# Sandbox state slice (config_dir_path / template_class / respawn_template_data / pty_phase / …).
@spec read_sandbox(agent :: URI.t(), read_ctx()) ::
        {:ok, map()} | {:error, term()}

# Status — already non-activating; delegates to the EXISTING lifecycle_status/1. NOT re-derived.
@spec read_status(agent :: URI.t()) :: Ezagent.Domain.Agent.status()
```

### How each read resolves (non-activating contract)

The interface does NOT re-implement slice reading. Each read **delegates to the slice's owning,
already-allowlisted facade** so the unified module never opens a new raw `get_slice`/`matches?` site
(this is what keeps `SensitiveSliceReadTest` + `CapCheckOnlyAtChokepointTest` green — see §5):

1. **`read_config`** → `Ezagent.Agent.Config.read_cascade/4` (already pure-DB via
   `ConfigEvolve.build_cascade/2`; already gated by `cap(:agent, Manage, :read_cascade)`).
   `Domain.Agent` passes the caller's non-activating caps (§3) into it.

2. **`read_caps`** → `Ezagent.Identity.read_entity_caps/1` (the sanctioned owner). That function is
   the reference de-activation pattern: live `Kind.get_slice(uri, :identity)` first (registry
   lookup — `:not_found` for a cold entity, never spawns), then `SnapshotStore.latest/1` fallback,
   normalized via `Ezagent.Kind.normalize_slice_view/1`. `Domain.Agent` applies the `list_caps`
   gate (§3) before returning the rows.

3. **`read_sandbox`** → reads the `:sandbox` slice via the **same** live-then-snapshot pattern.
   This pattern already exists and is proven for `:sandbox`:
   `Ezagent.AgentRoleResolver.role_from_durable_snapshot/1` reads `SnapshotStore.latest/1` →
   `state[:sandbox]` on the routing hot path with no live-Kind read. The conversion lifts that into
   a sandbox-slice reader **owned by a sandbox-slice-owning facade** (see §4 + §5 for the owner
   placement constraint), live `Kind.get_slice(uri, :sandbox)` first then `SnapshotStore.latest`
   fallback, normalized via `normalize_slice_view`. `Domain.Agent` applies the `cap(:agent,
   Sandbox, :read)` gate (§3).

4. **`read_status`** → the existing `lifecycle_status/1`. No change; it is already
   `KindRegistry.lookup` + guarded `Domain.Pty.status`. Listed in the interface for completeness so
   callers have one module to reach for; the implementation is unchanged.

> **Decision D2.** The unified reader is a thin **authorize-then-delegate** layer. The actual slice
> reads stay in their owning facades (`Agent.Config`, `Identity`, and a sandbox-slice owner). This
> keeps the de-activation machinery DRY at exactly one site per slice *and* keeps every sensitive
> slice read at its allowlisted owner. `Domain.Agent` adds the **uniform authz preflight** + the
> uniform non-activating caller-caps read; it does not add raw slice access.

---

## 3. Authorization — chokepoint, and the PR-CC-2c reconciliation

### 3.1 The gate must be preserved, at a chokepoint owner

Each live dispatch enforced a **distinct** cap at runtime step 5.5. The unified reader preserves
each one — they do **not** collapse to one cap:

| read | needed-cap (runtime shape the dispatch built) | extra |
|------|-----------------------------------------------|-------|
| config | `%{kind: :agent, behavior: Manage, action: :read_cascade, instance: <agent>, workspace_uri: <ws>}` | instance-scoped: a Manage cap over a *different* agent must NOT match |
| caps | `%{kind: <entity_kind>, behavior: Identity, action: :list_caps, instance: <entity>, workspace_uri: <ws>}` | **self-read exemption**: `same_uri?(caller, entity)` → `:ok` (mirrors the dispatch's self-`list_caps`) |
| sandbox | `%{kind: :agent, behavior: Sandbox, action: :read, instance: <agent>, workspace_uri: <ws>}` | instance-scoped |

The needed-cap is constructed by **pure field assignment from the target** (no `matches?` in the
facade) — preserving the instance binding (and thus the wrong-target denial) exactly as
`resolve_required_cap/4` does at the chokepoint.

The cap **match** is NOT hand-rolled in `Domain.Agent`. It runs through the sanctioned chokepoint
owner **`Ezagent.Identity.caps_authorize?/2`** — the one allowlisted home for the cap-shape check
used by non-dispatching read facades (it applies the EXACT predicate `default_holds_cap?` /
`Runtime.authorizes?` apply: `granted_by_entity?/1` AND `Capability.matches?/2`). This is why
`CapCheckOnlyAtChokepointTest` p3 (`Capability.matches?` outside the chokepoint) stays green: the
new module never calls `matches?`; it calls `caps_authorize?`, which lives at an allowlisted owner
(`apps/ezagent_domain_identity/lib/ezagent/`).

### 3.2 The two authz routes — both permanent (the `ctx.caps` / `holds_cap?` interaction)

The live dispatch step 5.5 (`runtime.ex` `authz_check/4`) authorizes via **two routes**, OR'd:

1. **`granted_via_ctx_caps?(ctx, needed)`** — the caller's **inline caps** carried in `ctx.caps`
   match `needed`.
2. **`granted_via_holds_cap?(ctx, needed)`** — slice-backed: `Kind.holds_cap?` reads
   `get_slice(caller, :identity)` and `matches?` against `needed`.

The stale `runtime.ex` comment claims a future "PR-CC-2c removes the ctx.caps branch". **That
premise is OBSOLETE.** A scope analysis (lead, 2026-06-26) found Decision **#154**
(system-principal elimination) deliberately made `ctx.caps` the **PERMANENT inline self-authority
carrier**: deleting `system://` principals (e.g. `worker-publish`, `agent-internal`) meant the
authority those principals provided is now **minted inline into `ctx.caps`**, never into a slice.
The evidence is in the code I read: `ExternalMirrorWorker` carries its OWN inline publish/subscribe
caps in `ctx.caps` *"the deleted `system://worker-publish` principal's replacement, north star /
Decision #154"*; `Agent.TemplateSpawn` carries the agent's self-`sandbox.write_path` authority
inline after `agent-internal` was eliminated. A worker/spawn caller holds these in `ctx.caps` and
**NOT** in any `:identity` slice — so the slice route (`holds_cap?`) cannot authorize them.
Removing the `ctx.caps` branch would **break** every inline-self-authority caller.

> **Conclusion (Decision D3): the unified reader authorizes EXACTLY as the live dispatch does —
> `granted_via_ctx_caps?(ctx.caps) OR granted_via_holds_cap?(slice)` — and BOTH routes are
> permanent.** There is no future migration to "holds_cap?-only". The SPEC's deliverable here is a
> note to **fix the stale `runtime.ex` comment** (recommended Option A from the scope analysis: keep
> `ctx.caps` permanent), so a future contributor doesn't re-derive the wrong premise. (This also
> reconciles with caps-cleanup-v1 r4 §0d.1, which already said "`ctx.caps` KEPT" — the live comment
> was the outlier.)

**Why the reader must implement BOTH routes (the trap a naive reader falls into):** if it took only
a pre-loaded `caps` set (`caps_authorize?(caps, needed)`), it would honor route 1 but **silently
drop route 2** — a logged-in user who holds the cap in their `:identity` slice but did not hand it
inline would be wrongly **denied**. If it took only the caller URI and read the slice, it would
honor route 2 but drop route 1 — an inline-self-authority worker would be wrongly **denied** (its
authority lives only in `ctx.caps`). The live dispatch ORs them precisely so neither caller class is
locked out; the reader must mirror that.

**The two-route authz, non-activating, at the chokepoint owner:**

```elixir
# `ctx` is the read_ctx: %{caller: uri, caps: inline_caps}. Mirrors dispatch step 5.5.
defp authorize(needed, %{caller: caller} = ctx) do
  inline = Map.get(ctx, :caps, [])                 # route 1: ctx.caps (inline self-authority)
  cond do
    Ezagent.Identity.caps_authorize?(inline, needed) -> :ok                       # route 1
    Ezagent.Identity.caps_authorize?(slice_caps(caller), needed) -> :ok           # route 2
    true -> {:error, :unauthorized}
  end
end

# Route 2 source = the caller's slice caps, read NON-ACTIVATINGLY (live slice → snapshot fallback).
defp slice_caps(%URI{} = caller), do: Ezagent.Identity.read_entity_caps(caller)
```

Both routes match through the SAME sanctioned chokepoint owner `Ezagent.Identity.caps_authorize?/2`
(`granted_by_entity?/1` AND `matches?/2`) — the new module never hand-rolls `matches?`. Properties:

- **Same two routes + same predicate as the live dispatch — but route 2 is a deliberate SUPERSET,
  not identical.** The reader uses the same OR-of-(`ctx.caps`, slice-caps) structure and the same
  `granted_by_entity?` + `matches?` predicate. It is **NOT** "the identical caller set, no more no
  less": on route 2 the reader reads the caller's caps via `read_entity_caps/1` (slice → snapshot
  fallback), whereas the live dispatch reads them via bare `default_holds_cap?` (slice **only**, no
  snapshot — `kind.ex:236`). So **the reader authorizes a strict SUPERSET of the dispatch's caller
  set: it additionally authorizes a COLD caller whose persisted (snapshot) caps match** but whose
  `:identity` Kind isn't currently hot. This is intentional (a read surface must work for a
  logged-in user whose Kind is cold), and it is the ONLY divergence — it never authorizes a caller
  with *insufficient* caps; it only refuses to deny a caller solely for being cold. See OQ-1 for the
  proposal to make the dispatch path itself cold-safe (which would collapse the superset back to
  equality).
- **`ctx.caps` is permanent** (#154) — there is **no** future migration this reader must anticipate;
  it will not break when PR-CC-2c lands (PR-CC-2c keeps `ctx.caps`).
- **Fail-closed on caps, never fail-open.** A caller with no matching cap (inline or
  slice-or-snapshot) is denied on both routes. The superset is strictly along the cold/hot axis, not
  the cap-content axis.
- **Non-activating throughout.** Neither route spawns the caller's Kind.

> **OQ-1 (for the lead):** route 2 uses `read_entity_caps` (slice+snapshot) where the live dispatch
> uses bare `holds_cap?` (slice-only, denies cold callers). Should `default_holds_cap?` *itself*
> gain the snapshot fallback so the dispatch path and the reader share one cold-safe caller-caps
> read? Deeper fix, changes dispatch semantics — out of scope, flagged not assumed. (§10.)

> **Note on `ctx.caps` callers today.** The world facade already threads `caller_caps` (an
> `ctx.caps`-shaped MapSet) into the per-site readers — that is route 1, and it stays. The unified
> reader keeps accepting inline caps AND adds the slice/snapshot route, so it serves both the
> human-user (slice) and inline-self-authority (ctx.caps) caller classes. The **render transport**
> is unaffected.

---

## 4. Consolidation — how the three #1028 reads fold behind ONE interface

| #1028 site | today | after this SPEC |
|------------|-------|------------------|
| `Ezagent.Agent.Config.read_cascade/4` | pure-DB read + `caps_authorize?` (landed) | **KEPT** as the config-slice owner. `Domain.Agent.read_config/3` delegates to it. The world facade stops calling it directly and calls `Domain.Agent` instead. No behavior change to `Agent.Config`. |
| `Ezagent.Identity.read_entity_caps/1` | slice→snapshot read (landed) | **KEPT** as the caps owner + the reference de-activation pattern. `Domain.Agent.read_caps/2` applies the `list_caps` gate + delegates. `World.IdentityData.list_entity_caps/3`'s authz + read move into `Domain.Agent`; the world facade keeps only `cap_row/1` (render). |
| `World.IdentityData.sandbox_read/3` | **still dispatches → activates** | **CONVERTED + RELOCATED.** The dispatch is deleted. A new non-activating sandbox-slice reader (live `get_slice(:sandbox)` → `SnapshotStore.latest` fallback, normalized) lands at a **sandbox-slice owner facade** (§5), gated by `cap(:agent, Sandbox, :read)`, surfaced via `Domain.Agent.read_sandbox/2`. `World.IdentityData.list_extensions/3` + `agent_sandbox_state/3` call `Domain.Agent.read_sandbox/2`. |

**Deleted:** `World.IdentityData.sandbox_read/3` (the dispatch), `World.IdentityData.authorize_list_caps/3`
+ `list_entity_caps`'s authz/read body (moves to `Domain.Agent`), and the world facade's two
inline needed-cap constructions (config caller already centralised). **Kept:** every render helper
in the world facade (`cap_row/1`, `jsonable/1`, the LiveView assigns) — the **generic render
transport is untouched** (§6). **Kept unchanged:** `Agent.Config` (config owner),
`Identity.read_entity_caps` + `caps_authorize?` (caps owner + chokepoint).

Net: three de-activation re-derivations collapse to **one authorize-then-delegate layer**
(`Domain.Agent`) over **three slice-owning facades**, one of which (sandbox) gets the same
treatment config + caps already received. A fourth read surface added next month calls
`Domain.Agent.read_*`; it cannot re-derive the patch because there is nothing to copy — the world
facade no longer contains read machinery.

---

## 5. Boundary — what is non-activating vs. what must stay live

**Legitimately non-activating (all persisted slices — IN this interface):**

- **config cascade** — durable `ConfigStore` rows (`ConfigEvolve.build_cascade`). Pure DB.
- **caps** — `:identity` slice; snapshot-backed.
- **sandbox** — `:sandbox` slice (`config_dir_path`, `template_class`, `respawn_template_data`,
  `pty_phase`, `passive`, `role`). All DURABLE (the slice's own moduledoc: every field survives a
  restart); snapshot-backed. The `pty_phase` field is itself the *persisted mirror* of the live
  phase precisely so the badge renders without a live subprocess — confirming a read is meant to be
  non-activating.
- **status** — `lifecycle_status/1`: `KindRegistry.lookup` (registry, no spawn) + a guarded read of
  an already-running sidecar. Reading status of a cold agent returns `:not_found` — correct, and
  non-activating by construction.

**Genuinely live — MUST NOT be forced into this interface:**

- **PTY buffer / terminal scrollback** (`Ezagent.Domain.Pty.Server.snapshot_buffer/1`,
  `World.IdentityData.pty_initial_buffer/1`). This is the *live subprocess's* in-memory ring
  buffer; it has **no persisted slice** and is meaningless for a cold agent (a cold agent has no
  PTY). Forcing it behind a "non-activating read" would either return empty/garbage or — worse —
  tempt someone to spawn the PTY to satisfy the read, reintroducing the exact activation bug. It
  stays a separate, explicitly-live read.
- **`pty_alive?` / live `subprocess_phase` of a live agent** — querying the *running* process is a
  liveness probe, not a persisted read. (`Domain.Agent` already separates `lifecycle_status` (Kind
  lifecycle, non-activating) from `subprocess_phase` (live subprocess) — that split is exactly this
  boundary and is preserved.)
- **`list_api_keys` / API-key bodies (`:api_keys` slice).** This is a deliberate **non-inclusion**,
  flagged so reviewers see it was considered, not missed. The `:api_keys` slice *is* persisted, so
  by the surface test ("is it a persisted slice?") it looks eligible. It is excluded on **two**
  axes:
  1. **It is SENSITIVE.** `SensitiveSliceReadTest` allowlists `:api_keys` reads to the owning
     `Behavior.ApiKeys` only. A new reader of it must be allowlisted *with justification* — caps
     bodies / credentials are the gate's whole reason to exist.
  2. **It is NOT cap-gated.** `:put_api_key`/`:delete_api_key` and the read are authorized by
     **data_owner (the agent's creator) or admin**, not a held cap (`World.IdentityData.can_edit_api_keys?`
     → `Identity.admin?` / `same_uri?(creator)`). Folding it into a cap-gated `caps_authorize?`
     reader would be wrong on the authz axis too.
  > Excluded from this SPEC. If a non-activating API-key *list* read is later wanted, it is a
  > **separate** design (data_owner/admin gate, `SensitiveSliceReadTest` allowlist entry with
  > justification, kept out of the cap-gated path). Flagged as **OQ-2** for the lead.

**Boundary rule (Decision D4):** a read belongs in this interface iff (a) its source is a DURABLE
slice/store readable without a live process, AND (b) its authorization is **cap-gated** (so the
uniform `caps_authorize?` preflight applies). Persisted-but-not-cap-gated (`:api_keys`) and
live-only (PTY buffer) reads are explicitly out.

---

## 6. Generic render transport — UNTOUCHED

The world/LiveView render path (`World.IdentityData.cap_row/1`, `jsonable/1`, the detail-page
assigns, the React/LV surface) is **not** in scope. The interface returns the SAME shapes the
per-site readers return today (`{:ok, cascade_map}`, `{:ok, [%Capability{}]}`, `{:ok,
sandbox_state_map}`). The render functions keep consuming those shapes verbatim. This SPEC moves
**authz + non-activating read** behind `Domain.Agent`; it does not move or alter rendering. (Memory
`feedback_explain_problem_not_code_structure`: the consolidation is about the read/authz machinery,
not the view.)

---

## 7. Dep-safety + architecture gates

- **No new cross-app dep.** Home is `ezagent_domain_session`, which already depends on `core`,
  `identity`, `agent`, `pty`. All four reads are reachable through existing edges. No edge added,
  no cycle created (the dangerous `agent → session` / `agent → pty` edges are NOT created — the
  reader is *in* session, reaching *down*).
- **No flavor-refs-in-core.** The reader is flavor-agnostic (it asks for slices, not "cc"). It
  lives in domain, not core; core gains nothing.
- **Cap-check stays at the chokepoint** (design discipline — the new module calls `caps_authorize?`
  at the allowlisted owner, never `Capability.matches?`; needed-cap construction is pure field
  assignment).
  > **Honest gate-strength caveat (do not overclaim).** `CapCheckOnlyAtChokepointTest` p3
  > allowlists the ENTIRE `apps/ezagent_domain_session/lib/ezagent/` directory
  > (`cap_check_only_at_chokepoint_test.exs:59`), which **includes** the proposed `Domain.Agent`
  > home. So p3 will **not PROVE** the reader avoids a hand-rolled `matches?` — a stray `matches?`
  > in `domain.agent.ex` would pass CI. p3 only guarantees the reader doesn't fail CI; it does not
  > enforce the discipline here. Two consequences this SPEC accepts: (a) the "no hand-rolled
  > `matches?`" property is a **review/design** obligation for `Domain.Agent`, not a gate-enforced
  > one; (b) to give it teeth, §8 adds a **module-scoped** assertion that `domain.agent.ex` source
  > contains no `Capability.matches?` token (a targeted unit grep, since the global p3 can't). The
  > preferred match path stays `caps_authorize?` regardless.
- **No new sensitive-slice read site** (`SensitiveSliceReadTest`): `read_caps` delegates to the
  allowlisted owner `Identity.read_entity_caps`; the new module adds NO `get_slice(:identity)` /
  `get_slice(:api_keys)` call. The sandbox `get_slice(:sandbox)` reader is placed at a sandbox-slice
  owner facade (`:sandbox` is not in `@sensitive_slices`, so it's not gated by that test — but the
  reader is still co-located with a sandbox-owning facade to keep the consolidation honest, not
  sprayed across plugins).
- **Lifecycle gate** (`ezagent.check_invariants.lifecycle`): the reader does no engine-internal
  calls inside a Behavior handler — it is a plain domain facade, not a Behavior. Untouched.
- **NEW — `no_surface_read_dispatch` arch-gate (the anti-recurrence gate; full design §11).** A new
  probe added to `CapCheckOnlyAtChokepointTest`'s `@probes` list (p14): it greps the
  presentation/surface dirs for a dispatch of any of the **three consolidated read-class
  `(behavior, action)` pairs** — `(:config_evolve, :read_cascade)`, `(:identity, :list_caps)`,
  `(:sandbox, :read)` — and FAILS if any is found. This makes "a future surface re-introduces an
  ad-hoc activate-on-read" structurally un-reintroducible: the consolidation §4 is a one-time
  cleanup, this gate is the regression-lock that keeps it cleaned. **It is the LAST step of the
  unified-read implementation** — see §9 (it can only go green once all three reads are already
  migrated onto `Domain.Agent.read_*`). Mirrors the established `cap_check_only_at_chokepoint` probe
  machinery exactly (same `%{id, desc, pattern, allowlist}` shape, same surface-dir scan, same
  failure-message format). Does NOT forbid WRITE/action dispatch from surfaces (those legitimately
  activate) and does NOT touch the live PTY-buffer read (no persisted slice, never dispatched) — see
  §11.2 for the read-vs-write classification and the explicit carve-outs.

---

## 8. Test plan

All assertions follow `config_no_activation_test.exs`: use a **cold** agent (URI valid, Kind never
spawned), assert `KindRegistry.lookup == :error` **before AND after** the read.

1. **Unified no-activation (one test per read + a combined one).** For config / caps / sandbox /
   status against a cold agent: `refute kind_live?` before, perform `Domain.Agent.read_*`, assert
   the data resolves from store/snapshot, `refute kind_live?` after. (Mirrors + supersedes
   `config_no_activation_test` and `identity_caps_no_activation_test`; **adds the missing sandbox
   no-activation test** — sandbox is the one site that currently still dispatches.)
2. **Authz preserved — unauthorized caller.** Each read with a caller holding no matching cap →
   `{:error, :unauthorized}`, `refute kind_live?` (no activation on the deny path either).
3. **Authz preserved — wrong-target (instance scope).** A caller holding `Manage`/`Sandbox` over a
   *different* agent reading the target → `{:error, :unauthorized}` (config + sandbox).
4. **Self-read exemption (caps).** `caller == entity` → `:ok` even with no `list_caps` cap.
5. **Two-route authz parity (the D3 case).** (a) **Route 1 — inline `ctx.caps`:** caller passes a
   matching cap inline, holds NOTHING in its slice → `read_*` succeeds (covers the inline-self-
   authority worker class). (b) **Route 2 — slice/snapshot, cold caller:** caller's User Kind is
   **cold**, passes NO inline caps, but its persisted slice caps authorize → `read_*` succeeds
   (proves the `read_entity_caps` snapshot-fallback authorizes a cold caller — the bug bare
   `holds_cap?` would have). (c) **Neither route:** no inline cap + no slice cap → `:unauthorized`.
   All assert neither caller nor target Kind goes live.
6. **Two-route structure lock (NOT "identical caller set").** Assert BOTH routes are honored — an
   inline-`ctx.caps`-only caller AND a slice/snapshot-only caller each authorize — so a refactor
   cannot silently drop one route (which would lock out one caller class). Do **not** assert "same
   caller set as the live dispatch": the reader is a deliberate SUPERSET on the cold-caller axis
   (§3.2). The bounded-divergence claim is instead pinned by an explicit pair: (a) a HOT caller is
   authorized identically by the reader and by a real `Invocation.dispatch` step-5.5 (parity on the
   hot path), and (b) a COLD caller with matching persisted caps is authorized by the reader but
   DENIED by `Kind.default_holds_cap?` directly (proving the superset is exactly the cold-snapshot
   set, nothing more). This is the honest invariant; "identical set" would be false.
7. **Render parity.** The shapes returned by `Domain.Agent.read_*` equal what the per-site readers
   returned, so the world render path is unchanged (a fixture-equality test against the prior
   shapes).
8. **Arch gates green** (run, don't assume): `mix ezagent.check_invariants` (incl. cap-check-only,
   sensitive-slice), `cap_check_only_at_chokepoint_test`, `sensitive_slice_read_test`.
9. **Module-scoped no-hand-rolled-`matches?` (compensates for the p3 allowlist).** A unit test
   asserting the `domain.agent.ex` source has zero `Capability.matches?` occurrences — because the
   global p3 probe allowlists the whole session dir and therefore can't enforce this for the new
   reader (§7 caveat). Guarantees the reader routes the match through `caps_authorize?`.
10. **Anti-recurrence regression-lock (the gate — §11). Green ONLY after migration.** The new p14
    probe (added to `CapCheckOnlyAtChokepointTest.@probes`) scans the surface dirs
    (`apps/ezagent_plugin_world/lib/`, `apps/ezagent_web/lib/`, the operator-CLI
    `apps/*/lib/mix/tasks/`) and asserts **zero** occurrences of a dispatch of any of the three
    consolidated read pairs `(:config_evolve, :read_cascade)`, `(:identity, :list_caps)`,
    `(:sandbox, :read)`. This is the test that **fails today** (the `World.IdentityData` sandbox
    read site dispatches `:sandbox/:read`) and only turns green once §9 step 3 has pointed every
    surface read at `Domain.Agent.read_*`. It is therefore wired in as the **LAST** migration step
    (§9 step 5) — landing the probe before the reads are migrated would red-bar CI immediately. It
    is the durable proof that a FUTURE surface cannot re-add an activate-on-read: anyone who writes
    `Invocation.dispatch(with_action(uri, :sandbox, :read), …)` (or either of the other two pairs)
    in a surface file breaks p14.
11. **Anti-recurrence POSITIVE control (the gate fires — green TODAY, no migration needed).** A unit
    test that proves the p14 regex is not a vacuous/no-op pattern: construct a synthetic surface-file
    fixture string containing `Ezagent.URI.with_action(uri, :sandbox, :read)` at a fake surface path
    and assert p14's pattern **matches** it (and, symmetrically, that a WRITE dispatch
    `with_action(uri, :pty, :write)` and the deliberately-kept-dispatchable
    `with_action(uri, :identity, :list_api_keys)` read do **NOT** match). Without this, a broken
    regex would let test 10 pass vacuously. Tests 10 (regression-lock) and 11 (positive control)
    are kept **distinct** on purpose: 10 proves the tree is clean *after* migration; 11 proves the
    detector actually detects, *before* (and independent of) migration.
12. **Negative carve-out assertions (read-vs-write classification defensible, not asserted).** Two
    explicit assertions that the gate does NOT false-positive on the two reads the SPEC intentionally
    leaves live/dispatchable at the surface (§5 + §11.2): (a) the live **PTY-buffer** read path
    (`Domain.Pty.Server.snapshot_buffer/1` / `World.IdentityData.pty_initial_buffer/1`) — which is a
    direct function call, not a dispatch, and uses no read-class action atom — is not flagged; and
    (b) the **`:list_api_keys`** surface dispatch (sensitive, data_owner/admin-gated, deliberately
    excluded from the unified reader per §5) is not flagged. Together with test 11's write-dispatch
    non-match, these pin the classification: the gate forbids EXACTLY the three consolidated
    cap-gated read pairs, nothing wider.

---

## 9. Migration order

1. Add `Domain.Agent.read_config/3`, `read_config_key/4`, `read_caps/2`, `read_sandbox/2`, surface
   `read_status/1` (delegate to existing `lifecycle_status/1`). Authz via D3 (`read_entity_caps`
   caller-caps + `caps_authorize?`). Tests §8.1–8.7.
2. Land the non-activating sandbox-slice reader at the sandbox owner facade; wire `read_sandbox/2`
   to it. Delete `World.IdentityData.sandbox_read/3` (the dispatch).
3. Point `World.IdentityData` (config/caps/sandbox/extensions) at `Domain.Agent.read_*`; delete its
   inline authz + read bodies; keep its render helpers. **After this step, NO surface file dispatches
   any of the three read pairs** — this is the precondition for step 5.
4. Run the full invariant suite (§8.8) before any merge (memory `feedback_run_check_invariants_gate`).
5. **LAST — land the `no_surface_read_dispatch` arch-gate (p14, §11) + its positive-control and
   carve-out tests (§8.10–8.12).** The probe MUST be the final step, not the first. **Migration
   reality:** p14 is a regression-lock that asserts *zero* forbidden read-dispatches in the surface
   dirs — so it can only be added once steps 1–3 have ALREADY migrated all three reads onto
   `Domain.Agent.read_*`. Adding the probe before the reads are migrated would red-bar CI on the very
   sandbox dispatch (`:sandbox/:read`) this SPEC is removing. The gate does not *drive* the
   migration; it *seals* it. (The positive-control test §8.11 and carve-out tests §8.12 are
   independent of migration state and could land earlier, but ship them with the probe as one unit so
   the gate arrives proven.)

No back-compat shim: the per-site readers either become the owning slice facade (config/caps,
unchanged) or are deleted (sandbox dispatch). Per `feedback_let_it_crash_no_workarounds`, the old
dispatch path is removed, not kept alongside.

---

## 10. Open questions for the lead

- **OQ-1 — `default_holds_cap?` cold-caller fallback.** Should the dispatch-path `holds_cap?` gain
  the same `SnapshotStore.latest` fallback `read_entity_caps` has, so the *whole system* authorizes
  a cold caller from persisted caps (and the unified reader could delegate caller-authz to
  `holds_cap?` directly)? Deeper fix, changes dispatch semantics — out of this SPEC's scope but the
  natural next consolidation. (§3.2.)
- **OQ-2 — non-activating API-key list.** Is a non-activating read of the `:api_keys` slice wanted
  on the detail page? If so it's a *separate* design (data_owner/admin gate, `SensitiveSliceReadTest`
  allowlist entry). This SPEC deliberately excludes it. (§5.)
- **OQ-3 — home confirmation.** `Ezagent.Domain.Agent` (session app) is chosen by the DAG. Confirm
  the lead is happy putting the consolidated reader there rather than minting a new `Agent.View`
  module (D1). If a new module is preferred for naming, it still must live in `ezagent_domain_session`.
- **OQ-4 — fix the stale `runtime.ex` comment.** This SPEC asserts (per the #154 scope analysis)
  that `ctx.caps` is **permanent** and the "PR-CC-2c removes the ctx.caps branch" comment in
  `runtime.ex` `authz_check/4` is obsolete. Confirm the lead wants that comment corrected (Option A:
  keep `ctx.caps` permanent) as part of — or as a prerequisite to — this work, so a future
  contributor reading the chokepoint doesn't re-derive the wrong "holds_cap?-only" premise this
  reader was almost specced against. (Doc-only; outside the reader itself but in its blast radius.)
- **OQ-6 — consolidation sequencing vs. `fix/cc-folder-trust` (BLOCKING for implementation).** The
  config + caps non-activating reads (and their `Identity.read_entity_caps` / `caps_authorize?`
  owners) exist ONLY on `fix/cc-folder-trust`, not on `origin/main` (§0 ⚠ callout — verified). The
  "delegate to the landed owner" framing of §4/§9 steps 1–2 assumes that branch is merged FIRST (or
  the unified reader is built on top of it). If the lead wants the unified reader built against
  `main` as-is, §9 must be reordered: the reader's first job becomes *porting* the config+caps
  de-activation (not delegating to an owner that doesn't exist yet) — i.e. this SPEC then SUBSUMES
  `fix/cc-folder-trust`'s config+caps work rather than building on it. **Confirm the merge order**:
  (A) land `fix/cc-folder-trust` → then this reader delegates; or (B) this reader supersedes and
  ports all three reads itself. The SPEC is written for (A); (B) is a larger single PR.
- **OQ-5 — single `Identity.authorize_read/2` seam (optional).** The two-route authz (§3.2) is ~10
  lines that could fold into one `Identity` helper (`%{caller, caps}` + needed → boolean) so the
  unified reader makes one call and the two-route logic lives once, next to `caps_authorize?`, in
  `ezagent_domain_identity`. Minor; affects only the seam shape, not the semantics. Lead's call on
  whether to add the helper now or inline in `Domain.Agent`.
- **OQ-7 — surface-dir registry for the `no_surface_read_dispatch` gate (§11).** p14's scanned set
  (`ezagent_plugin_world/lib`, `ezagent_web/lib`, `apps/*/lib/mix/tasks/`) is a hand-listed allowlist
  of *where presentation lives*. When a NEW surface app is added (a second web app, a new console
  plugin, an admin LV app), its `lib/` must be added to p14 or the gate silently stops covering it.
  Confirm the lead is OK with this one-line maintenance obligation, or wants a stronger "any app
  tagged `:surface` in mix config is scanned" auto-discovery (heavier; deferred unless asked). Flagged
  per `feedback_flag_user_assist_steps` so it isn't a silent landmine.

---

## 11. The anti-recurrence arch-gate — `no_surface_read_dispatch` (lead-requested)

### 11.0 Why this section exists (the gap the gate closes)

§§1–9 PROVE the new reader is non-activating and CONSOLIDATE the three current per-site reads. They
do **not** FORBID a *future* surface from re-introducing an ad-hoc activate-on-read — e.g. someone
adds a new world/console/web LiveView next month and writes
`Invocation.dispatch(with_action(uri, :sandbox, :read), …)` straight from the presentation layer
because it's the first pattern they find, re-creating exactly the FP5/§0 activation bug this work
removed. Consolidation is a one-time cleanup; without a gate it decays. This section adds the
**regression-lock** that makes activate-on-read **structurally un-reintroducible** at the surface.

### 11.1 The gate, concretely

**Name:** `no_surface_read_dispatch`. **Form:** a new probe **p14** appended to the existing
`EzagentCore.Invariants.CapCheckOnlyAtChokepointTest.@probes` list
(`apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs`). It reuses that suite's
proven `%{id, desc, pattern, allowlist}` machinery and its source-tree scan (no runtime BEAM needed),
so it slots into `mix ezagent.check_invariants` with zero new infrastructure — exactly mirroring how
`no_flavor_refs_in_core` / p1–p13 already work.

**Forbidden dispatches (the THREE consolidated read pairs, and ONLY these):**

| dispatch pair (`with_action(uri, <behavior>, <action>)`) | the unified reader that replaces it |
|----------------------------------------------------------|-------------------------------------|
| `(:config_evolve, :read_cascade)` | `Ezagent.Domain.Agent.read_config/3` |
| `(:identity, :list_caps)`         | `Ezagent.Domain.Agent.read_caps/2`  |
| `(:sandbox, :read)`               | `Ezagent.Domain.Agent.read_sandbox/2` |

These are the dispatch **action atoms** verified at the chokepoint (config dispatches as the
`:config_evolve` behavior / `:read_cascade` action — `apps/ezagent_domain_agent/lib/ezagent/agent/config.ex`
docstring + `authorize_read_cascade` `action: :read_cascade`; caps as `:identity`/`:list_caps` —
`apps/ezagent_domain_identity/lib/ezagent/identity.ex:45`
`with_action(user_uri, :identity, :list_caps)`; sandbox as `:sandbox`/`:read` — the runtime gate
`cap(:agent, Sandbox, :read)`). The gate keys on the **dispatch atom**, not the cap behavior (config's
cap behavior is `Manage`, but it is *dispatched* as `:config_evolve` — match the dispatch).

> **Decision D5 — key on the exact (behavior, action) PAIRS, not a read-verb heuristic.** A broad
> `~r/list_|read_|get_/` regex is rejected: it would false-positive on (a) `(:identity,
> :list_api_keys)` — a READ the SPEC **deliberately keeps dispatchable** from the surface (sensitive,
> data_owner/admin-gated, excluded from the unified reader, §5) — and (b) `(:kanban, :get_tree)` /
> other legitimate surface reads. Keying on exactly the three pairs the unified reader consolidates
> makes **gate-scope == reader-scope**: the gate forbids precisely what the reader replaces, no more.

**Scanned dirs (the presentation/surface layer):**

```
apps/ezagent_plugin_world/lib/    # world detail page + actions (the #1028 sites)
apps/ezagent_web/lib/             # web controllers + LiveViews + socialware surfaces
apps/*/lib/mix/tasks/             # operator CLI / "console" (mix ezagent <verb>)
```

The operator-CLI tasks (`apps/*/lib/mix/tasks/`) are the "console" surface named in the brief. They
legitimately dispatch operator **WRITES** (`mix ezagent.* → Invocation.dispatch → authz`, the
sanctioned path per the skill) — so the gate forbids them ONLY the three READ pairs, never all
dispatch.

**Allowlist (deliberately minimal — defensive, not load-bearing):**

```elixir
allowlist: [
  # Domain.Agent IS the sanctioned reader. By construction (D2 — authorize-then-DELEGATE)
  # it never dispatches a read; it calls Agent.Config / Identity.read_entity_caps / the
  # sandbox-slice reader directly. So it would not match the pattern even unlisted. Listed
  # for clarity so a reviewer sees the one sanctioned home and isn't surprised if a future
  # delegation comment mentions an action atom.
  "apps/ezagent_domain_session/lib/ezagent/domain/agent.ex"
]
```

Note the scan is **already scoped to the surface dirs** (it does not walk all `apps/*/lib`), and
`Domain.Agent` lives in `ezagent_domain_session` — **outside** the scanned set — so the allowlist
entry is belt-and-suspenders, not the thing that makes the gate correct. Domain-internal dispatch of
`(:identity, :list_caps)` — e.g. `identity.ex:45`, a self-read INSIDE `ezagent_domain_identity` — is
likewise outside the scanned surface dirs and needs no allowlist entry.

**Pattern (one regex per forbidden pair, OR'd):**

```elixir
%{
  id: :p14,
  desc:
    "surface/presentation layer dispatching a CONSOLIDATED READ-class action to an agent " <>
      "(re-introducing activate-on-read). All agent config/caps/sandbox/status reads MUST go " <>
      "through Ezagent.Domain.Agent.read_* (non-activating). Forbidden pairs: " <>
      "(:config_evolve,:read_cascade) (:identity,:list_caps) (:sandbox,:read). WRITE/action " <>
      "dispatch is NOT forbidden (it legitimately activates); the live PTY-buffer read is a " <>
      "direct call, not a dispatch, and is NOT covered. See SPEC §11.",
  # Matches `with_action(<anything>, :<behavior>, :<action>)` for the three read pairs.
  # `with_action/3` is THE builder every surface dispatch uses to set the action atom, so
  # keying on it (rather than on `Invocation.dispatch`, whose target is built separately)
  # catches the read-action construction precisely.
  pattern:
    ~r/with_action\([^,]+,\s*:config_evolve,\s*:read_cascade\)|with_action\([^,]+,\s*:identity,\s*:list_caps\)|with_action\([^,]+,\s*:sandbox,\s*:read\)/,
  # surface-only scan — see surface_files/0 below; allowlist as above.
  allowlist: ["apps/ezagent_domain_session/lib/ezagent/domain/agent.ex"]
}
```

Because p14 needs a **narrower file set** than p1–p13's global `apps/*/lib/**/*.ex`, the scan
restricts its `all_files` to the surface dirs for this probe (a `surface_files?/1` guard, or a
per-probe `dirs:` field added to the probe map — the latter is the cleaner extension and is the
recommended shape). Either keeps p1–p13 global and scopes only p14.

**Exact failure message (mirrors the suite's existing format):**

```
no_surface_read_dispatch — a presentation/surface layer is dispatching a consolidated
READ-class action to an agent, which ACTIVATES a cold agent (FP5/#115). Agent
config/caps/sandbox/status reads MUST go through the non-activating
Ezagent.Domain.Agent.read_* interface, not Invocation.dispatch.

  [p14] <desc>
        @ apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex
        pattern: ~r/with_action\(..., :sandbox, :read\) | .../

Replace the dispatch with Ezagent.Domain.Agent.read_{config,caps,sandbox}/N
(authorize-then-delegate, non-activating). WRITE/action dispatch is fine; live PTY-buffer
reads are direct calls, not dispatches, and are unaffected.
See SPEC docs/together/2026-06-26/specs/unified-non-activating-agent-read.md §11.
```

### 11.2 Read-vs-write classification + the carve-outs (no false positives)

The gate distinguishes a **read-class** dispatch from a **write/action** dispatch by the *exact
(behavior, action) pair*, not by a verb heuristic. This is sound because:

- **Write/action dispatches are NOT forbidden** — they legitimately activate the target (you cannot
  send a message, join a session, delete an agent, write a PTY key, or revoke a credential grant
  without a live Kind). The surface keeps dispatching `(:session, :send)`, `(:session, :join)`,
  `(:manage, :delete)`, `(:pty, :write)`, `(:credential_grant, :revoke_credential_grant)`,
  `(:kanban, :sync_miro)`, `(:workspace, :add_template)`, `(:identity, :put_api_key)` etc.
  unchanged. None of these match p14's three-pair pattern.

- **Carve-out A — the live PTY buffer read is structurally outside the gate.** The terminal
  scrollback (`Ezagent.Domain.Pty.Server.snapshot_buffer/1`,
  `World.IdentityData.pty_initial_buffer/1`) is a **direct function call** to the running PTY server
  — it is NOT an `Invocation.dispatch`, has **no read-class action atom**, and goes through no
  `with_action(_, _, :read)`. So p14 (which matches only the `with_action` read-pair construction)
  **cannot** flag it. This is the right outcome: the PTY buffer is genuinely live (meaningless for a
  cold agent, §5), is deliberately NOT in the unified reader, and forcing it behind a
  "non-activating read" would be wrong. The gate carves it out *by construction* (it isn't a
  dispatch of a forbidden pair), and §8.12(a) asserts this explicitly so it can't regress into a
  false positive.

- **Carve-out B — `(:identity, :list_api_keys)` stays dispatchable.** This is a persisted-slice READ
  that the SPEC **intentionally excludes** from the unified reader (§5: sensitive +
  data_owner/admin-gated, not cap-gated). It must keep dispatching from the surface
  (`world_live.ex` / `identity_data.ex`). Because p14 keys on `:list_caps` (not `:list_*`), the
  `:list_api_keys` dispatch does **not** match. §8.12(b) asserts this non-match so a future
  tightening of the regex toward a verb heuristic would break the test and be caught.

> **Decision D6 — the gate's scope is exactly the cap-gated, durable, unified-reader-eligible reads
> (Decision D4's set).** A dispatch is forbidden at the surface iff it is one of the three pairs the
> unified reader provides a non-activating replacement for. Persisted-but-not-cap-gated
> (`:list_api_keys`) and live-only (PTY buffer) reads are out of the gate precisely because they are
> out of the reader (§5) — gate-scope tracks reader-scope, the same boundary, enforced once.

### 11.3 Why this fits the established gate machinery (not a bespoke mechanism)

- Same suite, same `@probes` shape, same scan-the-source-tree-without-the-BEAM approach as
  `cap_check_only_at_chokepoint` p1–p13 and `no_flavor_refs_in_core`. A contributor who has seen any
  existing probe reads p14 with zero new concepts.
- Runs inside the existing `mix ezagent.check_invariants` aggregate gate (already in §8.8 + CI), so
  no new CI wiring.
- The only extension to the suite is per-probe directory scoping (so p14 scans surfaces, not the
  whole umbrella) — a small, reusable addition that future surface-only probes can reuse.

### 11.4 Limitations (honest scope, do not overclaim)

- **Static source grep, not a type/dataflow gate.** p14 catches the canonical
  `with_action(uri, :sandbox, :read)` construction (the form every surface dispatch in the repo
  uses today, verified §11.1). A sufficiently obfuscated dispatch — building the action atom
  dynamically (`with_action(uri, beh, act)` with `act` computed at runtime), or constructing the
  `%Invocation{}` target by hand without `with_action` — would evade it, exactly as p3's
  `Capability.matches?` grep can be evaded by aliasing. This is the accepted ceiling of the grep-gate
  class repo-wide; the §8.11 positive control proves the gate catches the *real, idiomatic* pattern,
  which is what re-introduction actually looks like (someone copies an existing read dispatch). If a
  dynamic-atom evasion is ever observed, the contract (per the suite's own moduledoc) is to add a
  probe + amend this SPEC — the same regression-lock discipline as the existing p1–p13.
- **Surface-dir list is an allowlist of *where* presentation lives** — if a NEW surface app is added
  (a second web app, a new console plugin), its `lib/` dir must be added to p14's scanned set. This
  is a one-line maintenance obligation, flagged here so it isn't forgotten (OQ-7).
