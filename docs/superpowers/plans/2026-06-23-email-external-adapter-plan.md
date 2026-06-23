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

### DECISION D1 — the verification gate (resolved; forgery-safe, NOT escalated)

The spec's §11 test partition splits the gate across the two PRs, and the second codex review surfaced a real trust bug we resolve here:

- **PR-1 ships the verification-status *concept* and the `publish/2` `:verified` refusal.** A binding whose status is not `:verified` returns `{:error, :not_verified, state}` (recoverable).
- **PR-2 ships the handshake that *mints* `:verified`** (token email + web endpoint + TTL + a **server-owned status column**).

**FORGERY FIX (codex BLOCKER 1 — resolved in-plugin, no escalation):** the per-binding Worker forwards **caller-controlled** `opts` straight into `Binding.init/1` (`external_mirror_worker.ex` `create/1` stores `opts: Map.get(args, :opts, %{})`; `activate/2` calls `binding_module.init({state.target_id, adapter_module, state.opts})`). Therefore PR-1 **MUST NOT read `verification_status` from `opts`** — a bind-capable caller could set `verification_status: :verified` and bypass the gate. Instead:

- **`Binding.init/1` HARD-CODES `verification_status: :pending_verification`** in PR-1. It never reads the field from `opts`. PR-1 stores **no** verification state anywhere (no opts_json field, no column).
- Unit tests exercise the `:verified` branch of `publish/2` by **constructing the binding state map directly** (not via `init/1`/`opts`).

**Consequence (state in the PR-1 description):** PR-1 is **production-inert until PR-2** — nothing in PR-1 can mint `:verified`, so PR-1 outbound only fires in tests. This is the "no bidirectional claim" posture, closes the consent hole (we never email an unverified address in prod), and is forgery-safe (caller opts cannot flip the gate). **DO NOT default status to `:verified`** (rejected shim class, `feedback_let_it_crash_no_workarounds`). PR-2 adds a **server-owned** status column updated ONLY by the token-confirm flow, never from caller opts.

### DECISION D2 — PR-1 data model is `email_thread_state` ONLY; thread key from server-truth

`local_address` (alias) exists solely for **inbound** reverse lookup (spec §3/§6). PR-1's outbound path never reads it — the Binding owns `target_id` (= the bound human address) and the `From:` comes from `Ezagent.Email.send/4`'s existing `configured_from`/`@default_from`. Confirmed by codex review: no current outbound path reads the alias. Therefore PR-1's only migration = `email_thread_state` (no `local_address` in PR-1; PR-2 adds it).

**THREAD-KEY FIX (codex BLOCKER 2 — resolved in-plugin via server-stamped `msg.session_uri`):** the Binding keys durable threading by `BindingRow.row_id(session_uri, "email", target_id)`, but `Binding.init/1` only receives `{target_id, adapter, opts}` — `session_uri` is NOT in that tuple, and reading it from caller `opts` would reintroduce the forgery class. The clean path:

- `event_to_payload/1` already holds the `%Ezagent.Message{}` (we port `extract_last_message/1`). `msg.session_uri` is **server-stamped** in `MessageStore.write/2` (`apps/ezagent_core/lib/ezagent/message_store.ex:77` `Map.put(:session_uri, session_uri)`) — **not caller-controllable**. Feishu already reads exactly this field (`feishu_adapter.ex:520` `source_session_label`).
- The Adapter includes it in the payload: `{:publish, %{subject, text, html, session_uri: msg.session_uri}}`. This is **context, not the recipient** — it does NOT violate the spec's "`To:` not in payload" rule (the Binding still owns `target_id` = the recipient).
- The Binding computes `binding_row_id = BindingRow.row_id(session_uri, "email", state.target_id)` **at publish time**, then loads/upserts `email_thread_state` by it.
- **Stringification parity:** `do_bind` keys the row via `URI.to_string(session_uri)` (`external_mirror.ex:892` → `BindingRow.row_id/3`). The Binding MUST normalize the payload's `session_uri` identically (parse to `%URI{}` if it arrives as a string, then `BindingRow.row_id/3`) so the computed key EQUALS the actual binding-row id and the `email_thread_state` FK (Task 2) matches.

> **Future platform note (NOT a blocker, for the lead):** a cleaner long-term design would have the Domain pass server-owned binding context (session_uri, adapter_id, row_id) to `Binding.init/1` rather than each plugin re-deriving it from the message. That is a shared `ExternalMirror.Binding` contract change touching Feishu + protocol_api, out of scope for #88. Email resolves it in-plugin above. Mention to the lead as a future enhancement, not a question.

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
  - `Ezagent.Email.ThreadState.upsert(binding_row_id, %{root_message_id:, last_message_id:, references_chain:, workspace_uri:}) :: {:ok, %ThreadState{}} | {:error, term()}`
  - Schema fields: `binding_row_id` (PK, string — the `BindingRow.row_id/3` value), `root_message_id` (string, nullable), `last_message_id` (string, nullable), `references_chain` (string, nullable — the full space-joined `References` header value, RFC-5322), `workspace_uri` (string, NOT NULL), timestamps.
- Consumes: `BindingRow.row_id/3` shape (24-hex) from the external_mirror domain (no dependency edge — the value is passed in by the Binding).

> Migration MUST be PG-compatible (suite is PG-only). Follow the existing `20260607000000_pr_em_3_external_mirror_bindings.exs` migration style. `binding_row_id` is the natural PK (one thread per binding).

> **codex finding 7 (full References chain):** the spec (§8 / §4.8 + test §496-498) requires the `References` chain to GROW across messages (full RFC-5322 chain), NOT a two-element root+last shortcut. Store `references_chain` (the full header value) and append each new `Message-ID` to it on every outbound send. (`In-Reply-To` = the immediate parent = `last_message_id`; `References` = the full chain.)

> **codex finding 6 (per-tenant invariant #14):** per-tenant tables carry `workspace_uri NOT NULL`. Include the column AND **register the schema** in `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs` `@per_tenant_schemas` (currently lists `external_mirror_bindings` at line 58 but NOT this new table) by adding `{Ezagent.Email.ThreadState, "email_thread_state"}`. Without this the invariant test fails once the migration lands. Add a module-load guard if the email plugin app isn't loaded in the core-only test context.

> **codex finding 3 (orphan/rebind — DECISION D3, rebind = NEW thread):** an `unbind` deletes only the `external_mirror_bindings` row; the email `terminate/2` is `:ok` (no cleanup). To avoid (a) a rebind silently continuing the OLD thread and (b) orphan thread rows: add a foreign key `email_thread_state.binding_row_id REFERENCES external_mirror_bindings(id) ON DELETE CASCADE`. Same repo, both tables in `ezagent_core`'s Repo, so the FK is feasible. **Semantics: rebind = new thread** (the row id is a function of `(session, adapter, target)`, so a same-target rebind reuses the id; the CASCADE on unbind clears the prior thread so the rebind starts fresh). Test BOTH: same-target unbind→rebind starts a fresh chain, and unbind removes the thread row (no orphan).

- [ ] **Step 1: Write failing test** — `thread_state_test.exs`: `load(unknown_id)` → `nil`; `upsert(id, %{root_message_id: "<r>", last_message_id: "<r>", references_chain: "<r>", workspace_uri: ws})` then `load(id)` returns those values; a second `upsert` advancing `last_message_id` + appending to `references_chain` keeps root unchanged and grows the chain; deleting the parent `external_mirror_bindings` row CASCADE-deletes the thread row. Use the PG sandbox (`Ecto.Adapters.SQL.Sandbox`).
- [ ] **Step 2: Run to verify it fails** (module/table absent).
- [ ] **Step 3a: Write the migration** — `create table(:email_thread_state, primary_key: false)` with `binding_row_id :string, primary_key: true`, `root_message_id :string`, `last_message_id :string`, `references_chain :text`, `workspace_uri :string, null: false`, `timestamps()`; add the FK to `external_mirror_bindings(id)` with `on_delete: :delete_all` (Ecto `references/2`). Run `mix ecto.migrate` against the TEST DB (NOT a live dev DB — `feedback_destructive_migration_anti_pattern`).
- [ ] **Step 3b: Write the schema + functions** — `use Ecto.Schema`; `load/1` via `EzagentCore.Repo.get`; `upsert/2` via `Repo.insert` with `on_conflict: {:replace, [:root_message_id, :last_message_id, :references_chain, :updated_at]}, conflict_target: :binding_row_id`. Pure data module (no GenServer).
- [ ] **Step 3c: Register the invariant** — add `{Ezagent.Email.ThreadState, "email_thread_state"}` to `@per_tenant_schemas`.
- [ ] **Step 4: Run to verify it passes** (incl. `mix test apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`).
- [ ] **Step 5: format touched files + commit** (`feat(email): durable email_thread_state store w/ full References chain (#88 PR-1)`).

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
  - `event_to_payload/1 → {:publish, %{subject, text, html, session_uri}}` | `:skip`. The `To:` is NOT in the payload (Binding owns `target_id`). `session_uri` IS in the payload — it is **context** (read server-stamped off `msg.session_uri`), used by the Binding to compute the durable thread key (D2); it is NOT the recipient.
- Consumes: `Ezagent.Publisher.Event`, the two-container slice unwrap, `Ezagent.Message` shape (`:last_message`, `:last_message_id`, `:send_cursor`, `:session_uri`).

> Mirror `FeishuAdapter.event_to_payload/1`'s structure: `slice_state/1` unwrap (delegate to `Ezagent.Kind.normalize_slice_view/1` + string-`"state"` shim), `chat_send_occurred?/2`, `extract_last_message/1`, self-echo skip on `_email_origin` (atom + string key), and the diagnostic `Logger.warning` skip-reasons (no silent drops). Read `session_uri` off the message the same way Feishu's `source_session_label/1` does (`%Ezagent.Message{session_uri: %URI{} = u}` → keep the `%URI{}`; binary → keep the binary; the Binding normalizes). Payload `subject` = pinned `[<session_name>]` form. `text` = the `[<session> | <sender>] <body text>` prefix shape (parity with Feishu). `html` = nil for v1 (text-only).

> **codex finding 5 (sanitize ALL header-valued fields, not just subject):** Swoosh's SMTP adapter maps `subject`, custom headers (`Message-ID`/`In-Reply-To`/`References`), `to`, and `from` directly into MIME headers; `Swoosh.Email.header/3` stores raw binaries. Body text/html are MIME body parts (not a header-injection path) but every header field must be sanitized. Add a central `sanitize_header_value!/1` (strip/replace `\r`, `\n`, and other control chars `[\x00-\x1f\x7f]`). Apply it to the payload `subject` here (the only session-derived header field at the Adapter), and the Binding applies it to `message_id`/`in_reply_to`/`references`/`from`/`to`-derived-from-`target_id` (most are server-minted, but apply uniformly — defence in depth). Tests assert CR/LF + control chars are stripped from EVERY header field.

- [ ] **Step 1: Write failing tests** — `adapter_test.exs`:
  - `event_to_payload` on a `:session` event whose new_slice carries a fresh `:last_message` (non-`_email_origin`, with `msg.session_uri` set) → `{:publish, %{subject: s, text: t, session_uri: su}}` where `su` matches `msg.session_uri` and `s` (subject) contains NO `\r`/`\n` even when the session name contains them (header-injection test — feed a session name / subject-source with `"x\r\nBcc: evil@x"` and assert the payload subject is sanitized).
  - `:skip` when `chat_send_occurred?` is false (same `last_message_id` + `send_cursor`).
  - `:skip` on `_email_origin: true` (atom AND string key).
  - `:skip` on `slice_key != :session`.
  - `cap_subject/0.behavior_module == EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow`; `binding_module/0 == Ezagent.Email.Binding`; `adapter_kind/0 == :push`.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the adapter, porting the Feishu structure. Add a `sanitize_header_value!/1` helper (`String.replace(text, ~r/[\x00-\x1f\x7f]/, " ")` — confirm it strips CR/LF + control chars). Apply it to the SUBJECT unconditionally. Include `session_uri: msg.session_uri` in the payload (read off the message, server-stamped). Body text in `text_body` is NOT a header so isn't a header-injection vector, but the subject MUST be sanitized.
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
  - `init({target_id, adapter, opts})` → builds state: `%{target_id: <bound human address>, opts: opts, verification_status: :pending_verification, publish_count: 0, error_count: 0}`. **`verification_status` is HARD-CODED `:pending_verification`** (D1 — NEVER read from `opts`; caller opts are untrusted). `target_id` must be a binary that passes a cheap RFC-5322 sanity check, else `{:error, {:invalid_target_id, other}}`. `init/1` does NOT load thread state (it doesn't know `session_uri`); thread state is loaded per-publish (below).
  - `publish(payload, state)` → `{:ok, new_state}` | `{:error, reason, new_state}` (3-tuple recoverable shape, HIGH 3).
  - `terminate/2 → :ok` (the FK CASCADE in Task 2 cleans the thread row on unbind — D3).
- Consumes: `Ezagent.Email.send/4` (Task 1), `Ezagent.Email.ThreadState` (Task 2), the adapter payload `%{subject, text, html, session_uri}` (Task 4), `Ezagent.ExternalMirror.BindingRow.row_id/3`.

> **`binding_row_id` (D2 — server-truth, computed at publish):** the Worker's `init/1` does NOT carry `session_uri` (confirmed: `external_mirror_worker.ex` `activate/2` calls `binding_module.init({state.target_id, adapter_module, state.opts})` — no session). Reading it from caller `opts` would be forgeable. Instead the Adapter put server-stamped `msg.session_uri` in the payload (D2). `publish/2` reads `payload.session_uri`, normalizes to `%URI{}` (parse if binary — identical to `do_bind`'s `URI.to_string` keying so the id matches), and computes `binding_row_id = BindingRow.row_id(session_uri, "email", state.target_id)`. This is the SAME id `email_thread_state` is keyed by AND the FK parent (`external_mirror_bindings.id`) — so the row exists by the time publish runs (bind persisted it).

> `publish/2` algorithm:
> 1. If `state.verification_status != :verified` → `{:error, :not_verified, state}` (recoverable; Worker logs + carries state).
> 2. Normalize `payload.session_uri` → `%URI{}`; compute `binding_row_id = BindingRow.row_id(session_uri, "email", state.target_id)`. Load durable thread state: `ts = ThreadState.load(binding_row_id) || %{root_message_id: nil, last_message_id: nil, references_chain: nil}`.
> 3. Mint this message's `Message-ID` (`"<" <> rand_hex <> "@ezagent.chat>"`). `in_reply_to = ts.last_message_id` (immediate parent); `references = <ts.references_chain or ts.root_message_id> <> " " <> new_mid` (full chain, growing — codex finding 7). Sanitize all header values (`sanitize_header_value!/1`).
> 4. Call `Ezagent.Email.send(state.target_id, payload.subject, payload.text, html: payload.html, message_id: new_mid, in_reply_to: ts.last_message_id, references: <chain>)`.
> 5. On `{:ok, _}` → `ThreadState.upsert(binding_row_id, %{root_message_id: ts.root_message_id || new_mid, last_message_id: new_mid, references_chain: <grown chain>, workspace_uri: <derive from session_uri via Ezagent.Capability.workspace_of/1 or Ezagent.Persistence.workspace_uri_for!/1>})`; return `{:ok, %{state | publish_count: +1}}` (thread state is durable, not in worker state).
> 6. On transient send failure (`{:error, :mail_not_configured}`, connection refused, timeout, relay reject) → `{:error, reason, %{state | error_count: +1}}` (recoverable).
> 7. **RAISE** only on invariant violation: the `ThreadState.upsert` itself failing (durable write must succeed once the mail was sent), `payload.session_uri` missing/unparseable, or `target_id` structurally invalid at publish time. (Per spec §4.2: one chat send = one email, so there is NO partial-publish RAISE branch — unlike Feishu.)

- [ ] **Step 1: Write failing tests** — `binding_test.exs` (use `Swoosh.Adapters.Test`, PG sandbox for ThreadState; pre-insert the parent `external_mirror_bindings` row so the FK holds, or insert via the bind path):
  - `publish` with state `verification_status: :verified` + a payload carrying `session_uri` sends one email (`assert_email_sent`) carrying subject/text + a `Message-ID` header; a 2nd publish carries `In-Reply-To` = the prior `Message-ID` and a `References` chain that GREW (contains both ids); returns `{:ok, new_state}`.
  - `publish` with `verification_status: :pending_verification` → `{:error, :not_verified, state}`, NO email sent.
  - `init/1` does NOT set `:verified` even if `opts` contains `verification_status: :verified` (forgery test — assert the state's status is `:pending_verification`).
  - `publish` on a transient send failure (configure SMTP adapter without config → `{:error, :mail_not_configured}`) → `{:error, reason, new_state}` (3-tuple), state carried, NO crash.
  - `init` with a malformed `target_id` → `{:error, {:invalid_target_id, _}}`.
  - threading durability: after a `publish` persists `last_message_id`, a fresh `publish` (no in-worker carry — simulates restart) reloads it from `ThreadState` by the same `binding_row_id` and sets `In-Reply-To` to the persisted value; `References` keeps growing.
  - header-injection: subject/message_id/in_reply_to/references contain no `\r`/`\n` even with hostile input.
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** the binding per the algorithm above.
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

## PR-2 — EXPANDED (implementation, 2026-06-23)

> Branch (actual): `email-inbound-pr2`, off `origin/main` (PR-1 = b2fd803b merged). Migrations live in **`priv/repo_pg/migrations/`** (the PG-only suite; `priv/repo/migrations` is dead). PR-1's `email_thread_state` set this precedent.

### KEY DESIGN DECISION D4 — email metadata lives in an email-OWNED side-table, NOT generic columns (spec §6 deviation, spirit-preserved, lower-risk)

Spec §6 says `local_address` + `verification_status` go as columns on the **generic** `external_mirror_bindings` projection row. Investigation of the actual code (now on main) shows that row is written by the **generic** `Ezagent.Behavior.ExternalMirror.do_bind/3` → `insert_binding_row/1`, a fixed-column path shared by Feishu + protocol_api + email, with **no adapter-callback seam**. Adding email-specific columns + alias-generation logic there is a generic-domain contract change touching the other two adapters — against the North Star (keep plugin concerns out of core).

**Resolution (zero core change):** a new email-owned table `email_inbound_binding` keyed by `binding_row_id` (the `BindingRow.row_id/3` value), FK CASCADE to `external_mirror_bindings(id)` — the SAME proven pattern PR-1's `email_thread_state` uses. It holds, per binding:
- `local_address` (string, **UNIQUE** — the inbound reverse-lookup authority, spec §3/§6)
- `session_uri` (string) + `target_id` (string) — so inbound is a single-table lookup `local_address → (session_uri, target_id, status)`
- `verification_status` (`"pending_verification" | "verified"`, default pending — server-owned, flipped ONLY by the web confirm path; never from caller opts)
- `verification_token_hash` (binary) + `verification_expires_at` (utc_datetime_usec) — binding-scoped one-time token (MagicLinkToken keys by email, not binding → reused its hash/TTL/single-use *shape* but not the table, since a human may bind the same address to multiple sessions and the confirm must be binding-scoped)
- `workspace_uri` (string, NOT NULL — invariant #14)
- UNIQUE index on `session_uri` (§6.1 — one email binding per session, v1)

**Gate moves to a durable read.** PR-1's `Binding.init/1` keeps `verification_status: :pending_verification` as the forgery-safe in-memory default (unchanged), but `Binding.publish/2`'s gate now reads the **durable** status by `binding_row_id` at publish time (so the web confirm — which can't reach a possibly-cold Worker — is authoritative, spec §4.4 "readable without a live Worker"). The inbound poller reads the same durable status. Init's in-memory value is no longer the gate; it's a safe default for a not-yet-recorded binding (→ not verified → refuse, fail-closed).

**Alias generation = email-specific bind WRAPPER, not the generic body.** `Ezagent.Email.bind_session/N` calls the generic `Ezagent.ExternalMirror.bind/4`, then on `{:ok, _}` mints the alias + writes the `email_inbound_binding` row + sends the verification mail. Regenerate-and-retry on the `local_address` unique collision. Fail-closed: a binding with no email-meta row reads as not-verified.

### KEY DESIGN DECISION D5 — inbound injection cap is an EPHEMERAL ctx-authorizer (not a grant, not a Catalog principal)

Per `capbac.md` §3: a dispatch authorizes when `ctx.caps` contains a cap matching the needed shape (path 1, `granted_via_ctx_caps?`) — `granted_by` is NOT consulted on this path; the cap is never persisted. So inbound injection mirrors `Agent.Receive.sync_result_effect/3` (capbac §7 "self-authority carried inline at the dispatch"):
- Synthetic principal URI: `entity://<ws>/user/email-<short-id>` (a real `%URI{scheme: "entity"}`, #154-compliant), constructed via `Ezagent.URI`.
- Mint EXACTLY one cap: `Capability.cap(:session, <BehaviorRegistry.lookup(Session, :send)>, :send, session_instance, workspace)` with `granted_by: <synthetic principal URI>` (genuine self-authority) + fresh `granted_at`. Pin `kind/behavior` (least-privilege; behavior fixed for Session :send, unlike the agent-flavor `:any` case).
- Put it in `ctx.caps`, dispatch `mode: :call`. **NOT** routed through `Ezagent.Identity.Grant` (that chokepoint is for persisted grant/revoke; grep-gated to `:grant_cap`/`:revoke_cap`), **NOT** a new `system://` Catalog principal (those are persisted standing authority; this is per-dispatch). So no `no_unowned` / `no_admin_caps_fallback` gate is touched.
- TDD asserts a REAL `Invocation.dispatch` under this principal authorizes the send AND is denied for a different session — an honest auth test, not struct-equality.

### Tasks (TDD, red→green per task; format only touched files; commit per task)

- **T1 — CF Worker §4.5a** (`infra/cf-email-worker/src/worker.js`): capture `authResults` (`Authentication-Results`), `autoSubmitted` (`Auto-Submitted`), `precedence` (`Precedence`), `returnPath`/envelope-from (`message.from`; empty `<>` = bounce). Pull API shape unchanged. Test: a small JS assertion or a doc note (no JS test harness in-repo → assert via the Elixir-side parser in T6 consuming these fields).
- **T2 — migration** `priv/repo_pg/migrations/<ts>_email_inbound_binding.exs`: `email_inbound_binding` table per D4. + register `{Ezagent.Email.InboundBinding, "email_inbound_binding"}` in `per_tenant_tables_have_workspace_column_test.exs` `@per_tenant_schemas`.
- **T3 — `Ezagent.Email.InboundBinding` schema + funcs**: `record/1` (insert w/ alias+status+token), `by_local_address/1` (reverse lookup), `by_binding_row_id/1`, `verified?/1`, `mark_verified/1`, `mint_token/1` / `consume_token/2`. PG sandbox tests incl. CASCADE-on-unbind + `local_address` unique + `session_uri` unique.
- **T4 — `Ezagent.Email.Binding.publish/2` durable gate**: read status by `binding_row_id` (D4); verified→send, else `{:error, :not_verified, state}`. Test: pre-insert verified row → sends; pending/absent row → refuses. (Modifies PR-1 binding; keep init's in-memory default.)
- **T5 — `Ezagent.Email.Verification`** + bind wrapper `Ezagent.Email.bind_session/N`: alias mint (`<ws-hint>-<short-id>@ezagent.chat`) + regenerate-retry; verification email send (token link); web confirm endpoint flips status. Plus the `EzagentWeb` route + controller for the link. Tests: pending→token→verified; expired/invalid/consumed refused; no flow while pending.
- **T6 — inbound auth + loop-guard pure functions** (`Ezagent.Email.Inbound.Guard` / parsing): DMARC/SPF/DKIM PASS parse from `authResults`; From==target_id; loop guard (Auto-Submitted≠no / Precedence bulk|auto_reply|list / empty envelope-from / no Message-ID). Pure, table-tested.
- **T7 — restricted participant cap mint** (`Ezagent.Email.Inbound.Principal`): D5. Real-dispatch auth test (authorizes own session, denied other).
- **T8 — `Ezagent.Email.Inbound` poller GenServer**: poll → guard → `by_local_address(To:)` → auth → deterministic-id dedup → inject (`with_action(:session,:send)`, `mode: :call`, `_email_origin: true`, minted principal) → update threading (`last_message_id` from human's Message-ID) → DELETE-after-inject. Tests w/ injected `inbox`/`delete` funs + dispatch seam: dedup (2 polls→1), delete-only-after-inject, auth-fail rejected+deleted, loop-guard rejected.
- **T9 — `children/0` wiring** (`application.ex`): `[Ezagent.Email.Inbound]` via `maybe_inbound_spec()` (`Mix.env() == :test → nil`, mirror Feishu `maybe_ws_client_spec/0`). Test: `children/0` excludes the poller under test, includes it otherwise (via the spec helper).
- **T10 — gate + codex + PR**: `mix precommit` EXIT=0; codex:codex-rescue static review; `gh pr create` (#88, PR-2 inbound, depends-on-PR-1, note the D4 spec-§6 deviation). NO MERGE.

---

## Verification checklist (both PRs)

- [ ] `mix precommit` `EXIT=0` (PG up).
- [ ] `mix ezagent.check_invariants` (+ `.lifecycle`) green — Grill-5, cap-subject, per-tenant invariants. Email is a normal `:push` adapter with a real cap → no exemptions.
- [ ] `AdapterCapSubjectRegisteredTest` passes for `"email"`.
- [ ] No new test failures vs a clean `origin/main` baseline (`feedback_zero_new_failures_baseline_proof`).
- [ ] codex:review folded.
- [ ] No secrets in the diff.
- [ ] PRs opened, NOT merged.
