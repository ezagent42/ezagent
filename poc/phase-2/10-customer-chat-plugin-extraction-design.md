# Customer-chat plugin extraction — design spec

> Design spec (2026-05-29). Extract the customer-service surface (today
> riding inside `ezagent_plugin_liveview` + `ezagent_web`) into a
> dedicated `ezagent_plugin_customer_chat` plugin, add a direct operator
> entry route + a real operator cap. **Pure extraction + operator entry;
> no new features** (escalation signal, foreign-IM adapter, full SSO are
> explicitly out — see §9). Builds on the decisions in
> `8-customer-chat-frontend-design.md` and `9-operator-surface-vs-generic-console.md`.

## 1. Context & goal

The PoC proved AI customer service + operator takeover end-to-end. The
code currently lives **inside** `ezagent_plugin_liveview` (the platform
admin UI plugin) under a `CustomerChat` namespace + two controllers in
`ezagent_web`. That was the deliberate prototype shortcut. Now that the
capability is proven, the goal is to make it a **first-class, decoupled
plugin** in the ezagent ecosystem:

- It appears on `/plugins` as its own card.
- It can be modified without touching (or risking) the platform admin UI.
- It honors the migration north-star: ezagent stays generic; the
  customer-service *shape* lives in a composable plugin.

This extraction does **not** add behavior — every e2e flow that passes
today (customer chat, widget, reload-resume, operator dashboard,
takeover) must still pass after it, byte-for-behavior identical.

## 2. Decision summary (settled in discussion)

| # | Decision |
|---|---|
| D1 | New umbrella app `ezagent_plugin_customer_chat` with the full `Ezagent.Plugin` contract (so it registers on `/plugins`). |
| D2 | The generic capability — `Ezagent.Behavior.Mode` (auto/takeover) — **stays in `ezagent_domain_chat`**. The plugin ships UI + bootstrap only, **no Behaviors/Kinds**. |
| D3 | The generic `/sessions` console is **untouched** (no CS-specific takeover affordances there — persona separation, per doc 9). |
| D4 | The operator dashboard becomes the plugin's **dedicated operator surface**, reached via a direct route + the `/plugins` card. |
| D5 | Operator authorization = a real **operator cap** (holds `Mode.set` over the workspace), replacing the PoC "any cap" gate. Admin/system members always pass. |
| D6 | The two HTTP controllers (SSE + widget) **stay in `ezagent_web`** (the HTTP edge) and call into the plugin's `Bootstrap`. Controllers are NOT moved into the plugin. |
| D7 | **Scope = pure extraction + operator entry.** Escalation signal, foreign-IM EM adapter, full SSO are out (§9). |

## 3. Plugin app structure — `ezagent_plugin_customer_chat`

`apps/ezagent_plugin_customer_chat/`:

- **`mix.exs`** — mirrors the other plugin apps:
  - `compilers: Mix.compilers() ++ [:ezagent_plugin_check]`
  - `env: [ezagent_plugin: EzagentPluginCustomerChat.Application]`
  - deps: `ezagent_core`, `ezagent_domain_identity`, `ezagent_domain_workspace`,
    `ezagent_domain_chat`, `ezagent_domain_ui`, `ezagent_plugin_cc`
    (for `EagerBridge`), `phoenix_live_view`, `phoenix_html`, `gettext`,
    `jason`. (Same set `ezagent_plugin_liveview` uses for these LVs.)
- **`lib/ezagent_plugin_customer_chat/application.ex`** — `use Application`
  + `use Ezagent.Plugin`; `start/2 → Ezagent.Plugin.boot(__MODULE__)`.
  Contract callbacks:
  - `plugin_info/0` — card identity (name "Customer Service", description).
  - `config_surface/0` — `%{kind: :route, path: "/operator", label: "Customer Service"}`
    → the `/plugins` card links straight to the operator entry.
  - all others keep the `use Ezagent.Plugin` defaults: `behaviors/0 → []`,
    `kinds/0 → []`, `agent_flavors/0 → []`, `template_classes/0 → []`,
    `adapters/0 → []` (**reserved** — future foreign-IM EM adapter home,
    see §7), `children/0 → []`, `after_boot/0 → :ok`.

The plugin ships **no OTP processes** and **no Kinds/Behaviors** — it is a
UI + bootstrap-logic plugin, exactly like `ezagent_plugin_liveview` is a
"pure UI" plugin.

## 4. Code migration map (exact)

### Moves INTO the new plugin (with module rename)

| From (`ezagent_plugin_liveview`) | To (`ezagent_plugin_customer_chat`) | Module rename |
|---|---|---|
| `lib/.../customer_chat/theme.ex` | `lib/ezagent_plugin_customer_chat/theme.ex` | `EzagentPluginLiveview.CustomerChat.Theme` → `EzagentPluginCustomerChat.Theme` |
| `lib/.../customer_chat/bootstrap.ex` | `lib/ezagent_plugin_customer_chat/bootstrap.ex` | `…CustomerChat.Bootstrap` → `EzagentPluginCustomerChat.Bootstrap` |
| `lib/.../customer_chat/components.ex` | `lib/ezagent_plugin_customer_chat/components.ex` | `…CustomerChat.Components` → `EzagentPluginCustomerChat.Components` |
| `lib/.../customer_chat/chat_live.ex` | `lib/ezagent_plugin_customer_chat/chat_live.ex` | `…CustomerChat.ChatLive` → `EzagentPluginCustomerChat.ChatLive` |
| `lib/.../customer_sessions_dashboard_live.ex` | `lib/ezagent_plugin_customer_chat/dashboard_live.ex` | `EzagentPluginLiveview.CustomerSessionsDashboardLive` → `EzagentPluginCustomerChat.DashboardLive` |
| `lib/.../customer_session_view_live.ex` | `lib/ezagent_plugin_customer_chat/session_view_live.ex` | `EzagentPluginLiveview.CustomerSessionViewLive` → `EzagentPluginCustomerChat.SessionViewLive` |
| `priv/customer_chat_themes/acme.json` | `priv/customer_chat_themes/acme.json` | (fixture; `Theme` reads `:code.priv_dir(:ezagent_plugin_customer_chat)`) |
| `test/.../customer_chat/{theme,bootstrap,components}_test.exs` | `test/ezagent_plugin_customer_chat/{theme,bootstrap,components}_test.exs` | update aliases |

Gettext: the LVs that `use Gettext` must point at a backend the new app
owns (or drop to plain strings for the PoC). Plan decides: add a
`EzagentPluginCustomerChat.Gettext` backend (mirrors liveview's) OR
inline strings. Lean: inline (the CS surface has few strings) to avoid a
gettext tree; revisit if i18n is needed.

### Stays in `ezagent_web` (HTTP edge), repointed to the plugin

| File | Change |
|---|---|
| `lib/ezagent_web/controllers/customer_chat_controller.ex` | alias `EzagentPluginCustomerChat.Bootstrap` (was `…Liveview.CustomerChat.Bootstrap`) |
| `lib/ezagent_web/controllers/customer_chat_widget_controller.ex` | unchanged (no plugin dep) |
| `lib/ezagent_web/router.ex` | repoint LV module names + add operator routes (§5) |
| `test/.../customer_chat_widget_controller_test.exs` | unchanged |

### Dependency rewiring

- `ezagent_web/mix.exs`: **add** `{:ezagent_plugin_customer_chat, in_umbrella: true}`
  (controller calls `Bootstrap`; router references the plugin LVs by atom).
  Keep the existing `:ezagent_plugin_liveview` dep (other admin LVs remain there).
- `ezagent_plugin_liveview`: just loses the moved files; its `mix.exs` deps
  are unchanged (it still deps on `plugin_cc`/`domain_chat` for other admin LVs).
- The config keys move app namespace:
  `:ezagent_plugin_liveview, :customer_chat_*` → `:ezagent_plugin_customer_chat, :customer_chat_*`
  (`Theme` + `Bootstrap` read their own app's env; sandbox/soul-root defaults recomputed for the new file location).

## 5. Routes (in `ezagent_web` router)

| Route | Module | Pipeline / auth | Status |
|---|---|---|---|
| `live "/chat/:tenant"` | `EzagentPluginCustomerChat.ChatLive` | `customer_chat_browser` (public, relaxed CSP) | repointed |
| `get "/customer-chat/widget.js"` | `CustomerChatWidgetController` | `public_asset` | unchanged |
| `post "/api/customer/:workspace/chat"` | `CustomerChatController` | (existing) | unchanged |
| `live "/operator/:tenant"` | `EzagentPluginCustomerChat.DashboardLive` | logged-in + operator gate (§6) | **NEW** |
| `live "/operator/:tenant/:conv"` | `EzagentPluginCustomerChat.SessionViewLive` | logged-in + operator gate (§6) | **NEW** |
| `live "/operator"` | `EzagentPluginCustomerChat.DashboardLive` (no-tenant mode) | logged-in | **NEW** |
| `live "/admin/customer_sessions[/:id]"` | (old dashboard routes) | admin | **redirect → `/operator`** (avoid breaking existing links) |

**Tenant is baked into the operator route.** `DashboardLive` /
`SessionViewLive` read `:tenant` from the path param and operate on
`workspace://<tenant>` **directly** — they no longer depend on the admin's
"current workspace" switcher. This eliminates the workspace-switch friction
observed in the PoC (operator had to manually switch to acme).

`config_surface/0`'s `/operator` path is the canonical entry. `/operator`
with no tenant lists the workspaces the logged-in operator holds the cap
for; if exactly one, it redirects straight to `/operator/<that-tenant>`.
The `/plugins` "Customer Service" card links here.

## 6. Operator cap (no new RBAC system)

Reuse the existing capability primitive — **the operator cap is the
takeover cap, workspace-scoped**:

```
Ezagent.Capability.cap(:session, Ezagent.Behavior.Mode, :set, :any, workspace://<tenant>)
```

Semantics: *"if you can take a session over (Mode.set) in this workspace,
you may use the operator console for it."* Coherent, and needs no new cap
subject.

`DashboardLive` / `SessionViewLive` `mount` authorization becomes:

```
operator? = is_system_member?(caller)            # admin always passes
            or holds_cap?(caller, Mode.set, workspace://<tenant>)
```

(Replaces the PoC `has_any_cap?` gate.) `is_system_member?` keeps admin
working out-of-the-box for the demo; a granted operator user passes via
the scoped cap.

**Granting (demo)**: an operator user is granted
`cap(:session, Behavior.Mode, :set, :any, workspace://acme)` + the
`chat.send` cap over the workspace (so their takeover messages dispatch).
The plan documents the grant step (via `EntityCapsLive` or an RPC seed).
The plan MUST verify admin's cap set satisfies the gate (it does today via
system membership) so the demo path can't regress.

## 7. Relationship to External Mirror (EM)

EM (`ezagent_domain_external_mirror`) is ezagent's generic bidirectional
bridge **session ↔ a foreign chat surface** (Feishu/Slack/SMS). The
domain owns bindings + per-binding workers + the `bind/unbind` CapBAC
facade; **plugins supply `Ezagent.ExternalMirror.Adapter` modules, declared
via the plugin contract's `adapters/0`**. Feishu is the live example
(`ezagent_plugin_feishu/.../feishu_adapter.ex`). EM is therefore exactly
the "generic primitive businesses compose" pattern — and it IS for plugins.

**Overlap analysis (native vs foreign):**

| Our piece | Overlaps EM? | Why |
|---|---|---|
| Customer LiveView `/chat/:tenant` + widget | **No** | The browser is an ezagent-NATIVE LiveSocket client (subscribe topic + dispatch chat.send). No foreign system to bridge. EM bridges foreign surfaces that have their own servers. (Same reason `/sessions` is native, not EM.) |
| Operator dashboard | **No** | Operator console over sessions; unrelated to EM. |
| Headless `POST /api/customer/:workspace/chat` | **Yes, conceptually** | "Let a 3rd-party IM (CINNOX) talk to a session" is literally an EM adapter's job (inbound foreign event → chat.send; outbound message → foreign push). We built a bespoke SSE controller as a PoC shortcut. |

**Honest nuance:** EM's shape is a *persistent per-binding worker* against a
foreign surface with a *stable external_id* (a Feishu group that persists;
webhook in, API push out). Our SSE is *ephemeral request/response* (the
customer's HTTP connection opens per turn, streams the reply, closes). So a
real CINNOX integration would be an EM adapter (webhook-in / API-push-out),
a different shape than our SSE-stream-back — **not a drop-in swap**.

**Forward path (NOT this PR):** the customer-chat plugin's channels are
three-legged:
1. **Native web** (LiveView + widget) — built; not EM.
2. **Headless SSE API** — PoC stand-in; production path = migrate to an EM adapter.
3. **Future foreign IMs** (CINNOX/WhatsApp…) — **EM adapters declared via this
   plugin's `adapters/0`**, reusing EM's binding/worker lifecycle.

That is why §3 keeps `adapters/0` present-but-empty: it is the reserved
home for a future CINNOX EM adapter. We evaluated EM and are deliberately
not reinventing it — we are leaving the seam where it belongs.

## 8. Testing / e2e preservation

- The 3 unit suites (theme/bootstrap/components, 12 tests) + the widget
  controller test (1) move with the code (module-name updates only) and
  must stay green.
- `mix compile --warnings-as-errors` clean **and** the `:ezagent_plugin_check`
  gate passes for the new app (proves contract compliance).
- `/plugins` shows a "Customer Service" card linking to `/operator`.
- Re-run the browser e2e on the extracted tree:
  1. `/chat/acme` — themed page, live AI reply with soul facts (12/24-mo Pro).
  2. widget embed (cross-origin host) — bubble → iframe chat.
  3. reload-resume — same thread restored.
  4. **`/operator/acme`** — lands directly on the dashboard for acme **without
     a workspace switch** (validates the tenant-baked route + operator gate).
  5. takeover from the operator console → customer page shows notice +
     operator message live.
- No change to `/sessions` behavior (smoke it still loads).

## 9. Out of scope (explicitly NOT in this extraction)

- **Escalation signal** (AI-initiated "needs human" → dashboard highlight) —
  separate phase; needs a Mode state + cc directive + UI. Its own spec.
- **Foreign-IM EM adapter** (e.g. CINNOX) — the `adapters/0` seam is reserved
  (§7) but no adapter is built now.
- **Full SSO** — operator entry is a direct route + scoped cap, not federated identity.
- **Any change to `/sessions`** (the generic console) — untouched.
- **Moving the HTTP controllers into the plugin** — they stay in `ezagent_web`.

## 10. Acceptance criteria

1. `ezagent_plugin_customer_chat` exists as a plugin app; `mix compile`
   + `:ezagent_plugin_check` pass; it shows on `/plugins` as "Customer Service".
2. All customer-chat unit tests pass under the new app (module renames only).
3. `ezagent_plugin_liveview` no longer contains any `CustomerChat` / customer-
   session code; the generic admin UI still compiles and loads.
4. Browser e2e (§8) all green on the extracted tree, including the new
   `/operator/:tenant` direct entry with no workspace switch.
5. Operator gate is the scoped `Mode.set` cap (admin still passes); the PoC
   "any cap" gate is gone.
6. No hardcoded tenant data in code (theme + paths config-driven; `acme`
   only in the fixture).
7. `/sessions` unchanged.

## 11. Risks & follow-ups

- **Admin must still pass the new operator gate** — relying on
  `is_system_member?`. The plan verifies this before declaring done (else the
  demo login can't open the dashboard).
- **Gettext backend** — moved LVs `use Gettext`; the plan picks inline-strings
  vs a plugin-owned backend (lean: inline for the PoC).
- **`/admin/customer_sessions` redirect** — keep a redirect so any existing
  links / muscle memory still reach the operator console.
- **PR #446** is the (now-draft) home; after extraction the branch is
  re-verified and the PR re-opened for review.
- Deferred, tracked elsewhere: escalation signal; CINNOX EM adapter;
  production operator SSO + per-tenant operator provisioning.

## 12. Next phase after this extraction (sequencing decision 2026-05-29)

The third leg of the core triad — **admin iterates the AI** (edit soul /
话术 / KB / service flow) — is the agreed NEXT phase, to be built **after**
this extraction lands, **inside the new plugin**. Decision: extract first
(this spec), then admin-edit; rationale = admin-edit is another
customer-service-shaped surface whose home is this plugin, so building it
pre-extraction would only grow the extraction debt.

**admin-edit is NOT a small feature** — it decomposes like Mode/EM into a
generic-vs-specific split and must get its **own brainstorm** (do not jump
to implement):
- **soul / 话术 editing** — partly generic (any agent has a soul/config);
  check whether ezagent's existing agent/template admin surfaces
  (`agent_detail_live`, `AdminTemplatesLive`, `session_editor`,
  `EntityCapsLive`) already cover part of it before building new UI.
- **KB / knowledge retrieval** — generic, PoC-deferred, large
  (AutoService: `kb_chunks` + `kb_search` MCP).
- **service flow / flow_directives** — generic, PoC-deferred, large.

The admin-edit brainstorm must (a) scope the minimal PoC version, and
(b) decide what lands in ezagent core/domain (generic) vs this plugin
(customer-service-specific) — same discipline as the Mode (core) /
operator-console (plugin) split.
