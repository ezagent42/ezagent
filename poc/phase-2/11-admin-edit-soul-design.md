# Scope #1 — Editable Soul — Design Spec

> **Status**: design approved (decisions locked 2026-05-30, after a round-2
> architecture review: tenancy model, route placement, rollback, cinnox e2e).
> Next: writing-plans → subagent-driven implementation → browser functional e2e.
> **Branch**: `poc/phase-2-customer-service`. **PoC** — held for review on
> draft PR ezagent42/ezagent#446.
> **Reader**: see `HANDOFF-2026-05-30.md` for surrounding context (3rd core
> capability of the AutoService → ezagent migration: "admin iterates the AI").
> This spec covers only **scope #1 = an editable soul**.

## 1. Goal & scope boundary

**Goal (functional only):** an admin edits a tenant's customer-service soul
(the whole markdown body) in a UI → Save → **new conversations automatically
use the edited soul.** That's it.

**Explicitly NOT in this scope** (deferred to the A/B roadmap, see §11):
soul layering (L0/L1/L2/L3), KB chunks, flow directives, slot templates,
change-request / approval workflow, lint, **full version-history UI**, and
forced recycle of live agents. The **quality** A/B measurement (on cinnox) is
a *separate* later cycle; scope #1 proves only the *mechanism* ("edit → new
conversation reflects it").

### Strategic frame (the red lines this spec obeys)

- **Incremental + empirically A/B-driven.** Build the smallest slice; let
  measured quality on **cinnox** decide every *next* scope. Do NOT cargo-cult
  AutoService's earned soul-layer decomposition — that complexity was the
  end-state of production pain, not a starting requirement.
- **Plugin must not compromise ezagent core generality.** The capability model
  is ezagent's universal authority primitive; this plugin authorizes through it
  (not around it) and adds **nothing** to core (see §5.5).

## 2. Locked decisions

| # | Decision | Choice |
|---|----------|--------|
| 0 | Tenancy model | **Line B — tenant ≡ workspace** (confirmed, §3). The plugin is a single shared OTP app; everything tenant-specific is keyed by workspace. Multi-tenancy is already free; no storage change needed. |
| 1 | Route + module | **`/plugins/customer-chat/:tenant/config`** + **`ConfigLive`** (matches the feishu `/plugins/<plugin>/...` precedent; semantically "configure the plugin", **not** under `/operator` — operators don't configure). |
| 2 | Rollback | **"Reset to default" + single-step "Revert to previous".** Fixture is the immutable baseline; `reset` → fixture; `revert` → the one snapshot taken before the last save (`.prev`). Full version-history UI deferred. |
| 3 | Capability gate | **Option E — reuse the workspace-admin cap** (`Behavior.Workspace`/`:any` on `workspace://:tenant`). Cap-native (admin passes via its stored all-`:any` cap, **not** a membership bypass), per-tenant, excludes operators/responders. **Zero core change.** C/D are need-gated futures (§11). |
| 4 | Recycle live agents | **No — deferred.** CS conversations are short; a forced recycle would drop a live agent's in-flight context; new conversations pick up the edit at spawn anyway. |
| 5 | e2e baseline | **cinnox** (not acme). Seed the real 88KB cinnox soul as the fixture; scope #1 e2e = a sentinel-injection **mechanism** test. Quality A/B + case-set selection = scope #2. |

### Cap decision rationale (why E, not B/A/C/D)

The AutoService `master` model gates soul editing to the **platform** tier
(`_master`, tier-0) — *not* the per-tenant admin, never the responder
(`PATCH /crs/{id}/souls/{role}` → `_MASTER_DEP`). So soul-editing is
structurally a **higher privilege than operating**. Mapping to ezagent:

| AutoService | ezagent analog | edits soul? |
|---|---|---|
| `master` (tier-0 platform admin) | system / bootstrap admin (`entity://user/system/admin`) | ✅ |
| tenant (a company) | **workspace** (`workspace://acme`, `workspace://cinnox`) | — |
| tenant `admin` | **workspace admin** (`Behavior.Workspace :any` on that ws) | ✅ in ezagent (Line B) |
| `responder` | **operator cap** (`Mode.set` on ws) — gates `/operator` today | ❌ |

ezagent has **no "plugin admin" concept** — only system/bootstrap admin,
workspace admin, and capability tuples. Options considered:

- **B — gate on `is_system_member?`.** Rejected: an *identity/membership
  bypass*, not a capability — routes *around* the cap model.
- **A — reuse the operator (`Mode.set`) cap.** Rejected: conflates "take over a
  chat" with "rewrite the bot's brain"; lets responders edit souls.
- **C — a plugin-local `Behavior.Config` cap.** Cap-native, zero core impact,
  finer-grained than E, but plugin-specific (not the generic abstraction).
- **D — a generic core `Behavior.Config` primitive.** Maximal generality, but a
  **core architectural Decision** (needs Allen per `CLAUDE.md` grill-culture) and
  speculative with one consumer — against the incremental red line.
- **E — reuse the workspace-admin cap (chosen).** *"Whoever administers tenant X
  may configure tenant X's plugins, incl. the soul."* Uses the universal
  primitive already in core; adds no module to core; admin passes via its stored
  `:any/:any/:any` cap (verified retrievable, §5.5), so genuinely cap-native.

**Promotion path (need-gated):** a *config-only sub-admin* (edit soul but not
manage members) → introduce C. A *second plugin* needing config-gating → promote
to a generic core `Behavior.Config` (D), via Allen as a core Decision. Not now.

## 3. Tenancy model (Line B — confirmed in code)

**tenant ≡ workspace, 1:1.** Verified:

- The customer-chat plugin is a **single shared OTP app**, registered once by
  slug in `PluginRegistry` (ETS `:set`) — [application.ex](../../apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/application.ex), [plugin_registry.ex:36-54](../../apps/ezagent_core/lib/ezagent/plugin_registry.ex#L36). **Not** instantiated per tenant.
- The `:tenant` path segment **is** the workspace: `workspace://<tenant>`,
  validated against `Workspace.Store` by name ([bootstrap.ex:62-67](../../apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex#L62)).
- Everything tenant-specific is keyed by workspace: sessions
  (`session://default/<ws>/<conv>`), customers (`entity://user/<ws>/customer_*`),
  souls (`<root>/<ws>/souls/`), caps (`workspace_uri`). **No** sub-tenant /
  many-tenants-in-one-workspace concept exists.

**Consequences for this spec:**
- The plugin stays generic + shared; per-tenant authority is the **workspace-admin
  cap** (decision #3 / §5.5). `workspace://cinnox`'s admin edits cinnox's soul and
  *structurally cannot* touch acme's (the `workspace_uri` axis enforces it).
- **Multi-tenancy is already free** — the soul path is `<root>/<tenant>/souls/`
  today, so the editable soul is per-tenant by construction. **No storage change**
  is required for multi-tenancy; we must only avoid hardcoding a single tenant
  (the spec uses `:tenant`/workspace throughout).
- "Tenants share one workspace" (rejected) would require inventing a sub-tenant
  isolation axis beneath the workspace — against ezagent's grain.

## 4. Storage model (corrects the handoff wording)

> **Handoff correction.** The handoff said "reuse `:customer_chat_sandbox_root`"
> for souls. Verified in [`bootstrap.ex`](../../apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex):
> there are **two distinct config keys**, souls are read from a *different* one
> than implied, and the resolver is currently **fixture-only**:
>
> | config key | default | used for (today) |
> |---|---|---|
> | `:customer_chat_sandbox_root` | `~/poc-sandbox-phase2` | the cc agent **cwd** ([bootstrap.ex:144](../../apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex#L144)) |
> | `:customer_chat_soul_root` | `<repo>/poc/fixtures/plugins` | the **fixture** soul ([bootstrap.ex:149](../../apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex#L149)) |
>
> `cc_soul_path_for_workspace/2` today returns **only** the fixture path (or
> `nil`). The scope-#1 change: make it **sandbox-first, fixture-fallback.**

**Three files per (tenant, role).** `role = "customer"` for this PoC.

```
<sandbox_root>/<tenant>/souls/<role>.md        # EDITED  (writable, the override)
<sandbox_root>/<tenant>/souls/<role>.prev.md   # PREV    (one snapshot for single-step undo)
<soul_root>/<tenant>/souls/<role>.md           # FIXTURE (immutable seed / baseline)
```

- **The fixture is immutable** — it is never written by the editor. It is the
  stable A/B baseline scope #2 needs (every version is measured against the same
  reference; this is *why* we don't roll it forward). It is also "reset" target.
- **The edited file** is the current override.
- **The prev file** is a single snapshot of the edited file taken *before* each
  Save, enabling one-level undo. (Full history is deferred — §11.)

**Effective-soul resolution (one rule, shared by editor + spawn):**
1. **edited** file exists → use it;
2. else **fixture** exists → use it (seed);
3. else `nil` (cc spawns with no `--append-system-prompt`).

**Take-effect is automatic.** `cc_agent` reads `soul_path` **at spawn** and
inlines `["--append-system-prompt", channel_preamble() <> contents]`
([cc_agent.ex:1043-1062](../../apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex#L1043)).
New conversations call the resolver at spawn ([bootstrap.ex:98](../../apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex#L98)),
so once it's sandbox-first, a new conversation picks up the edit with no extra
wiring. **The editor edits only the soul body** — the preamble is prepended at
spawn and is not in the file (textarea == file == body).

## 5. Components

Five units, each independently understandable/testable.

### 5.1 `SoulStore` (new, plugin) — storage + resolution

`EzagentPluginCustomerChat.SoulStore`. **Single source of truth** for resolution
and edited-file I/O.

| function | behavior |
|---|---|
| `effective_path(tenant, role) :: Path.t() \| nil` | §4 rule (edited → fixture → nil) |
| `edited_path/2`, `prev_path/2`, `fixture_path/2` | computed paths (fixture: nil if absent) |
| `read_effective(tenant, role) :: {:ok, body, source}` | `source ∈ {:edited, :fixture, :none}`; `:none` → `body = ""` |
| `write(tenant, role, body)` | snapshot current edited → `.prev` (if edited exists), `mkdir -p`, write edited file |
| `revert_previous(tenant, role) :: :ok \| {:error, :no_previous}` | restore `.prev` → edited (single-step undo) |
| `reset(tenant, role) :: :ok` | delete edited (and `.prev`); effective → fixture (idempotent) |
| `edited?/2`, `has_previous?/2` | booleans for UI button enablement |

### 5.2 `bootstrap.ex` change — delegate resolution to `SoulStore`

`cc_soul_path_for_workspace/2` (fixture-only today) is refactored to call
`SoulStore.effective_path/2`, so editor and spawn share **one** rule. No behavior
change when no edited file exists (still the fixture).

### 5.3 `ConfigLive` (new, plugin) — the edit UI

`EzagentPluginCustomerChat.ConfigLive`, route **`/plugins/customer-chat/:tenant/config`**.

- **Routing:** declared in a scope with the **`EzagentPluginCustomerChat`**
  alias (handoff gotcha: a scope prepends its alias to the module). On_mount
  `:require_entity`; then `ConfigAuth.config_admin?/2` in `mount` (deny →
  redirect with flash). **Verify** the new route does not collide with existing
  `/plugins...` routes (`PluginsLive` `/plugins`, feishu `/plugins/feishu/bindings`)
  — declare with literal `/plugins/customer-chat/...` segments and order before
  any `/plugins/:x` wildcard if one exists.
- **Mount:** `SoulStore.read_effective/2` → `<textarea>`; show source badge
  (`:edited` "customized" vs `:fixture`/`:none` "default"); enable
  Revert iff `has_previous?`.
- **Save** (`phx-submit`): `SoulStore.write/3`; flash; refresh badges.
- **Revert to previous** (`phx-click`): `SoulStore.revert_previous/2`; reload body.
- **Reset to default** (`phx-click`): `SoulStore.reset/2`; reload (now fixture).
- **UI:** mirror operator-console styling. The plugin's lib path is already in
  the Tailwind `@source` list (handoff); a live-browser CSS check still required.

### 5.4 Entry point

Primary entry: a "Configure" link on the operator dashboard (`/operator/:tenant`,
`DashboardLive`), **shown only when the viewer passes `ConfigAuth.config_admin?/2`**
(so responders don't see it), linking to `/plugins/customer-chat/:tenant/config`.
The dashboard is the existing per-tenant landing that knows `:tenant`. Repointing
the plugin's `config_surface/0` (currently `/operator`) to a dedicated tenant-picker
admin landing is a **deferred** IA cleanup, not scope #1.

### 5.5 `ConfigAuth` (new, plugin) — the capability gate (Option E)

Mirrors `OperatorAuth` but checks the **workspace-admin** capability:

```elixir
@spec config_admin?(URI.t() | nil, String.t() | nil) :: boolean()
def config_admin?(%URI{} = caller, tenant) when is_binary(tenant) do
  ws = URI.parse("workspace://#{tenant}")
  needed = %{kind: :workspace, behavior: Ezagent.Behavior.Workspace,
             action: :any, instance: ws, workspace_uri: ws}
  caller |> Ezagent.Identity.list_caps_for() |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))
end
def config_admin?(_, _), do: false
```

**Why cap-native (not B).** `Capability.matches?/2`
([capability.ex:205](../../apps/ezagent_core/lib/ezagent/capability.ex#L205)) lets
a *held wildcard* cap satisfy a *concrete* request:

- the **bootstrap admin**'s stored `:any/:any/:any` cap matches every field
  (verified retrievable: "admin's caps include `:any/:any/:any`",
  [identity.ex:84-88](../../apps/ezagent_domain_identity/lib/ezagent/identity.ex#L84)) — so
  `entity://user/system/admin` passes **via its capability**, **no membership
  bypass** (the line between E and B).
- a real **workspace-admin** cap matches. Canonical minted shape:
  `kind: :workspace, behavior: Behavior.Workspace, action: :any, instance: :any,
  workspace_uri: :any` ([identity.ex:767-773](../../apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex#L767));
  its held `:any` instance/workspace_uri match the concrete `needed`, and a
  tenant-scoped variant matches its tenant while a *different* workspace's does
  not — correct per-tenant isolation.
- a **responder**'s `Mode.set` cap does **not** (behavior mismatch).

> Matcher asymmetry: in `needed`, `action: :any` matches **only** action-wildcard
> (admin-grade) held caps — a responder's concrete `action: :set` fails on the
> action axis too. Intended "is workspace admin" semantics.

`ConfigLive.mount` and the §5.4 link both call `config_admin?/2`. No `sys?` bypass.

## 6. Data flow

```
ADMIN CONFIG
  ConfigLive.mount(tenant)
    └─ ConfigAuth.config_admin?(caller, tenant)  ── deny → redirect
    └─ SoulStore.read_effective(tenant,"customer") → textarea + source badge
  Save   → SoulStore.write(tenant,"customer", body)   [snapshots edited→.prev first]
  Revert → SoulStore.revert_previous(tenant,"customer")  [.prev → edited]
  Reset  → SoulStore.reset(tenant,"customer")            [delete edited + .prev → fixture]

TAKE-EFFECT (unchanged path, now sandbox-aware)
  new conversation → Bootstrap.ensure_cc_for_conv(tenant, conv, session)
    └─ cc_soul_path_for_workspace → SoulStore.effective_path  (edited!)
        └─ cc_agent at spawn → ["--append-system-prompt", preamble <> body]
  (live per-conv agents keep their already-spawned soul — decision #4)
```

## 7. Generic vs plugin-specific boundary

- **Plugin-specific:** `SoulStore`, `ConfigLive`, `ConfigAuth`, the dashboard
  link, the route. All CS-shaped.
- **Generic, reused unchanged:** cc `soul_path` → `--append-system-prompt`; the
  capability model + `Capability.matches?` + `Identity.list_caps_for`.
- **Core touched:** none. (The point of choosing E + Line B.)

## 8. Error handling

- **Write failure:** `{:error, reason}` → error flash, textarea preserved.
- **Revert with no `.prev`:** `{:error, :no_previous}` → button disabled anyway;
  defensive flash.
- **Reset when no edited file:** idempotent `:ok`.
- **Effective `:none`:** empty textarea + hint; Save still creates the file.
- **Unreadable edited file at spawn:** already non-fatal in cc_agent (logs, no
  `--append-system-prompt`).
- **Deny at mount:** redirect to `/operator/:tenant` with flash.

## 9. Testing

**Unit (`SoulStore`)** — temp `:customer_chat_sandbox_root` / `:customer_chat_soul_root`:
- resolution: edited→edited; no-edited+fixture→fixture; neither→nil.
- `write` snapshots edited→`.prev`, then writes; `read_effective` round-trips
  `source: :edited`.
- `revert_previous`: after two saves, restores the prior body; with no `.prev` →
  `{:error, :no_previous}`.
- `reset`: deletes edited + `.prev` → effective falls back to fixture; idempotent.

**Unit (`ConfigAuth`)** — synthesized caps:
- bootstrap `:any/:any/:any` → true; workspace-admin on tenant → true; on a
  *different* workspace → false; responder `Mode.set` only → false; none → false.

**Functional e2e (browser, on cinnox — the acceptance gate):**
0. (Setup) cinnox workspace provisioned; the real cinnox soul seeded as the
   **fixture** (`<soul_root>/cinnox/souls/customer.md`).
1. Open `/plugins/customer-chat/cinnox/config` as admin → see the cinnox soul;
   inject a recognizable **sentinel** phrase; Save.
2. Open a **new** cinnox conversation → the AI reflects the sentinel (edit took
   effect at spawn).
3. Edit again (sentinel-2), Save; **Revert to previous** → sentinel-1 restored;
   new conversation reflects sentinel-1.
4. **Reset to default** → new conversation back to the seeded cinnox soul
   (no sentinel).
5. (Auth) a responder-only principal cannot reach the config route (redirected);
   the dashboard "Configure" link is hidden for them.

> Scope boundary: this is a **mechanism** test (does the edit propagate?), **not**
> a quality eval. Answer-quality scoring + the cinnox golden case-set = scope #2.

## 10. Acceptance criteria

- [ ] `/plugins/customer-chat/:tenant/config` renders the effective soul for a
      config-admin; redirects others; entry link hidden for non-config-admins.
- [ ] Save writes the edited file (snapshotting `.prev`); a **new** conversation
      uses it (browser-verified on cinnox).
- [ ] Revert restores the previous body; Reset reverts to the immutable fixture.
- [ ] `cc_soul_path_for_workspace/2` delegates to `SoulStore.effective_path/2`.
- [ ] Cap gate via `Capability.matches?` (admin passes by capability, no
      membership bypass); responders excluded.
- [ ] New route doesn't collide with existing `/plugins...` routes.
- [ ] Unit tests green; our code `--warnings-as-errors` clean.
- [ ] Live browser confirms styling intact (CSS `@source` check).
- [ ] cinnox soul seeded as fixture; cc tolerates the ~88KB `--append-system-prompt`.

## 11. Deferred (NOT doing) + roadmap

Deferred to the cinnox A/B roadmap, each adopted only if a measured A/B on cinnox
cases shows it improves answers: soul **layering**, **KB** retrieval, **flow**
directives, **slot templates**, **change-request/approval**, **lint**, **full
version-history UI** (scope #1 ships only single-step undo), **forced recycle**.

Capability promotion (§2): **C** when a config-only sub-admin is needed; **D**
when a *second* plugin needs config-gating (then via Allen).

IA cleanup: repoint `config_surface/0` to a dedicated tenant-picker admin landing.

**After scope #1:** the *separate* cinnox A/B measurement-harness cycle, whose
data picks scope #2.

### cinnox asset inventory (groundwork for scope #2 — in the AutoService repo)

| asset | path | note |
|---|---|---|
| **soul (main)** | `AutoService/plugins/cinnox/souls/customer_soul.md` | 88 KB / 1655 lines, production-grade; **seed as the scope-#1 fixture** |
| soul (voice) | `AutoService/plugins/cinnox/souls/customer_soul.voice.md` | Mandarin variant |
| KB | `AutoService/.autoservice/sandbox/cinnox/kb/chunks/` (336 files) | scope #2+ (no KB retrieval in scope #1) |
| UAT cases | `AutoService/skills/cinnox-demo/SKILL.md` | TC-A…TC-I narrative scenarios → golden case-set source for scope #2 |
| mock customers | `AutoService/plugins/cinnox/mock_data/accounts.json` | 6 profiles |
| glossary | `AutoService/plugins/cinnox/references/glossary.json` | ~400 terms |
| post-mortems | `AutoService/docs/analysis/2026-05-07-cinnox-investigation-digest-and-implementation-guide.md` | pitfalls to avoid |

> The 88KB soul references companion KB/contracts absent in ezagent — **inert &
> harmless for the scope-#1 mechanism test** (bot just lacks KB), relevant for
> scope #2. Selecting TC-A…I into a small fixed golden set + a rubric = scope #2.

## 12. Non-obvious learnings carried in (do not re-derive)

- Two soul config keys, not one (§4); current resolver is fixture-only.
- cc reads `soul_path` at **spawn**; preamble prepended there, not stored.
- **Scope alias gotcha**: a route for `EzagentPluginCustomerChat.X` must sit in a
  scope aliased to that module (a scope prepends its alias). The `/config` route
  is no longer under `/operator`, so the old `/:conv` wildcard-swallow risk is
  gone — but watch ordering vs any `/plugins/...` wildcard.
- Tailwind v4 `@source` purge: compile/tests stay green even when CSS is purged —
  only a live browser catches it.
- `Ezagent.Capability.workspace_uri` is the field name (not `workspace`); wrong
  key silently denies everyone.
- The fixture is immutable (stable A/B baseline) — never write it from the editor.
