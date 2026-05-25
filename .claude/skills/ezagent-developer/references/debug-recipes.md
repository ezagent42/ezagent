# Debug recipes (symptom-first)

When you encounter a problem in ezagent, start here. Symptoms are listed in roughly the order Allen has hit them historically — most common first.

## Symptom: message disappeared / silent drop

In order of likelihood:

1. **URI shape mismatch — non-canonical input.** Per SPEC v3 §5.15, per-tenant schemes use 3-segment authority `<scheme>://<type>/<workspace>/<name>`. 2-segment forms (`entity://user/admin`, `session://default/main`) RAISE at parse time. Check the URI string at the call site — it must be `entity://user/default/admin`, not `entity://user/admin`.
2. **Channel notification meta has non-string value** (Decision #132). Grep `meta = ...` in your push path; ensure every value is `String.t()`. Run `apps/ezagent_domain_chat/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings".
3. **Cap shape mismatch on `behavior`** (invariant 2). Check via `:rpc` that `Capability.matches?/2` returns true for the user's cap + the action's needed cap. Common error: cap struct has `behavior: :chat` (atom) while needed has `behavior: Ezagent.Behavior.Chat` (module).
4. **Workspace scope not plumbed** (invariant 4). Check `WorkspaceRegistry.lookup(session_uri)` returns `{:ok, _}` for the session involved. If `:error`, the session was spawned without `bind` (custom Template Class missed step 3 of how-to add a Template Class).
5. **Inbound transport using `:cast`** (Decision #134). For Feishu/Slack/etc inbound, verify the dispatch uses `mode: :call` and decomposes the result.
6. **Action syntax wrong** — per SPEC v2 §5.2, actions use query string `?action=behavior.action`. Old path-style `/behavior/X/Y` is removed (PR #146); if anything still constructs it, dispatch silently misses.

## Symptom: `:unauthorized` despite cap granted

1. Check the user's User Kind is **alive** (in-memory state). `Ezagent.Identity.list_caps_for/1` returns `MapSet.new()` if the Kind isn't spawned. The canonical user URI is `entity://user/<workspace>/admin` — spawn via `Ezagent.SpawnRegistry.spawn(uri)` if needed.
2. Verify cap struct shape (invariant 2 — module vs atom on `behavior`).
3. For scope-tuple caps, verify the scope dimension matches the needed action's context — e.g. `{:within_session, A}` won't match an action targeted at session B (Decision #137).
4. For `{:spawned_by, _}` caps: until PR 40 ships the lineage registry, this shape returns false (deny-by-default placeholder, Decision #137 forensic note).
5. **PR-CC-2-v2 chokepoint** (2026-05-25): cap check is now in dispatch step 5.5 via `Kind.holds_cap?/2` consulting `Behavior.required_caps/0`. If the Behavior doesn't declare `required_caps/0` for the action, dispatch defaults to deny. Check the Behavior module has the callback implemented + the action is listed.
6. SQL spot-check: `select * from caps where principal_uri = 'entity://user/default/admin' and behavior = 'Elixir.Ezagent.Behavior.Chat'` — `behavior` column stores the module's string form, not the atom shorthand.

## Symptom: `:cross_workspace_denied` (distinct from `:unauthorized`)

Dispatch step 5.6 (Phase 9) rejected the call because caller workspace ≠ target workspace AND none of the 4 cross-workspace overrides applied (cross-workspace cap, system caller, system target, system workspace member). Check:

1. Are caller + target in the same workspace? `Ezagent.Capability.workspace_of/1` on both URIs.
2. Is the target a system-scope entity? (e.g. `system://routing/default` — these are cross-cutting and accept any caller workspace.)
3. Should the caller hold a cross-workspace cap (`workspace_uri: :any`)? Grant via the workspace admin LV / CLI.
4. Should the caller be a `workspace://system` member? (Keycloak realm-admin model.) See SPEC v3 §13.1.

## Symptom: orphan node sidecar after phx restart

The sidecar's `process.stdin.on('end', ...)` handler may have been refactored away. Run `apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs --include slow` — the integration test spawns + kills + asserts the OS pid dies within 3s. If it fails, restore the EOF handler in `apps/ezagent_plugin_feishu/priv/ws_sidecar/main.js`.

## Symptom: workspace-scoped routing rule never fires

Check that `WorkspaceRegistry.lookup(session_uri)` returns `{:ok, workspace_uri}` for the session the message originated in. If `:error`, the session is unbound — workspace_uri opt to Resolver will be `nil` → rule with `workspace_uri: <something>` won't match (Decision #135 + SPEC v2 §5.4).

## Symptom: session-scoped routing rule never fires

New shape per SPEC v2 §5.4 + S-10: `routing_rules.session_uri` column. Check `RuleStore` evaluation iterates global + workspace_uri + session_uri layers. If a fork's session-scoped rules disappeared, check `Ezagent.Entity.Session.spawn_from_template/2` replays the template's routing_rules under the new session_uri (S-10 fix).

## Symptom: SessionTemplate fork lost lineage

Check `parent_template_uri` field on the new template. If `nil`, the fork code path didn't preserve it — `Ezagent.Entity.SessionTemplate.fork/2` MUST set `parent_template_uri = parent_uri@hash` (the specific source hash). CI gate: `template_fork_lineage_test.exs`.

## Symptom: SchemeRegistry parse error on a previously-working URI

Per SPEC v2 §5.6 + PR #147: `Ezagent.URI.SchemeRegistry` is the runtime ETS source of truth, fed by `SpawnRegistry.register/2`. If a URI parses fine in isolation but fails inside `Ezagent.URI.parse!/1`, the scheme isn't registered yet (boot-order issue) or the URI uses a deleted scheme (`user://`, `agent://`, `message://`, `feishu://`, `routing-admin://`, `pty-input://`).

## Symptom: audit log query returns rows from other workspaces

Likely caller of the audit table forgot to wrap query in `Ezagent.Persistence.scope_by_workspace/2`. The `per_tenant_tables_have_workspace_column_test.exs` invariant gates the SCHEMA but doesn't gate every READ site. Check the calling LV or context module derives `workspace_filter` from the current session/caller and passes it to the query (canonical pattern: `EzagentPluginLiveview.ObservabilityLive.workspace_filter_for/1`).
