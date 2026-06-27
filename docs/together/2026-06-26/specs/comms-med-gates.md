# Comms MED Gates — SPEC + Plan (codex handoff)

> Lock the two MED debts from the comms-unify #1047 codex review behind
> anti-regression gates NOW; the concrete fixes come later. Scope = gates only.

## Context
`#1047` (merged, main) collapsed chat+external onto one `SessionFeedChannel` over the
ExternalMirror `:pull` substrate. Independent codex review = SOUND-WITH-FIXES, no blocker,
2 MED debts tracked here.

## Gate 1 — participation must be parameterized by `participation_profile/0`
**Debt:** `SessionFeedChannel` write handlers (`handle_in "post"/"join"/"history"`,
`apps/ezagent_web/.../session_feed_channel.ex`) branch on `adapter_id == "external_feed"`.
A future 3rd *participatory* adapter would be silently no-op'd (`{:reply, :ok}` swallow).
**Gate:** a behavioral test that registers a SYNTHETIC participatory adapter
(`participation_profile/0 => :participatory` + the callbacks) and asserts a `"post"` to it
is NOT silently dropped — it must route through the participation path, not the
external_feed-only branch. RED today against a non-external participatory adapter (the
adapter_id-keyed code swallows it); GREEN once the handlers dispatch on
`participation_profile/0`. This forces the next dev who adds a participatory adapter to
parameterize properly.
**Bite-proof:** the test is RED with the synthetic adapter on current code, GREEN when
either (a) the handler routes by profile, or (b) only the two current adapters exist.

## Gate 2 — web→external_mirror stays the sanctioned acyclic seam
**Debt:** `#1047` introduced a real new web→external_mirror runtime coupling via the
`apply/3` + module-value IoC seam (gate-legal per `undeclared_umbrella_dep_test`; the SPEC
§8 premise "web already deps external_mirror" was false).
**Step (assess first):** determine whether the EXISTING gates
(`undeclared_umbrella_dep_test`, the acyclic gate, layer-purity) already catch a regression
— i.e. someone adding a *direct compile-time* `external_mirror` alias in `ezagent_web`, or
introducing a cycle.
- If existing gates already catch it → **do NOT add a redundant gate**; document the
  coupling as a known, intentional IoC edge (a note + the arch baseline manifest if apt) so
  it's tracked, and report that existing coverage suffices.
- If there is a real GAP → add the minimal pin: assert web reaches external_mirror ONLY via
  the sanctioned seam and the edge stays acyclic. Bite-prove.

## Constraints
- Gates run under `mix ezagent.check_invariants`.
- ROOT-ANCHORED wildcards (`Path.expand("../../../..", __DIR__)`-style), NOT CWD-relative — a
  prior gate in this repo was vacuous from that bug.
- Bite-proven: plant the violation → gate RED → remove → green.
- `MIX_TEST_PARTITION=<unique>` for test runs (shared-DB isolation).
- Full `mix precommit` + `arch.scan` + `check_invariants` green; `PluginIsolation`/
  `PresenceReadReceipts` are genuine intermittent flakes — note, don't chase (the
  deterministic regressions are fixed on main as of #1054/#1055/#1056).
- Do NOT self-merge; the lead/Claude verify + merge.

## Acceptance
- Gate 1 present, root-anchored, bite-proven, under check_invariants.
- Gate 2: either the minimal pin (bite-proven) OR a documented existing-coverage assessment.
- Full gate suite green; PR opened against main, not self-merged.
</content>
