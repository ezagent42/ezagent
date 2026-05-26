# CLI / GUI Parity + Identity Audit — 2026-05-24

Auditor: read-only audit of `apps/ezagent_cli/`, `apps/ezagent_plugin_liveview/`,
`apps/ezagent_web/lib/ezagent_web/controllers/`, and all `apps/*/lib/mix/tasks/*.ex`.
Skill context: `ezagent-developer` principles P1, P3, P5, P9, P14, P15.

---

## Summary verdict

**Pass-with-caveats.** Two CLI surfaces exist and the post-Phase-5 second pivot (`mix ezagent` as
distributed-Erlang RPC into the runtime BEAM — Decision Log #130, locked by
`apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs`) is structurally sound.
Any LV-callable Behavior `@interface` action is reachable via `mix ezagent <kind> <action>` in the
same BEAM, with the same `Ezagent.Invocation.dispatch/1` path, capability checks, audit
telemetry, and ReadyGate. **The same-source-derivation principle holds for the auto-derived CLI
surface.**

But two material gaps exist:

1. **`mix ezagent` cannot perform several user-facing GUI actions** — they live behind LV-only
   "facade" code paths that call private domain APIs (`Ezagent.Users.create`,
   `Ezagent.Workspace.add_member`, `Ezagent.Entity.Profile.upsert`,
   `Ezagent.AppSettings.put`, `Ezagent.Workspace.create`) rather than dispatchable actions, so
   they neither auto-appear in the `mix ezagent` tree nor have facade ops registered in
   `EzagentCli.FacadeRegistry`. Only ONE facade op is registered today: `:workspace, :create`
   (`apps/ezagent_cli/lib/ezagent_cli/application.ex:23`).
2. **The legacy `mix ezagent.*` tasks (16 of them) coexist with `mix ezagent` and diverge from the
   LV path** — they `Application.ensure_all_started` the umbrella locally and then write
   directly to a `Store`/`Registry` (no dispatch, no caps, no audit, no caller). This violates
   P14 (dispatch is the only path) at the operator entry point and means the same operation
   (e.g. "add routing rule") leaves different audit fingerprints depending on whether the
   operator clicked LV or ran the legacy task.

Identity is correctly URI-canonical (P5) — `EZAGENT_USER_TOKEN` + `EZAGENT_ENTITY_URI`
authenticate against `entity_tokens` and set `ctx.caller` to the resolved entity URI. The
`--as <uri>` impersonation flag is correctly env-gated (`EZAGENT_CLI_ALLOW_AS=1`) per P2 (no
silent admin fallback). However the **token-less fallback to admin caps** in
`EzagentCli.Dispatch.derive_caller/1` (`dispatch.ex:135`) is a P2 violation when the runtime
is exposed beyond a single-operator dev box.

---

## Section 1 — Feature parity matrix

LV `handle_event` actions across the 22 LV modules, mapped to the CLI surface. "Auto" = goes
through `mix ezagent <kind> <action>` via `Ezagent.BehaviorRegistry` auto-derivation; "Facade" =
registered in `EzagentCli.FacadeRegistry`; "Legacy" = standalone `mix ezagent.*` task; "—" =
not reachable from any CLI.

### Conversation / messaging

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Send chat message (text + attachments + mentions) | `admin_live.ex:258` chat_compose | `mix ezagent session send --session <name> --message <…>` (auto via `Behavior.Chat.@interface[:send]`) | ⚠️ partial — CLI has no file-upload primitive; `--message` carries text only. Attachments would need a `resource://` upload facade that does not exist. |
| Mark message displayed | `admin_live.ex:311` mark_displayed | — | ❌ GUI-only (`Ezagent.Chat.ReadMarker.mark/4` is a direct module call from LV; no Behavior, no Facade) |
| Switch active session in chat panel | `admin_live.ex:323` switch_session | n/a (UI-only navigation; not an ESR mutation) | n/a |
| Create session (short_name) | `admin_live.ex:334` create_session | `mix ezagent session create <name>` is NOT registered; closest is `mix ezagent session join` (auto from `Chat.@interface[:join]`). | ❌ no CLI; LV calls `EzagentDomainChat.create_session/3` directly — bypasses dispatch (P14 violation in BOTH surfaces). |
| Invite member to session | `admin_live.ex:430` invite_member | `mix ezagent session join --session <…> --member <uri>` (auto from `Chat.@interface[:join]`) — invariant test uses this exact path | ✅ |
| Switch session view (chat/terminal) | `admin_live.ex:372` switch_view | n/a (UI-only) | n/a |
| Switch active PTY agent | `admin_live.ex:394` switch_to_pty_for_agent | n/a (UI-only) | n/a |
| Load older messages (pagination) | `admin_live.ex:690` load_older_messages | n/a (UI-only) | n/a |
| Add session-scoped routing rule | `admin_live.ex:623` routing_rule_add_session | — | ❌ legacy `mix ezagent.routing.add_rule` exists but targets the GLOBAL table only; no `--session` scope flag, and it bypasses dispatch entirely. |

### Workspaces

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Create workspace | `workspaces_live.ex:74` create_workspace | `mix ezagent workspace create <name>` (Facade — only facade op registered today) | ✅ Same source: both call `Ezagent.Workspace.create/2`. |
| Add workspace member | `workspace_detail_live.ex:136` add_member | — | ❌ no CLI; LV calls `Ezagent.Workspace.add_member/2` directly. |
| Remove workspace member | `workspace_detail_live.ex:273` remove_member | — | ❌ no CLI |
| Add template to workspace | `workspace_detail_live.ex:218` add_template | — | ❌ no CLI; LV calls `Ezagent.Workspace.add_template/3` directly. This is the path `AgentNewLive` uses, so it's load-bearing. |
| Remove template from workspace | `workspace_detail_live.ex:255` remove_template | — | ❌ no CLI |
| Select template class (form picker) | `workspace_detail_live.ex:188` | n/a (UI-only) | n/a |

### Identities (users + agents + caps)

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Create user (handle, password, caps, display_name) | `users_live.ex:91` create_user | `mix ezagent.user.create <uri> --password … --caps …` (legacy, bypasses dispatch) | ⚠️ same `Ezagent.Users.create/3` underlying function (same-source ✓); LV adds display_name upsert + spawn — legacy task spawns but does NOT upsert display name. Diverged behavior. |
| Set user password | `users_live.ex:181` set_password | `mix ezagent.user.set_password <uri> --password <pw>` (legacy) | ✅ Both call `Ezagent.Users.set_password/2`. |
| Edit display name (inline) | `users_live.ex:152` save_display_name | — | ❌ no CLI; LV calls `Ezagent.Entity.Profile.upsert/1` directly. |
| Promote user to `workspace://system` | `users_live.ex:211` promote_to_system | — | ❌ no CLI |
| Revoke user from `workspace://system` | `users_live.ex:229` revoke_system | — | ❌ no CLI |
| Grant cap to entity (user or agent) | `entity_caps_live.ex:112` grant | — | ❌ no CLI. LV moduledoc admits "No dedicated mix task exists for grant/revoke today — this LV is the canonical operator surface" (`entity_caps_live.ex:30`). LV dispatches via `Behavior.Identity.@interface[:grant_cap]` so `mix ezagent entity grant_cap …` is reachable in principle — but `entity` Kind is not in `BehaviorRegistry` under that type_name (it's `user`/`agent` sub-types). Untested. |
| Revoke cap from entity | `entity_caps_live.ex:129` revoke | — | ❌ same as grant |
| Create agent (flavor, name, caps, cwd, with_pty) | `agent_new_live.ex:143` create_agent | `mix ezagent.agent.create <uri> --caps …` (legacy) | ⚠️ DIVERGED PATHS. LV uses `Ezagent.Workspace.add_template + invoke_template_now` (the V1-fix path that instantiates BOTH the Agent Kind AND the PtyServer). Legacy task uses `Ezagent.SpawnRegistry.spawn + Ezagent.Identity.grant_cap` (no template, no PTY sidecar). cc-flavor agents created via CLI will NOT have a PTY. |
| Restart agent | `agent_detail_live.ex:133` restart | `mix ezagent agent terminate --agent <name>` (auto from `Behavior.Lifecycle.@interface[:terminate]`) | ✅ Auto-derived; same dispatch path. |
| PTY input (xterm keystroke) | `agent_detail_live.ex:194` / `terminal_live.ex:136` pty_input | `mix ezagent agent write --agent <…> --bytes <…>` (auto from `Behavior.Pty.@interface`, if registered as such) | ⚠️ Untested but mechanically reachable via auto-derivation. |
| Toggle agent extension | `agent_extensions_live.ex:199` toggle | `mix ezagent template invoke_extension` (auto, if extension toggle is a Behavior action) | ⚠️ Untested but mechanically reachable. |

### Routing

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Add routing rule (form mode + JSON mode) | `routing_live.ex:159` add_rule | `mix ezagent.routing.add_rule <Table> <matcher> receivers:<…>` (legacy) | ❌ DIVERGED PATHS. LV calls `Ezagent.Invocation.dispatch(system://routing/default?action=routing.add_rule)` (P14-compliant — CapBAC + audit + cross-workspace check). Legacy task calls `Ezagent.Routing.RuleStore.add/4` directly (NO dispatch, NO cap check, NO audit, `created_by: nil`). This is a P14 + P15 violation at the operator entry point. |
| Delete / disable / enable rule | `routing_live.ex:246/249/252` | — | ❌ no CLI for delete/disable/enable |
| Switch table (UI) | `routing_live.ex:140` switch_table | n/a | n/a |

### Feishu plugin

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Bind feishu open_id → user URI | `feishu_bindings_live.ex:90` bind | `mix ezagent.feishu.bind <open_id> <user_uri> [--admin <uri>]` (legacy) | ✅ Both call `EzagentPluginFeishu.UserBinding.bind/3` + `BindingPolicy.apply/2`. Same source. |
| Unbind feishu open_id | `feishu_bindings_live.ex:143` unbind | `mix ezagent.feishu.unbind <open_id>` | ✅ |
| Bind feishu chat_id → session URI | `feishu_bindings_live.ex:163` bind_session | `mix ezagent.feishu.chat.bind <chat_id> <session_uri>` | ✅ |
| Unbind feishu chat_id | `feishu_bindings_live.ex:229` unbind_session | `mix ezagent.feishu.chat.unbind <chat_id>` | ✅ |
| Unbind feishu chat from admin chat panel | `admin_live.ex:523` unbind_feishu_chat | (covered above) | ✅ |

### Snapshots / observability / admin

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Dump snapshot | `snapshots_live.ex:49` dump | `mix ezagent.snapshot.dump <uri>` (legacy) | ✅ Both read `Ezagent.Ecto.KindSnapshot` directly (read-only, no dispatch needed). |
| List snapshots | (none — auto on mount) | `mix ezagent.snapshot.list` (legacy) | ✅ |
| Clear snapshot | `snapshots_live.ex:82` clear | `mix ezagent.snapshot.clear <uri>` (legacy) | ⚠️ Both call `Ezagent.Ecto.KindSnapshot.delete/1` directly. Destructive — should arguably be a Behavior so caps gate it. |
| Filter audit | `admin_authz_audit_live.ex:122` filter | n/a (UI-only filter on PubSub stream) | n/a |
| Filter caps registry | `admin_caps_live.ex:58` filter | n/a (UI-only filter) | n/a |
| Switch observability tab | `observability_live.ex:63` switch_tab | n/a (UI-only) | n/a |

### Settings (admin-scope SMTP + registration)

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Save SMTP config | `settings_live.ex:75` save_smtp | — | ❌ no CLI (LV calls `Ezagent.AppSettings.put("smtp_config", …)` directly) |
| Send test email | `settings_live.ex:104` send_test_email | `mix ezagent.auth.magic_link <email>` (legacy — operator debug tool, NOT identical) | ⚠️ Mirrors the silent-drop branches per P27 but the LV "test email" path uses `EzagentWeb.Mailer.deliver_magic_link` to a single recipient on-demand; the CLI mirrors the magic-link decision logic instead. Different intent, similar surface. |
| Save registration domains | `settings_live.ex:143` save_registration_domains | — | ❌ no CLI |

### Profile (per-user)

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| Edit own display name | `profile_live.ex:46` save_display_name | — | ❌ no CLI |

### Plugin discovery (no GUI mutations, mentioned for completeness)

| GUI action | Where | CLI command | Parity |
|---|---|---|---|
| List installed plugins (read-only) | `plugins_live.ex` mount | n/a | n/a |
| Hot-install plugin | NONE (no LV surface) | `mix ezagent.plugin.install <path>` (legacy) | CLI-only by design (operator op) |

### Auth (controllers, not LV)

| HTTP action | Where | CLI command | Parity |
|---|---|---|---|
| Magic-link request | `session_controller.ex:94` create | `mix ezagent.auth.magic_link <email>` (legacy) | ⚠️ CLI is intentionally NOT anti-enumeration (operator debug tool with explicit logging); HTTP path IS anti-enumeration per P27. Same underlying `EzagentWeb.Mailer.deliver_magic_link/2`. Intentional divergence. |
| Credential login (entity_uri + secret) | `session_controller.ex:125` credentials_create | — | ❌ no CLI |
| Logout | `session_controller.ex:161` delete | — | ❌ no CLI (n/a — CLI session is its rpc.call, no persistent login) |
| Mint bearer token for entity | n/a (no LV — admin must use CLI) | `mix ezagent.user.token <entity_uri> --mint [--label …]` | CLI-only by design (admin op) |
| Revoke bearer token | n/a | `mix ezagent.user.token <entity_uri> --revoke <id>` | CLI-only |
| List entity tokens | n/a | `mix ezagent.user.token <entity_uri> --list` | CLI-only |
| Onboarding (workspace join/create) | `onboarding_controller.ex:80` submit | — | ❌ no CLI (browser-only first-login flow) |
| Workspace switch | `workspace_switch_controller.ex:29` switch | n/a (browser-only) | n/a |
| `/api/v1/:kind/:action` invoke | `api_v1_controller.ex:46` invoke | `mix ezagent <kind> <action>` — same dispatch path, both go through `Ezagent.BehaviorRegistry` + `Ezagent.Invocation.dispatch` | ✅ ✅ HTTP API and `mix ezagent` are structurally isomorphic — both are thin "parse + caller-resolve + dispatch" shells. |

### Bootstrap / install / DB ops (operator-only, no GUI)

| CLI command | Notes |
|---|---|
| `mix ezagent.bootstrap` | one-shot install — `home.init + ecto.migrate + healthcheck`. CLI-only by design. |
| `mix ezagent.home.init` | `EZAGENT_HOME` skeleton. CLI-only. |
| `mix ezagent.home.adopt_db` | repo-root → `$EZAGENT_HOME` DB move. CLI-only. |
| `mix ezagent.db.reset` | destructive DB rebuild. CLI-only. |
| `mix ezagent.check_invariants` | greps source for 8-invariant violations. CLI-only (dev-loop tool). |
| `mix ezagent.stress` | V1 acceptance stress driver. CLI-only (measurement tool). |
| `mix ezagent.plugin.install <path>` | hot-load OTP plugin into running runtime. CLI-only by design. |

---

## Section 2 — CLI identity handling

Three distinct patterns coexist:

### Pattern A — `mix ezagent` (auto-derived + facade) — token + entity URI

`apps/ezagent_cli/lib/mix/tasks/ezagent.ex:37-78` extracts `--token` (or `EZAGENT_USER_TOKEN`)
and `--uri` (or `EZAGENT_ENTITY_URI`) from argv/env, calls
`Ezagent.Runtime.connect_as_cli/0` to reach the runtime BEAM via distributed-Erlang RPC, and
`:rpc.call`s `EzagentCli.Exec.exec/2` with the credentials.

Server-side, `apps/ezagent_cli/lib/ezagent_cli/exec.ex:43-67` calls
`resolve_caller(token, entity_uri)`:

- both nil → `{:ok, nil, nil}` → admin fallback in `Dispatch.derive_caller`
- token without entity_uri → `{:error, :missing_entity_uri}` → exit 4
- both present → `Ezagent.Entity.authenticate(uri, token)` → `{:ok, caller_uri, caps}` or
  `{:error, :invalid_token}` → exit 4

The `(caller_uri, caps)` pair is stashed in process dict
(`:ezagent_cli_caller_override`) so every dispatch in the same RPC pid picks it up via
`EzagentCli.Dispatch.derive_caller/1` (`dispatch.ex:124-144`).

**This pattern is correct.** UUID-/URI-canonical per P5. Token verify is hash-compared against
`entity_tokens` per `Ezagent.Entity.authenticate/2`. Caps come from the live Kind via
authenticate, not from a CLI-side claim.

### Pattern B — `mix ezagent` token-less fallback (anti-pattern per P2)

`apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:135`:

```elixir
case Map.get(options, :as) do
  nil ->
    {Ezagent.Entity.User.admin_uri(), Ezagent.Entity.User.admin_caps()}
  ...
end
```

When no token is presented AND `--as` is not used, the CLI silently dispatches as
**`entity://user/system/admin` with admin caps**. The moduledoc calls this "BC for single-user
installs" — but a single-machine assumption (per Decision Log #130) does not justify a silent
admin fallback. If the runtime is reachable on Tailscale (any deployment beyond
`127.0.0.1`-only loopback), any caller with `EZAGENT_RUNTIME_NODE` set and the cookie file
gets admin caps with zero authentication.

**This is the largest production-readiness gap in the CLI surface.** It violates P2 (let it
crash; no silent fallbacks) and contradicts the
`feedback_let_it_crash_no_workarounds` memory.

Note `api_v1_controller.ex:160-167` (PR #123 hardening) already removed the equivalent
admin-fallback for HTTP — anonymous `/api/v1` calls now fail-fast with
`401 missing_token`. The CLI surface has not yet been hardened to match.

### Pattern C — Legacy `mix ezagent.*` tasks (no identity at all)

The 16 legacy `mix ezagent.*` tasks run in their own BEAM
(`Application.ensure_all_started(:ezagent_*)` at task start), don't reach the runtime via RPC,
and don't construct an `%Invocation{}` — they call domain modules directly (`Ezagent.Users.create`,
`Ezagent.Workspace.add_template`, `RuleStore.add`, `UserBinding.bind`, etc).

Effect: every legacy task is implicitly running as "no caller" / "admin-equivalent" — the
underlying domain functions have no cap-check parameter to enforce against. They use
`Ezagent.Entity.User.admin_uri()` as the cap-parser principal
(`apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.create.ex:74`) and as the `bound_by`
field (`ezagent.feishu.bind.ex:36` defaults `--admin entity://user/system/admin`).

**This is a P14 violation by design** — these tasks predate the Phase-5-second-pivot CLI ↔ LV
isomorphism. They should be migrated to `mix ezagent` facade ops (where the operation is not yet
a Behavior action) or to auto-derived `mix ezagent <kind> <action>` (where it is).

---

## Section 3 — Identity switching / sudo

### `--as <user_uri>` flag

`apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:138-143`:

```elixir
as_str ->
  case System.get_env("EZAGENT_CLI_ALLOW_AS") do
    "1" -> derive_other_user(as_str)
    _ -> {:error, :as_not_allowed}
  end
```

The flag is **correctly gated** behind `EZAGENT_CLI_ALLOW_AS=1` per Phase 4 spec Q-F and
`feedback_let_it_crash_no_workarounds`. Default-deny.

When enabled, `derive_other_user/1` (dispatch.ex:146-155) parses the URI string and looks up
caps directly via `KindRegistry.lookup(uri) + :sys.get_state(pid).state.identity.caps`. This
is documented as a dev-only multi-user testing tool, NOT a production sudo mechanism — there
is no authorization check (any operator with `EZAGENT_CLI_ALLOW_AS=1` can impersonate any
URI). The `--as` is intended ONLY for `MIX_ENV=test` / dev-loop, never on a running
production runtime.

**Adequate as designed.** The env-gate is the entire safety property — operators who set it
to `1` on a production runtime own the consequences.

### No production sudo mechanism

There is NO concept of "admin runs as another user with audit trail." If admin needs to
perform an action as `entity://user/default/allen`, the only paths are:

1. Mint a token for allen (`mix ezagent.user.token entity://user/default/allen --mint`) and
   use that token. Allen is now indistinguishable from admin-doing-as-allen in the audit log.
2. Set `EZAGENT_CLI_ALLOW_AS=1` (dev-only).

If production sudo is ever required, it should be modeled as a Behavior action on a
`system://` Kind with a cap check + audit trail — never a new env flag.

---

## Section 4 — Same-source-derivation compliance

Tested 3 representative actions:

### Action: invite_member to session

- **LV path** (`admin_live.ex:430-512`): user submits the invite-modal form →
  `Ezagent.UI.UriOptions.valid_for?/4` revalidates the URI →
  `Ezagent.Invocation.dispatch(%Invocation{target: <session_uri>?action=chat.join, mode: :cast, args: %{member: uri}, ctx: %{caller: caller_uri, caps: caller_caps, …}})`.
- **CLI path** (`mix ezagent session join --session foo --member entity://agent/default/cc_x --cast`):
  `Mix.Tasks.Esr` → `:rpc.call` → `EzagentCli.Exec.exec(["session","join", …], opts)` →
  `EzagentCli.Dispatch.run_action(Session, Chat, :join, parsed)` → builds the same
  `%Invocation{target: session://default/default/foo?action=chat.join, mode: :cast, args: %{member: …}, ctx: %{caller: <resolved from token>, caps: <resolved from token>, …}}` → `Ezagent.Invocation.dispatch/1`.
- **Same source?** ✅ Both produce structurally-equivalent invocations that hit the same
  dispatch step 5.5 (CapBAC), step 5.6 (cross-workspace), step 6 (`Chat.invoke(:join, …)`).
  Pinned by `cli_lv_same_server_invariant_test.exs`.

### Action: create_workspace

- **LV path** (`workspaces_live.ex:74-89`): form submit → `Ezagent.Workspace.create(name, %{})`
  → `Store.create` + `spawn_workspace` (NO dispatch — direct domain call).
- **CLI path** (`mix ezagent workspace create <name>`): `EzagentCli.FacadeRegistry` op
  `:workspace, :create` → `workspace_create_facade/1` in
  `apps/ezagent_cli/lib/ezagent_cli/application.ex:32` → `Ezagent.Workspace.create(name, %{members: members})`.
- **Same source?** ✅ Both call the same `Ezagent.Workspace.create/2` function. NO dispatch
  on either side — both bypass CapBAC. That's a separate problem (`workspace.create` is not a
  Behavior; creating a workspace today does not check whether the caller is authorized).
  Same-source ✓; arch ⚠️.

### Action: add routing rule

- **LV path** (`routing_live.ex:159-244`): form submit → `revalidate_matcher_arg` +
  `revalidate_receivers` (server-side URI revalidation) →
  `dispatch_routing_admin(socket, :add_rule, …)` →
  `Ezagent.Invocation.dispatch(%Invocation{target: system://routing/default?action=routing.add_rule, mode: :call, args: %{table:, matcher_json:, receivers:}, ctx: %{caller: caller_uri, caps: caller_caps, …}})`.
  Step 5.5 enforces routing cap; step 5.6 enforces cross-workspace; receiver is the System
  Kind which calls `RuleStore.add/4` with `created_by: caller_uri` for audit.
- **CLI path** (`mix ezagent.routing.add_rule <Table> <matcher> receivers:<…>`):
  `apps/ezagent_core/lib/mix/tasks/ezagent.routing.add_rule.ex:48-58` →
  `RuleStore.add(table, matcher, receivers, nil)` + `RuleStore.load_into_registry(table)`.
  NO dispatch. NO cap check. NO cross-workspace check. `created_by: nil`. The legacy task's
  own moduledoc admits: `"created_by = nil for CLI; LV form will pass admin URI"`.
- **Same source?** ❌ DIVERGED. Same underlying `RuleStore.add` write at the bottom, but the
  LV path runs through 3 cross-cutting concerns (cap, workspace, audit) that the legacy task
  silently bypasses. A `mix ezagent` equivalent does not exist for this operation. This is one of
  the clearest P14/P15 holes in the operator surface.

---

## Section 5 — Findings

### Finding 1 — Token-less `mix ezagent` falls back to admin caps (HIGH)

- Severity: HIGH
- What: `EzagentCli.Dispatch.derive_caller/1` silently returns `User.admin_uri()` +
  `admin_caps()` when no token is presented and `--as` is unused.
- Where: `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:135`
- Why it matters: violates P2 (no silent admin fallback) and contradicts the PR #123 hardening
  that closed the same hole on `/api/v1`. Anyone who can `Node.connect` to the runtime (i.e.
  has the cookie file) gets admin caps. The "single-machine assumption" in Decision Log #130
  is a deployment constraint, not a security mitigation.
- Recommendation: change `derive_caller/1` to refuse the call (`{:error, :missing_token}`)
  when no token is presented AND `--as` is not used. Match the
  `api_v1_controller.ex:165-167` failure mode (clear stderr explaining how to mint a token).
  Add a `EZAGENT_CLI_ALLOW_ANON_ADMIN=1` opt-in env (off by default) ONLY if a transition
  period is needed for `mix ezagent.bootstrap`-style local install scripts.

### Finding 2 — Legacy `mix ezagent.*` tasks bypass dispatch (HIGH)

- Severity: HIGH
- What: 16 of the 17 mix tasks call domain modules directly instead of constructing an
  Invocation, bypassing P14 (dispatch is the only path), P15 (CapBAC), and the audit pipeline.
- Where: every `apps/*/lib/mix/tasks/ezagent.*.ex` except `apps/ezagent_cli/lib/mix/tasks/ezagent.ex`
  (the `mix ezagent` shell itself).
- Why it matters: same operation has different audit trails depending on the operator
  surface; the routing-add-rule case is the clearest example (LV ⇒ `created_by:
  caller_uri`; legacy task ⇒ `created_by: nil`). Operators running tasks on prod produce
  audit gaps. Also violates the IMPLEMENTATION_ROADMAP §1.3 invariant 9 "CLI ↔ LV 同 BEAM"
  for the legacy surface (these tasks DO run in a separate BEAM — they don't even reach the
  runtime).
- Recommendation: classify each legacy task:
  - **Pure operator/install ops** (`bootstrap`, `home.init`, `home.adopt_db`, `db.reset`,
    `check_invariants`, `stress`, `plugin.install`) — keep as standalone tasks; they
    legitimately can't go through the runtime (they install/repair the runtime itself).
    Document this carve-out in CLI README.
  - **Identity/Workspace/Routing/Feishu ops** (`user.create`, `user.set_password`,
    `user.token`, `agent.create`, `routing.add_rule`, `feishu.*`) — migrate to either
    auto-derived `mix ezagent` actions (register the underlying op as a Behavior on the
    appropriate Kind) or `FacadeRegistry` ops where the op is a constructor. Then `deprecate`
    the legacy task with a "use `mix ezagent <…>` instead" message.
  - **Snapshot ops** (`snapshot.list/dump/clear`) — `dump`/`list` are read-only and OK as-is;
    `clear` is destructive and should become a Behavior on a `system://snapshots` Kind so cap
    gates it.

### Finding 3 — `mix ezagent` cannot perform many user-facing GUI actions (MED)

- Severity: MED
- What: ~12 LV `handle_event`s have no `mix ezagent` equivalent because their underlying domain
  function is not a Behavior action AND there is no `FacadeRegistry` op for it. The full list
  is in Section 1: `mark_displayed`, `create_session`, `add_member`/`remove_member`,
  `add_template`/`remove_template`, `save_display_name`, `promote_to_system`/`revoke_system`,
  `save_smtp`/`save_registration_domains`, `routing_rule_add_session`,
  `delete_rule`/`disable_rule`/`enable_rule`. Plus identity grant/revoke, which the LV
  moduledoc explicitly admits has no CLI today.
- Where: see matrix above.
- Why it matters: violates the IMPLEMENTATION_ROADMAP §1.3 invariant 9 / ARCHITECTURE
  Decision Log #130 ("any LV-callable action MUST be CLI-callable in the same BEAM"). The
  invariant test `cli_lv_same_server_invariant_test.exs` only checks ONE action
  (`session join`) — it does not enumerate every LV handle_event.
- Recommendation: write a stricter invariant test that walks
  `Ezagent.BehaviorRegistry.list_all/0` AND every LV handler's underlying Domain call, and
  asserts each has either (a) an auto-derived `mix ezagent <kind> <action>` path OR (b) a
  registered `EzagentCli.FacadeRegistry` op. Filing a "GUI-only handler" as expected requires
  an explicit exemption list in the test (so additions surface in code review). This matches
  the `feedback_completion_requires_invariant_test` pattern.

### Finding 4 — `agent.create` LV path and CLI path diverge structurally (MED)

- Severity: MED
- What: LV `agent_new_live.ex:143` uses `Ezagent.Workspace.add_template → invoke_template_now`
  (instantiates Agent Kind AND PtyServer sidecar). Legacy `mix ezagent.agent.create` uses
  `Ezagent.SpawnRegistry.spawn + Ezagent.Identity.grant_cap` (no Template, no PtyServer).
- Where: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex:249-292`
  vs `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.agent.create.ex:144-153`.
- Why it matters: A cc-flavored agent created via CLI **will not have a PTY** and won't be
  usable for cc.agent terminal interaction. This is a same-source-derivation violation:
  identical operator intent ("create cc agent") produces two different runtime states.
- Recommendation: rewrite `mix ezagent.agent.create` to go through
  `Ezagent.Workspace.add_template` (matching LV), or migrate both to a `FacadeRegistry`-
  registered op that runs the same code path.

### Finding 5 — `workspace.create` bypasses CapBAC on both surfaces (LOW)

- Severity: LOW (intentional — workspace is currently considered a self-service operation)
- What: Both `mix ezagent workspace create` and LV's `workspaces_live.ex:74` call
  `Ezagent.Workspace.create/2` directly without dispatch. Anyone with CLI access (or LV
  access) can create a workspace.
- Where: `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:62`
- Why it matters: this is consistent across surfaces (same-source ✓) but does not enforce
  caps. Onboarding controller has the same property (`onboarding_controller.ex:180`). If
  workspace creation should ever be cap-gated (e.g. only system-workspace members can create
  workspaces), it must become a Behavior on a `system://workspaces` or `workspace://system`
  Kind.
- Recommendation: defer until workspace-creation policy is decided; the invariant
  property to preserve is "LV and CLI behave identically." That property currently holds.

### Finding 6 — `entity_caps_live` has no CLI mirror but moduledoc claims dispatch parity (LOW)

- Severity: LOW
- What: `entity_caps_live.ex:30` says "No dedicated mix task exists for grant/revoke today —
  this LV is the canonical operator surface." But there is no auto-derived `mix ezagent <…>
  grant_cap` either, because `Behavior.Identity` is registered on `User` and `Agent` Kind
  modules — the LV calls it generically via the entity URI, but the CLI tree-builder groups
  by `type_name()` which yields `:user`, `:agent`, etc. — not `:entity`.
- Where: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex:30-40`.
- Why it matters: the `Identity` Behavior is documented as "uniformly callable on any entity"
  but the CLI surface doesn't reflect that — `mix ezagent user grant_cap` may work (untested),
  `mix ezagent agent grant_cap` may work (untested), but the LV uses a single page for both.
- Recommendation: verify experimentally whether `mix ezagent user grant_cap --user
  entity://user/default/allen --cap <serialized>` works against the auto-derived surface.
  If it does, document the pattern in the LV moduledoc. If it doesn't, add a `FacadeRegistry`
  op `:entity, :grant_cap` that takes `--target <uri> --cap <…>`.

---

## Section 6 — Recommendations

In priority order:

1. **PR-1 (HIGH): Close the CLI admin-fallback hole.** Change
   `EzagentCli.Dispatch.derive_caller/1` to return `{:error, :missing_token}` when no token
   is presented and `--as` is not used (post: `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:135`).
   Match `api_v1_controller.ex:165` failure mode. Update `mix ezagent` help text. Add an
   `EZAGENT_CLI_ALLOW_ANON_ADMIN=1` env opt-in IF a transition period is needed for
   local install scripts (default off).

2. **PR-2 (HIGH): Write a CLI/LV parity invariant test.** Enumerate every
   `Ezagent.BehaviorRegistry` entry + every LV `handle_event` underlying Domain call; assert
   each has either a `mix ezagent` auto-derived path OR a registered FacadeRegistry op. Document
   the exemption list (`EXEMPT_GUI_ONLY`) inline with rationale. This is the
   `feedback_completion_requires_invariant_test` gate that's currently missing — the existing
   `cli_lv_same_server_invariant_test` only checks ONE action.

3. **PR-3 (HIGH): Unify `agent.create` path.** Either rewrite
   `mix ezagent.agent.create` to call `Ezagent.Workspace.add_template + invoke_template_now`
   (matching `agent_new_live.ex`), or register a `:agent, :create` FacadeRegistry op that
   both surfaces use. The second is preferred (single code path).

4. **PR-4 (MED): Migrate `mix ezagent.routing.add_rule` to `mix ezagent routing add_rule`** as a
   FacadeRegistry op or — better — make `routing.add_rule` a Behavior action on
   `system://routing/default` and register it in `BehaviorRegistry`. Either way, route the CLI
   through `Ezagent.Invocation.dispatch` so CapBAC + audit + cross-workspace gate the call,
   matching `routing_live.ex:308-318`. Deprecate the legacy task with a redirect message.

5. **PR-5 (MED): Add `mix ezagent` facade ops for the GUI-only ops where Behavior-conversion is
   premature.** Specifically: `workspace add_member`/`remove_member`/`add_template`/`remove_template`,
   `user promote_to_system`/`revoke_system`, `entity grant_cap`/`revoke_cap`, `profile
   save_display_name`, `settings save_smtp`/`save_registration_domains`. Each of these is a
   1-screen change in `apps/ezagent_cli/lib/ezagent_cli/application.ex`.

6. **PR-6 (LOW): Document the legitimate CLI-only carve-outs** in the CLI README:
   bootstrap/home/db/check_invariants/stress/plugin.install — these install or repair the
   runtime, so they CANNOT route through the runtime (chicken-and-egg). All other tasks should
   route through `mix ezagent`.

7. **PR-7 (LOW): Tighten `mix ezagent.snapshot.clear`** by making `snapshot.clear` a Behavior
   action on a `system://snapshots` Kind so caps gate it. Read-only `snapshot.dump/list` are
   fine as direct DB reads.

---

## Appendix — files referenced

CLI surface:
- `apps/ezagent_cli/lib/mix/tasks/ezagent.ex` — the `mix ezagent` shell (the RPC client)
- `apps/ezagent_cli/lib/ezagent_cli/exec.ex` — server-side exec (runs in runtime BEAM)
- `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex` — Invocation builder + caller resolution
- `apps/ezagent_cli/lib/ezagent_cli/facade_registry.ex` — non-Behavior op registry
- `apps/ezagent_cli/lib/ezagent_cli/tree_builder.ex` — Optimus tree builder
- `apps/ezagent_cli/lib/ezagent_cli/application.ex` — registers the ONE facade op
  (`workspace.create`)
- `apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs` — the existing
  isomorphism gate (only tests ONE action)

Legacy mix tasks (17 total):
- `apps/ezagent_core/lib/mix/tasks/` — 11 tasks (bootstrap, home.*, db.reset,
  check_invariants, snapshot.*, stress, plugin.install, routing.add_rule)
- `apps/ezagent_domain_identity/lib/mix/tasks/` — 4 tasks (user.create, user.token,
  user.set_password, agent.create)
- `apps/ezagent_plugin_feishu/lib/mix/tasks/` — 5 tasks (feishu.bind/unbind/list/chat.bind/chat.unbind)
- `apps/ezagent_web/lib/mix/tasks/ezagent.auth.magic_link.ex` — 1 task

GUI surface:
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/` — 22 LV modules, 88
  `handle_event` clauses (`grep -c def handle_event`)
- `apps/ezagent_web/lib/ezagent_web/controllers/` — 11 controllers (auth + uploads + api_v1
  + cc-events + health + onboarding + workspace_switch + registration)

HTTP API:
- `apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex` — `POST
  /api/v1/:kind/:action` is structurally isomorphic to `mix ezagent <kind> <action>`; both go
  through `Ezagent.BehaviorRegistry` + `Invocation.dispatch`. HTTP correctly fail-fasts on
  missing token (`api_v1_controller.ex:165`); CLI does not (Finding 1).

Key architecture references:
- `ARCHITECTURE.md` Decision Log #130 (CLI distributed-Erlang RPC pivot, 2026-05-17)
- `IMPLEMENTATION_ROADMAP.md` §1.3 invariant 9 (CLI ↔ LV 同 BEAM)
- Skill `ezagent-developer` principles P14 (dispatch-only), P15 (caps as modules), P5
  (UUID/URI canonical), P2 (let it crash), P9 (tier ownership)
