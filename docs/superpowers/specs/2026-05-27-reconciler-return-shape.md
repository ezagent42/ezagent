# SPEC — Reconciler `:partial` vs `:ok` return shape drift (Bug 3)

**Status:** r1 — DRAFT pending codex adversarial review. 2026-05-27.

**Companion:** PR #422 batch repaired umbrella-wide stale assertions but
flagged 3 bugs needing SEPARATE SPECs. This is **Bug 3** of that set.

**Scope:** Narrow. One assertion in one integration test; SPEC mostly
re-affirms the existing ratified three-arm return shape and identifies
whether production has drifted.

---

## §1 Problem statement

### 1.1 The failing assertion

`apps/ezagent_domain_chat/test/integration/reconciler_test.exs:523` —

```elixir
test "ownership-pending retry exhaustion → :partial (NOT :error)" do
  # ... pre-spawns orch_uri as a "limbo" process with NO lineage and
  # NO workspace bound, so `check_orchestrator/3` returns
  # `{:ownership_pending, _}` indefinitely ...
  result = Session.spawn_from_template(st, owner)

  assert match?({:partial, _}, result), ...
end
```

PR #422's body characterizes this test as failing with `{:ok, ...}` being
returned where `{:partial, _}` is expected, and flags the question:

> "Either the SPEC changed (test should update) or the production
> handling regressed (return shape should restore `:partial` for the
> exhaustion case). Needs SPEC verification before flipping the
> assertion."

### 1.2 Why this matters (the broader contract)

`Ezagent.Entity.Session.spawn_from_template/2` is the **Generator-Reconciler**
defined in [`docs/superpowers/specs/2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md).
Its return shape is a **three-arm tagged tuple** ratified by SPEC §1.2 and
re-affirmed by §7-2 after codex adversarial review. Each arm carries
distinct, load-bearing semantics:

- `{:ok, %{...}}` — full convergence.
- `{:partial, %{...}}` — completable failure; caller MAY retry.
- `{:error, _}` — un-completable refusal up-front; NO Session was created.

Collapsing `:partial` into `:ok` would break the caller's ability to
distinguish "session is alive but the orchestrator is still pending"
from "session is fully ready" — a distinction the LiveView session
panel and the `EzagentDomainChat.create_session/3` facade BOTH branch
on today.

---

## §2 Decision: **A — `:partial` is canonical; restore/preserve it**

After investigating:

1. **The ratified SPEC** [`2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
   §1.2 + §7-2 explicitly chose the three-arm shape after considering
   the two-arm `:ok | :error` alternative, with this rationale (§7-2,
   lines 1167-1180):

   > **Recommendation: three-arm `:ok / :partial / :error`** as
   > specified. The cost is one extra return shape; the benefit is
   > preventing the entire class of "silently treat partial as
   > success" bugs.

2. **Production code at the failing site still returns `:partial`** via
   `retry_after_race/3` →
   `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:984-986`:

   ```elixir
   defp do_retry(%URI{} = uri, _owner_uri, _workspace_uri, 0) do
     {:partial, %{orchestrator_pending: uri}}
   end
   ```

   And `reconcile_loop/4` (line 362-369) propagates that to the
   `partial_report/1` builder at line 1921 → returns `{:partial,
   %{session_uri, orchestrator_uri, completed, pending, errors}}`.

3. **Multiple production callers branch on `:partial`** (see §3.3 below):
   - `EzagentDomainChat.create_session/3`'s `ensure_orchestrator_meta/3`
     facade — `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:350`
     maps `{:partial, _}` → `orchestrator_status: :pending`.
   - `Ezagent.Orchestrator.MCPServer.to_mcp_result/2` —
     `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_server.ex:548`
     renders `:partial` distinctly in MCP tool output.
   - `EzagentPluginLiveview.AdminDashboardLive.cc_seed_badge/1` —
     `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_dashboard_live.ex:233`.
   - `Ezagent.Orchestrator.Tools` (spawn / update_agent_template /
     remove flows) — uses its own three-arm protocol mirroring
     this contract.

4. **The test's `@moduledoc` block (lines 15-22) explicitly cites
   `:partial`** as one of the "3 residual codex fixes baked into PR-A":

   > 1. retry_after_race REAL implementation + tests
   >    (exhaustion → :partial; same-owner concurrent never returns
   >    :orchestrator_foreign).

   And the test docstring at line 528 explicitly states
   `retry_after_race must EXHAUST and return `{:partial, _}`, NOT
   `{:error, _}`` — this is intentional, ratified test text, not
   stale drift.

**Therefore:** the contract has NOT changed. `:partial` remains the
ratified shape. The test is correctly asserting the SPEC. If
production is in fact returning `{:ok, _}` in the test's scenario,
that is a **regression** to be located in implementation phase, NOT
a SPEC change.

### 2.1 Confidence in the verdict

**High** for the SPEC question (the SPEC is unambiguous; production
code structure still carries `:partial` paths; multiple production
callers branch on it).

**Medium** for the empirical claim "production returns `:ok`": this
SPEC was authored from static analysis only in the
`/private/tmp/esr-spec-bug3-reconciler` worktree (no `mix deps.get`
allowed per scope rules). The PR #422 author's claim that production
returns `{:ok, ...}` could not be reproduced from code reading — the
visible code path goes `check_orchestrator → :ownership_pending →
retry_after_race → :partial`. The implementation phase MUST:

1. Reproduce the failure in a worktree that has `mix deps.get` run.
2. Locate the actual `{:ok, _}`-returning path.
3. Apply the fix (a) at the regression site, OR (b) confirm that the
   test was failing for a DIFFERENT reason (e.g. a sibling assertion
   on lines 567-570 about the `:orchestrator` atom being present in
   `partial.pending` or `partial.errors`) and the "returns `{:ok, _}`"
   characterization in PR #422 was inaccurate.

§10 captures this as an OQ for Allen.

### 2.2 Why NOT decision B (remove `:partial`)

Decision B would mean: "production unified on `:ok`; test should
update; remove `:partial` from the SPEC."

This is the wrong direction because:

1. **Multiple production callers branch on `:partial` today.** Removing
   it requires touching 4+ call sites and changing user-visible UX
   (the LiveView "pending" badge would have to be computed from
   something else). High change cost, no benefit.

2. **The SPEC explicitly considered and REJECTED the two-arm
   alternative** (§7-2). Reversing that decision needs new evidence
   the original SPEC missed — there is none.

3. **`EzagentDomainChat.create_session/3`'s meta map** (the public-facing
   `:orchestrator_status` field) has three values: `:ready | :pending |
   :failed`. Removing `:partial` from the reconciler breaks the
   `:pending` source of truth — every `:partial` path in the
   reconciler is what feeds `:pending` in the facade.

### 2.3 Why NOT decision C (need more info)

Decision C would mean: "the SPEC is ambiguous; ask Allen."

This is the wrong direction because:

1. **The SPEC is unambiguous.** §1.2 + §7-2 + the @spec on
   `spawn_from_template/2` itself are all aligned.

2. **The bug-report's framing is asymmetric.** It said "test should
   update OR production should restore." Choosing "production should
   restore" answers the SPEC question without needing Allen's input —
   the SPEC ratifies that answer.

The only place §10 reserves for Allen is the residual question of
*where* the regression lives (see §2.1) — not whether `:partial`
should exist.

---

## §3 Semantics — what each return shape MEANS

This section copies + tightens the §1.2 contract from
[`2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
because the test docstring at line 528 directly invokes "`:partial` not
`:error`" — the load-bearing distinction is between `:partial` and
`:error`, not between `:partial` and `:ok`.

### 3.1 The three shapes (verbatim from the existing @spec)

```elixir
@spec spawn_from_template(URI.t(), URI.t()) ::
        {:ok,
         %{
           session_uri: URI.t(),
           orchestrator_uri: URI.t(),
           slots: [{String.t(), URI.t()}]
         }}
        | {:partial,
           %{
             session_uri: URI.t() | nil,
             orchestrator_uri: URI.t() | nil,
             completed: [atom()],
             pending: [atom()],
             errors: [{atom(), term()}]
           }}
        | {:error, term()}
```

### 3.2 When each fires (semantics)

- **`{:ok, %{session_uri, orchestrator_uri, slots}}`** — full
  convergence. All slots converged + orchestrator owned-by-us + routing
  rules installed + owner caps granted. **`orchestrator_uri` is
  populated AND owned.**

- **`{:partial, %{...}}`** — at least one step did not converge in
  THIS pass, but the failures are **completable** (a re-invocation
  with the same `(template, owner)` can converge them). The map's
  `pending` field enumerates the un-converged steps (`:orchestrator`,
  `:slot, "<name>"`, `:rule`, …); `errors` carries per-step diagnostics.
  Critical sub-cases:
  - `pending: [:orchestrator]` + `errors: [{:orchestrator,
    {:orchestrator_ownership_pending, candidate_uri, ev}}]` — the
    `retry_after_race/3` exhaustion path. `orchestrator_uri` is `nil`
    in the outer map (because we declined to claim the limbo URI), but
    the `errors` entry surfaces the candidate URI so the operator can
    inspect it.
  - `pending: [{:slot, "name"}]` — a slot's AgentTemplate Kind isn't
    alive yet (plugin not booted).

- **`{:error, reason}`** — refused up-front, NO Session was created.
  Reasons enumerated in `2026-05-23-generator-reconciler.md` §1.2:
  `:unauthorized`, `:cross_workspace_denied`,
  `:session_template_not_populated`,
  `:invalid_routing_matcher`, etc. Notably DOES include
  `{:orchestrator_foreign, uri, evidence}` — POSITIVE foreign evidence
  (lineage or workspace POSITIVELY mismatches), which is corruption /
  cross-tenant collision rather than a re-runnable race.

### 3.3 Caller pattern-matching today (production)

| Caller | Branches on `:partial`? | What it does |
|---|---|---|
| `EzagentDomainChat.create_session/3` via `ensure_orchestrator_meta/3` | YES | Maps `{:partial, %{orchestrator_pending: uri}}` to `%{orchestrator_uri: uri, orchestrator_status: :pending}` (line 350-355) |
| `Ezagent.Orchestrator.MCPServer.to_mcp_result/2` | YES | Renders `:partial` as a distinct MCP result variant (line 548) |
| `EzagentPluginLiveview.AdminDashboardLive.cc_seed_badge/1` | YES | Renders a "partial" badge (line 233) |
| `Ezagent.Orchestrator.Tools` | YES (own three-arm protocol) | Tools dispatch their own `:partial` shapes for spawn / update_agent_template / remove |
| Reconciler integration tests (`reconciler_test.exs`) | YES | Multiple assertions (line 523, 561-570, etc.) |

Net: **`:partial` is load-bearing.** Removing it would require
breaking-change work across 4+ production sites. The SPEC ratifies
keeping it.

---

## §4 Migration plan

### 4.1 Production code changes

**None at the SPEC level.** The SPEC re-affirms the existing contract.

**At the implementation level (next PR):**

1. Reproduce the test failure in a worktree with `mix deps.get` run.
2. Locate the path that returns `{:ok, _}` instead of `{:partial, _}`
   for the test scenario (or confirm the PR #422 characterization was
   inaccurate and the test fails for a different reason — see §2.1).
3. Apply the targeted fix. Likely candidates to inspect:
   - `check_orchestrator/3` at session.ex:1007 — confirm the
     `:ownership_pending` branch fires when lineage AND workspace are
     both `:absent` (NOT one absent + one match).
   - `retry_after_race/3` at session.ex:980 — confirm the 3-retry
     exhaustion actually returns the line-985 `{:partial, _}` and is
     not short-circuited by an early `{:owned, _}` due to test
     interleaving.
   - `reconcile_loop/4` at session.ex:330 — confirm the line-362
     `{:partial, %{orchestrator_pending: candidate_uri} = ev}` clause
     pattern-matches successfully and the line-363 `partial_report/1`
     is invoked.
   - The `spawn_orchestrator_via_template_content/5` path added in
     PR #408 — confirm this path is NOT mis-routed when the URI is
     already live (i.e. `check_orchestrator` should classify as
     `:ownership_pending`, NOT `:not_live`, when the limbo process is
     pre-spawned).

### 4.2 Test changes

**None.** The test at line 523 is correctly asserting the SPEC. If
implementation phase finds an unrelated bug (e.g. a flaky helper),
that fix lives in its own PR scope.

### 4.3 Caller changes

**None.** All callers already branch on `:partial` correctly.

### 4.4 Documentation

- Cross-link this SPEC from the
  [`2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
  "Status" header so future readers see the re-affirmation.
- Update `docs/futures/todo.md` with the implementation-PR placeholder
  and a back-link to this SPEC.

---

## §5 Invariant test (drift guard)

Per the project memo
`feedback_completion_requires_invariant_test`, every multi-PR change
needs an invariant test that catches the architectural goal failing,
not just the symptom.

**Invariant:** *The reconciler's return shape is the three-arm
`{:ok, _} | {:partial, _} | {:error, _}` tuple, with `:partial` reachable
from the `retry_after_race` exhaustion path.*

**Test (add to
`apps/ezagent_domain_chat/test/integration/reconciler_test.exs` or a
sibling `reconciler_shape_invariant_test.exs`):**

```elixir
describe "return-shape invariant (SPEC 2026-05-27-reconciler-return-shape)" do
  test "the @spec declares all three arms" do
    # Reflect on the @spec metadata at compile time. Asserts the
    # declared spec includes a :partial arm. Catches a future refactor
    # that silently removes :partial from the type union.
    specs = Code.Typespec.fetch_specs(Ezagent.Entity.Session)
    {:ok, [{{:spawn_from_template, 2}, spec_asts}]} = filter_for(specs, :spawn_from_template, 2)

    assert Enum.any?(spec_asts, fn ast -> contains_tag?(ast, :partial) end),
           "spawn_from_template/2's @spec must declare a {:partial, _} return; " <>
             "removing it would break callers in EzagentDomainChat, " <>
             "Orchestrator.MCPServer, and AdminDashboardLive."
  end

  test "retry_after_race exhaustion reaches :partial, not :ok" do
    # Direct unit-test on the helper if it's made public via @doc false,
    # or via the exhaustion-test pattern from reconciler_test.exs:523.
    # This test replaces the integration test as the FAST regression
    # guard — runs in <100ms.
  end
end
```

The reflection-based test is small, fast, and would catch any future
SPEC drift that omits `:partial` from the @spec. The exhaustion test
mirrors the integration test scenario without the SessionTemplate
setup overhead.

---

## §6 Plugin isolation analysis

**N/A.** `Ezagent.Entity.Session` is infra-layer chat-domain code, not
a plugin extension point. The reconciler is the Generator —
authoritative for cc-orchestrated sessions, NOT delegated to plugins.

The only plugin-isolation consideration: the cc Template Class
(`ezagent_plugin_cc`) provides the orchestrator role-bootstrap; its
`role_degraded` flag is surfaced through
`ensure_orchestrator_with_meta/3`'s 4-tuple variant
(`{:ok, uri, outcome, %{role_degraded: true, …}}`). This is ORTHOGONAL
to the `:partial` arm — degraded role-bootstrap is `:ok` with meta,
NOT `:partial`. The SPEC change does not affect plugin contracts.

---

## §7 Trade-offs / alternatives considered

### 7.1 Alternative: collapse `:partial` into `:ok` with a flag

Could `{:ok, %{...status: :partial}}` replace `{:partial, %{...}}`?

**Rejected.** A flag inside `:ok` would mean every caller has to
inspect the flag to know whether it's actually OK. The Elixir-idiomatic
way to surface a third outcome is a third tag, NOT a flag in the
two-arm result. The original SPEC §7-2 made exactly this argument:

> Pro [of three-arm]: the caller can pattern-match on the result;
> "did this fully converge?" is a 1-line case. Con [of two-arm]:
> every caller must inspect the result map AND remember to
> pattern-match on `:partial` or silently misinterpret a partial
> as success.

### 7.2 Alternative: collapse `:partial` into `:error`

Could `{:error, {:partial, _}}` replace the `:partial` tag?

**Rejected.** `:partial` is fundamentally NOT an error — the session
IS alive, slots ARE converged, the operator can retry. Tagging it as
`:error` would force every caller to disambiguate `:error,
:cross_workspace_denied` (un-completable) from `:error,
{:partial, ...}` (retry me). The whole point of three-arm is that
this disambiguation is structural.

### 7.3 Alternative: flip the test instead

The PR #422 framing offered this as an option. Rejected because:

1. The test is asserting the SPEC. Flipping the assertion would mean
   the SPEC silently changed without a SPEC-level decision.
2. The test docstring (line 524-528) is intentional, ratified text
   carried in from PR-A.

---

## §8 Interaction with concurrent SPECs

### 8.1 [2026-05-27-capability-action-axis](2026-05-27-capability-action-axis.md)

Lands in parallel. Touches `%Capability{}` shape but does NOT touch
`Session.spawn_from_template/2`'s return shape. Independent.

### 8.2 [2026-05-26-session-create-orchestrator-unified](2026-05-26-session-create-orchestrator-unified.md)

PR #408 landed this. It introduced `ensure_orchestrator_with_meta/3`'s
4-tuple variant (`{:ok, uri, outcome, %{role_degraded: ...}}`). The
new 4-tuple shape is orthogonal to `:partial` — they coexist:

- 3-tuple `{:ok, _, _}` — orchestrator ready (no degraded role).
- 4-tuple `{:ok, _, _, %{role_degraded: true, ...}}` — orchestrator
  alive but skill-copy failed (Invariant #9 surfaces).
- `{:partial, %{orchestrator_pending: _}}` — orchestrator URI not yet
  classified (lineage+workspace not yet recorded).
- `{:error, _}` — refused or POSITIVE foreign.

PR #408 PRESERVED the `:partial` arm intact. Confirmed by reading the
post-merge code at session.ex:843-845, 877, 985.

### 8.3 Bug 1 (Feishu binding policy) + Bug 2 (Wizard cap grant)

Both are independent of Bug 3. No cross-PR coupling.

---

## §9 Backwards compatibility

### 9.1 Persisted state

The reconciler's return shape is NOT persisted (it's the runtime
result of a function call). No JSON / SQLite / ETS schema depends on
the tag. **No migration needed.**

### 9.2 External callers

Search confirmed: NO ops scripts, NO CLI, NO web HTTP endpoint
pattern-matches `:partial` outside the Elixir codebase. The shape is
purely internal-Elixir.

The LV "Retry instantiation" button (per
`2026-05-23-generator-reconciler.md` §1.4) renders when the latest
result was `{:partial, _}` — that branch lives inside Elixir code,
no external surface.

### 9.3 Snapshots

No `%Capability{}`-style snapshot concern here. Reconciler outcomes
aren't snapshotted; they're recomputed on each `spawn_from_template/2`
invocation.

---

## §10 Open questions for Allen

### OQ-1 — Verify the PR #422 empirical claim

PR #422's body says the test fails because "production returns
`{:ok, ...}`". From static reading the production code path is
`check_orchestrator → :ownership_pending → retry_after_race → :partial`.

**Question:** Did you (or whoever ran the test) observe the actual
return value, or was "returns `:ok`" inferred from the failing-test
log? If the latter, the test might be failing on a different assertion
(e.g. line 567-570's `partial.pending` content check) and the
"returns `:ok`" framing was approximate.

**Why it matters:** This determines whether the implementation PR's
fix is at the `:partial`-vs-`:ok` decision site (the case the
batch-author saw) or at the `partial.pending`/`partial.errors`
content assembly (a narrower fix in `partial_report/1`).

### OQ-2 — Confirm decision A

This SPEC recommends Decision A (preserve `:partial`). High confidence
on the SPEC question; medium confidence on the empirical regression
location (§2.1).

**Ack/NACK?**

---

## §11 Codex adversarial review questions

The codex review should adversarially probe:

1. **Is the SPEC change actually necessary?** The existing SPEC
   already specifies `:partial`. This SPEC re-affirms without
   changing. Is there value in a separate SPEC vs. a single-paragraph
   note in `docs/notes/` cross-linking to the existing SPEC?

2. **Did the SPEC author miss a regression vector?** Static reading
   says production still returns `:partial`. The PR #422 author saw
   `:ok`. Where's the gap? Plausible regression vectors to probe:
   - The post-PR #408 path `spawn_orchestrator_via_template_content/5`
     might successfully spawn at the limbo URI (registering lineage +
     workspace) before retry_after_race even runs — i.e. the
     pre-spawned URI gets adopted in a way that bypasses
     check_orchestrator's ownership_pending classification.
   - A change in `Ezagent.SpawnRegistry.spawn_detailed/1`'s
     `:already_started` handling could let the pre-spawned URI
     register lineage/workspace as a side effect, making
     check_orchestrator return `:owned` on retry → `{:ok, _, _}` →
     full ok.
   - A test-helper change (e.g. `register_inert_flavor` now
     accidentally registering a Template Class that DOES record
     lineage on init) could change the test scenario's semantics.

3. **Is the invariant test (§5) the right kind?** Reflection on @spec
   ASTs is fragile (Elixir typespec parsing). Is there a stronger
   structural invariant — e.g. a property test that drives
   `spawn_from_template/2` through a series of states and asserts the
   return tag is always in `{:ok, :partial, :error}` ?

4. **Caller exhaustiveness.** Are there callers OUTSIDE the 4 sites
   listed in §3.3 that pattern-match on `:partial`? A future refactor
   adding callers won't be caught by this SPEC's analysis.

5. **Test isolation gap.** Why has the test been failing without
   anyone fixing it for the PR cycles between PR-A (350e9c3) and now?
   Is there a `@tag :skip` or `setup` gate elsewhere that's been
   masking it? If yes, fixing this SPEC + implementation needs to
   un-skip whatever was masking.

6. **`:partial` shape internal consistency.** The map carries
   `{session_uri, orchestrator_uri, completed, pending, errors}` —
   when `orchestrator_pending` is the ONLY pending step,
   `orchestrator_uri` is `nil` and the candidate URI lives in
   `errors`. Is there a more readable shape (e.g. always populate
   `orchestrator_uri` with the candidate even when pending)? The
   SPEC could clarify this but DOES NOT propose changing it (out of
   scope; tracked as future polish if needed).

---

## §12 Rollback plan

If the implementation PR finds that decision A was wrong (i.e. the
SPEC change should actually be B or C):

1. **Revert this SPEC** by replacing §2's verdict with the new
   direction, keeping the investigation record (§1-§3) intact.
2. **No production code rollback** — this SPEC mandates NO production
   change (§4.1). The implementation PR's fix (if any) is what would
   need rollback.
3. **The invariant test** (§5) is small enough to delete if direction
   changes.

Rollback cost: low (one SPEC + one optional test).

---

## Appendix A — Why this SPEC is short

Per `feedback_main_agent_for_single_tasks` and the user's preference
for ergonomic SPECs, this SPEC re-affirms an existing ratified
contract rather than introducing a new one. The substantive work was
in `2026-05-23-generator-reconciler.md`; this SPEC's role is to:

1. Decide whether PR #422 Bug 3's "needs SPEC verification" question
   is "preserve" or "change" — answer: preserve.
2. Provide a tight invariant test (§5) so future drift is caught
   structurally.
3. Document the implementation-phase steps to locate the actual
   regression (if any).

The length budget is intentionally bounded at ~450 lines.

---

## Appendix B — Cross-references

- [`docs/superpowers/specs/2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
  — original three-arm SPEC.
- [`docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`](2026-05-26-session-create-orchestrator-unified.md)
  — PR #408 unified session create; preserved `:partial` intact.
- PR #422 — umbrella test batch (4 commits) that flagged Bug 3.
- PR #408 (bd968a2) — unified session create; touches the
  orchestrator-ensure path but preserves return shape.
- PR-A #259 (350e9c3) — original Generator-Reconciler refactor;
  introduced `:partial`.
