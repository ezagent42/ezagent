# World composer file upload — cap-authed HTTP endpoint (PR-2b)

**Date:** 2026-06-21
**Branch:** `world`
**Status:** DRAFT — awaiting codex adversarial review, then implement
**Context:** LV→world parity migration PR-2b. LV used Phoenix LiveView uploads
(`live_file_input` + `consume_uploaded_entries`). world's composer is a React
island under `phx-update="ignore"`, so the LiveView uploader cannot manage a
file input inside it. The transport must be a **cap-authorized HTTP POST**
(decision already forced by the island architecture). This is a NEW WRITE
SURFACE in a #154 CapBAC codebase, hence the spec + codex review.

## Goal

A session member can attach files to a chat message from the world composer.
Upload is decoupled from send (LV consumed on send): upload → store → return
`resource://<ws>/uploads/<name>` URI → composer holds the URI(s) → next
`chat.send` carries them as attachments → message stream renders signed
download links. Claims parity features `validate_compose` + `cancel_upload`
(ratchet 39→37).

## Threat model (the questions codex must pressure-test)

1. **Who may upload to which session's workspace?** Only a caller authorized to
   `:send` into the TARGET session. No authed-but-unauthorized user may write
   bytes into any workspace's upload store.
2. **Workspace binding.** The file MUST be stored under the TARGET SESSION's
   workspace (not the caller's home workspace), so store-ws == download-ws by
   construction (mirrors `Admin.Compose.upload_workspace_name!/1`, codex P2
   round-3 HIGH). A system member context-switched into tenant W uploading to a
   W-session must land the file under W.
3. **Traversal / unsafe names.** `stored_name` is server-generated
   (`<uuid>-<sanitized client_name>`); `Ezagent.Uploads.store!/3` resolves the
   dest through `FsResolver` which rejects unsafe names before any byte — but
   the controller MUST NOT pass client-controlled path segments.
4. **Size / type / count.** Bounded (max 10 MB/file matching LV; max 5
   files/message; accept any type as LV did). Enforced before `store!`.
5. **CSRF.** The endpoint is state-changing under `:browser`; the POST must
   carry a valid CSRF token (the island reads it from the page).
6. **No #154 regression.** Authorization is a cap check at the chokepoint —
   `Ezagent.Capability.matches?/2` against a required `:send` cap — NEVER a
   `caller == admin_uri()` hardcode (p13). `Ezagent.Identity.admin?/1` is the
   only admin shortcut, and even that is not required (a non-admin member with
   `:send` must succeed; an admin without a session relationship is governed by
   the same cap rule).

## Endpoint

`POST /uploads/world` (name TBD — codex may prefer `/world/uploads`), mounted in
the existing `scope "/", EzagentWeb do pipe_through [:browser, RequireEntity]`
block (same pipeline as the `/uploads/download` route), so the caller is an
authenticated entity and CSRF applies.

- **Params:** `session` (encoded target session URI), `file` (a `%Plug.Upload{}`
  multipart entry; repeatable as `file[]` for batch — or one request per file,
  codex to advise on simplicity).
- **Controller:** `EzagentWeb.WorldUploadsController.create/2` (new), thin —
  delegates storage to `Ezagent.Uploads.store!/3` (the chokepoint).

### Authorization (the load-bearing check)

```
caller       = conn.assigns.current_entity_uri          # set by RequireEntity
caller_caps  = Ezagent.Identity.list_caps_for(caller)
session_uri  = parse + canonicalize the `session` param (reject non-session)
session_ws   = Ezagent.Capability.workspace_of(session_uri)
required     = %Ezagent.Capability{kind: :session, behavior: Ezagent.Behavior.Session,
                 action: :send, instance: session_uri, workspace_uri: session_ws,
                 granted_by: caller, granted_at: <now>}
authorized?  = Enum.any?(caller_caps, &Ezagent.Capability.matches?(&1, required))
```

`Capability.matches?/2` already encodes `:any` instance/action/workspace
widening + cross-workspace rules, so a member holding `:send` (or a broader
`:any`) on the session passes, and nobody else does. This is EXACTLY the cap
the `:session :send` dispatch checks for the composer — upload and send share
one authorization, so they cannot drift. **Open question for codex:** is there
a reusable "can this caller perform action X on URI" predicate so we don't
hand-assemble the required cap? (If `Ezagent.Authz`/`Invocation` exposes a dry
authorize, prefer it.)

### Storage + response

```
workspace_name = Ezagent.URI.workspace_name!(session_ws)   # raise if no ws — no silent default
stored_name    = "#{Ecto.UUID.generate()}-#{sanitize(upload.filename)}"
uri            = Ezagent.Uploads.store!(workspace_name, stored_name, upload.path)
→ 200 JSON: %{"uri" => URI.to_string(uri), "name" => display_name, "size" => bytes}
```

`sanitize/1` = basename + `[^\w.\-]+ → _` + 200-char clamp (port of
`Admin.Compose.sanitize_filename/1`). Errors: 401 (unauthorized), 413 (too
large), 422 (bad/missing params), all JSON `%{"error" => ...}`.

## React composer (PR-2b client)

- A paperclip button + hidden `<input type="file" multiple>`; on change, POST
  each file (FormData) to the endpoint with the `x-csrf-token` header (read from
  the page's csrf meta/data attr — plumb it through `mountWorld` like
  `caller`), and the `session` param.
- Pending-attachment chips below the composer; an ✕ on each removes it from the
  pending list (this IS `cancel_upload` — purely client state, no server call,
  since upload already persisted; a future GC reaps unreferenced uploads).
- `validate_compose` parity = client-side pre-flight (size/type/count) before
  POST, surfacing a friendly error inline.
- On `chat.send`, include `attachments: [resource_uri,...]` in the dispatch
  args; `ConversationActions.send_message/4` + `ConversationData.build_message`
  thread them into `Ezagent.Message.new(.., %{text:, attachments:})`.

## Message render (download links)

`ConversationData.message_row/2` currently renders attachments as plain labels
(PR-1 breadcrumb). PR-2b: for a `resource://<ws>/uploads/<name>` attachment,
mint a signed `Ezagent.Uploads.DownloadToken` and render
`/uploads/download?token=<t>` (the existing authed download route does serve-
time participant re-check, so minting does not widen access — same contract as
LV's `att_to_link/1`). Non-uploads URIs render as plain text.

## Tests

- Controller: authorized member → 200 + resource URI stored under session ws;
  unauthorized authed user → 401, nothing written; missing/oversized → 422/413;
  traversal name → rejected by `store!` (no escape).
- `ConversationData.build_message/3` threads attachments into `msg.body`.
- `message_row/2` mints a download-token link for an uploads URI.
- agent-browser E2E: attach a file → chip appears → send → message shows a
  working download link (on the isolated home, seeded session+member).

## Ratchet + gates

Remove `validate_compose` + `cancel_upload` from `@pending_migration` (39→37),
lower `@pending_baseline`. Per-PR gates: world+web suites, check_invariants,
arch.scan, doc.scan, cap-elimination + p13, grep gate (no LV refs), vite build,
agent-browser E2E + frontend-design visual.

## Cleanup note (PR-7)

This endpoint replaces LV's `live_file_input`/`consume_uploaded_entries` upload
path; at PR-7 those LV upload sites (`admin_live.ex`, `compose.ex`,
`session_editor.ex`) are deleted with the app.

---

## codex adversarial review (2026-06-21) — SPEC REJECTED, needs redesign

codex found the draft authorization is unsafe. Findings (sev / claim / fix):

1. **[HIGH] Missing #154 provenance filter.** The dry `matches?/2` accepts
   stale/forged `system://`-granted caps the dispatch chokepoint rejects.
   Dispatch applies `Capability.granted_by_entity?/1` (Kind.ex:237-248,
   Kind.Runtime:557-563) BEFORE `matches?`. Upload must apply the same filter.
2. **[HIGH] Missing workspace isolation.** Dispatch step 5.6
   `Kind.Runtime.workspace_isolation_check` (627-690) is not in the dry check,
   so upload and `:session :send` drift for cross-workspace callers.
3. **[HIGH] Client-supplied attachment-URI laundering.** Client sends
   attachment URIs on `chat.send`; download authz only proves a filename
   appears in an attaching message (uploads_controller.ex:134-155), so any
   known `resource://<ws>/uploads/<name>` can be laundered into a tokenized
   link. Bind uploaded URIs server-side to caller/session/attempt (ledger or
   signed attach-grant), validate message attachments against it before mint.
4. **[MED] 5-file cap not server-enforced** — enforce at send/build_message.
5. **[MED] Orphan uploads / storage-exhaustion** — cancel is client-only + GC
   deferred (vs LV consume-on-send). Specify delete-on-cancel or bounded TTL GC.
6. **[LOW] CSRF after multipart parse** — parser runs before pipeline; add a
   route size/pre-parser guard.

**Root cause:** the draft recreates dispatch authorization OUTSIDE the dispatch
chokepoint. `Capability.matches?/2` ALONE is not the dispatch decision (which
also does provenance + ws-isolation + required-cap resolution, all PRIVATE in
`Kind.Runtime`). No `Ezagent.Authz` / dry-authorize predicate exists.

### Redesign decision (BIG — flagged to Allen 2026-06-21)

Two ways to keep upload authz in parity with dispatch:
- **(A) Extract a shared dry predicate** `Ezagent.Authz.can?(caller_caps,
  target, action)` from `Kind.Runtime` (required-cap + provenance + ws-iso),
  used by BOTH dispatch and the upload controller. Touches the #154 chokepoint.
- **(B, RECOMMENDED) Route upload THROUGH dispatch.** Controller stores to a
  caller/session-bound quarantine, then dispatches a real session action
  (`:session :attach`) that authorizes at the chokepoint + commits the file
  binding into an upload ledger. ONE authz path (the chokepoint), no duplicate
  predicate, and the ledger closes finding #3 by construction.

PR-2b is HELD pending Allen's pick (A vs B). Migration proceeds with PR-4+
meanwhile; upload is the least-critical conversation feature and must not ship
with the draft's holes.

---

## Option B — full design (Allen approved 2026-06-21, Feishu)

> Allen: "(B) 上传走派发链，记得继续坚持之前的 LV / CLI / API 原则." — route the
> upload through the dispatch chain so ONE authorization path serves the web, CLI
> and API surfaces. No duplicate dry-predicate (rejected draft's root cause).

### Shape (one authz path = the dispatch chokepoint)

```
browser → POST /world/uploads (multipart: session, file)        [:browser + RequireEntity → CSRF + authed caller]
  controller:
    1. parse + bound-check (size ≤ 10MB, ≤ 5 files/msg enforced at send too)
    2. store bytes to a CALLER/SESSION-scoped QUARANTINE dir (not the live store)
    3. dispatch %Invocation{target: session :attach, mode: :call,
                            args: %{quarantine_ref, filename, size, content_type},
                            ctx: %{caller, caps, reply: :ignore}}
       → AUTHORIZES AT THE CHOKEPOINT (required-cap + provenance + ws-isolation,
         all the real dispatch decision — NOT a re-implemented matches?/2)
    4. on {:error, _}  → DELETE the quarantine file, return 401/403 (no orphan)
       on :ok          → handler has committed the file under the SESSION's
                         workspace store + returned a signed attach-grant;
                         controller responds 200 JSON {uri, name, size, grant}
```

### New Session action: `:attach` (the chokepoint)

- Declared on `Ezagent.Behavior.Session` alongside `:send/:join/:leave`, with
  **`caps: [:send]`** — upload shares SEND authority, so they can never drift
  (the spec's original goal, now structural). A member who may `:send` may
  `:attach`; nobody else. No new cap to grant, no participation-tier change.
- Handler `handle_attach/2`:
  1. resolve `session_ws = Ezagent.Capability.workspace_of(session_uri)`;
     `workspace_name = Ezagent.URI.workspace_name!(session_ws)` (raise — no
     silent default, closes the earlier #2 ws-binding finding by construction).
  2. `stored_name = "#{Ecto.UUID.generate()}-#{sanitize(filename)}"`;
     `uri = Ezagent.Uploads.store!(workspace_name, stored_name, quarantine_path)`
     (moves quarantine→live store under the SESSION ws; `FsResolver` rejects
     unsafe names before any byte).
  3. mint `grant = Phoenix.Token.sign(EzagentWeb.Endpoint, "world_attach",
     %{uri: URI.to_string(uri), caller: caller, session: session_uri})`.
  4. return `{:ok, %{uri: uri, grant: grant}}`.
- Pure-ish: the handler does a filesystem move + token sign; no slice mutation,
  so it adds no persistent session state (avoids the slice-bloat alternative of a
  `pending_attachments` map).

### Closing codex's findings, by construction

1. **#1 provenance / #2 ws-isolation** — gone: authorization IS the dispatch of
   `:session :attach`, so it runs the SAME chokepoint (provenance filter +
   `workspace_isolation_check` + required-cap resolution) as `:session :send`.
   There is no second predicate to drift.
2. **#3 client-URI laundering** — the signed **attach-grant** binds
   `uri ↔ caller ↔ session`. On `chat.send` the client sends `grants: [...]`
   (NOT raw URIs). `ConversationData.build_message/3` verifies each grant with
   `Phoenix.Token.verify(.., "world_attach", grant, max_age: …)` and checks
   `caller`/`session` match the sender + target before embedding the bound URI.
   A forged or cross-session `resource://…/uploads/…` has no valid grant → dropped.
3. **#4 file count** — `build_message/3` server-enforces `length(grants) ≤ 5`
   (and the controller pre-checks per request); neither trusts the client.
4. **#5 orphans** — (a) delete-on-reject: the controller removes the quarantine
   file whenever `:attach` returns `{:error, _}`, so an unauthorized upload
   commits zero bytes; (b) attached-but-never-sent: the grant has a `max_age`
   (e.g. 1h) and the committed file is swept by a bounded TTL GC over the uploads
   store (documented; the sweep is a follow-up, NOT a system principal — a plain
   `mix ezagent` maintenance task / scheduled job).
5. **#6 CSRF** — the route is in the existing `:browser` pipeline (CSRF token
   from the page, plumbed through `mountWorld` like `caller`); a size guard caps
   the multipart body before parse.

### Three-surface parity (LV / CLI / API — Allen's reminder)

Because attach is a real dispatch action, the SAME authorization is reachable
from: the web controller (above), a CLI `mix ezagent session attach <session>
<file>`, and any API caller issuing the `:session :attach` invocation. The web
controller is just the HTTP adapter in front of the one dispatch — exactly the
LV/CLI/API principle. (CLI/API adapters are thin and can land in this PR or a
fast follow; the dispatch action is the shared core.)

### Message render (download links) — unchanged from the draft

`ConversationData.message_row/2`: for a `resource://<ws>/uploads/<name>`
attachment, mint a signed `Ezagent.Uploads.DownloadToken` →
`/uploads/download?token=<t>` (the existing authed download route re-checks
participant at serve time, so minting does not widen access). Non-uploads URIs
render as plain text.

### Tests

- `handle_attach/2`: authorized member (holds `:send`) → file committed under the
  SESSION ws + valid grant returned; caller without `:send` → `{:error,
  :unauthorized}`, no commit; cross-workspace caller → denied by the same
  ws-isolation as `:send`; unsafe filename → rejected by `store!`.
- Controller: 200 + grant on authorized; 401 + quarantine deleted on unauthorized
  (assert the quarantine path no longer exists); 413 oversized; 422 bad params.
- `build_message/3`: valid grant → bound URI embedded; forged/altered grant →
  dropped; grant for a DIFFERENT session/caller → dropped; > 5 grants → refused.
- `message_row/2`: mints a download-token link for an uploads URI.
- agent-browser E2E (on the seeded home, `docs/guide/world-e2e-seed.md`): attach
  a file → chip appears → send → message shows a working download link.

### Ratchet + gates

Remove `validate_compose` + `cancel_upload` from `@pending_migration`
(current baseline 35 → 33; the spec's earlier "39→37" predates PR-3a's removals —
reconcile to 33). Per-PR gates: world+web suites, invariants (incl
`missing_cap_check_mutating_actions` — the new `:attach` MUST declare `caps:`),
arch.scan, doc.scan, p13, no-LV grep, vite build, agent-browser + frontend-design.

---

## codex review of Option B (2026-06-21) → revisions (the design to implement)

codex confirmed the architectural direction (authz through dispatch) and that
`store!/3` arg-order (#3) + download-token (#6) are genuinely CLOSED. It found
the rest needs these concrete fixes — folded in below as the binding design:

1. **[HIGH] `caps: [:send]` on `:attach` does NOTHING.** The runtime sets the
   *needed* action to the *dispatched* action name and `Capability.matches?`
   requires held-action == needed-action (no alias) — `kind/runtime.ex:468-476`,
   `capability/match.ex:34-37`. **FIX:** `:attach` declares **`caps: [:attach]`**
   (a real cap) AND `:attach` is added to the confirmed-member participation tier
   `@member_chat_actions` (`membership.ex:255` → `[:send, :leave, :attach]`), so a
   member who is granted `:send` at join is co-granted `:attach`. "Upload shares
   send authority" is now true by CO-GRANTING, not by a (non-functional) alias.
   Unconfirmed/anon members (read-only tier) get neither — correct.
2. **[HIGH→CLOSED-on-impl] dispatch gives provenance + ws-isolation + cap check**
   for free once `:attach` exists — `kind/runtime.ex:157-162,557-563,652-690`.
3. **[NEW-HOLE #4/#5] `store!/3` is `File.cp!`, not a move, and FS-I/O must not
   run in the Kind.** `uploads.ex:103-104`. **FIX:** the `:attach` HANDLER is a
   thin authorize-gate — it does NO filesystem I/O and NO slice mutation; merely
   reaching `handle_attach/2` means the chokepoint authorized the caller, so it
   returns `{:ok, %{ok: true}, []}`. The **controller** does the `store!` AFTER
   the `:ok` dispatch (in the web request process, never the session actor), then
   **always deletes the quarantine file** (success OR failure — `cp!` leaves it),
   in an `after`-style cleanup. On `{:error, _}` the controller deletes quarantine
   and returns 403, committing zero bytes.
4. **[#7 replay] same-caller/same-session grant replay is ACCEPTED** (documented):
   the grant binds `uri/caller/session` with a `max_age`; a caller replaying their
   own grant only re-attaches their own file — harmless. Cross-caller/cross-session
   is blocked by the binding. No nonce/jti ledger (keeps it stateless, no table).
5. **[#8 size guard] cap the multipart body at the PARSER layer**, not the
   controller/router — `Plug.Parsers` runs in `endpoint.ex:79-87` before the
   pipeline. **FIX:** the upload route uses a scoped parser with a `:length`
   limit (≈11 MB to cover one 10 MB file + overhead); the controller additionally
   rejects any single entry > 10 MB and > 5 entries. CSRF still applies (route in
   `:browser`).

### Net file touch-list

- `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` — `action(:attach,
  caps: [:attach], modes: [:call], ...)` + `handle_attach/2` (thin gate).
- `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` —
  `@member_chat_actions` += `:attach`.
- `apps/ezagent_web/lib/ezagent_web/controllers/world_uploads_controller.ex` (new)
  + route (scoped parser `:length`) in `router.ex`.
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex` —
  `build_message/3` verifies grants → embeds bound URIs (≤5); `message_row/2`
  mints download-token links for `resource://…/uploads/…`.
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` + `main.tsx`
  — paperclip + hidden file input, FormData POST with CSRF, pending chips (✕ =
  client-only `cancel_upload` parity), pre-flight validate (`validate_compose`).
- Tests as listed above; ratchet 35 → 33.
