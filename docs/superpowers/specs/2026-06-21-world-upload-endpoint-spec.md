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
