# Email external-mirror adapter — design (#88 / via #82)

> Status: REV2 — resolves the codex adversarial review (2 BLOCKER, 4 HIGH,
> 2 MED, 1 LOW). Will get a SECOND codex adversarial review after this rewrite,
> then Allen review of the remaining open questions (Q4/Q5).
> Brainstormed with Allen 2026-06-23 (Feishu chat thread); rev2 decisions
> taken by the lead (Allen) per the codex findings.

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

**Rev2 in one line:** an email address CANNOT be reverse-parsed to a session
(session URIs are 3-segment and dots are legal in name segments), so each
binding now carries a **stored, unique, human-friendly local alias** that maps
alias → binding row → session; and because email senders are trivially
forgeable, every binding is **verified at bind time** and every inbound email
must pass **SPF/DKIM/DMARC AND match the verified address** before injection.

---

## 1. Context (what already exists — reuse, don't rebuild)

- **`ezagent_domain_external_mirror` (DOMAIN — generic machinery, reuse as-is):**
  `Ezagent.ExternalMirror.Adapter`/`Binding` behaviours, `AdapterRegistry`,
  `BindingRegistry`, `BindingRow` (the `external_mirror_bindings` projection
  table: natural key `session_uri × adapter_id × target_id`, workspace-scoped,
  NOT NULL `workspace_uri`), the per-binding `Worker` GenServer (subscribes to
  the session Publisher, calls `Adapter.event_to_payload/1` then
  `Binding.publish/2`), `PerBindingSupervisor`, the `bind/4`·`unbind/4`·
  `list_bindings/2` facade (cap-checked), `BootReconciler`, and the Grill-5
  invariants. Three adapter kinds exist: `:push` (paired Binding + Worker),
  `:pull`, `:request_scoped`.
- **`ezagent_plugin_email` (PLUGIN — merged, CLI-only primitives, build on top):**
  `Ezagent.Email.send/4` (Swoosh SMTP), `Ezagent.Email.{inbox,fetch,delete}/_`
  (pull from the CF Email Worker over `:httpc`), `Ezagent.Email.Config`
  (creds-file + env), `Ezagent.Email.Mailer` (Swoosh), `Ezagent.Mail.SmtpOpts`
  (shared 465/587 + OTP 27/28 TLS mapping). Registers **no** adapter today;
  `behaviors/0`/`adapters/0`/`children/0` are all empty (CLI-only).
- **Cloudflare Email Worker** (`infra/cf-email-worker`, deployed): catch-all on
  `ezagent.chat` → caches inbound mail in KV → ezagent pulls via authenticated
  HTTP (`GET /inbox`, `GET /inbox/<key>`, `DELETE /inbox/<key>`). Today it
  stores `from / to / subject / text / html / messageId / date / receivedAt /
  size` but **NOT the email-authentication verdict** — rev2 extends it (§4.5 +
  BLOCKER 2). Inbound loop already verified live (#88).
- **`EzagentWeb.Mailer` + `AppSettings."smtp_config"`:** the existing
  runtime SMTP relay config (workspace-scoped, admin-set). Reused for sending.
- **Reference impl:** `EzagentPluginFeishu.FeishuAdapter` (`:push`, bidirectional
  Lark chat) is the closest analog and the template for this work; its inbound
  side (`EzagentPluginFeishu.InboundDispatcher`) is the template for sender →
  caller+caps resolution.

## 2. Reference mapping (Feishu → Email)

| Concern | Feishu (`:push`) | Email (this design, rev2) |
|---|---|---|
| Adapter id | `"feishu"` | `"email"` |
| Outbound transport | Lark HTTP in `FeishuChatBinding.publish/2` | `Ezagent.Email.send/4` in `Email.Binding.publish/2` |
| `event_to_payload/1` | chat-send → `{:publish, [{:lark_text, …}, …]}` | chat-send → `{:publish, %{subject, text, html, headers}}` (bare map inside the worker `{:publish, _}` wrapper — Binding receives the map directly) |
| target_id (natural key) | Lark `chat_id` | the bound human's external email address (the outbound `To:` + the inbound `From:` validator) |
| Inbound ingress | webhook → `InboundDispatcher` | **poll CF Worker inbox** → `Email.Inbound` dispatcher |
| Inbound address resolution | webhook carries `chat_id` directly | parse inbound `To:` → **stored unique `local_address`** → binding row → session_uri (BLOCKER 1) |
| Inbound injection identity | `SenderResolver` → bound user URI + caps | **synthetic "external email participant" principal** with a minimal `session.send`-on-this-session cap (BLOCKER 2 / §4.6) |
| Inbound auth | Feishu signs webhooks (transport-trusted) | **SPF/DKIM/DMARC PASS AND `From == verified address`** (BLOCKER 2) |
| Bind authz | `cap_subject` Allow cap + Lark membership `target_ownership_check` | `cap_subject` Allow cap + **bind-time email verification handshake** (BLOCKER 2 / §4.4) |
| Self-echo guard | `from_feishu?` skip in `event_to_payload` | `from_email?` skip (`body._email_origin`) |
| Loop guard (beyond self-echo) | n/a (Lark) | reject bounces / auto-replies / bulk + rate-limit + loop-detect (MED 8 / §7) |

## 3. Addressing (BLOCKER 1 — RESOLVED: stored unique alias, NOT a derived address)

**Why the derived scheme is removed.** The rev1 design derived ezagent's own
side of a binding as `<workspace>.<session_name>@ezagent.chat` and resolved an
inbound `To:` by reverse-parsing it back to `(workspace, session_name)`. This is
**unsound** against the real URI model (`Ezagent.URI`):

- A session URI is **three** segments — `session://<workspace>/<template>/<name>`
  — not two. `<session_name>` alone never identified a session; a
  `<workspace>.<session_name>` address drops the template axis entirely.
- URI **segments legally contain dots** (`segment!/1` rejects only the empty
  string and `/`; everything else, including `.`, is a valid segment). So an
  address like `acme.code-review.main@ezagent.chat` cannot be unambiguously
  split back into workspace/template/name — the dots are load-bearing in the
  names themselves. Reverse-parsing an address to a session is impossible.

**Rev2: generate and STORE a per-binding local alias.** At bind time ezagent
mints a **local address ("alias")** for the binding and stores it,
**unique-indexed**, so inbound resolves by exact alias lookup — no parsing:

    alias  -->  binding row  -->  session_uri

- **The alias is the ezagent-side address** (the `From:`/envelope-from on
  outbound, the `To:` the human replies to). On the shared domain it is
  `<slug>@ezagent.chat`; on a workspace's optional custom domain it is
  `<slug>@<custom-domain>`.
- **The alias MAY be human-friendly.** A readable slug is fine — e.g.
  `acme-ticketing-42@ezagent.chat` — because **inbound security does NOT depend
  on the alias being unguessable** (auth is BLOCKER 2: verified-bind + DMARC +
  From-match). The slug is for human legibility only. Suggested construction: a
  short workspace/intent hint + a short random/sequence suffix for uniqueness
  (e.g. `<workspace-hint>-<short-id>`). Exact slug policy is cosmetic; the only
  hard requirement is **global uniqueness on the sending domain**, enforced by
  the index below.
- **Uniqueness is enforced by a unique index** (§6). If alias generation
  collides on insert, the bind action **regenerates** and retries (mirroring the
  natural-key idempotency pattern already in `BindingRow.insert/1`).
- **Custom domains** (optional): a workspace admin who configures their own
  domain (MX → CF Worker + that domain's SMTP relay) gets aliases on that
  domain. The alias slug rule is unchanged; only the `@domain` part differs.

**Reverse resolution (inbound) — exact lookup, no parsing:**

1. Read the inbound `To:` (ezagent's alias).
2. Look up the binding row by `local_address == To:` (unique index → at most one
   row). No row → reject (logged, not bounced in v1).
3. The row yields `session_uri` (where to inject) and `target_id` (the bound,
   verified human address — the `From:` validator for BLOCKER 2).

**The previously-proposed "session_name unique per workspace" invariant is
DELETED.** It existed only to make reverse-parsing tractable; the stored unique
alias supersedes it entirely. No new constraint on session names is required.
(See Q2, now RESOLVED.)

## 4. Components (all new, inside `ezagent_plugin_email`)

### 4.1 `Ezagent.Email.Adapter` (`@behaviour Ezagent.ExternalMirror.Adapter`)
- `adapter_id/0` → `"email"`; `display_name/0`; `description/0`.
- `adapter_kind/0` → `:push`.
- `binding_module/0` → `Ezagent.Email.Binding`.
- `cap_subject/0` → `%{behavior_module:
  Ezagent.Email.Behavior.ExternalAdapter.Email.Allow, description: …}` — a real
  grantable `(Session, :allow_email, behavior)` cap (parity with Feishu; this is
  what makes the `AdapterCapSubjectRegisteredTest` invariant pass — see MED 7 +
  §9). NOT a `behavior_module: nil` opt-out.
- `target_ownership_check/2` → returns `:ok` (optionally a cheap RFC-5322
  address-format sanity check). **It does NOT perform the human verification
  handshake** — that cannot run here (Check 3 executes in a bounded ~5s
  supervised Task per the `bind/4` facade; it cannot block waiting on a human
  clicking a link). Verification is a separate async lifecycle on the binding
  (§4.4).
- `event_to_payload/1` → pure; same chat-send detection as `FeishuAdapter`
  (unwrap the two-container slice, `slice_key == :session`, `chat_send_occurred?`
  on `last_message_id` / `send_cursor`, `extract_last_message`, self-echo skip on
  `_email_origin`). Returns `{:publish, %{subject, text, html, headers}}` or
  `:skip`. **The `To:` is NOT in the payload** — the Binding owns the bound
  address (its `target_id`) and the threading headers (its durable state), just
  as `FeishuChatBinding` owns the `chat_id`.

### 4.2 `Ezagent.Email.Binding` (`@behaviour Ezagent.ExternalMirror.Binding`)
- `init({target_id, adapter, opts})` → builds binding state from the bound
  external address (`target_id`) + the binding's own `local_address` (alias) +
  the binding's **verification status** + **durable threading state** loaded
  from the per-binding thread-state store (§4.3 / HIGH 5). It does NOT mint
  threading state in volatile memory — Worker restarts must not lose the RFC
  chain.
- `publish(payload, state)` → **returns the 3-tuple recoverable shape**
  `{:ok, new_state}` | `{:error, reason, new_state}`, exactly as
  `FeishuChatBinding.publish/2` does and as the `Ezagent.ExternalMirror.Binding`
  behaviour's `t:publish_result/0` requires (HIGH 3). It:
  1. Refuses to send if the binding is not `:verified` (returns
     `{:error, :not_verified, state}` — recoverable; the Worker logs + carries
     state, does not crash).
  2. Calls `Ezagent.Email.send/4` with subject + body + the RFC 5322 threading
     headers (`Message-ID` for this message, `In-Reply-To` + `References` from
     the durable thread chain — HIGH 5).
  3. On success advances + **persists** the thread's last `Message-ID` into the
     durable thread-state store, returns `{:ok, new_state}`.
  - **Recoverable vs. raise (HIGH 3):** transient SMTP/relay failures
    (`{:error, :mail_not_configured}`, connection refused, 4xx/5xx relay
    rejection, timeout) → `{:error, reason, new_state}` (recoverable; next slice
    change retries). An **invariant violation** (e.g. the durable thread-state
    write itself fails, or `target_id` is structurally invalid) → **RAISE**
    (let-it-crash; PerBindingSupervisor restarts). Unlike Feishu, one chat send =
    one email (no multi-payload partial-send class), so there is no
    "partial-publish RAISE" branch.
- `terminate/2` → `:ok`.

### 4.3 `Ezagent.Email.ThreadState` (durable threading store — HIGH 5)
RFC 5322 threading needs the thread's **root `Message-ID`** and the **last
outbound `Message-ID`** to set `In-Reply-To` + `References` so the human's mail
client groups the conversation. The per-binding `Binding` runtime state is
**transient** (lost on Worker restart / node restart), so threading state MUST
be **durable**:

- **Decision:** a small per-binding `email_thread_state` table keyed by the
  binding's row id (`BindingRow.row_id/3`), columns: `root_message_id`,
  `last_message_id`, timestamps. `init/1` loads it; `publish/2` updates it inside
  the same logical step as the send. (Alternative considered: stamp each outbound
  `Message-ID` onto the session message's metadata and rebuild the chain by
  reading the session's message history — rejected for v1 because it couples the
  adapter to the session's message schema and makes the `References` chain a
  scan; a tiny dedicated table is simpler and self-contained.)
- Inbound emails carry the human's `Message-ID`; the inbound dispatcher records
  it as the next `In-Reply-To` target by updating `last_message_id` (so the
  agent's reply threads under the human's last mail).

### 4.4 Bind-time verification handshake (BLOCKER 2, part 1 — async, NOT Check 3)
Because email `From:` is forgeable and `target_ownership_check/2` cannot block on
a human, binding a session to a human address is a **two-state async lifecycle**
on the binding itself:

- **Bind creates the binding in status `:pending_verification`.** No outbound and
  no inbound flow while pending (the Binding refuses to publish; the inbound
  dispatcher refuses to inject — see §4.6).
- ezagent **sends a verification email** to the bound address (`target_id`)
  containing a **one-time verification token**.
- **Confirmation is via a LINK to an ezagent web endpoint**, NOT a reply token.
  The link carries the token (the token is the secret). Hitting the endpoint with
  a valid, unexpired token flips the binding to status `:verified` and activates
  both directions.
  - **Why a link, not a reply:** inbound is gated on `From == verified address`
    (BLOCKER 2). A *reply-token* confirmation would arrive as an inbound email
    that the verified-address gate would itself reject (the address isn't
    verified yet) — the gate would block the very message trying to open it. A
    verification link bypasses the inbound poller/gate entirely (it is an HTTP
    request, authenticated by the token), so it has no bootstrap paradox.
- Verification status lives on the binding (its `opts_json` and/or a status
  column on the projection row) so it survives restart and the poller can read it
  without a live Worker.
- Token: single-use, time-boxed (TTL), unguessable random. A failed/expired token
  surfaces an actionable error on the web endpoint; re-binding (or a "resend
  verification" action) mints a fresh token.

### 4.5 `Ezagent.Email.Inbound` (poll loop — replaces Feishu's webhook)
A supervised GenServer/poller that periodically calls `Ezagent.Email.inbox/1`
(CF Worker pull). For each fetched message, in order:

1. **Loop/bounce guard (MED 8):** reject and `DELETE` (do not inject) any message
   that is an auto-response, bounce, or bulk mail — see §7. Checked FIRST so a
   bounce of ezagent's own outbound never re-enters as fresh inbound.
2. **Address resolution (BLOCKER 1):** look up the binding row by
   `local_address == To:`. No row → log + `DELETE` (no bounce in v1).
3. **Authentication enforcement (BLOCKER 2, part 2):** accept ONLY if
   - the captured `Authentication-Results` verdict shows **SPF/DKIM/DMARC PASS**
     for the `From:` domain (the CF Worker computes + stores this — §4.5a), AND
   - the binding is `:verified` AND `From: == target_id` (the bound verified
     address).
   Senders with **no** email authentication are **rejected** (no
   degrade-to-allow). A forged `From:` fails DMARC → rejected. On rejection: log +
   `DELETE` (no injection, no bounce in v1).
4. **Dedup (HIGH 6):** build the `Ezagent.Message` with a **deterministic id**
   derived from the normalized email `Message-ID` + session (§4.5b) so a
   re-delivered poll cannot double-inject.
5. **Inject:** dispatch `<session_uri>?action=session.send` via
   `Ezagent.URI.with_action(session_uri, :session, :send)` +
   `Ezagent.Invocation.dispatch/1` (mode `:call`, mirroring
   `InboundDispatcher`), under the **synthetic external-email-participant
   identity** with its minimal cap (§4.6). Stamp `body._email_origin = true` for
   the self-echo guard.
6. **Update threading:** record the human's `Message-ID` as the next
   `In-Reply-To` target in the durable thread-state store (§4.3).
7. **`DELETE /inbox/<key>` only AFTER a successful inject** (at-least-once; the
   deterministic id in step 4 makes a pre-DELETE re-poll idempotent).

Poll interval + the pull token come from `Ezagent.Email.Config`.

#### 4.5a Required CF Email Worker change (BLOCKER 2 + MED 8 — ONE revision)
The Worker (`infra/cf-email-worker/src/worker.js`) MUST be extended to capture +
store, alongside the existing fields, the headers ezagent needs to enforce auth
AND the loop guard — in a **single** Worker revision so §4.5/§7 don't each invent
their own:

- **`authResults`** — the `Authentication-Results` header (Cloudflare Email
  Routing computes SPF/DKIM/DMARC; the verdict is on this header). Store the raw
  header (and/or a parsed `{spf, dkim, dmarc}` triple). This is the field
  BLOCKER 2's inbound enforcement reads.
- **`autoSubmitted`** — the `Auto-Submitted` header (RFC 3834; `auto-replied` /
  `auto-generated` mark vacation responders + system mail).
- **`precedence`** — the `Precedence` header (`bulk` / `auto_reply` / `list`).
- **`returnPath` / envelope-from** — `message.from` envelope sender; an **empty
  envelope-from (`<>`)** is the RFC bounce marker.
- (`messageId` is already stored; the dedup in §4.5b reuses it.)

The pull API shape (`GET /inbox`, `/inbox/<key>`, `DELETE`) is unchanged; the
stored records just carry the extra fields.

#### 4.5b Deterministic inbound dedup (HIGH 6 — RESOLVED: deterministic id)
`Ezagent.Message.new/3` auto-generates a random 16-hex id, and `MessageStore`
dedups on the message id with `on_conflict: :nothing`. Rev2 makes inbound dedup
**free** by passing a **deterministic** id via the `:id` opt
(`Ezagent.Message.new/3` already supports `:id` for replay):

    id = truncated_hash(session_uri_string <> "/" <> normalized_message_id)

— the same SHA-256-truncated shape `BindingRow.row_id/3` uses. Normalize the
email `Message-ID` (trim angle brackets / whitespace, lowercase) before hashing.
Because the id is a pure function of `(session, Message-ID)`, a re-delivered poll
of the same email injects the SAME id → `MessageStore`'s `on_conflict: :nothing`
silently no-ops the second write → no double-injection, even across node
restarts. This is preferred over a separate `processed_email` side-table because
it reuses the existing idempotent write path (one mechanism, no new table to keep
in sync, no read-before-write race).
(An inbound email with **no** `Message-ID` at all is treated as
auto/malformed → rejected by §7, so the deterministic-id path always has an
input.)

### 4.6 Inbound injection identity (BLOCKER 2, part 3 — restricted participant)
Inbound email MUST NOT be injected under an arbitrary or admin caller. Mirroring
how `EzagentPluginFeishu.InboundDispatcher` resolves sender → bound user URI +
caps, email resolves the verified external address to a **restricted synthetic
participant principal** with a **minimal** cap:

- **Principal URI:** a synthetic, workspace-scoped entity URI representing "this
  verified external email correspondent for this binding" — e.g. an
  `entity://<workspace>/user/email-<short-id>` constructed via `Ezagent.URI`
  (canonical, in the session's workspace). It is NOT the admin URI and NOT any
  real ezagent user; it stands only for the external email participant.
- **Caps:** exactly ONE cap — `session.send` (the
  `Ezagent.Behavior.Session`/`:send` cap) scoped to **that one bound session
  instance** in **that workspace**. Nothing else: it cannot bind, cannot list,
  cannot reach any other session. Constructed the same way
  `InboundDispatcher` carries `caps` into the dispatch ctx, but minted minimally
  for this principal rather than copied from a human user's cap set.
- This keeps the inbound path least-privilege: a compromised/abused external
  address can only post into the single session it is verified for.

### 4.7 Plugin wiring (MED 7)
`EzagentPluginEmail.Application` (today all-empty) MUST declare:

- **`behaviors/0`** → register the cap-only marker behavior on the Session Kind
  for each of its actions, exactly like Feishu's `application.ex`:

      def behaviors do
        for action <- Email.Behavior.ExternalAdapter.Email.Allow.actions() do
          {Ezagent.Entity.Session, action, Email.Behavior.ExternalAdapter.Email.Allow}
        end
      end

  Without this, `cap_subject/0.behavior_module` references a behavior that was
  never registered against `(Session, :allow_email)`, and the
  **`AdapterCapSubjectRegisteredTest` invariant FAILS**. (This is the concrete
  reason the cap marker must be a real registered behavior, not `nil`.)
- **`adapters/0`** → `[{Email.Adapter, Email.Binding}]` (Grill-5 bidirectional
  declaration; `Ezagent.Plugin.boot/1` registers both + auto-registers the cap
  subject via `AdapterInstall.install/1`).
- **`children/0`** → `[Email.Inbound]` (the poller; skipped at test boot like
  Feishu's `WsClient`).
- The plugin is already wired into the web deps + the release list.

### 4.8 Required extension to `Ezagent.Email.send/4` (HIGH 5)
`Ezagent.Email.send/4` today accepts only `to / subject / body / from / html`
(via `opts`). It MUST be extended to accept **threading headers** so the Binding
can thread the conversation:

- `:message_id` — the `Message-ID` to stamp on this outbound mail.
- `:in_reply_to` — the `In-Reply-To` header (the previous message in the chain).
- `:references` — the `References` header (the full chain).

These map onto Swoosh's custom-header support
(`Swoosh.Email.header/3`). The existing signature stays backward-compatible
(new opts default to absent → no header emitted, identical to today's behavior).

## 5. Data flow

**Outbound** (session → email): user/agent posts in the bound session → session
Publisher emits → per-binding `Worker` calls `Email.Adapter.event_to_payload/1`
→ `Email.Binding.publish/2` → (verified? else recoverable error) →
`Ezagent.Email.send/4` with durable threading headers → one message → one
threaded email to the bound human address.

**Inbound** (email → session): human replies to the thread → CF catch-all → CF
Worker KV (now incl. auth verdict + loop-guard headers) → `Email.Inbound` poll →
loop/bounce guard → alias → binding row → DMARC + From-match auth → deterministic
id dedup → inject as a session message (`_email_origin`) under the restricted
participant identity → the session's agents see it and may reply → that reply
flows back out via the Outbound path. The loop is broken by (a) the
`_email_origin` self-echo skip in `event_to_payload/1` and (b) the
bounce/auto-reply rejection in §7.

## 6. Data model (rev2)
- **Reuse `BindingRow`** (`external_mirror_bindings`): one row per bound session,
  `adapter_id = "email"`, **`target_id` = the bound human's external address**
  (the outbound `To:` + the inbound `From:` validator), parallel to Feishu's
  `target_id = chat_id`.
- **NEW: `local_address` field + UNIQUE index** on the projection (a migration).
  This is the queryable authority for inbound reverse lookup (alias → row →
  session). The alias is generated by the bind action, written into the Session
  `:external_mirror` slice (the P3 source of truth), then projected onto this
  row; the unique index enforces global uniqueness, and an alias-generation
  collision on insert triggers a regenerate-and-retry (mirroring the existing
  natural-key idempotency in `BindingRow.insert/1`). The session Kind slice MAY
  also mirror the alias for UI display, but the **indexed projection row is the
  reverse-lookup authority**.
- **NEW: verification status** (BLOCKER 2): a `:pending_verification | :verified`
  status + verification token, carried on the binding (a status column and/or
  `opts_json`) so it survives restart and the poller reads it without a live
  Worker.
- **NEW: `email_thread_state`** per-binding table (HIGH 5): `root_message_id`,
  `last_message_id`, keyed by `BindingRow.row_id/3`. Durable RFC threading state.
- **The previously-proposed derived address column is NOT added and the derived
  scheme is gone** — ezagent's own address IS the stored `local_address`, not a
  pure function of the session URI (BLOCKER 1).

### 6.1 BindingRow key policy (HIGH 4)
The table's natural key stays `(session_uri, adapter_id, target_id)`. For email,
**v1 = exactly ONE email binding per session** — enforced by a uniqueness
constraint on `(session_uri, adapter_id = "email")` (a session cannot bind two
human addresses in v1). Inbound resolves by the unique **`local_address`** (not
by `(session + adapter)`), so the inbound path never has to disambiguate. (A
future multi-address-per-session feature would relax this; out of scope for v1.)

## 7. Error handling / edge cases / loop guard (MED 8)
- **Send failure** (SMTP down / relay reject / not configured):
  `publish/2 → {:error, reason, new_state}` (recoverable 3-tuple); Worker logs +
  telemetry + carries state, no crash, retries on next slice change. No silent
  drop (`feedback_let_it_crash_no_workarounds`).
- **Unknown inbound alias** (no row): log + `DELETE` (no bounce in v1).
- **Unverified binding:** outbound refuses (recoverable error); inbound rejects
  (no injection).
- **Auth failure** (DMARC fail / no auth / From-mismatch): reject + `DELETE`, no
  injection (BLOCKER 2).
- **Self-echo:** `_email_origin` skip in `event_to_payload/1` (mirrors
  `_feishu_origin`).
- **Loop / bounce / auto-response guard (MED 8) — `_email_origin` alone is
  insufficient** because bounces (NDRs) and auto-replies (vacation responders)
  re-enter as *fresh* inbound from a *different* envelope, not carrying our
  origin flag. Inbound rejects (and `DELETE`s without injecting) when ANY of:
  - `Auto-Submitted` is present and not `no` (RFC 3834 — auto-replied /
    auto-generated),
  - `Precedence` is `bulk`, `auto_reply`, or `list`,
  - the envelope-from / `Return-Path` is **empty (`<>`)** (the RFC bounce
    marker), or the message otherwise has no usable `Message-ID`.
  These are read from the CF Worker fields added in §4.5a.
- **Rate limiting + loop detection:** cap the inbound injection rate per binding
  (and globally) so a misbehaving correspondent or a residual mail loop can't
  flood a session; if the same `(session, From)` pair exceeds a threshold in a
  window, pause that binding's inbound and surface telemetry rather than
  injecting. (Self-echo + bounce rejection break the common loop; the rate cap is
  the backstop for the pathological case.)
- **Mail not configured** (`smtp_config` absent): `bind` may succeed into
  `:pending_verification`, but the verification send + `publish` return
  `{:error, :mail_not_configured, _}` — surfaced to operator.

## 8. Threading (RFC 5322)
First outbound email mints a root `Message-ID` (stored in `email_thread_state`);
every subsequent outbound sets `In-Reply-To` (the last `Message-ID`) +
`References` (the chain) so the human's client groups them. Inbound emails carry
the human's `Message-ID`, recorded as the next `In-Reply-To` target. State is
**durable** (§4.3 / HIGH 5) so a Worker/node restart never breaks the chain.

## 9. Capability model (MED 7)
A grantable `(Ezagent.Entity.Session, :allow_email,
Email.Behavior.ExternalAdapter.Email.Allow)` cap (parity with Feishu's
`allow_feishu`). The marker behavior is **cap-only** (`dispatchable?/0 == false`,
`data_owner/1 → :any` so workspace admins grant it), modeled exactly on
`EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow`. It is registered via
`behaviors/0` (§4.7) — which is what keeps the **`AdapterCapSubjectRegisteredTest`
invariant satisfied** (a real registered `behavior_module`, not the `nil`
opt-out). `Ezagent.ExternalMirror.bind/4` Check 2 enforces it.

The inbound restricted-participant cap (§4.6) is a separate, minimal,
runtime-minted `session.send` cap — distinct from this grantable bind cap.

## 10. Config / out of scope (v1)
- **Send:** reuse `AppSettings."smtp_config"` (workspace-scoped). The
  ezagent-owned domain's relay is the single SMTP path.
- **Receive:** CF Email Worker pull (`Ezagent.Email.Config`), with the §4.5a
  Worker revision deployed.
- **IMAP:** seam only — not implemented (bridging a pre-existing external mailbox
  is future).
- **No inbound auto-create:** v1 only routes to **already-bound + verified**
  sessions; "stranger emails in → spawn a session" is future.
- **Attachments:** v1 mirrors text + a textual attachment note; binary
  attachment passthrough (like Feishu's file upload) is a follow-up.
- **One email binding per session** (HIGH 4); multi-address per session is
  future.

## 11. Testing / E2E
- **Unit — outbound:** `event_to_payload/1` (chat-send detect, self-echo skip,
  payload shape, two-container unwrap); `Binding.publish/2` with
  `Swoosh.Adapters.Test` (`assert_email_sent`, threading headers present);
  `publish/2` returns the **3-tuple recoverable shape** on transient failure
  (HIGH 3); `publish/2` refuses when `:pending_verification`.
- **Unit — addressing (BLOCKER 1):** alias generation is unique; a duplicate
  alias on insert regenerates; **reverse lookup** `alias → row → session_uri`
  returns exactly one session; an inbound `To:` with no matching alias → reject.
- **Unit — verification (BLOCKER 2):** bind creates `:pending_verification`; a
  valid token flips to `:verified` and activates both directions; an
  expired/invalid token is refused; no outbound/inbound while pending.
- **Unit — inbound auth (BLOCKER 2):** DMARC PASS + From-match → injected;
  DMARC fail → rejected; no auth verdict → rejected; verified binding but
  From != target_id → rejected; forged-From (fails DMARC) → rejected.
- **Unit — dedup (HIGH 6):** two polls of the same email (same `Message-ID`)
  inject ONE message (deterministic id + `on_conflict: :nothing`); inbox item
  deleted only after successful inject.
- **Unit — loop guard (MED 8):** `Auto-Submitted: auto-replied` rejected;
  `Precedence: bulk` rejected; empty envelope-from (bounce) rejected; rate cap
  pauses a flooding `(session, From)` pair.
- **Unit — threading durability (HIGH 5):** thread state survives a simulated
  Worker restart (reload from `email_thread_state`); `References` chain grows
  across messages.
- **Unit — wiring (MED 7):** `behaviors/0` registers
  `(Session, :allow_email, Email...Allow)`; the **`AdapterCapSubjectRegisteredTest`
  invariant passes** for the email adapter; Grill-5 passes for the
  `{Email.Adapter, Email.Binding}` pair.
- **Invariants:** Grill-5 + cap-subject + per-tenant invariants stay green
  (email is a normal `:push` adapter with a real cap → no exemptions needed).
- **Live E2E** (PG disposable stack, extend `scripts/e2e_init_protocol_api.sh`
  sibling): bind a session to a test address → receive + click the verification
  link → outbound message arrives as a threaded email (assert via a mailbox / CF
  Worker) → reply email (authenticated) → poll injects it into the session →
  agent reply mirrors back out (threaded). Also assert an unverified/forged
  inbound is rejected.

## 12. Open questions
- **Q1 — bind-time address verification: RESOLVED.** A verification handshake IS
  required for v1 (BLOCKER 2 / §4.4): bind → `:pending_verification` → ezagent
  emails a one-time token → human clicks a **link to an ezagent web endpoint**
  (not a reply token, to avoid the inbound-gate bootstrap paradox) → binding
  activates. No outbound/inbound while pending.
- **Q2 — session-name uniqueness: RESOLVED (obviated).** The derived-address
  reverse-parse is removed (BLOCKER 1), so no session-name-unique-per-workspace
  invariant is needed. Inbound resolves by the **stored, unique-indexed
  `local_address` alias** instead. No new constraint on session names.
- **Q3 — threading-state storage: RESOLVED.** Threading state is made
  **DURABLE** (HIGH 5) in a per-binding `email_thread_state` table keyed by
  `BindingRow.row_id/3` (root + last `Message-ID`); `Ezagent.Email.send/4` is
  extended to accept `:message_id` / `:in_reply_to` / `:references`. NOT derived
  from session history, and not transient-only.
- **Q4 — subject line (refined note, for Allen):** a pinned thread subject (e.g.
  `[<session_name>] …`, fixed after the first message) is acceptable **only with
  subject/header sanitization** — strip CR/LF and control chars from any
  session-derived text before it reaches a mail header (header-injection
  prevention). Recommend: pinned subject + mandatory sanitization.
- **Q5 — scope / PR split (refined note, for Allen):** keep the split, but
  **PR-1 is OUTBOUND-ONLY** (`:push` adapter + binding + cap + `behaviors/0`
  wiring + extended `send/4` + durable thread-state + Swoosh-test E2E) and makes
  **no bidirectional-complete claim**. PR-2 is the inbound poller + injection +
  auth, and it **requires the addressing (stored alias), verification, auth, and
  dedup decisions above to have already landed** (alias index + verification
  lifecycle + CF Worker §4.5a revision + deterministic dedup) before the poller
  can be safely enabled.

---

> Note: this rev2 will receive a SECOND codex adversarial review before
> implementation begins.
