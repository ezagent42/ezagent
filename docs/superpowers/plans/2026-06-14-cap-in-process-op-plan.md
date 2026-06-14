# Cap-checked in-process op primitive — Implementation Plan (#56)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development.
> Steps use checkbox (`- [ ]`). Load `Skill: esr-developer` + `Skill: elixir-phoenix-helper`
> (ezagent invariants) before any edit.

**Goal:** Replace the un-cap-checked `reads_siblings` in-process slice-read
mechanism with a cap-checked in-process read (`authorize_in_process/2` + a gated
`ctx.read_slice` accessor), then retire `reads_siblings`/`reads_sibling_slices`.

**Architecture:** Per spec `docs/superpowers/specs/2026-06-14-cap-in-process-op-design.md`
(codex-reviewed). The pure `Capability.matches?` decision is reused in-process
against the **Kind's own** caps (resolved from its in-memory `:identity` slice —
NOT `get_slice(self)`, which would re-introduce the deadlock; NOT the caller's
`ctx.caps`). Same closure (`cross_workspace?/2`) as cross-process step 5.5/5.6.

**Tech Stack:** Elixir umbrella; `ezagent_core` (Capability, Kind.Runtime);
6 consumer Behaviors across agent/external_mirror/identity/session domains.

**Sequencing:** 基座化 (PR-9c) is merged — UNBLOCKED. Authz-touching → keep each
step green; run `mix ezagent.check_invariants` + `arch.scan` per task.

---

## Scope correction (vs spec §3)

The spec said "3 consumers"; the actual count post-9c is **6** (`reads_siblings`):

| # | file | slice keys |
|---|------|-----------|
| 1 | `apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex:148` | `[:api_keys]` |
| 2 | `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:80` | `[:sandbox]` |
| 3 | `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:181` | `[:publisher]` |
| 4 | `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex:80` | `[:sandbox, :identity]` |
| 5 | `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:118` | `[:sandbox]` |
| 6 | `apps/ezagent_domain_session/lib/ezagent/behavior/socialware_publisher_read.ex:93` | `[:session]` |

---

### Task 1: `Ezagent.Capability.authorize_in_process/2`

**Files:** Modify `apps/ezagent_core/lib/ezagent/capability.ex`; Test
`apps/ezagent_core/test/ezagent/capability/authorize_in_process_test.exs`.

- [ ] **Step 1 — failing test:** caps holding `cap(:user, B, :read, uri, ws)`
  → `authorize_in_process(caps, %{kind: :user, behavior: B, action: :read, instance: uri, workspace_uri: ws}) == :ok`; empty caps → `{:error, :unauthorized}`;
  a `:any`-workspace admin cap + cross-ws target → `:ok` (closure). Run, watch fail.
- [ ] **Step 2 — implement:** `def authorize_in_process(caps, needed), do: if Enum.any?(caps, &matches?(&1, needed)), do: :ok, else: {:error, :unauthorized}`. Reuse `Match.matches?` (closure already lives in matcher/Scope). Run, watch pass.
- [ ] **Step 3 — commit.**

### Task 2: resolve a Kind's OWN caps in-process (whose-authority)

**Files:** Modify `apps/ezagent_core/lib/ezagent/kind/runtime/context.ex` (or
where ctx is built); Test in the accessor test (Task 3).

- [ ] **Step 1:** add a private helper that reads the Kind's caps from its
  **in-memory `:identity` slice** (already in the GenServer state passed to the
  handler) — NOT `Kind.get_slice(self_uri, :identity)` (deadlock). Return a
  `MapSet` of the Kind's effective caps.
- [ ] **Step 2:** unit test it returns the in-memory identity caps; commit.

### Task 3: `ctx.read_slice/1` cap-gated in-process accessor

**Files:** Modify `apps/ezagent_core/lib/ezagent/kind/runtime/context.ex` +
`runtime.ex` (build ctx); Test `apps/ezagent_core/test/ezagent/kind/in_process_read_test.exs`.

- [ ] **Step 1 — failing test:** a handler given `ctx.read_slice.(:sandbox)`
  returns `{:ok, slice}` when the Kind holds `cap(kind, owning_behavior_of(:sandbox), :read, self, ws)`, `{:error, :unauthorized}` when not. Watch fail.
- [ ] **Step 2 — implement:** `ctx.read_slice = fn key -> needed = %{kind: self_kind, behavior: BehaviorSet.owning_behavior_of(key), action: :read, instance: self_uri, workspace_uri: self_ws}; case authorize_in_process(own_caps, needed) do :ok -> {:ok, state.slices[key]}; err -> err end end`. Watch pass.
- [ ] **Step 3 — commit.**

### Task 4: mint self-read caps at create + boot reconcile

**Files:** the create-time cap minting for the 6 consumers' Kinds; boot
reconciler. Test: a freshly-created Kind holds its self-read cap(s).

- [ ] **Step 1 — failing test:** create an agent of each consumer type → assert
  it holds `cap(kind, owning_behavior, :read, self, ws)` for each key it reads.
- [ ] **Step 2 — implement:** add the self-read cap(s) to each Kind's create-time
  cap set (keyed by the slice keys in the Scope-correction table). Boot reconciler
  grants them to already-existing Kinds of those types.
- [ ] **Step 3 — commit.**

### Tasks 5-10: migrate each consumer (one task each, TDD)

For EACH of the 6 (table above):
- [ ] **Step 1:** test the consumer's handler still produces its effect with the
  granted cap (and is denied without it).
- [ ] **Step 2:** replace `reads_siblings([...])` + the surfaced-slice access with
  `ctx.read_slice.(key)`; ensure its create-time cap (Task 4) covers the keys.
- [ ] **Step 3:** run that domain's suite; commit per consumer.

### Task 11: delete the `reads_siblings` mechanism

**Files:** `behavior.ex` (macro/callback), `lifecycle.ex` (macro),
`behavior/introspection.ex` (union), `kind.ex` + `kind/behavior_set.ex` +
`kind/runtime.ex` + `kind/runtime/context.ex` (surfacing), any
`get_slice(self)`-avoidance.

- [ ] **Step 1:** grep proves zero `reads_siblings(`/`reads_sibling_slices` call
  sites remain (after Tasks 5-10). 
- [ ] **Step 2:** remove the macro, callback, introspection union, runtime
  surfacing, and avoidance code. Compile.
- [ ] **Step 3:** run full umbrella suite; commit.

### Task 12: completion invariant tests (spec §5)

**Files:** `apps/ezagent_core/test/ezagent/kind/in_process_read_invariant_test.exs`.

- [ ] deny (no cap), allow (cap), **revoke → deny again** (live-checked),
  **whose-authority** (Kind's own caps decide; caller `ctx.caps` irrelevant),
  **closure parity** (admin/system-member self-read passes via `cross_workspace?`).
- [ ] commit.

### Task 13: gates

- [ ] `mix compile --force` then `mix ezagent.arch.scan` + `check_invariants` +
  `check_invariants.lifecycle` + `doc.scan` + full `mix test` all green
  (update any baseline counters the mechanism-deletion shifts). Commit.

---

## Self-review

- Spec coverage: §2.1 (Task 1) / §2.2-2.3 (Task 3) / §2.4 (Task 4) / §2.5
  whose-authority+closure (Tasks 2,3,12) / §3 migration (Tasks 5-11) / §5 tests
  (Task 12). All covered.
- The "3 consumers" in the spec is corrected to 6 here — fold this correction
  back into the spec before merge.
- Codex adversarial-review the final diff before merge (`feedback_codex_review_every_pr`).
