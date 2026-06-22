# Out-of-scope changes on the `agent-console` branch (task #84)

> **Purpose:** the user asked that any change **outside the Agent Console (#84) scope** be called out prominently in the PR description. This note tracks them so the PR can list them verbatim. These are doc/reference fixes surfaced *while* doing #84 (mostly stale-doc drift the review exposed) — they are NOT Console features.

| # | Change | Files | Why out-of-scope | Commit | Needs |
|---|--------|-------|------------------|--------|-------|
| 1 | **capbac.md §3 clarification** — dispatch authz is `ctx.caps` OR `holds_cap(caller)`; "empty caps fails closed" is chokepoint-specific, not the general path. | `.claude/skills/ezagent-developer/references/capbac.md` | Fixes a skill-reference drift (would mislead any future dev), not a Console feature. | `56902617` | — |
| 2 | **SKILL.md URI-shape correction** — per-tenant URIs are **workspace-first** `<scheme>://<workspace>/<type>/<name>`, not type-first. The skill documented it type-first; the code (`uri.ex` `per_tenant(scheme, workspace, type, name)`) is workspace-first. This stale skill line was the source of the demo's URI errors. | `.claude/skills/ezagent-developer/SKILL.md` | Skill drift correction (code wins, per the skill's own rule). | this batch | — |
| 3 | **uri-design.md §5.15 URI-shape correction** — same flip (the section was transcribed type-first; its own O(1)-extraction rationale assumes workspace-first). Corrected to match `uri.ex`. | `docs/notes/uri-design.md` | **Normative-ish spec note.** Corrected to match code + flagged inline for Allen to confirm. | earlier | **Allen confirm** |
| 4 | **design-principles.md P20 + architecture-invariants.md §11 URI-shape correction** — same type-first→workspace-first flip; P20 self-claims authority, so leaving it stale would re-contradict #2/#3. Now all four skill-side references agree with `uri.ex`. | `.claude/skills/ezagent-developer/references/{design-principles,architecture-invariants}.md` | Completes the URI correction so the skill is internally consistent (a half-correction is worse — it creates contradictions). | this batch | — |
| 5 | **capbac.md §1 + §6 self-consistency** — §1 role table still said "authorizer reads ctx.caps NOT caller" (contradicting the §3 fix); §6 still called `default_caps` a "broad cap" but the code returns `[]` (`user.ex:175`, per-session refactor landed). Both corrected. | `.claude/skills/ezagent-developer/references/capbac.md` | Same file was internally contradictory after the §3 fix; finishing it so it's a coherent reference. | this batch | — |

## Verification (uri.ex is authoritative)
```
apps/ezagent_core/lib/ezagent/uri.ex
  per_tenant(scheme, workspace, type, name) ->
    "#{scheme}://#{workspace}/#{type}/#{name}"      # workspace = segment 1
  entity(workspace, type, name) / session(workspace, template, name) / template(workspace, type, name)
  workspace_name!/1 reads segment 1 ; moduledoc §"Shape (SPEC v3 §3.6 — Amendment 2)"
```

## Note
No production `.ex` code was changed for these — they are documentation/reference corrections. The Console's own backend work (the Manage-gate, etc.) is in-scope and tracked separately in the proposal + demo spec.
