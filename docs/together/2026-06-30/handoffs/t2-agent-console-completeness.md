# Handoff: T2 Agent Console completeness

> **Date:** 2026-06-30 · **From:** allen · **To:** fatnine
> **Tracking:** `T2-agent-console-completeness` · **Base:** `origin/main`
> **Status:** confirmed — validate, list, and fix clear missing pieces.

## Mission

Verify whether Agent Console is complete enough for current internal use. First
list the missing pieces, then directly fix the clear/small ones. Return design
questions separately instead of hiding them in broad implementation work.

## Required reading

1. #1027 Agent Console QA report.
2. `docs/together/2026-06-26/agent-console-qa-findings.md`
3. Phoenix/LiveView rules in `AGENTS.md`
4. Skill `ezagent-developer`

## Definition of Done

- [ ] Missing Agent Console items are listed with severity and owner surface.
- [ ] Small/clear gaps are fixed with tests or clear manual proof.
- [ ] Nontrivial gaps are returned as design-decision items with recommendation.
- [ ] CapBAC/session authority changes are not made without confirmation.

## Discuss-first

Stop before changing CapBAC, session membership, cross-workspace authority, or
Agent Console scope beyond current internal completeness.

## Merge model

Use branch `fix/agent-console-completeness-0630`; return PR/evidence to lead.
