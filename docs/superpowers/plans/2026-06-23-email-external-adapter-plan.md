# Email external-mirror adapter — Implementation Plan (#88)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make email a fully bidirectional session channel — outbound session messages mirror out as threaded emails (PR-1), and inbound emails (authenticated, deduped) inject into the bound session (PR-2). Modeled on `EzagentPluginFeishu.{FeishuAdapter, FeishuChatBinding}`, implementing the `Ezagent.ExternalMirror` domain contract.

**Architecture:** A new `:push` Adapter+Binding pair inside the existing `ezagent_plugin_email`, registered via the plugin's `adapters/0` + `behaviors/0`. Outbound: Session Publisher → per-binding Worker → `Email.Adapter.event_to_payload/1` (pure) → `Email.Binding.publish/2` → `Ezagent.Email.send/4` (Swoosh) with durable RFC-5322 threading headers. Inbound (PR-2): poll the Cloudflare Email Worker inbox → loop-guard → alias→binding→session resolution → SPF/DKIM/DMARC + From-match auth → deterministic-id dedup → inject under a restricted synthetic participant identity.

**Tech Stack:** Elixir/OTP umbrella, Phoenix 1.8, Ecto (PostgreSQL — the test suite is PG-only), Swoosh (`Swoosh.Adapters.Test` for unit tests), `:httpc` (CF Worker pull), Cloudflare Email Worker (JS).

**Spec:** `docs/superpowers/specs/2026-06-23-email-external-adapter-design.md` (rev2). Read it before any task.

## Global Constraints

- **`uv run` not `python`/`python3`** (global hook blocks raw python).
- **`pnpm` not `npm`**.
- **`mix precommit` is the merge gate** — read the `EXIT=` line; it is authoritative. PostgreSQL must be up (`docker-compose.pg.yml`).
- **Format only touched files** (`mix format path/to/file.ex`); do not absorb repo-wide formatter debt into a feature PR.
- **No back-compat shims, no degrade-to-allow, no default-to-permissive** (`feedback_let_it_crash_no_workarounds`). Transient transport failures → recoverable `{:error, reason, new_state}`; invariant violations → RAISE.
- **Do NOT touch** `apps/ezagent_domain_session/.../session_creator.ex`, `apps/ezagent_core/lib/ezagent/invocation.ex`, `conversation_actions.ex` — the lead owns a separate bug there.
- **Secrets never enter the repo.**
- **CapBAC:** capabilities are module references not atoms; caps flow through `Ezagent.Capability.normalize!/2`; the inbound restricted-participant cap (PR-2) is minted minimally, never copied from a human's cap set.
- **TDD:** every behavior/bugfix gets a failing test first.

## PR split & sequencing (Q5 — adopted, with the verification-gate decision baked in)

- **PR-1 = OUTBOUND-ONLY.** `:push` Adapter + Binding + cap marker + `behaviors/0`/`adapters/0` wiring + extended `Ezagent.Email.send/4` (threading headers) + durable `email_thread_state` + Swoosh-test unit coverage. **Makes NO bidirectional-complete claim.**
- **PR-2 = INBOUND.** Poll loop + alias addressing (`local_address` column + unique index) + bind-time verification handshake (mints `:verified`) + SPF/DKIM/DMARC + From-match auth + deterministic dedup + restricted-participant injection + the CF Worker §4.5a revision. **PR-2's branch depends on PR-1 having landed.**

### DECISION D1 — the verification gate (resolved from spec §11, NOT escalated)

The spec's §11 test partition splits the gate across the two PRs:

- **PR-1 ships the verification-status *concept* and the `publish/2` `:verified` refusal.** A binding whose status is not `:verified` returns `{:error, :not_verified, state}` (recoverable). PR-1 unit tests set the status field **directly** to exercise both branches (`:pending_verification` → refuse; `:verified` → send via `Swoosh.Adapters.Test`).
- **PR-2 ships the handshake that *mints* `:verified`** (token email + web endpoint + TTL + binding-status transitions).

**Consequence (state this in the PR-1 description):** PR-1 is **production-inert until PR-2** — no binding can reach `:verified` without the PR-2 handshake, so PR-1 outbound only fires in tests. This is the "no bidirectional claim" posture AND it closes the consent hole (we never email an unverified address in prod) **without a permissive default**. **DO NOT default status to `:verified`** — that is the rejected shim class (`feedback_let_it_crash_no_workarounds`).

### DECISION D2 — PR-1 data model is `email_thread_state` ONLY

`local_address` (alias) exists solely for **inbound** reverse lookup (spec §3/§6). PR-1's outbound path never reads it — the Binding owns `target_id` (= the bound human address) and the `From:` comes from `Ezagent.Email.send/4`'s existing `configured_from`/`@default_from`. Therefore:

- **PR-1's only migration = `email_thread_state`.** No `local_address` column in PR-1.
- **Verification status rides in the binding `opts_json` / slice for PR-1** (spec §6 sanctions "a status column and/or `opts_json`") — avoids a second migration in PR-1. PR-2 may add a dedicated status column + the `local_address` column + its unique index in one PR-2 migration.

---

# PR-1 — Outbound email external-mirror adapter

**Branch:** `email-external-adapter` (the current branch; rebased onto `origin/main`).

## File Structure (PR-1)

- **Create:** `apps/ezagent_plugin_email/lib/ezagent/email/behavior/email_allow.ex` — `EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow` cap-only marker Behavior (mirror of `Feishu.Allow`).
- **Create:** `apps/ezagent_plugin_email/lib/ezagent/email/adapter.ex` — `Ezagent.Email.Adapter` (`@behaviour Ezagent.ExternalMirror.Adapter`, `:push`).
- **Create:** `apps/ezagent_plugin_email/lib/ezagent/email/binding.ex` — `Ezagent.Email.Binding` (`@behaviour Ezagent.ExternalMirror.Binding`).
- **Create:** `apps/ezagent_plugin_email/lib/ezagent/email/thread_state.ex` — `Ezagent.Email.ThreadState` Ecto schema + load/upsert for durable threading.
- **Create:** `apps/ezagent_core/priv/repo/migrations/<ts>_email_thread_state.exs` — the `email_thread_state` table (migrations live in `ezagent_core`).
- **Modify:** `apps/ezagent_plugin_email/lib/ezagent/email.ex` — extend `send/4` with `:message_id`/`:in_reply_to`/`:references` opts.
- **Modify:** `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex` — add `behaviors/0` + `adapters/0` (NOT `children/0` — the poller is PR-2).
- **Test:** `apps/ezagent_plugin_email/test/adapter_test.exs`, `binding_test.exs`, `thread_state_test.exs`, `email_send_threading_test.exs`, `plugin_wiring_test.exs`.

**Naming note (module vs OTP-app prefix):** existing email modules use the `Ezagent.Email.*` namespace (e.g. `Ezagent.Email`, `Ezagent.Email.Config`) while the Behavior/cap marker follows the Feishu convention `EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow`. Keep the adapter/binding/thread-state under `Ezagent.Email.*` (matches the existing plugin namespace and the spec §4 names); keep the cap marker under `EzagentPluginEmail.Behavior.*` (matches Feishu's `EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow` so the `cap_subject/0` + `behaviors/0` registration shape is byte-parallel). Confirm `cap_subject.behavior_module` and the `behaviors/0` tuple reference the **same** module.

---

### Task 1: Extend `Ezagent.Email.send/4` with threading headers (HIGH 5 / §4.8)

**Files:**
- Modify: `apps/ezagent_plugin_email/lib/ezagent/email.ex`
- Test: `apps/ezagent_plugin_email/test/email_send_threading_test.exs`

**Interfaces:**
- Produces: `Ezagent.Email.send(to, subject, body, opts)` now honors `opts[:message_id]`, `opts[:in_reply_to]`, `opts[:references]` (all binary or absent). Absent → no header emitted (backward-compatible). Headers map onto `Swoosh.Email.header/3`.

> Context7 FIRST: `resolve-library-id "swoosh"` then `query-docs` topic "custom headers" / "header" to confirm `Swoosh.Email.header/3` arity + that `Swoosh.Adapters.Test` preserves custom headers in `assert_email_sent`.

- [ ] **Step 1: Write the failing test** — in `email_send_threading_test.exs`, set the Test adapter, call `Ezagent.Email.send("a@b.c", "S", "B", message_id: "<m1@ezagent.chat>", in_reply_to: "<m0@x>", references: "<m0@x>")`, assert via `Swoosh.Adapters.Test`/`assert_email_sent` that the delivered email carries those three headers. Add a second test asserting absent opts emit no threading headers.
- [ ] **Step 2: Run to verify it fails** — `mix test apps/ezagent_plugin_email/test/email_send_threading_test.exs` → FAIL (headers absent).
- [ ] **Step 3: Implement** — add a `maybe_threading_headers(email, opts)` private that pipes `Swoosh.Email.header/3` for each present opt; insert into the `send/4` build pipeline after `subject`. Keep the existing 4-arity signature; new opts are read from the existing `opts` keyword.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: `mix format apps/ezagent_plugin_email/lib/ezagent/email.ex apps/ezagent_plugin_email/test/email_send_threading_test.exs` then commit** (`feat(email): thread headers on send/4 (#88 PR-1)`).

---

### Task 2: `email_thread_state` table + `Ezagent.Email.ThreadState` (HIGH 5 / §4.3)

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/<ts>_email_thread_state.exs`
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/thread_state.ex`
- Test: `apps/ezagent_plugin_email/test/thread_state_test.exs`

**Interfaces:**
- Produces:
  - `Ezagent.Email.ThreadState.load(binding_row_id :: String.t()) :: %ThreadState{} | nil`
  - `Ezagent.Email.ThreadState.upsert(binding_row_id, %{root_message_id:, last_message_id:}) :: {:ok, %ThreadState{}} | {:error, term()}`
  - Schema fields: `binding_row_id` (PK, string — the `BindingRow.row_id/3` value), `root_message_id` (string, nullable), `last_message_id` (string, nullable), timestamps.
- Consumes: `BindingRow.row_id/3` shape (24-hex) from the external_mirror domain (no dependency edge — the value is passed in by the Binding).

> Migration MUST be PG-compatible (suite is PG-only). Follow the existing `20260607000000_pr_em_3_external_mirror_bindings.exs` migration style. `binding_row_id` is the natural PK (one thread per binding). Workspace scoping: per invariant #14, per-tenant tables carry `workspace_uri NOT NULL`. **Decision:** include a `workspace_uri` (string, NOT NULL) column derived by the Binding from the session at write time, to satisfy invariant #14 and the per-tenant gate. Confirm against `mix ezagent.check_invariants` whether a per-binding thread-state table is in-scope for the per-tenant gate; if the gate flags it, add the column (default plan: include it).

- [ ] **Step 1: Write failing test** — `thread_state_test.exs`: `load(unknown_id)` → `nil`; `upsert(id, %{root_message_id: "<r>", last_message_id: "<r>"})` then `load(id)` returns those values; a second `upsert` with a new `last_message_id` advances it (root unchanged). Use the PG sandbox (`Ecto.Adapters.SQL.Sandbox`) like other email tests.
- [ ] **Step 2: Run to verify it fails** (module/table absent).
- [ ] **Step 3a: Write the migration** — `create table(:email_thread_state, primary_key: false)` with `binding_row_id :string, primary_key: true`, `root_message_id :string`, `last_message_id :string`, `workspace_uri :string, null: false`, `timestamps()`. Run `mix ecto.migrate` against the test DB (NOT a live dev DB — `feedback_destructive_migration_anti_pattern`).
- [ ] **Step 3b: Write the schema + functions** — `use Ecto.Schema`; `load/1` via `EzagentCore.Repo.get`; `upsert/2` via `Repo.insert` with `on_conflict: {:replace, [...]}, conflict_target: :binding_row_id` (or a get-then-update). Keep it a pure data module (no GenServer).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: format touched files + commit** (`feat(email): durable email_thread_state store (#88 PR-1)`).

---

### Task 3: `EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow` cap marker (MED 7 / §9)

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/behavior/email_allow.ex`
- Test: covered by Task 6 wiring test (the marker has no standalone behavior beyond registration).

**Interfaces:**
- Produces: `EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow` — cap-only marker (`dispatchable?/0 == false`), action `:allow_email`, `data_owner/1 → :any`, `required_caps/0` keyed on `:session` axis. `actions/0` returns `[:allow_email]`.

> Mirror `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_allow.ex` EXACTLY, renaming `feishu`→`email`. Use `use Ezagent.Lifecycle, state_slice: :external_adapter_email` with the `# lifecycle:state_slice_override` marker comment (Phase C grep gate requires it for a non-derivable slice key). `create/1 → {:ok, %{}}`; raising `handle_allow_email/2`; custom `required_caps/0` on `:session` axis; `dispatchable?/0 == false`; `data_owner(_) → :any`.

- [ ] **Step 1: Write the marker module** (no separate failing test — its contract is "registers correctly", verified in Task 6).
- [ ] **Step 2: `mix compile` the email app** — Expected: compiles; the Lifecycle macro emits `state_slice/0`, `actions/0`, etc. Fix any `@before_compile` handler-required errors.
- [ ] **Step 3: format + commit** (`feat(email): allow_email cap marker behavior (#88 PR-1)`).

---

### Task 4: `Ezagent.Email.Adapter` (`@behaviour Ezagent.ExternalMirror.Adapter`, §4.1)

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/adapter.ex`
- Test: `apps/ezagent_plugin_email/test/adapter_test.exs`

**Interfaces:**
- Produces:
  - `adapter_id/0 → "email"`, `display_name/0`, `description/0`, `adapter_kind/0 → :push`.
  - `binding_module/0 → Ezagent.Email.Binding`.
  - `cap_subject/0 → %{behavior_module: EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow, description: ...}`.
  - `target_ownership_check/2 → :ok` (optionally a cheap RFC-5322 format sanity check on the address; on malformed → `{:error, :invalid_address}`). **Does NOT do human verification** (that is the PR-2 async handshake; this callback runs in a bounded ~5s Task and cannot block on a human).
  - `event_to_payload/1 → {:publish, %{subject, text, html, headers}}` | `:skip`. The `To:` is NOT in the payload (Binding owns `target_id`).
- Consumes: `Ezagent.Publisher.Event`, the two-container slice unwrap, `Ezagent.Message` shape (`:last_message`, `:last_message_id`, `:send_cursor`).

> Mirror `FeishuAdapter.event_to_payload/1`'s structure: `slice_state/1` unwrap (delegate to `Ezagent.Kind.normalize_slice_view/1` + string-`"state"` shim), `chat_send_occurred?/2`, `extract_last_message/1`, self-echo skip on `_email_origin` (atom + string key), and the diagnostic `Logger.warning` skip-reasons (no silent drops). Payload `subject` = pinned `[<session_name>]` form **with mandatory CR/LF + control-char sanitization** (Q4 — strip `\r`, `\n`, and other control chars from any session-derived text before it reaches a mail header). `text` = the `[<session> | <sender>] <body text>` prefix shape (parity with Feishu's prefix). `html` = nil for v1 (text-only). `headers` = `%{}` placeholder here — threading headers are owned + injected by the Binding from durable state, NOT computed in this pure function.

- [ ] **Step 1: Write failing tests** — `adapter_test.exs`:
  - `event_to_payload` on a `:session` event whose new_slice carries a fresh `:last_message` (non-`_email_origin`) → `{:publish, %{subject: s, text: t, ...}}` with `s` and `t` containing NO `\r`/`\n` even when the session name / body contain them (header-injection test — feed a body with `"x\r\nBcc: evil@x"` and assert the payload subject/text are sanitized).
  - `:skip` when `chat_send_occurred?` is false (same `last_message_id` + `send_cursor`).
  - `:skip` on `_email_origin: true` (atom AND string key).
  - `:skip` on `slice_key != :session`.
  - `cap_subject/0.behavior_module == EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow`; `binding_module/0 == Ezagent.Email.Binding`; `adapter_kind/0 == :push`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the adapter, porting the Feishu structure. Add a `sanitize_header/1` helper (`String.replace(text, ~r/[\x00-\x1f\x7f]/, " ")` or equivalent — confirm it strips CR/LF + control chars). Apply it to subject AND to any session-derived text that could reach a header. Body text in `text_body` is NOT a header so does not strictly need it, but sanitize the SUBJECT unconditionally.
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: format + commit** (`feat(email): ExternalMirror Adapter event_to_payload (#88 PR-1)`).

---

### Task 5: `Ezagent.Email.Binding` (`@behaviour Ezagent.ExternalMirror.Binding`, §4.2)

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/binding.ex`
- Test: `apps/ezagent_plugin_email/test/binding_test.exs`

**Interfaces:**
- Produces:
  - `adapter_module/0 → Ezagent.Email.Adapter` (Grill-5).
  - `init({target_id, adapter, opts})` → builds state: `%{target_id: <bound human address>, opts: opts, verification_status: <from opts_json, default :pending_verification>, binding_row_id: <derived/passed>, root_message_id: nil, last_message_id: nil, publish_count: 0, error_count: 0}` after loading durable thread state via `Ezagent.Email.ThreadState.load/1`. `target_id` must be a binary that passes a cheap RFC-5322 sanity check, else `{:error, {:invalid_target_id, other}}`.
  - `publish(payload, state)` → `{:ok, new_state}` | `{:error, reason, new_state}` (3-tuple recoverable shape, HIGH 3).
  - `terminate/2 → :ok`.
- Consumes: `Ezagent.Email.send/4` (Task 1), `Ezagent.Email.ThreadState` (Task 2), the adapter payload `%{subject, text, html, headers}` (Task 4).

> **How does the Binding learn `binding_row_id` and `verification_status`?** `init/1`'s `opts` carries binding-time metadata (`bound_by`, `bound_at`, plus caller-supplied opts). The Worker passes the Domain's binding options. For `binding_row_id`, derive it the same way the Domain does — but the Binding does NOT know `session_uri` from `target_id` alone. **Decision:** the Worker's `options` map includes the session URI (confirm by reading how `Ezagent.Entity.ExternalMirrorWorker` calls `Binding.init/1` and what it passes — see `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex` and `worker_spawn.ex`). If `session_uri` is present in options, compute `binding_row_id = BindingRow.row_id(session_uri, "email", target_id)`. If it is NOT plumbed, the cleanest fix is to read the `binding_row_id` from a field the Worker already holds (the worker slice carries the binding identity). RESOLVE THIS BY READING THE WORKER before writing `init/1` — do not guess. Whichever source, the row id MUST equal the one `email_thread_state` is keyed by.

> `verification_status` for PR-1 rides in `opts` (decoded from `opts_json` per D2). Default to `:pending_verification` when absent (the consent-safe default — NOT `:verified`).

> `publish/2` algorithm:
> 1. If `state.verification_status != :verified` → `{:error, :not_verified, state}` (recoverable; Worker logs + carries state).
> 2. Mint this message's `Message-ID` (e.g. `"<" <> rand_hex <> "@ezagent.chat>"`). Set `in_reply_to`/`references` from `state.last_message_id`/the chain. (For v1, `references` = the chain built from root + last; a simple `root_message_id` + `last_message_id` two-element chain is acceptable for v1 — note this in the moduledoc.)
> 3. Call `Ezagent.Email.send(state.target_id, payload.subject, payload.text, html: payload.html, message_id: <new_mid>, in_reply_to: state.last_message_id, references: <chain>)`.
> 4. On `{:ok, _}` → persist via `Ezagent.Email.ThreadState.upsert(state.binding_row_id, %{root_message_id: state.root_message_id || new_mid, last_message_id: new_mid})`; return `{:ok, %{state | root_message_id: ..., last_message_id: new_mid, publish_count: +1}}`.
> 5. On transient send failure (`{:error, :mail_not_configured}`, connection refused, timeout, relay reject) → `{:error, reason, %{state | error_count: +1}}` (recoverable).
> 6. **RAISE** only on invariant violation: the `ThreadState.upsert` itself failing (durable write must succeed once the mail was sent), or `target_id` structurally invalid at publish time. (Per spec §4.2: one chat send = one email, so there is NO partial-publish RAISE branch — unlike Feishu.)

- [ ] **Step 1: Write failing tests** — `binding_test.exs` (use `Swoosh.Adapters.Test`):
  - `publish` with `verification_status: :verified` sends one email (`assert_email_sent`) carrying subject/text + a `Message-ID` header + (on a 2nd publish) `In-Reply-To`/`References` from the prior message; returns `{:ok, new_state}` with advanced `last_message_id`.
  - `publish` with `verification_status: :pending_verification` → `{:error, :not_verified, state}`, NO email sent.
  - `publish` on a transient send failure (force `{:error, :mail_not_configured}` by configuring the SMTP adapter without config, or inject a failing send) → `{:error, reason, new_state}` (3-tuple), state carried.
  - `init` with a malformed `target_id` → `{:error, {:invalid_target_id, _}}`.
  - threading durability: after a `publish` advances `last_message_id`, a fresh `init/1` (simulated Worker restart) reloads it from `ThreadState` and the next `publish` sets `In-Reply-To` to the persisted value.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the binding per the algorithm above (after reading the Worker to resolve `binding_row_id` plumbing).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: format + commit** (`feat(email): ExternalMirror Binding publish + verified gate + durable threading (#88 PR-1)`).

---

### Task 6: Plugin wiring — `behaviors/0` + `adapters/0` (MED 7 / §4.7)

**Files:**
- Modify: `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex`
- Test: `apps/ezagent_plugin_email/test/plugin_wiring_test.exs`

**Interfaces:**
- Produces:
  - `behaviors/0 → [{Ezagent.Entity.Session, :allow_email, EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow}]` (iterate `Allow.actions()` like Feishu).
  - `adapters/0 → [{Ezagent.Email.Adapter, Ezagent.Email.Binding}]`.
  - **NO `children/0`** (the poller is PR-2; do not add it here).
- Consumes: the marker (Task 3), adapter+binding (Tasks 4-5).

> Mirror Feishu's `application.ex` `behaviors/0`/`adapters/0`. `Ezagent.Plugin.boot/1` runs Grill-5 on the `(Adapter, Binding)` pair and auto-registers the cap subject via `AdapterInstall.install/1`. The existing email `plugin_info/0` stays.

- [ ] **Step 1: Write failing tests** — `plugin_wiring_test.exs`:
  - `EzagentPluginEmail.Application.behaviors()` includes `{Ezagent.Entity.Session, :allow_email, ...Email.Allow}`.
  - `EzagentPluginEmail.Application.adapters()` == `[{Ezagent.Email.Adapter, Ezagent.Email.Binding}]`.
  - **The `AdapterCapSubjectRegisteredTest` invariant passes for the email adapter** — find that test (`grep -rn AdapterCapSubjectRegistered apps/`) and either assert it now covers email or add an email assertion mirroring the feishu one. Confirm Grill-5 passes for the pair (it runs at `Ezagent.Plugin.boot/1`; the existing `plugin_boot_test.exs` exercises boot — extend it).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** `behaviors/0` + `adapters/0` in the email Application.
- [ ] **Step 4: Run to verify it passes.** Also run the invariant suites: `mix ezagent.check_invariants` (+ `.lifecycle` if it exists) and the external-mirror Grill-5 / cap-subject tests; all green.
- [ ] **Step 5: format + commit** (`feat(email): register email adapter + allow_email behavior (#88 PR-1)`).

---

### Task 7: PR-1 gate + open PR (NO MERGE)

- [ ] **Step 1: `mix precommit`** with PostgreSQL up (`docker compose -f docker-compose.pg.yml up -d` first if needed). Read the `EXIT=` line. If non-zero, fix and re-run until `EXIT=0`. Do NOT proceed on a red gate.
- [ ] **Step 2: codex:review of the PR-1 diff** — dispatch `codex:codex-rescue` with the static-only constraints (cd to esr-ng, STATIC ANALYSIS ONLY, skip all mix). Fold valid findings (commit fixes; re-run precommit).
- [ ] **Step 3: `gh pr create`** — title references #88, body states PR-1 is OUTBOUND-ONLY, no bidirectional claim, production-inert-until-PR-2 (D1), data model = `email_thread_state` only (D2). **DO NOT MERGE.** Report back.

---

# PR-2 — Inbound email poller + addressing + verification + auth

**Branch:** `email-external-adapter-inbound`, off `origin/main` AFTER PR-1 has merged. **If PR-1 is not yet merged when you reach PR-2, STOP and report PR-2 is blocked-on-PR-1-merge.**

## File Structure (PR-2)

- **Modify:** `infra/cf-email-worker/src/worker.js` — capture `authResults` (`Authentication-Results`), `autoSubmitted` (`Auto-Submitted`), `precedence` (`Precedence`), `returnPath`/envelope-from (empty `<>` = bounce marker). One revision (§4.5a). Pull API shape unchanged.
- **Create:** `apps/ezagent_core/priv/repo/migrations/<ts>_email_inbound_addressing.exs` — add `local_address` (string) + UNIQUE index on `external_mirror_bindings`; optionally a `verification_status` column (or keep in `opts_json` — decide in PR-2). Per §6.1: a uniqueness constraint on `(session_uri, adapter_id="email")` (one email binding per session, v1).
- **Create:** alias generation + reverse-lookup helper (`Ezagent.Email.Alias` or extend `BindingRow`) — `alias → row → session_uri`.
- **Create:** `apps/ezagent_plugin_email/lib/ezagent/email/verification.ex` — bind-time token mint + the web-endpoint confirm path (token → `:verified`). Plus the web route (`EzagentWeb` controller/endpoint) for the verification LINK.
- **Create:** `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex` — the supervised poller GenServer (§4.5): loop/bounce guard → alias resolution → DMARC + From-match auth → deterministic-id dedup → inject under restricted participant → update threading → DELETE-after-inject.
- **Create:** restricted-participant identity minting (§4.6) — synthetic `entity://<ws>/user/email-<short-id>` + exactly one `session.send` cap scoped to that session.
- **Modify:** `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex` — add `children/0 → [Ezagent.Email.Inbound]` (skipped at test boot like Feishu's `WsClient`).
- **Modify:** alias generation into the bind path (write into the Session `:external_mirror` slice + project onto the row; regenerate-and-retry on unique collision).
- **Tests:** addressing (alias unique + regenerate + reverse lookup + no-match reject), verification (pending→token→verified, expired/invalid refused, no flow while pending), inbound auth (DMARC pass+From-match injected; DMARC fail / no-auth / From-mismatch / forged-From rejected), dedup (two polls → one message; delete only after inject), loop guard (Auto-Submitted / Precedence:bulk / empty envelope-from / no Message-ID rejected; rate cap pauses a flooding pair), live E2E (extend `scripts/e2e_init_protocol_api.sh` sibling).

> PR-2 detail tasks are deliberately summarized — PR-2 is gated on PR-1 landing, and the lead reviews PR-1 first. Expand PR-2 into bite-sized TDD tasks (same granularity as PR-1) at the time PR-2 is implemented, after PR-1 merges and the contracts are concrete. Key constraints to carry forward: (a) inject via `Ezagent.URI.with_action(session_uri, :session, :send)` + `Ezagent.Invocation.dispatch/1` mode `:call` (mirror `InboundDispatcher.dispatch_to_session/5`), stamping `body._email_origin = true`; (b) deterministic id = `truncated_hash(session_uri_string <> "/" <> normalized_message_id)` passed as `Ezagent.Message.new/3`'s `:id` opt so `MessageStore`'s `on_conflict: :nothing` dedups; (c) DO NOT touch `invocation.ex` / `conversation_actions.ex` / `session_creator.ex`; (d) the restricted participant cap is minted minimally, never copied from a human's cap set.

---

## Verification checklist (both PRs)

- [ ] `mix precommit` `EXIT=0` (PG up).
- [ ] `mix ezagent.check_invariants` (+ `.lifecycle`) green — Grill-5, cap-subject, per-tenant invariants. Email is a normal `:push` adapter with a real cap → no exemptions.
- [ ] `AdapterCapSubjectRegisteredTest` passes for `"email"`.
- [ ] No new test failures vs a clean `origin/main` baseline (`feedback_zero_new_failures_baseline_proof`).
- [ ] codex:review folded.
- [ ] No secrets in the diff.
- [ ] PRs opened, NOT merged.
