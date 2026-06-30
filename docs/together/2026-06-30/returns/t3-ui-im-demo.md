# Return: T3 UI IM-like Demo

> **Task:** T3-ui-im-demo
> **Branch:** `docs/world-ui-redesign-prototype-0630`
> **PR:** https://github.com/ezagent42/ezagent/pull/1104
> **Dev:** zyli
> **returned_at:** 2026-06-30 12:47 +0800
> **deadline:** 2026-06-30 17:00 +0800
> **deadline_status:** on_time

## Summary

Produced a demo-first World UI redesign artifact for team confirmation before any
broad production refactor. The work stays documentation-only and records the
intended IM-like direction: Chat as the default surface, Agents as participant
management, and Manage as shared workspace/plugin/admin/system operations.

## Artifacts

- `docs/together/2026-06-30/world-ui-redesign-prototype.html`
- `docs/together/2026-06-30/world-ui-redesign-analysis.md`

## DoD reconciliation

| # | DoD line | status | proof / open decision |
| --- | --- | --- | --- |
| 1 | Demo/screenshots show the revised IM-like layout and interaction direction. | met | The static interactive prototype shows the revised Chat / Agents / Manage IA and IM-like Chat layout in `world-ui-redesign-prototype.html`. |
| 2 | Gap list compares current UI vs target IM behavior. | met | `world-ui-redesign-analysis.md` now includes `Current UI vs Target IM Gap Matrix`. |
| 3 | Proposed production changes are listed as follow-up slices. | met | `world-ui-redesign-analysis.md` now includes `Production Follow-up Slices` P0-P9. |
| 4 | No broad production UI refactor lands before team confirms the demo. | met | PR #1104 changes only documentation artifacts under `docs/together/2026-06-30/`; no production React/Phoenix UI files are part of this PR. |

## Gate Status

Latest `origin/main` observed at return time:
`d8ffd6c09d016fc52e71eb6aa5bba5c363d7fe6b`.

Current PR CI status at return time:

- `precommit + check_invariants`: failing
  https://github.com/ezagent42/ezagent/actions/runs/28420552590/job/84212621875
- `Return file advisory`: passing
- `Only repo owner may edit dev-together skill`: passing

Local verification performed for the docs/prototype:

- prototype control/panel reachability check passed earlier:
  `controls: 33`, `panels: 33`, `missing: []`, `unreachable: []`
- HTML tag stack check passed earlier: `depth: 0`, `errors: []`
- `git diff --cached --check` passed for this return update
- latest local `mix precommit` rerun at 13:04 +0800 compiled through the umbrella
  apps, printed stale BEAM artifact `corrupt file header` warnings for Python/PTY
  modules, and then failed because local PostgreSQL at `127.0.0.1:55432` refused
  connections while creating the test DB

This return is therefore complete for the design-demo DoD, but it is not a green
machine-gate return.

## World Conflict Avoidance

- Linked/used the World coordination guide.
- Owned surfaces: documentation artifacts only.
- New surface vs existing edit: no production surface edit.
- `styles.css` plan: no `styles.css` edits.
- Branch/PR: PR #1104 remains the docs-only demo PR.
- Shared additive files: none outside `docs/together/2026-06-30/`.

## Deferred Follow-ups / Open Decisions

- Lead/team needs to confirm or reject the IM-like IA direction before P1-P9
  production slices begin.
- The handoff branch name was `demo/ui-im-alignment-0630`; the actual PR branch
  is `docs/world-ui-redesign-prototype-0630`. Lead should decide whether this
  docs-only PR is sufficient for T3 or should be renamed/rebranched.
- KB plugin route decision remains open: implement `/plugins/kb`, hide the link,
  or change the plugin's declared config surface.

## Method Friction

The original handoff asked for demo/screenshots, gap list, and follow-up slices,
but it did not name the required return artifact. That made the initial PR look
complete as a prototype while still missing the dev-together DoD reconciliation.
For future demo-first UI handoffs, include the return file requirement in the
handoff itself and require the gap matrix / follow-up slices as explicit headings.

## Merge Request

Review PR #1104 as a demo/design artifact only. Do not treat it as production UI
implementation. If the direction is accepted, schedule P1-P9 as separate
production slices.
