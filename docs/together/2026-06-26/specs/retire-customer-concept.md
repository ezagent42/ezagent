# SPEC — Retire the "customer" business concept from socialware

**Status:** PLAN ONLY. Do **NOT** implement. The lead confirms this plan (and the
codex adversarial-review verdict) before any execution.

**Date:** 2026-06-26
**Branch (this plan only):** `docs/retire-customer-spec` (docs add; the retirement is a
separate future PR set).
**Skills:** `ezagent-developer` + `ezagent-socialware`.

---

## 0. TL;DR

"customer" is an **AutoService business concept** (the served end-user, from the
#589 "AutoService+loom fusion" vocabulary) that got baked into the generic socialware
**domain**. The codebase already grew a fully generic replacement — the **anon-user +
membership** primitive (#51/#68) — and is **mid-migration**: the chat external surface
(`ChatFeed`/`ChatFeedController`, #51) is the modern membership-authorized form, while the
older customer surface (`CustomerFeed`/`CustomerController`/`CustomerAuth`) is the legacy
token-authorized parallel. They are not two *features*; they are **two auth models over
the same SPA + channel + json-render machinery**.

The discriminating insight (validated against `CustomerFeed.snapshot/2`): **auth and
projection are orthogonal**. `snapshot/2` does `authorize(token)` *then*
`project(messages/page/shell)`. The projection needs nothing from the token. Therefore:

- **KEEP + RENAME (generic, load-bearing):** the **2-tier visibility class**
  (`:customer_visible`/`:operator_only`), the **page/shell/surface projection** that the
  hello demo genuinely depends on (`CustomerFeed` minus its auth), the settlement/outbox
  delivery durability, and the SPA/channel machinery — all re-authorized via
  membership/anon-user, **exactly as `ChatFeed` already does for the chat projection.**
- **RETIRE (business residue / redundant auth):** `CustomerAuth` (the identity-less
  token), `CustomerController`, `CustomerSocket`, the `/socialware/customer` route, the
  `"socialware:customer:"` topic string, and the already-dormant `CustomerFeedAdapter` +
  `:allow_customer_feed` cap. Every public viewer becomes a minted **anon-user**
  (read-only) or a signed-in **member** — the choice `ChatFeedController` already made.

The one genuine gap anon-user does not cover — **truly identity-less public reads** — is
a deliberate product decision foregrounded in §6 for the lead, **not** a blocker.

---

## 1. Problem

The literal `customer` is a **served-end-user business noun** from the AutoService
vocabulary. Socialware is a generic **domain** ("a session made publicly viewable so
external/anonymous users can watch and join it" — `ezagent-socialware` SKILL). Baking
"customer" into the domain:

1. **Mislabels the generic.** A public socialware viewer is not a "customer" — it is an
   anonymous or authenticated **external viewer**. The chat surface already proves the
   neutral framing: `ChatFeedAuth`'s moduledoc explicitly contrasts itself with
   `CustomerAuth` ("a chat session has no 'customer' / settlement token"), and
   `anon_cookie.ex` notes it follows "the same pattern as CustomerController".
2. **Spawns a parallel auth model.** `CustomerAuth` (stateless session+ws token) sits
   beside the anon-user + membership primitive that #51/#68 built to be *the* generic
   external-access mechanism. Two ways to authorize the same external read is exactly the
   redundancy the north-star (plugin isolation / one generic primitive) forbids.
3. **Leaks the noun across three tiers** — core (`message.ex` visibility enum value
   `:customer_visible`; `message_store` query fns), domain
   (`CustomerFeed`/`CustomerAuth`/`CustomerFeedAdapter`/`customer_outbox`/`customer_delivery`),
   and web (`CustomerController`/`CustomerSocket`/`CustomerChannel`/route/topic/SPA
   `customer_app.js` + `customer.css` + `data-theme="customer"`).

This document is the **retirement plan**: the full inventory (live vs dormant), the
anon-user/membership mapping, the keep-rename / retire split per module, the
migration + back-compat design, the test plan, and the `elimination_test` gate.

---

## 2. Background — the two parallel models (the thing being consolidated)

### 2.1 The legacy customer model (token auth + page projection)

```
GET /socialware/customer?session_uri=…[&token=…]   (CustomerController)
   token path:     CustomerAuth.authorize(token, session, ws)   → CustomerFeed.snapshot
   tokenless path: PublicView.public_view? → CustomerAuth.issue_token(…) → snapshot
        ↓ SPA shell (customer_app.js, data-socket-path "/socialware_socket",
                     data-topic-prefix "socialware:customer")
   WS  /socialware_socket  (CustomerSocket → CustomerChannel "socialware:customer:*")
        read:  CustomerFeed.{snapshot,join,replay,history,chat_messages}  (CustomerAuth)
        write: handle_in("join"|"post")  ← uses viewer_principal (ChatFeedAuth identity!)
                                            + Behavior.Session.Membership  ← ALREADY membership
```

`CustomerFeed.snapshot/2` returns `%{messages, page, shell, shell_css}` — the
**agent-generated surface page** (`Surface.customer_tree`, shell HTML, compiled CSS). It
also owns the **durable delta-cursor** replay over the settlement **outbox**
(`customer_outbox.ex`, `committed_deliveries_since/2`) — the exactly-once delivery model.

### 2.2 The modern chat model (membership auth + chat projection)

```
GET /socialware/chat?session_uri=…   (ChatFeedController, #51 — public :browser scope)
   authenticated → ChatFeedAuth token for the principal
   anonymous + public_view → mint/reuse AnonUser, AnonBinding, cookie, session.join,
                             mount_participation_caps → ChatFeedAuth token for the anon
        ↓ SAME SPA shell (customer_app.js, data-socket-path "/socialware_chat_socket",
                          data-topic-prefix "socialware:chat_feed")
   WS  /socialware_chat_socket (ChatFeedSocket → ChatFeedChannel)
        read:  ChatFeed.snapshot/2  ← LIVE Session.Membership.authorize/2 (re-checked every advisory)
```

`ChatFeed.snapshot/2` returns `%{messages, page}` where `page = chat_tree(messages)` —
the **chat recency window** (NO settlement, NO cursor, NO surface page). Auth is **live
membership** (an ex-member is denied on the next advisory; no token revocation needed).

### 2.3 The key observation

`CustomerChannel`'s **write** path (`join`/`post`) **already** authorizes via
`viewer_principal` (a `ChatFeedAuth` identity) + `Behavior.Session.Membership` — the
modern model. Only the **read** path still uses `CustomerAuth`. The customer model is
*already half-migrated*; this SPEC finishes the migration and renames the surviving
generic half.

---

## 3. Full "customer" surface inventory (live vs dormant)

Grep basis: `git grep -i customer origin/main -- 'apps/**'` + docs. Grouped by role.
**LIVE** = a non-test caller depends on it on a real request/turn path. **DORMANT** =
present but no load-bearing caller (vestigial). **RESIDUE** = naming-only (a generic
thing wearing the business noun).

### 3.1 Visibility class (core) — KEEP + RENAME (generic)

| File:sym | Status | Notes |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/message.ex` — `visibility: :customer_visible \| :operator_only` (enum, default `:customer_visible`) | **LIVE / RESIDUE** | The 2-tier external-vs-internal visibility is **generic and keepable**. Only the *value name* `:customer_visible` is residue. |
| `apps/ezagent_core/lib/ezagent/message_store.ex` — `committed_customer_visible/2`, `committed_customer_visible_by_ids/2`, `chat_visible_recent/2`, `mark_visibility/2` | **LIVE / RESIDUE** | Query fns gating on `:customer_visible`. Rename the value + the fn names. |
| `apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex` — `initial_visibility(:auto)=:customer_visible`; `mark_visibility(_, :operator_only)` | **LIVE / RESIDUE** | The turn settlement decides external-visibility per message. Generic. |
| `apps/ezagent_domain_session/lib/ezagent/socialware/settlement.ex` — `mark_visibility(ids, :customer_visible/:operator_only)` | **LIVE / RESIDUE** | Same. |

### 3.2 The customer feed / projection — SPLIT (keep projection, retire auth)

| File:sym | Status | Disposition |
|---|---|---|
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` — `CustomerFeed.{snapshot,join,replay,history,chat_messages,committed_deliveries_since,authorized_attachment_path}` | **LIVE** (hello e2e, CustomerChannel, CustomerSocket, CustomerController all call it) | **KEEP the projection + delivery logic, RENAME the module, REPLACE its `CustomerAuth.authorize` step with membership/anon-user auth.** This is the load-bearing surface-page read. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_auth.ex` — `CustomerAuth.{issue_token,authorize}` | **LIVE** but **redundant** | **RETIRE.** The identity-less token is the parallel auth model anon-user replaces. (See §6 for the one caveat.) |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed_adapter.ex` — `CustomerFeedAdapter` + `.Allow` + `:allow_customer_feed` cap | **DORMANT** | **DELETE outright.** Per its own 2026-06-26 moduledoc: "With the advisor vertical removed, NO plugin currently declares it, so its `allow_customer_feed` cap subject is no longer published at boot. The live customer feed does NOT depend on that registration — the channel calls `CustomerFeed.snapshot/2` directly." Confirmed by §3 grep: no non-test, non-self caller. (Matches the #1034 finding.) |

### 3.3 The customer web surface — RETIRE (fold into membership-authorized surface)

| File:sym | Status | Disposition |
|---|---|---|
| `apps/ezagent_web/lib/ezagent_web/controllers/socialware/customer_controller.ex` — `show/2` (token + tokenless), `download/2` | **LIVE** | **RETIRE the token-auth ingress.** The page-surface view migrates to a membership/anon ingress modeled on `ChatFeedController` (which already mints anon-users for `public_view`). `download/2` (attachment) re-homes onto the same membership/anon auth. |
| `apps/ezagent_web/lib/ezagent_web/socialware/customer_socket.ex` — `CustomerSocket` (channel `"socialware:customer:*"`; auth via `CustomerFeed.snapshot(token)`) | **LIVE** | **RETIRE / merge** into a single membership-authorized surface socket (analogous to `ChatFeedSocket`). |
| `apps/ezagent_web/lib/ezagent_web/socialware/customer_channel.ex` — `CustomerChannel` (read: `CustomerFeed.*`; write: `join`/`post` via `viewer_principal` + Membership) | **LIVE** | **KEEP the join-protocol/cursor/post logic, RENAME, drop the `CustomerAuth` read auth** (the write path is *already* membership-based). |
| `apps/ezagent_web/lib/ezagent_web/endpoint.ex` — `socket "/socialware_socket", CustomerSocket` | **LIVE** | Retire/rename with the socket. |
| `apps/ezagent_web/lib/ezagent_web/router.ex` — `get "/socialware/customer"`, `get "/socialware/customer/download"` | **LIVE** | Retire/rename routes (see §5 back-compat for shipped links). |

### 3.4 The settlement / delivery plumbing — KEEP + RENAME (naming residue only)

| File:sym | Status | Disposition |
|---|---|---|
| `apps/ezagent_domain_session/lib/ezagent/socialware/customer_outbox.ex` — `CustomerOutbox` schema (`socialware_customer_outbox` table) | **LIVE** | **KEEP, RENAME** (module + table). Durable exactly-once delivery. Generic. |
| `apps/ezagent_domain_session/lib/ezagent/session/customer_delivery.ex` — `CustomerDelivery.topic/1` = `"socialware:customer:" <> uri` | **LIVE / RESIDUE** | **KEEP, RENAME** the module and the **wire topic string** (back-compat surface — §5). |
| `apps/ezagent_domain_session/lib/ezagent/socialware/customer_outbox.ex` calls + `settlement.ex` `{:customer_delivery, …}` PubSub event tag | **LIVE / RESIDUE** | Rename the event atom in lockstep with subscribers (`CustomerChannel`, `CustomerFeedAdapter` doc). |

### 3.5 The customer SPA (P4) — KEEP + RENAME (asset residue)

| File:sym | Status | Disposition |
|---|---|---|
| `apps/ezagent_domain_socialware/assets/js/customer_app.js` (+ web copy `apps/ezagent_web/assets/js/customer_app.js`), `catalog*.mjs`, `theme_shell.mjs` | **LIVE** | **KEEP, RENAME** the bundle (`customer_app.js` → e.g. `viewer_app.js`). Note the hardcoded fallbacks `socketPath \|\| "/socialware_socket"` and `topicPrefix \|\| "socialware:customer"` (customer_app.js:168–169) — these are the **defaults used when `data-*` attrs are absent**, i.e. exactly the customer page; update with the socket/topic rename. |
| `apps/ezagent_web/assets/css/customer.css` + `data-theme="customer"` (both controllers' page shells) | **LIVE / RESIDUE** | **KEEP, RENAME** the stylesheet + theme token. |
| `id="socialware-customer-root"` in the page shells | **LIVE / RESIDUE** | Rename DOM id; update SPA selector. |

### 3.6 Tests — move with the code

`customer_*_test.exs` (socket, auth, feed_adapter, approved_attachment, join_protocol,
leak, page_commit_gate, delivery_cursor, turn_customer_feed_integration,
customer_renderer) — all **LIVE tests**; they move/rename with their subjects. The
`customer_leak_test` and `customer_page_commit_gate_test` encode the **security boundary**
(operator-only never leaks; only committed/approved pages serve) — they must keep passing
under the new auth, byte-equivalent on the boundary.

### 3.7 Hello demo + misc docstring residue

`apps/ezagent_plugin_hello/**` references `CustomerFeed.snapshot` (e2e test + driver
docstrings) and `/socialware/customer`. **LIVE** (the e2e is the live socialware proof).
Update call sites + docstrings to the renamed projection. Numerous moduledoc mentions of
"customer" (`session_view.ex`, `plugin.ex`, `download_token.ex`, `uploads_controller.ex`,
`check_invariants.ex`) are **RESIDUE** — update prose.

### 3.8 Inventory summary

- **DORMANT (delete outright):** `CustomerFeedAdapter` + `.Allow` + `:allow_customer_feed`.
- **RETIRE (redundant auth / business ingress):** `CustomerAuth`, `CustomerController`
  (token + tokenless ingress), `CustomerSocket`, `/socialware/customer[/download]` routes,
  `"socialware:customer:"` topic, `:customer_delivery` event atom.
- **KEEP + RENAME (generic, load-bearing):** the visibility class
  (`:customer_visible`→neutral), `CustomerFeed` projection+delivery,
  `CustomerChannel` serving/cursor/post logic, `CustomerOutbox`, `CustomerDelivery`,
  the SPA bundle/CSS/theme/DOM-id.

---

## 4. The anon-user / membership mapping (what already replaces "customer")

| "customer" capability | anon-user + membership equivalent | Gap? |
|---|---|---|
| Identify a public viewer | `AnonUser.mint_for_public_session/1` mints a read-only `entity://` anon (one narrow `session.join` cap, `granted_by` the owner — Decision #154). Signed-in viewers use their real principal. | No. (Caveat: anon is an *identity*; CustomerAuth was identity-less — §6.) |
| Persist viewer across visits | `AnonBinding` (one-anon ⇄ one-session) + signed `socialware_anon` cookie (`AnonCookie`); `AnonBinding.touch/3` refresh; 48h `AnonUser.GC` reap. | No. |
| Authorize the read | LIVE `Ezagent.Session.Membership.authorize/2` over the session's `:chat`/`:session` slice — re-checked every advisory (ex-member denied; no revocation needed). Replaces `CustomerAuth.authorize/3`. | No. The customer token was a *static* grant; membership is *live* — strictly better. |
| Authorize the write (join/post) | `Membership.provision_invited_join_authority/3` + `session.join` dispatched as the principal + `mount_participation_caps/2` (UNCONFIRMED tier = read-only, no `:send`; member = `:send`). | No — `CustomerChannel` **already** does this for `join`/`post`. |
| Anon → login takeover | `EzagentWeb.Socialware.AnonTakeover` relabels the anon's footprint to the confirmed user (#68). | No — and customer had **no** takeover path (a strict capability gain). |
| Attachment download auth | `CustomerFeed.authorized_attachment_path/4` (approved-only, committed, serve-time revocation) — re-home onto membership/anon auth (the validation is auth-agnostic; only the token-gate changes). | No. |
| Surface page projection | The renamed `CustomerFeed.snapshot` projection (`messages/page/shell/shell_css`) — **auth-agnostic**; swap only the `authorize` step. | No. |

**Conclusion:** anon-user + membership covers every customer *capability* and adds two
the customer model lacked (live re-auth, login takeover). The only thing it does not
provide is *identity-less* access — §6.

---

## 5. The keep / retire split (per-tier disposition)

### 5.1 KEEP + RENAME — proposed neutral names

| Old (business) | New (neutral) | Rationale |
|---|---|---|
| `:customer_visible` / `:operator_only` | **`:external_visible` / `:operator_only`** | Mirrors the domain's own word "external" (`ChatFeed` moduledoc: "external read"; `ChatFeedController`: "external SPA"; `page_view_external_render_test`). `:operator_only` is already neutral — keep it; the pair reads as external-vs-internal. (Alt considered: `:public`/`:internal` — rejected: `public_view` already owns "public" at the template level; "external" is the viewer axis, avoiding overload.) |
| `Ezagent.Socialware.CustomerFeed` | **`Ezagent.Socialware.ExternalFeed`** (or `SurfaceFeed`) | The gated external projection of a socialware session's surface page. |
| `Ezagent.Socialware.CustomerOutbox` / table `socialware_customer_outbox` | **`Ezagent.Socialware.DeliveryOutbox`** / `socialware_delivery_outbox` | Durable delivery ledger; not customer-specific. |
| `Ezagent.Session.CustomerDelivery` / topic `socialware:customer:` | **`Ezagent.Session.ExternalDelivery`** / topic `socialware:external:` | Wire convention rename — back-compat in §5.3. |
| `:customer_delivery` PubSub atom | **`:external_delivery`** | Rename with subscribers in lockstep. |
| `EzagentWeb.Socialware.CustomerChannel`/`Socket` | **`ExternalFeedChannel`/`Socket`** (or merge into `ChatFeed*`) | See §5.4 — consider unifying with chat. |
| `customer_app.js` / `customer.css` / `data-theme="customer"` / `#socialware-customer-root` | **`viewer_app.js` / `viewer.css` / `data-theme="viewer"` / `#socialware-viewer-root`** | Asset rename. |
| `committed_customer_visible/2` etc. | `committed_external_visible/2` etc. | Track the enum value rename. |

> The neutral names above are **proposals for lead sign-off**, not decided. The
> `soul-config-key-rename.md` precedent shows the lead picks the final name; this SPEC
> recommends `:external_visible` + the `External*` family.

### 5.2 RETIRE — deletion list

- `Ezagent.Socialware.CustomerAuth` (entire module).
- `EzagentWeb.Socialware.CustomerController` (token ingress + tokenless ingress; the
  page-surface view is re-served by the renamed membership/anon ingress — §5.4).
- `EzagentWeb.Socialware.CustomerSocket` (merge into the renamed/unified socket).
- `Ezagent.Socialware.CustomerFeedAdapter` + `.Allow` + `:allow_customer_feed` cap
  (dormant — delete; drop the cap-subject from any allowlist/doc).
- Routes `/socialware/customer` + `/socialware/customer/download`.
- The `"socialware:customer:"` topic + `:customer_delivery` atom (renamed, §5.1).

### 5.3 The ingress consolidation (the heart of the retirement)

The two `show/2` ingresses converge. `CustomerController.show` (tokenless public branch)
already mirrors `ChatFeedController.show` almost line-for-line — both:
`ensure_live` → `public_view?` gate → (customer: issue CustomerAuth token; chat: mint
anon-user) → render SPA. **The retirement makes the customer page take the chat branch:**
on a `public_view` session, mint/reuse an **anon-user** (read-only) instead of issuing a
`CustomerAuth` token; for a signed-in viewer, use the real principal. The renamed
`ExternalFeed.snapshot` then authorizes via **live membership** instead of the token.

This yields **one external-surface ingress pattern** with two *projections*
(chat-recency vs surface-page), both membership/anon-authorized — collapsing the
business/generic fork into a single generic surface.

### 5.4 Open design choice for the lead — one socket or two?

After retiring `CustomerAuth`, `ExternalFeedChannel` (surface-page, delta-cursor) and
`ChatFeedChannel` (chat-recency, snapshot-refresh) differ only in **projection + read
model**, not auth. Two options:

- **(A) Two channels, shared auth** (lower-risk): keep distinct channels/sockets (one
  per read model), both using `Membership`/anon. Minimal behavior change; just drops the
  token half. **Recommended for the first PR.**
- **(B) One unified surface channel** with a projection selector: maximal
  consolidation but merges two read models (cursor vs snapshot-refresh) — higher risk,
  defer to a follow-up.

---

## 6. The genuine gap — identity-less public reads (decision for the lead)

This is the **one capability anon-user does not replicate**, and the task asks to name it
precisely:

- **`CustomerAuth` is identity-less.** A stateless signed token binds `{session, ws}`;
  the server can mint it for *anyone* (the tokenless branch does exactly that) with **no
  cookie, no `AnonBinding` row, no Kind spawn, no GC, no join dispatch**. A viewer leaves
  zero footprint.
- **anon-user mints an identity per viewer.** Cookie + `AnonBinding` + a live `AnonUser`
  Kind + `session.join` + `mount_participation_caps` + 48h GC. Heavier per first-view;
  durable; supports login-takeover and live re-auth.

**Recommendation:** adopt anon-user for page views too — **`ChatFeedController` already
made this exact choice for public chat in #51**, so consolidating is the *consistent*
direction, and it buys live re-auth + takeover the customer model never had. Flag the
**per-viewer-identity overhead** (one Kind + one `AnonBinding` row + GC pressure per
first-time public viewer) as the accepted tradeoff.

**If the lead wants a truly identity-less public read** (e.g. a high-fanout marketing
page where minting an anon per visitor is unacceptable), that is the single thing
anon-user does not cover today. Two ways to close it — both deferrable:

- **(i)** Keep a *minimal renamed* stateless read-token (e.g. `PublicReadToken`) for the
  read-only surface snapshot ONLY (no write, no identity), explicitly scoped as "the
  identity-less public read" — i.e. retire the *name* and the *write coupling* but keep
  the mechanism. This is the smallest residue.
- **(ii)** Extend anon-user with an **ephemeral mode** (no cookie/binding/GC; a transient
  read-only principal per request). More work; keeps one primitive.

Default the SPEC to "anon-user for all viewers" (option none) unless the lead raises the
fanout concern; (i)/(ii) are the fallbacks.

---

## 7. Migration & back-compat

### 7.1 The stored visibility value (`:customer_visible` → `:external_visible`)

`message.ex` stores `visibility` as a **`:string` column** (migration
`20260618000400`, `add :visibility, :string, null: false, default: "customer_visible"`) —
**not** a hard Postgres enum, so the rename is a value rewrite, not a type alteration.

Repo policy (`ezagent-developer` SKILL: "No back-compat shims … Existing DB data is
wiped + rebuilt on URI migrations") **permits a rebuild**. Two paths — lead picks:

- **(A) Rebuild (policy default):** dev/disposable DBs are reseeded; no data migration.
  Cleanest; consistent with the URI-migration precedent. **Recommended** given the
  disposable-stack E2E model and that socialware sessions are not yet production data.
- **(B) Data migration (if any environment holds durable messages):** an Ecto migration
  `UPDATE messages SET visibility='external_visible' WHERE visibility='customer_visible'`
  + flip the column default. Single mechanical statement; the value is a free-text string
  so no enum constraint blocks it.

Either way: change `message.ex` enum `values:` + `default:`, the `message_store` query
predicates, `turn.ex` `initial_visibility`, `settlement.ex` — **in one mechanical pass**
(memory `feedback_systematic_fix_over_local_entropy`).

### 7.2 The wire topic + route + bundle (shipped-surface back-compat)

- **Topic `"socialware:customer:"`** (`customer_delivery.ex:16`): a live WS subscription
  string. Renaming breaks any in-flight client subscribed to the old topic. Because the
  customer SPA is served fresh per page load (the controller embeds the topic via
  `data-topic-prefix`, and the *retired* customer route stops serving the old prefix
  entirely), there is **no persistent client** holding the old topic — the rename is safe
  as long as server + the (renamed) bundle change together. **Verify no external/3rd-party
  consumer subscribes to `socialware:customer:`** (grep shows only first-party).
- **Route `/socialware/customer`**: the task notes "the customer SPA's endpoint" as a
  back-compat concern. Check for **shipped/hardcoded links** to `/socialware/customer`
  (e.g. in seed tasks, docs handed to users, the hello demo). Grep result: references are
  first-party (hello plugin docstrings + tests + this repo's docs). **Recommendation:**
  hard-cut the route (no 301 shim, per no-shim policy) and update the first-party callers
  to `/socialware/chat` (or the renamed surface route) in the same PR. If any *external*
  share-link is known to be live, the lead must approve either a one-release 301 redirect
  or coordinated link reissue (flag — user-assist step).
- **JS fallbacks `customer_app.js:168–169`** (`"/socialware_socket"`,
  `"socialware:customer"`): update to the renamed socket/topic; they are only used when
  `data-*` is absent (i.e. the customer page), which is being retired/renamed anyway.

### 7.3 Deletion ordering

1. Delete dormant `CustomerFeedAdapter` + cap (no caller; safe first).
2. Rename the KEEP set (`CustomerFeed`→`ExternalFeed`, outbox, delivery, topic, atom,
   visibility value, SPA assets) — mechanical, behavior-preserving.
3. Swap `ExternalFeed` auth from `CustomerAuth` → `Membership`/anon; migrate the
   `CustomerController`/`CustomerSocket` ingress onto the anon/membership pattern
   (modeled on `ChatFeedController`/`ChatFeedSocket`).
4. Delete `CustomerAuth`, `CustomerController`, `CustomerSocket`, the routes, the topic.
5. Update first-party callers/docstrings (hello plugin, moduledocs).
6. Add the `elimination_test` gate (§8.3).

Steps 1–2 and 3–4 can each be a PR; codex-review each (memory `feedback_codex_review_every_pr`).

---

## 8. Test plan

### 8.1 Move-with-code (behavior-preserving)

The existing `customer_*_test.exs` suite re-points at the renamed modules and the
membership/anon auth. **Security-boundary tests must stay byte-equivalent:**
`customer_leak_test` (operator-only never leaks), `customer_page_commit_gate_test`
(only committed/approved pages serve), `customer_feed_approved_attachment_test`,
`customer_delivery_cursor_test` (exactly-once replay). These are the contract for "the
projection is unchanged; only the auth changed."

### 8.2 New regression tests (each retired bug-class earns one)

- **Anon page view** (the new ingress): an anonymous visitor to a `public_view` session
  sees the **surface page** (`snapshot.page`/`shell`) under a *minted anon-user*, not a
  CustomerAuth token — the e2e analogue of `hello_page_e2e_test` but driven through the
  membership-authorized ingress. (memory `feedback_e2e_failure_earns_unit_test`.)
- **Live re-auth on the page surface:** an ex-member (or a revoked anon) loses the
  surface-page read on the next advisory — proving the auth swap from static token to live
  membership holds the boundary.
- **Tokenless = anon, not token:** assert the retired `/socialware/customer` path is gone
  and the surface view is reachable only via the membership/anon ingress.

### 8.3 The `elimination_test` (north-star-style invariant gate)

Model on `lv_cli_parity_test`'s `refute File.dir?` + the system-principal
`elimination_test` (memory `feedback_completion_requires_invariant_test`,
`project_afk_goal_eliminate_sysprincipals`). The gate is the **completion criterion**:

```elixir
# apps/ezagent_core/test/invariants/no_customer_concept_test.exs (sketch)
test "the customer business concept is fully retired from socialware" do
  # 1. retired modules/files do not exist
  refute Code.ensure_loaded?(Ezagent.Socialware.CustomerAuth)
  refute Code.ensure_loaded?(Ezagent.Socialware.CustomerFeedAdapter)
  refute File.exists?("apps/.../socialware/customer_controller.ex")
  refute File.exists?("apps/.../socialware/customer_socket.ex")

  # 2. no `customer` identifier survives in apps/ outside a tiny allowlist
  hits =
    grep_idents("customer", under: "apps/", exclude: @allowlist)
  assert hits == [], "customer residue remains:\n#{Enum.join(hits, "\n")}"

  # 3. the stored visibility value is renamed
  refute :customer_visible in Ezagent.Message.visibility_values()
  assert :external_visible in Ezagent.Message.visibility_values()

  # 4. the retired cap subject is gone from the catalog
  refute :allow_customer_feed in declared_cap_subjects()
end
```

`@allowlist` starts empty (or holds only this test + a CHANGELOG/decision note) and
**ratchets to zero** — the same ratchet pattern as the doc-coverage gate
(`project_doc_coverage_gate`). Wire it into `mix ezagent.check_invariants` so CI hard-fails
on any reintroduction (`feedback_run_check_invariants_gate`).

---

## 9. Risks & non-goals

- **Risk — page projection regresses under membership auth.** Mitigation: the projection
  is auth-agnostic (`authorize` then `project`); §8.1 boundary tests stay byte-equivalent.
- **Risk — the delta-cursor delivery model is subtler than chat snapshot-refresh.** The
  surface feed keeps its cursor/outbox (do **not** naively collapse it onto chat's
  snapshot-refresh — that would lose exactly-once delivery). §5.4 option A keeps them
  separate.
- **Risk — fanout cost of per-viewer anon identities** (§6). Decision for the lead;
  fallback (i)/(ii) deferrable.
- **Non-goal:** changing the `public_view` template flag, the SPA's visual design, or the
  hello demo's behavior. The page a visitor sees is identical; only *how they are
  authorized* and *what the code is called* change.
- **Non-goal:** touching the chat surface (`ChatFeed*`) — it is already the target shape.

---

## 10. Open questions for the lead

1. **Identity-less reads (§6):** accept per-viewer anon identities everywhere (consistent
   with #51), or preserve an identity-less public read (option (i) minimal read-token /
   (ii) ephemeral anon)? Default: anon everywhere.
2. **Visibility value name (§5.1):** `:external_visible` (recommended) vs `:public` vs
   another? And the `External*` module family vs `Surface*`/`Viewer*`?
3. **DB migration (§7.1):** rebuild (policy default, recommended) or data-migrate the
   stored `customer_visible` value?
4. **One socket or two (§5.4):** keep `ExternalFeedChannel` + `ChatFeedChannel` separate
   (recommended, lower risk) or unify into one surface channel?
5. **Route hard-cut (§7.2):** any *external* live link to `/socialware/customer` that
   needs a transitional 301, or is a clean cut + first-party link update acceptable?
```
