# Scenario 22: Routing rule CRUD + precedence

**Category**: 10 — Routing
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-26 (PR #418 + post-#120 consolidation)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- Admin logged in
- A session `session://system/sess_a` with members: admin + 2 echo agents
- System default rule active: `always() → ["$session_members"]` (PR #120, never deletable)

## Actors

- **Caller**: admin
- **Targets**: `routing_rules` table in `RoutingRegistry`
- **Behaviors**: `Ezagent.Behavior.Routing` (actions: `:add_rule`, `:remove_rule`, `:disable`, `:enable`, `:list_rules`)

## Steps

### Add per-session rule

1. Open `/admin/sessions/sess_a/routing`.
2. Click "Add rule"; choose Matcher AST:
   - Matcher type: `{:mention, "agent://system/echo_1"}`
   - Receptors: `["entity://agent/system/echo_1"]`
3. Submit; verify the rule appears + has `enabled = true`.
4. Verify `routing_rules` DB row with the Matcher serialized via `Ezagent.Routing.Matcher.to_json/1`.

### Test precedence

5. Send a non-mention message in `sess_a`: "hi all". Verify both echos receive (system default fans out).
6. Send a mention: `@echo_1 hi`. Verify ONLY echo_1 receives (custom rule + mention-gating combined).

### Disable + re-enable

7. Disable the per-session rule. Send `@echo_1 hi` again; verify mention-gated routing falls through to the default rule (echo_1 receives because mention-gated targets the mentioned agent regardless of custom rule).
8. Re-enable.

### Remove

9. Click "Remove rule"; verify the row is deleted.
10. Try to remove the system default `always → $session_members` rule; verify `:cannot_delete_system_default` (PR #120 — system default is admin-disable-only).

## Expected outcomes

- CRUD operations all dispatch via `Ezagent.Behavior.Routing`.
- `RoutingRegistry` ETS table (owner-pid-checked per Decision #95) updates synchronously.
- Matcher AST is JSON-serialized + deserialized correctly (5-leaf + 3-combinator grammar — PR #118).
- Precedence: custom rules + system default both apply additively; mention-gating sits on top.

## Failure modes to test

- Add rule with cycle (rule A targets B, B targets A via routing-emit): not currently detectable, but `RoutingResolver` is single-step so no infinite loop.
- Add rule with invalid receptor URI: `:invalid_receptor`.
- Add rule with reserved magic token `$session_members` as a receptor: allowed (this is the system-default pattern).
- Disable + restart phx: enable state survives via `kind_snapshots` (Decision #115).

## Cross-references

- Related PRs:
  - PR #95 — RoutingRegistry as 3rd Registry family (Decision #95)
  - PR #118 — Matcher combinators and/or/not (Decision #118)
  - PR #120 — Routing consolidation + system default + CI invariant gate (Decision #120)
  - PR #418 — unbind projection + session routing nav
- Related SPECs:
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  - (PR #120 docs in ARCHITECTURE Decision Log)
- Tests:
  - `apps/ezagent_core/test/integration/routing_consolidation_invariant_test.exs` — THE invariant gate
  - `apps/ezagent_core/test/integration/routing_boot_test.exs`
  - `apps/ezagent_core/test/integration/routing_cap_test.exs`
  - `apps/ezagent_core/test/integration/chat_routing_test.exs`
  - `apps/ezagent_domain_chat/test/.../default_rules_migration_test.exs`
- Evidence:
  - `docs/notes/phase-9-demo-2026-05-21.md` — routing screenshots

## Notes

- The `RoutingRegistry` is the 3rd Registry family alongside `KindRegistry` + `BehaviorRegistry`, but it carries owner-pid checks because admin writes at runtime (not boot-only).
- The "no rules + no members → no recipients" invariant test (`routing_consolidation_invariant_test.exs`) is the regression gate for any future hidden-fan-out reintroduction.
