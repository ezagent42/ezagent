# PR-6 — Domain-owned desired skills/caps + `update_member_template` / regenerate

> domain.agent work, PR-6. Branch `feat/pr6-desired-skills` off main (incl #544).

## Problem

The orchestrator can ADD a managed member (`add_managed_member`) and REMOVE one
(`remove_member`), but it cannot CHANGE a member's blueprint after the fact. The
slot-era `update_agent_template` (generation/respawn/repoint) was retired in §3.8
with the member-level replacement explicitly **deferred** (tools.ex moduledoc
"SEAM / FOLLOW-UP"). PR-6 implements that follow-up.

Two coupled gaps:

1. **No DOMAIN-owned declaration of what skills/caps a member should have.** The
   AgentTemplate `:template` content has a `default_caps` field, but:
   - it is **never consumed** — `Agent.spawn_from_template_content/4` grants the
     template's `default_caps` to NOTHING. (Verified: no call site reads
     `content.default_caps` to grant the spawned agent identity caps.)
   - "skills" are entirely flavor/plugin-private — the cc Template Class copies
     the `ezagent-session-orchestrator` skill into the config_dir, gated on the
     `"role"` field. There is no DOMAIN-tier, flavor-agnostic way to say "this
     member should have skills X, Y and caps A, B."

2. **No member-template swap.** Once a member is joined with
   `source_template_uri = T1`, there is no way to repoint it at `T2` and
   re-materialize.

## Design

### A. Domain-owned `desired_skills` / `desired_caps` on the AgentTemplate content

Two NEW universal (flavor-agnostic) fields on the AgentTemplate `:template`
content, owned by the DOMAIN (not the plugin):

| Field | Type | Meaning |
|---|---|---|
| `desired_skills` | `[String.t()]` | skill names the DOMAIN declares a member built from this template should have, materialized into the agent's config_dir at instantiate |
| `desired_caps`   | `[Ezagent.Capability.t()]` | caps the DOMAIN declares the spawned member identity should hold, granted at instantiate |

**Why domain-owned, not plugin-owned (North-Star: plugin isolation):** a plugin
author should NOT have to know about caps or the skill catalog. The DOMAIN
declares desired skills/caps once; each flavor's Template Class only knows how to
*place a skill into its own config layout*. We keep the existing universal-base /
flavor-extra split (SPEC 2026-06-01): `desired_skills`/`desired_caps` join
`flavor`/`working_directory`/`default_caps`/… in the UNIVERSAL base. They are
threaded into the Template-Class data map by `to_template_data/2` so the flavor's
`instantiate/3` can place skills; the cap grant happens in the DOMAIN spawn path,
flavor-blind.

`default_caps` vs `desired_caps`: `default_caps` is the template's STRUCTURAL cap
*policy* (the Identity behavior's baseline — what the template Kind itself grants
on fork). `desired_caps` is what the DOMAIN wants the *spawned member instance*
to hold. They are distinct axes; PR-6 introduces `desired_caps` and does NOT
touch `default_caps` semantics. (Flagged ambiguity #1 below — see "reconcile".)

PR-6 scope decision: this PR lands the FIELDS + their flow through
`to_template_data/2` + a structural `regenerate` action that recomputes a
member's content from its (possibly swapped) template. The actual *granting* of
`desired_caps` into a live agent identity and the *live skill re-copy* is the
re-materialization seam that **overlaps PR-5's `reconfigure` Manage hook** — see
"Overlap" below. PR-6 makes the data domain-owned and the swap mechanical;
PR-5's `reconfigure` does the live re-apply. PR-6's `regenerate` therefore
produces the NEW content + repoints the member facet + (where the agent is
re-spawnable) drives instantiate; it does NOT duplicate a live in-place
reconfigure of a running PTY.

### B. `update_member_template` orchestrator tool

```
update_member_template(role_name, new_source_agent_template_uri, opts)
  :: {:ok, %{member_uri, regenerated: bool}} | {:error, reason}
```

1. Resolve `role_name` → current member URI from the session `:members` slice.
2. Authority: reuse cap #1 `{:within_session, S}` (the same authority
   `add_managed_member` / `remove_member` use — §3.8 "reuse existing authz"; NO
   new cap shape, manage-cap still deferred to #533).
3. Repoint the member's `source_template_uri` facet to
   `new_source_agent_template_uri` (a faceted `chat.set_member_facets` /
   re-`chat.join` with merged facets — uses the existing member-facet path).
4. Regenerate: read the NEW template content, re-derive the member's runtime
   config (the cc/codex/curl data map via `to_template_data/2` with the new
   content) and re-materialize.

### C. Regenerate semantics — destroy-and-recreate (let-it-crash, structural)

`regenerate` for a member = **terminate the old worker + spawn a fresh worker
from the NEW template content at the SAME member role**, then re-join. This is
the structural option (no live-reconfigure shim; consistent with
`feedback_let_it_crash_no_workarounds`): a swapped template can change flavor,
cwd, config_dir, skills — a live in-place mutation of all of those on a running
PTY is exactly the fragile path the let-it-crash principle rejects. The member's
`role_name` is the stable binding (survives respawn — §3.1), so routing rules
keyed on role_name re-resolve to the new worker URI automatically.

This reuses the EXISTING `add_managed_member` spawn+join path and the
`remove_member` terminate+prune-or-repoint path — `update_member_template` is
their composition with a facet repoint in the middle, NOT new spawn machinery.

## Flagged design ambiguities (for maintainer 拍板)

1. **`desired_caps` reconciliation with already-granted caps.** On regenerate to
   a template with FEWER `desired_caps`, do we REVOKE the dropped caps from the
   member, or only ADD the new ones (monotonic)? PR-6 implements **additive
   (grant desired, never revoke)** — revocation of caps mid-life is a separate
   authority question (manage-cap, #533). Flagged; structural revoke can land
   with manage-cap.

2. **Regenerate = spawn-new-then-retire-old vs live-reconfigure.** PR-6 chose
   spawn-new-worker-first, repoint routes, join, then retire-the-old (structural,
   atomic-safe ordering). This **overlaps PR-5's `reconfigure` Manage hook**,
   which does live in-place re-materialization. Two consequences the maintainer
   should weigh:
   - **SAME-URI swaps are rejected** (`:same_member_uri_use_reconfigure`). A
     re-point to a template that hashes to the SAME member URI (an in-place edit
     of the same template) cannot spawn-first (URI collision); that case is
     PR-5's `reconfigure` territory by construction. PR-6 fails loud rather than
     a fragile destroy-then-respawn-same-URI.
   - **The rare `terminate-old-succeeds-then-join-new-fails` edge** leaves the
     role momentarily empty (rollback best-effort re-joins the now-terminated
     old member). This residual non-atomicity is the exact gap PR-5's
     `reconfigure` (live re-apply, no destroy) closes; once PR-5 lands,
     `update_member_template` should call `reconfigure` instead of
     terminate+respawn. PR-6 keeps the member-template-swap + desired-skills/caps
     DATA model independent of the re-apply mechanism, so this is a clean
     follow-up swap.
   - Authority (cap #2 `{:spawned_by, orchestrator}`) is enforced PRE-COMMIT
     (an unauthorized old-worker terminate rolls back); only the old worker's
     CLEANUP outcome is best-effort post-authority.

3. **Skill catalog / placement.** PR-6 threads `desired_skills` (a name list)
   into the Template-Class data map. Each flavor's `instantiate/3` is responsible
   for resolving a skill NAME → on-disk source and copying it (cc already has the
   `resolve_orchestrator_skill_source` walk for one hard-coded skill). A generic
   name→source skill registry is OUT of PR-6 scope (flagged); PR-6 lands the
   domain DECLARATION + the data-flow seam, and cc's existing role-based copy is
   the reference placement.

## Concurrency / merge notes

- **PR-2** (separate worktree) is splitting `working_directory` →
  `project_cwd`/`config_dir` in `agent_template.ex`. PR-6 changes there are
  **purely additive** (two new universal fields + their inclusion in the
  to_template_data base) and localized to the universal-base assembly — minimal
  conflict surface. PR-6 does NOT restructure the struct.
- **PR-5** (#533) builds a `reconfigure` Manage hook — see ambiguity #2.

## Tests (TDD)

- `agent_template_test.exs`: `to_template_data/2` threads `desired_skills` +
  `desired_caps` into the universal base; absent → omitted.
- `tools_test.exs` / new `update_member_template_test.exs`: swapping a member's
  template repoints the `source_template_uri` facet; unauthorized caller →
  `{:error, :unauthorized}`; unknown role → `{:error, {:unknown_member_role, _}}`.
