# Email external-mirror adapter — design (#88 / via #82)

> Status: DRAFT for codex adversarial review, then Allen review of open questions.
> Brainstormed with Allen 2026-06-23 (Feishu chat thread).

**Goal:** make email a **fully bidirectional session channel** — a human's
email thread is bound to an ezagent session: each outbound session message is
mirrored out as a (threaded) email, and each inbound email is injected into the
bound session as a message. Email becomes "Feishu, but the external surface is
an email thread instead of a Lark group."

**Architecture in one line:** a new `:push` adapter+binding inside the existing
`ezagent_plugin_email`, implementing the `Ezagent.ExternalMirror` **domain**
contract, modeled directly on `EzagentPluginFeishu.{FeishuAdapter,
FeishuChatBinding}`; inbound arrives by **polling the Cloudflare Email Worker
inbox** (email has no push webhook) instead of Feishu's webhook.

---

## 1. Context (what already exists — reuse, don't rebuild)

- **`ezagent_domain_external_mirror` (DOMAIN — generic machinery, reuse as-is):**
  `Ezagent.ExternalMirror.Adapter`/`Binding` behaviours, `AdapterRegistry`,
  `BindingRegistry`, `BindingRow` (the `external_mirror_bindings` projection
  table: `session_uri × adapter_id × target_id`, workspace-scoped, NOT NULL
  `workspace_uri`), the per-binding `Worker` GenServer (subscribes to the
  session Publisher, calls `Adapter.event_to_payload/1` then `Binding.publish/2`),
  `PerBindingSupervisor`, the `bind/4`·`unbind/4`·`list_bindings/2` facade
  (cap-checked), `BootReconciler`, and the Grill-5 invariants. Three adapter
  kinds exist: `:push` (paired Binding + Worker), `:pull`, `:request_scoped`.
- **`ezagent_plugin_email` (PLUGIN — merged, CLI-only primitives, build on top):**
  `Ezagent.Email.send/4` (Swoosh SMTP), `Ezagent.Email.{inbox,fetch,delete}/_`
  (pull from the CF Email Worker over `:httpc`), `Ezagent.Email.Config`
  (creds-file + env), `Ezagent.Email.Mailer` (Swoosh), `Ezagent.Mail.SmtpOpts`
  (shared 465/587 + OTP 27/28 TLS mapping). Registers **no** adapter today.
- **Cloudflare Email Worker** (`infra/cf-email-worker`, deployed): catch-all on
  `ezagent.chat` → caches inbound mail in KV → ezagent pulls via authenticated HTTP
  (`GET /inbox`, `GET /inbox/<key>`, `DELETE /inbox/<key>`). Inbound loop already
  verified live (#88).
- **`EzagentWeb.Mailer` + `AppSettings."smtp_config"`:** the existing
  runtime SMTP relay config (workspace-scoped, admin-set). Reused for sending.
- **Reference impl:** `EzagentPluginFeishu.FeishuAdapter` (`:push`, bidirectional
  Lark chat) is the closest analog and the template for this work.

## 2. Reference mapping (Feishu → Email)

| Concern | Feishu (`:push`) | Email (this design) |
|---|---|---|
| Adapter id | `"feishu"` | `"email"` |
| Outbound transport | Lark HTTP in `FeishuChatBinding.publish/2` | `Ezagent.Email.send/4` in `EmailBinding.publish/2` |
| `event_to_payload/1` | chat-send → `{:lark_text, …}` list | chat-send → `{:email, %{to, subject, text, html, headers}}` |
| target_id | Lark `chat_id` | external email address (the human's real mailbox) |
| Inbound ingress | webhook → `InboundDispatcher` | **poll CF Worker inbox** → `Email.Inbound` dispatcher |
| Inbound injection | `with_action(session, :session, :send)` + `Invocation.dispatch`, stamp `_feishu_origin` | identical, stamp `_email_origin` |
| Self-echo guard | `from_feishu?` skip in `event_to_payload` | `from_email?` skip (`body._email_origin`) |
| Bind authz | `cap_subject` Allow cap + `target_ownership_check` (Lark membership) | `cap_subject` Allow cap + `target_ownership_check` → `:ok` (cap-gated; see Open Q1) |

## 3. Addressing

ezagent's side of every binding is an address **at a domain ezagent owns**, so there is
exactly one send path and one receive path — no per-user Gmail/Outlook/IMAP
adapter zoo (IMAP stays a seam, see §10).

- **Default (shared domain):** `<workspace>.<session_name>@ezagent.chat`.
  Workspace prefix is required because `session_name` is only unique **within**
  a workspace; the prefix makes the address globally unique on one catch-all
  domain (chosen over a per-workspace MX subdomain for operational simplicity).
- **Custom domain (optional):** when a workspace admin configures their own
  domain (MX → CF Worker + that domain's SMTP relay), the address collapses to
  `<session_name>@<custom-domain>`.
- **ezagent's own per-binding address is DERIVED, not stored:**
  `<workspace>.<session_name>@<domain>` is a pure function of the session URI, so
  no column is needed for it.
- **Reverse resolution (inbound):** parse the inbound recipient (`To:`, which is
  ezagent's derived address) → `(workspace, session_name)` → session URI → confirm a
  `BindingRow` for `(session_uri, adapter_id="email")` exists. That row's
  `target_id` is the bound human address (used for threading + to validate the
  `From:`). The parse + row-confirm together are the resolution; the row is the
  source of truth for "is this session bound to email?" (see §6). Inbound to a
  derived address with **no** matching binding → rejected (logged, not bounced in
  v1).

**New invariant required:** `session_name` MUST be unique per workspace.
Today the session URI path makes a session addressable, but a flat
"name unique across the workspace" constraint is not enforced. This spec adds
that constraint + a regression test (an address must resolve to exactly one
session). See Open Q2 for where the uniqueness is enforced.

## 4. Components (all new, inside `ezagent_plugin_email`)

### 4.1 `Ezagent.Email.Adapter` (`@behaviour Ezagent.ExternalMirror.Adapter`)
- `adapter_id/0` → `"email"`; `display_name/0`; `description/0`.
- `adapter_kind/0` → `:push`.
- `binding_module/0` → `Ezagent.Email.Binding`.
- `cap_subject/0` → `%{behavior_module: Ezagent.Email.Behavior.ExternalAdapter.Email.Allow, description: …}` — a real grantable `(Session, :allow_email, behavior)` cap (parity with Feishu; NOT the `behavior_module: nil` opt-out protocol_api used).
- `target_ownership_check/2` → `:ok` (v1: binding is cap-gated + ezagent-initiated; there is no external "membership" to verify for an outbound destination). Open Q1 covers an optional address-verification handshake.
- `event_to_payload/1` → pure; same chat-send detection as `FeishuAdapter`
  (`slice_key == :session`, `chat_send_occurred?` on `last_message_id` /
  `send_cursor`, `extract_last_message`, self-echo skip on `_email_origin`).
  Returns `{:publish, %{to: addr, subject: subj, text: body, headers: hdrs}}`
  or `:skip`.

### 4.2 `Ezagent.Email.Binding` (`@behaviour Ezagent.ExternalMirror.Binding`)
- `init({target_id, adapter, opts})` → builds binding state: the bound external
  address, ezagent's own address for this binding, and **threading state** (the
  root `Message-ID` for the thread; the last seen `Message-ID` for
  `In-Reply-To`/`References`).
- `publish(payload, state)` → calls `Ezagent.Email.send/4` with subject + body +
  RFC 5322 threading headers; returns `{:ok, new_state}` (advancing the
  thread's last `Message-ID`) or `{:error, reason}` (surfaced; the Worker's
  crash boundary + retry applies).
- `terminate/2` → `:ok`.

### 4.3 `Ezagent.Email.Inbound` (poll loop — replaces Feishu's webhook)
- A supervised GenServer/poller that periodically calls `Ezagent.Email.inbox/1`
  (CF Worker pull), and for each new message:
  1. parse the recipient address → `(workspace, session_name)` → session URI;
     confirm a `BindingRow` for `(session_uri, adapter_id="email")` exists (its
     `target_id` = the bound human address, matched against the `From:`).
  2. build an `Ezagent.Message` from the email (from/subject/body/attachments),
     stamp `body._email_origin = true`.
  3. inject via `Ezagent.URI.with_action(session_uri, :session, :send)` +
     `Ezagent.Invocation.dispatch/1` (identical to `FeishuInboundDispatcher`).
  4. `DELETE /inbox/<key>` on success (at-least-once; idempotency via the
     email `Message-ID` so a re-delivered poll doesn't double-inject).
- Poll interval + the pull token come from `Ezagent.Email.Config`.

### 4.4 Plugin wiring
- `EzagentPluginEmail.Application`: add `adapters/0 → [{Email.Adapter, Email.Binding}]` and `children/0 → [Email.Inbound]`. (Today both return empty / the app is CLI-only.) Already wired into web deps + the release list.

## 5. Data flow

**Outbound** (session → email): user/agent posts in the bound session →
session Publisher emits → per-binding `Worker` calls
`Email.Adapter.event_to_payload/1` → `Email.Binding.publish/2` →
`Ezagent.Email.send/4` (threaded). One message → one email.

**Inbound** (email → session): human replies to the thread → CF catch-all → CF
Worker KV → `Email.Inbound` poll → address→session resolve → inject as a
session message (`_email_origin`) → the session's agents see it and may reply →
that reply flows back out via the Outbound path. Loop is broken by the
`_email_origin` self-echo skip in `event_to_payload/1`.

## 6. Data model
- **Reuse `BindingRow`** (`external_mirror_bindings`): one row per bound session,
  `adapter_id = "email"`, **`target_id` = the bound human's external address**
  (the outbound `To:`), parallel to Feishu's `target_id = chat_id`. This is the
  outbound destination + the `From:` validator for inbound.
- **ezagent's own address is NOT stored** — it is derived from the session URI
  (`<workspace>.<session_name>@<domain>`). Inbound resolution parses the
  recipient → session, then looks the row up by `(session_uri, "email")` (§3),
  so no column holds ezagent's own address.
- **Threading state** lives in the binding's `opts`/runtime state; whether to
  persist the thread root `Message-ID` (new tiny `email_thread_state` keyed by
  binding) or derive `In-Reply-To` from the session's last outbound message is
  Open Q3. No new table for v1 if threading can be derived.

## 7. Error handling / edge cases
- **Send failure** (SMTP down / relay reject): `publish/2 → {:error, reason}`;
  Worker surfaces + retries per the domain's existing retry/crash boundary.
  No silent drop (`feedback_let_it_crash_no_workarounds`).
- **Unknown inbound address** (no binding): log + drop (no bounce in v1).
- **Self-echo:** `_email_origin` skip (mirrors `_feishu_origin`).
- **Duplicate inbound** (poll re-delivery before DELETE): dedupe by email
  `Message-ID`.
- **Mail not configured** (`smtp_config` absent): `bind` may succeed but
  `publish` returns `{:error, :mail_not_configured}` — surfaced to operator.

## 8. Threading (RFC 5322)
First outbound email mints a root `Message-ID`; every subsequent outbound sets
`In-Reply-To` + `References` to the thread chain so the human's client groups
them. Inbound emails carry the human's `Message-ID`, captured as the next
`In-Reply-To` target.

## 9. Capability model
A grantable `(Ezagent.Entity.Session, :allow_email, Email...Allow)` cap
(parity with Feishu's `allow_feishu`). Granted to the session owner / workspace
admin; `Ezagent.ExternalMirror.bind/4` Check 2 enforces it. Keeps the
`AdapterCapSubjectRegisteredTest` invariant satisfied the normal way (a real
behavior_module, not the nil opt-out).

## 10. Config / out of scope (v1)
- **Send:** reuse `AppSettings."smtp_config"` (workspace-scoped). The ezagent-owned
  domain's relay is the single SMTP path.
- **Receive:** CF Email Worker pull (`Ezagent.Email.Config`).
- **IMAP:** seam only — not implemented (bridging a pre-existing external mailbox
  is future).
- **No inbound auto-create:** v1 only routes to **already-bound** sessions
  (ezagent-initiated binding); "stranger emails in → spawn a session" is future.
- **Attachments:** v1 mirrors text + a textual attachment note; binary
  attachment passthrough (like Feishu's file upload) is a follow-up.

## 11. Testing / E2E
- Unit: `event_to_payload/1` (chat-send detect, self-echo skip, payload shape);
  `Binding.publish/2` with `Swoosh.Adapters.Test` (`assert_email_sent`, threading
  headers); address parse/resolve; session-name uniqueness invariant.
- Grill-5 + cap-subject + per-tenant invariants stay green (email is a normal
  `:push` adapter with a real cap → no exemptions needed).
- Live E2E (PG disposable stack, extend `scripts/e2e_init_protocol_api.sh`
  sibling): bind a session to a test address → outbound message arrives as a
  threaded email (assert via a mailbox/CF Worker) → reply email → poll injects it
  into the session → agent reply mirrors back out.

## 12. Open questions (for Allen)
- **Q1 — bind-time address verification:** v1 has `target_ownership_check → :ok`
  (cap-gated trust). Do you want a confirmation handshake (ezagent sends a verify
  email to the address; binding activates only after a click/reply token) before
  v1 ships, or defer it? (Recommend: defer; cap-gated is enough for
  admin-initiated binds.)
- **Q2 — where to enforce session-name-unique-per-workspace:** at session
  creation (reject duplicate name in workspace) is the clean spot, but it
  tightens an existing surface other code/tests create sessions through. Enforce
  globally now, or only when an email binding is requested (lazy)? (Recommend:
  global at creation + a one-time audit for existing dup names.)
- **Q3 — threading-state storage:** persist the thread root `Message-ID` in a new
  per-binding store, or rebuild `In-Reply-To` from the session's last outbound
  message each time (no new table)? (Recommend: derive from the last outbound
  `Message-ID` — no new table — unless you want exact `References` chains.)
- **Q4 — subject line:** fixed (`[ezagent] <session_name>`) vs. mirror the first
  user message vs. configurable per binding? (Recommend: `[<session_name>] …`
  with the thread subject pinned after the first message.)
- **Q5 — scope/PR split:** one plugin PR (adapter + binding + inbound poll +
  cap + uniqueness invariant + E2E), or split inbound poll into its own PR?
  (Recommend: split — PR-1 outbound (`:push` adapter+binding+cap), PR-2 inbound
  poll + injection, so each is independently testable.)
