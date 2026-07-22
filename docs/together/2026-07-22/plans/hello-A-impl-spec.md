# hello A — 官网 workspace de-hardcode (IMPLEMENTATION SPEC for KIMI)

**Status:** spec, pre-adversarial-review. **Author:** coordinator (cc). **Date:** 2026-07-22.
**Grounded on:** `origin/main` @ `22fe5436a` (verified in a worktree; every file:line below is that commit).
**Implementer:** kimi (K3). **Load skills before writing code:** `ezagent-developer` + `ezagent-socialware` + `elixir-phoenix-helper`.
**Convention reminders:** `uv run` (never bare `python`); `mix format` only touched files; no back-compat shims (delete legacy paths); this is Elixir — never `cat >>` a `.ex` file, use the Edit tool.

---

## 0. What this is, and what it is NOT

**Goal.** Turn the ezagent 官网 from a `system`-workspace-pinned singleton into a session
**`ezagent-official`** in the **`ezagent`** workspace, created by **mimicking an ezagent-workspace
member creating the session** (not the system admin). Because that makes
`session-ws == owner-ws == the-users'-ws == ezagent`, the cross-workspace denial that currently
mutes the greeter disappears **with zero cap-machinery change**. The same de-hardcode makes hello
support **ANY user creating a hello page session in THEIR workspace** — the 官网 becomes just the
first caller of a now-generic path (future: `ezagent-billboard`, other users' pages).

**IN scope (hello A — infrastructure only):**
1. Single-source workspace config (kill the `system` split-brain) + the credential-bridge de-hardcode.
2. Seed rewrite: seed-as-ezagent-member + thread the owner/caller through `create_app` (the real linchpin).
3. Agent/routing migration into the new session.
4. Credential-path change (a **confirmed blocker** — see §6; the earlier "it probably won't break" note is wrong).
5. A fail-before/pass-after test.
6. Deploy migration (PR-4) — **described but coordinator-gated, do NOT auto-run.**

**OUT of scope (do NOT touch in this work):**
- **`do_grant_join_cap` fail-loud** — going to kimi separately via **#195 Phase M**. Do not include it.
- **官网 page CONTENT redo ("hello B")** — a separate data update to `priv/seed_page/*`. This spec is
  workspace/session/seed/routing **infrastructure** only; the page bytes are unchanged.
- **The manifest Definition-publish lane's use of `system`** — see §10; it legitimately stays `system`.

---

## 1. The confirmed root cause this fixes

`do_workspace_isolation_check/2` — `apps/ezagent_core/lib/ezagent/kind/runtime.ex:403-430`:

```elixir
defp do_workspace_isolation_check(target, ctx) do
  caller_ws = workspace_of_caller(Map.get(ctx, :caller))
  target_ws = Ezagent.Capability.workspace_of(target)
  cond do
    caller_ws == :any -> :ok
    target_ws == :any -> :ok
    ws_equal?(caller_ws, target_ws) -> :ok
    caps_have_cross_workspace?(ctx) -> :ok
    true -> {:error, :cross_workspace_denied}   # <-- L427-429
  end
end
```

Today the 官网 lives in `system` while its users live in `ezagent`. When an `ezagent` user (or an
anon minted into the session's workspace) sends to the greeter, `caller_ws=ezagent`,
`target_ws=system` → not equal, no cross-workspace cap → **`:cross_workspace_denied`** (ezagent-developer
architecture-invariant **#13**, "cross-workspace dispatch requires structural authority"). Move the
session (and its members) into `ezagent` and `caller_ws == target_ws == ezagent` → the check returns
`:ok` at `ws_equal?`. **No CapBAC change required.** (This is why #195 Phase M's join-cap fail-loud is a
*separate* problem — it's about a different grant, not this equality check.)

### The `system` split-brain that pins it there (all four confirmed)

| Pin | file:line (main) | current value |
|---|---|---|
| Seed workspace (instance) | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/official_site_seed.ex:70` | `@workspace "system"` |
| Seed session name | `…/official_site_seed.ex:71` | `@name "web"` |
| Fusion default workspace | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/fusion_seed.ex:14` | `@default_workspace "system"` |
| Credential-bridge destination | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/credential_bridge.ex:80` | `@system_workspace "system"` |
| Web serve workspace | `config/config.exs:67` (`:ezagent_web`) | `hello_workspace: "system"` |
| Web serve consumer | `apps/ezagent_web/lib/ezagent_web/controllers/socialware/chat_feed_controller.ex:92` | `Application.get_env(:ezagent_web, :hello_workspace, "demo")` |

Note the split-brain hazard the config value **already** demonstrates: the code default is `"demo"`
(chat_feed_controller.ex:92, router.ex:207 comment) but config sets `"system"` — two disagreeing
sources for one truth. That is exactly the class of bug §3's single source removes.

---

## 2. Two distinct changes: the isolation FIX (workspace flip) and the owner SEMANTICS (caller threading)

Be precise about what each change buys — they are separable, and conflating them will mislead kimi when
it hits friction.

**(a) The isolation fix is the workspace flip.** `do_workspace_isolation_check` (§1) compares only
`caller_ws` vs `target_ws` — it **never reads owner-ws**. So the `:cross_workspace_denied` symptom is
cured purely by the session + its materialized members + the minted anons all landing in `ezagent`:
the `@workspace` flip (§3/§4) does the members-and-session half, and `mint_for_public_session` minting
anons into the *session's* workspace (§8, code-verified) does the visitor half. This alone reopens the
greeter for both members and anons.

**(b) Owner-as-ezagent-member is the product owner's DESIGN requirement, not an isolation blocker.**
The runtime greeter flow does not depend on it: the session owner (the seed principal) does not send
messages at runtime, and the anon-view-cap granter **falls back to the admin entity**
(`installation.ex:302`), so an admin-owned session sitting in `ezagent` would likely still relay. Owner
matters for two *owner-consuming* paths — owner→builder message routing (`app.ex:82` comment) and the
`anon_view_granter` — but neither is a functional gate on the isolation fix. We thread the owner anyway
because the product owner explicitly mandated "seed as an ezagent **member**, not the system admin" and
"retire `system` to an admin marker" — legitimate design grounds — **and** because the same threading
delivers the north star: **any user creating a hello session in their own workspace, owned by them**
(the world-UI path, below). Treat owner-threading as design-cleanliness + generalization, not as the
thing that unmutes the greeter.

### 2.1 The owner-threading change surface

The session owner is derived from the *installer/caller*, and today that caller is hard-coded to the
system admin:

- `Definition.owner_uri/2` — `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:192`:
  `def owner_uri(%__MODULE__{owner_policy: %{type: :installer}}, caller), do: caller`. The hello
  definition's `owner_policy` is `:installer` (`app.ex:190`), so **owner == caller, verbatim.**
  (Aside, per "code wins": the `:fixed` policy is *rejected at validation* — `definition.ex:538-539` —
  so the `create_app` moduledoc comment at `app.ex:80-82` claiming the def is "`:fixed` to the system
  admin (D-5)" is **stale/inaccurate**; kimi should fix that comment, not trust it.)
- `EzagentPluginHello.App.create_app/3` — `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:63`
  takes `_opts` but **ignores it** and hard-codes `User.admin_uri()` at:
  - `app.ex:84` — `Installation.owner_uri_for_template(content, workspace, User.admin_uri())` (owner fallback)
  - `app.ex:104` — `Installation.install_template_installs(session_uri, workspace, content, User.admin_uri())` (install actor)
  - `app.ex:198` — `seed_hello_definition` → `actor_uri: User.admin_uri()`
- `EzagentPluginHello.FusionSeed.apply_seed/2` — `fusion_seed.ex:57,58` drives the page turn +
  shell as `User.admin_uri()`.
- `EzagentPluginHello.Template.HelloSession.instantiate/3` — `hello_session.ex:48` calls
  `App.create_app(workspace_name, session_name)` with **no caller** (the world-UI create path drops it).

**Design requirement.** `create_app` (and the `FusionSeed`/`OfficialSiteSeed` chain that reaches it)
MUST accept an **owner/caller principal** and use it for owner-resolution and the page-drive turn.
Then:
- The **boot 官网 seed** passes the `ezagent`-workspace owner principal → owner is an `ezagent` member
  → `owner-ws == session-ws == ezagent`.
- The **world-UI create path** (`HelloSession.instantiate/3`, which runs inside the
  `Workspace.create_session` dispatch — `provisioning.ex:104-124`, whose Behavior already documents
  "the caller becomes the session owner", `behavior/workspace.ex:634`) threads its dispatch caller
  through → **any user gets a hello session owned by them in their own workspace, for free.**

This generalization is the point. The 官网 is one caller of the generic path; do not special-case it.

> **Impl-constraint (kimi picks the mechanism, don't over-build):** the create-session caller must
> reach `create_app`'s owner resolution + the seed's page-drive turn. Simplest shape: give `create_app`
> an explicit `owner:`/`caller:` (replacing the ignored `_opts`), resolve owner from it, thread it from
> `FusionSeed.run` and from `HelloSession.instantiate/3`. The internal install/materialize actor may
> stay a trusted boot/self-authority context — what MUST become an `ezagent` principal is the **session
> owner** and the **page-drive turn author** (so the durable owner + granter are `ezagent`, not `system`).

---

## 3. Single-source workspace config (kill the split-brain)

Define **ONE** configurable source of truth for "the hello home workspace", default **`ezagent`**, that
**both** the seed side and the serve side read. A mismatch must be structurally impossible.

**Design:**
- One app-env key owned by the hello plugin, e.g. `config :ezagent_plugin_hello, :home_workspace, "ezagent"`,
  exposed via a single accessor (e.g. `EzagentPluginHello.home_workspace/0`).
- **Seed side:** `official_site_seed.ex` `@workspace` and `fusion_seed.ex` `@default_workspace` both
  read that accessor (delete the two `"system"` literals).
- **Serve side:** `chat_feed_controller.ex:92` reads the SAME key
  (`Application.get_env(:ezagent_plugin_hello, :home_workspace, "ezagent")` — no compile dep needed for
  `Application.get_env`). **Delete** `:ezagent_web, :hello_workspace` (`config/config.exs:67`) and its
  `"demo"` fallback so there is exactly one key.
- **Credential-bridge destination** reads the SAME key too — see §6 (this is the part that survives
  adversarial review only if framed correctly).

> **Impl-constraint:** the accessor is the single read point; no caller passes the workspace as an
> argument to the credential path (preserve the #185 no-caller-redirect property — §6). SPEC fixes the
> design (one key, both sides + bridge read it, default `ezagent`); kimi may choose the exact module/key
> name. Add an invariant test asserting seed-workspace, serve-workspace, and bridge-destination are the
> *same* value (see §8).

**Per-env note:** currently no `dev.exs`/`prod.exs`/`runtime.exs` overrides `hello_workspace` (only
`config.exs:67`). If a lane ever needs a different home workspace, it overrides the single key — but the
default is `ezagent` for all envs.

---

## 4. Seed rewrite: mimic an ezagent member creating `ezagent-official`

**From:** "provision `system/hello/web` via a system-privileged seed."
**To:** "as the `ezagent`-workspace owner, create `ezagent-official` in `ezagent`, install hello,
drive the committed page, page is public."

### 4.1 Which principal the seed mimics (the linchpin's concrete input)

The seed runs at boot in a system context but must produce an **`ezagent`-member-owned** session.
Resolve the principal deterministically: the `ezagent` workspace records its founder/creator in
`created_by` — `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:61` (`field :created_by`),
surfaced on the row struct (`store.ex:224`). So:

- **Owner principal = the `ezagent` workspace's `created_by`** (its founder/owner), resolved at seed
  time via the workspace store read. Pass that URI as the `create_app` owner/caller (§2).
- **Flag (deploy input):** the exact founder URI is deploy state, not a repo constant. PR-2 defines the
  *resolution rule* ("the home workspace's `created_by`"), and **must not hard-code a username.** If a
  deploy's `ezagent` workspace has no `created_by`, that is a fail-loud precondition for the seed (log +
  skip, same fail-soft posture as today's credential step) — do not silently fall back to `admin` (that
  would re-introduce a `system`/`ezagent` owner mismatch).

### 4.2 Session name: `web` → `ezagent-official`

`official_site_seed.ex:71` `@name "web"` → `@name "ezagent-official"`. The 官网 URI becomes
`session://ezagent/hello/ezagent-official`; the public URL becomes `/hello/ezagent-official` (via
`chat_feed_controller.show_by_name/2`). See §7 for the full rename parity audit — this string appears in
several places and a partial rename silently breaks the page.

### 4.3 The three sub-steps are already covered — only ws/owner/name change

The current `FusionSeed.run` already: (a) `App.ensure_app` creates the session + installs the hello
Definition + materializes the four+ role members; (b) `apply_seed` drives `body.json` + `shell.css`
onto the Surface. **"Set public" is already declared** in the definition —
`visibility_policy: %{publish_policy: :auto, web_anon_access: true}` (`app.ex:189`). The anon-admit gate
is **definition-based and workspace-independent** (code-verified): `chat_feed_controller` →
`PublicView.web_anon_access?/1` (`public_view.ex:18-19`) → `Installation.web_anon_access?/1`
(`installation.ex:277-283`), which reads the installed **definition's** `visibility_policy.web_anon_access`
— NOT the template-content `public_view?` key. Because it reads the definition installed on the session
(whatever workspace the session lives in), the workspace move **preserves** public-visibility with no
extra step; installing the hello definition IS setting it public. **The only deltas are: home workspace
(§3), owner principal (§4.1), session name (§4.2), and the credential destination (§6).** Keep PR-2 minimal.

### 4.4 Seed entry points that change

- `official_site_seed.ex`: `@workspace`→ accessor (§3); `@name "web"`→`"ezagent-official"`; `site_uri/0`
  (L81) follows; `provision/0` (L153-161) passes the resolved owner into `FusionSeed.run`; moduledoc
  (L1-59) rewritten to describe the `ezagent`-member instance (not the `system` singleton).
- `fusion_seed.ex`: `@default_workspace`→ accessor; `run/1` (L28-41) accepts + threads an `owner`/`caller`;
  `apply_seed/2` (L55-61) drives the turn as that owner instead of `User.admin_uri()`.
- `app.ex`: `create_app/3` (L63) honors the owner (L84/L104) and threads it to `seed_hello_definition`
  (L198); `ensure_app/3` (L35) passes it through; `hello_session.ex:48` threads its caller.

---

## 5. Agent/routing migration

**Good news: the routing table migrates unchanged.** The team + routing live as **relative role names**
in the hello Definition, not workspace-absolute URIs:

- `App.hello_definition_attrs/1` — `app.ex:146-192`:
  - `roles` (L158-171): `front-desk` (recipe `hello.front-desk`, flavor `hello`), `builder`, `concierge`,
    `llm` (curl), `sharer`, `publisher`, `dispatcher`.
  - `routing_rules` (L172-179): `{"matcher"=>{"type"=>"always"}, "receivers"=>["front-desk"], "rule_set"=>"default"}`.
  - The recipes are workspace-agnostic role recipes registered by the plugin
    (`application.ex:94-103` `roles/0`; `hello_llm_recipe/0` L143-159).

Members materialize as per-session agents **in the session's workspace** (`entity://ezagent/agent/<uuid>`
by role_name facet), so moving the session to `ezagent` moves the whole team + the `{always}→[front-desk]`
relay into `ezagent` automatically. **No routing_rules edit, no receiver-URI rewrite.** The Definition is
seeded per-workspace via `DefinitionRegistry.seed_definition_if_absent(..., workspace_uri:
Ezagent.URI.workspace(ws))` (`app.ex:194-200`), so with `ws=ezagent` the definition + team land in
`ezagent`. Builder/concierge/llm/sharer/publisher/dispatcher all ride along.

**What PR-2 must NOT do:** invent new routing rules or per-workspace receiver URIs. The migration is
"the session moves workspace; the relative-role routing table is carried by the Definition." Confirm via
the pass-after test (§8) that the `{always}→front-desk` relay fires in `ezagent`.

---

## 6. The credential path — CONFIRMED BLOCKER (the earlier note is wrong) + the fix

> **Finding (confirmed against code + a shipping test, not a "possible risk"):** moving the 官网 to
> `ezagent` **breaks the greeter's LLM** unless the DeepSeek shared-curl source is provisioned **in
> `ezagent`.** The credential is **workspace-scoped**, not resolved via any "workspace-agnostic
> `system://` authority." That earlier framing conflated *the system workspace* with a nonexistent
> workspace-agnostic authority.

### 6.1 Why it breaks — every path is closed

The `hello.llm` role is credential-optional with **no explicit source** — the key comes purely from the
platform cascade (`application.ex:143-159`: `credential_optional: true`, no `credential_source_uri`).
That cascade is strictly `(workspace, flavor)`-keyed:

1. **Resolver** — `apps/ezagent_core/lib/ezagent/credential/resolver.ex:152-175` +
   `:340-354`: `pick_credential_source` resolves workspace-shared via
   `workspace_shared_source(workspace_uri, flavor)` — arg is `{workspace_uri, flavor}`.
2. **Store** — `apps/ezagent_core/lib/ezagent/credential/workspace_shared_source.ex:32,51-58`: the row
   PK is `"#{workspace_uri}|#{flavor}"`; `resolve("workspace://ezagent","curl")` is a *different row*
   from `"workspace://system|curl"`.
3. **Writer forbids cross-workspace source** — the chokepoint
   `apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_shared_credential_source.ex:97-125`
   (`validate_source_workspace/2`) requires the pointed source agent to be **in the same workspace** →
   you cannot register `entity://system/agent/hello-deepseek-credential-source` as `ezagent`'s shared
   source (`:source_workspace_mismatch`).
4. **Grant mint forbids cross-workspace source** — `resolver.ex:277-278`:
   `Capability.workspace_of(agent_uri) != Capability.workspace_of(source)` →
   `:agent_source_workspace_mismatch`.
5. **The shipping isolation test proves it** —
   `apps/ezagent_plugin_hello/test/integration/hello_credential_source_test.exs:182-217`
   ("a hello app in a DIFFERENT workspace stays keyless"): `App.ensure_app(plain_ws,"main")` →
   `llm` member's `:api_keys` has no `deepseek`, `GrantRow` is nil. `ezagent ≠ system` is exactly that
   "different workspace" case.

So the 官网 `llm` member cold-spawned in `ezagent` resolves `(workspace://ezagent, curl)` → **absent →
keyless → `{:no_api_key, "deepseek"}`** at the visitor's first cold reply. **The greeter goes mute
again — a different failure than the isolation denial, but the same user-visible symptom.**

### 6.2 The fix: the credential-bridge destination follows the single-source config

The bridge (`credential_bridge.ex`) currently pins `@system_workspace "system"` (L80) and is
**deliberately zero-arity / non-caller-redirectable** (#185 review; `ensure_deepseek_source/0` L119-135;
test asserts `refute function_exported?(…, 1)`, `hello_credential_source_test.exs:88`).

**Change:** the bridge's destination reads the **same single-source config accessor as §3** (default
`ezagent`) instead of the `"system"` literal. The env-key → curl-source flow is otherwise unchanged:
it spawns `entity://<home-ws>/agent/hello-deepseek-credential-source`, stores the key, and registers it
as `<home-ws>`'s shared curl source. With home-ws = `ezagent`, the 官网 `llm` resolves it → born
credentialed.

**Why re-pointing is the CORRECT change (the positive reason, not just "less bad than B"):** the shared
DeepSeek source is **normal infrastructure**, and `system` is being retired to an admin-privilege marker
(the north star for this whole effort). Normal infra must not live in `system`; it follows the hello home
workspace. Leaving the bridge on `system` would leave a piece of ordinary credential infra stranded in the
workspace we are explicitly emptying — inconsistent with the retirement. Re-pointing it to the single home
config is what makes `system` actually empty of "normal" state.

**Why it survives the #185 adversarial review (frame it exactly this way):**
- #185's actual threat model was a **caller-supplied, per-invocation redirect** — the arity-1
  parameter by which *any caller* could copy the real `DEEPSEEK_API_KEY` + admin authority into an
  *arbitrary* workspace. That hole stays closed: **no function argument is added** (`refute
  function_exported?(…, 1)` stays green), and no caller can redirect the destination.
- A **single deploy-config constant read once at boot** is a *different, acceptable* class: the
  destination is still not caller-redirectable; it is the one deploy-authoritative home workspace. The
  key still flows to exactly one workspace — now `ezagent` (the retired-`system`'s replacement as the
  hello home), not an attacker-named one.
- **Option B considered and rejected** (name it in the review so it's visibly dismissed): keep the
  bridge pinned to `system` and have `OfficialSiteSeed` provision a *second* `ezagent` curl source. That
  either re-reads `DEEPSEEK_API_KEY` in a second place (spreads the env-key surface — worse for #185) or
  copies from the `system` source into `ezagent` (the exact cross-workspace copy #185 forbids, and
  blocked anyway by `validate_source_workspace`). Option A (single config) is strictly better.

**Tests this change breaks — respec them as part of PR-1 (do not leave to blow up CI):**
- `hello_credential_source_test.exs`:
  - "prod entry" block hard-asserts `system`: L91-108 (`source_uri == entity("system",…)`, `resolve("workspace://system","curl")`), L98-102, and L117. Respec to assert the **configured home workspace** (`ezagent` by default), driving the same real cap-checked chokepoint.
  - **Keep** L84-89 (`refute function_exported?(…,1)`) — it is the preserved #185 invariant; call that out.
  - The arbitrary-workspace fixture tests (L149-217) already parametrize `ws` — they stay valid as-is
    (they prove the cascade + isolation for *any* seeded ws; `ezagent` is just one).
- `credential_bridge.ex` moduledoc (L1-135) + `official_site_seed.ex` moduledoc (L1-59, esp. L27-35,
  L67-70): rewrite the `system`-literal + isolation rationale to the "single deploy-config home
  workspace, still non-caller-redirectable" framing above.
- `config/config.exs:31-46` comments reference the `system` bridge — update.

---

## 7. `web` → `ezagent-official` rename — full parity audit (grep-verified)

A partial rename silently breaks the page (URL + absence-gate both key on the exact session URI). Every
`hello/web` / `"web"` reference on main (`session://system/hello/web` → `session://ezagent/hello/ezagent-official`):

| file:line | what | change |
|---|---|---|
| `official_site_seed.ex:70` | `@workspace "system"` | → accessor (§3) |
| `official_site_seed.ex:71` | `@name "web"` | → `"ezagent-official"` |
| `official_site_seed.ex:4,14,36,67-68,79,93` | moduledoc `system/hello/web`, `/hello/web` | rewrite (§4.4) |
| `official_site_seed.ex:81` | `site_uri/0` builds `session(@workspace,:hello,@name)` | follows attrs |
| `fusion_seed.ex:14` | `@default_workspace "system"` | → accessor |
| `fusion_seed.ex:19` | moduledoc "canonical `system/hello/fusion`" | update |
| `application.ex:221,277,312` | boot moduledoc/log; log literally says "open /hello/web" (L312) | update to `/hello/ezagent-official` |
| `config/config.exs:39` | comment `session://system/hello/web` | update |
| `config/config.exs:67` | `:ezagent_web, hello_workspace: "system"` | **delete** (§3) |
| `scripts/refresh_hello_site.exs:6,673,674,675` | PR-4 operator tool drives `session://system/hello/web` + `App.ensure_app("system","web")` in 3 spots | update (PR-4 — coordinator-gated, §12) |
| `apps/ezagent_web/.../chat_feed_controller.ex:92` | `Application.get_env(:ezagent_web,:hello_workspace,"demo")` | → single key (§3) |
| `apps/ezagent_web/.../router.ex:207` | comment `session://<hello_workspace>/hello/<name>` | update |
| `official_site_seed_test.exs:4,42,44,46` | asserts `session("system",:hello,"web")` | respec (§8) |

**Note (leave as-is):** `hello_greeter_relay_repro_test.exs:61` uses `App.ensure_app(ws,"web")` with an
*arbitrary* per-test `ws` and the literal name `"web"` — that is NOT the 官网; it's a generic
same-workspace relay repro. It stays valid. (Optional: rename its local literal to avoid reader
confusion, but not required.)

**Deploy consequence (PR-4 / open question):** the public URL changes `/hello/web` → `/hello/ezagent-official`.
Any external links to `/hello/web` break. Decide (coordinator): accept the new canonical URL, or add a
redirect/alias `/hello/web → /hello/ezagent-official`. Flagged in §12/§14.

---

## 8. The fail-before / pass-after test (kimi writes this)

Add an integration test (`apps/ezagent_plugin_hello/test/integration/`) that encodes the whole point.
Model it on the **anonymous-visitor** path (the 官网's real users), not just a logged-in member — the
anon path is the one that must work in production.

**Fail-before (proves the bug, on pre-fix code / a `system`-pinned session):**
- Create the hello app in `system` (`App.ensure_app("system","web")`), user/anon in `ezagent`.
- A `send` from the `ezagent` principal to the greeter/front-desk trips
  `do_workspace_isolation_check` → **`{:error, :cross_workspace_denied}`** (assert this exact atom is
  reachable when `caller_ws=ezagent, target_ws=system`).

**Pass-after (proves the fix):**
- Create the hello app in `ezagent` owned by an `ezagent` principal (`App.ensure_app("ezagent",
  "ezagent-official", owner: ezagent_owner_uri)`), with a `ezagent`-workspace user/anon sender.
- The same `send` → the isolation check returns `:ok` (same-workspace), the `{always}→front-desk`
  relay fires, and the greeter relays (reuse the genuine-runtime-receive primitive
  `Ezagent.ActionSet.Session.Delivery.dispatch_receive_call/3` — see the pattern in
  `hello_greeter_relay_repro_test.exs:58-98`).
- **Keyless is an acceptable downstream stop** (clear `DEEPSEEK_API_KEY` like the greeter repro does):
  the acceptable failure is the concierge/llm's `{:no_api_key,"deepseek"}` *past* the resolver — that
  proves the workspace gate opened. (The credential §6 change is validated separately by the respec'd
  `hello_credential_source_test.exs` asserting the `ezagent` home workspace.)

**Plus an invariant/config test (PR-1):** assert seed-workspace == serve-workspace ==
credential-bridge-destination (all read the one accessor; default `ezagent`) — so a future edit can't
re-open the split-brain. (Memory: "completion = an invariant test that fails when the goal is unmet.")

**Anon-path confirmation (already code-verified — bake into the assertion, don't re-derive):**
`Ezagent.Socialware.AnonUser.mint_for_public_session/1`
(`apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex:60-68,118-121`) mints the anon into
**the session's workspace** (`entity://<session-ws>/user/anon-…`, derived via `workspace_of(session_uri)`).
So with the session in `ezagent`, the anon is an `ezagent` principal → `caller_ws == target_ws == ezagent`
→ the isolation check passes for anons exactly as for members. **There is no second cross-workspace trap
on the anon path.**

---

## 9. Per-lane `system`: what legitimately stays (the answer, not a hand-wave)

Grep of all non-test `"system"` workspace literals on the hello + serve surface resolves to two classes:

- **Instance + credential lanes (this spec moves them → `ezagent`):** `official_site_seed.ex`,
  `fusion_seed.ex`, `credential_bridge.ex`, `config.exs:67`, `chat_feed_controller.ex:92`.
- **Definition-publish lane (STAYS `system` — out of scope):** the reusable socialware **Definition**
  registry publish. `Ezagent.Socialware.ManifestSeed.import_package/2` /`scan_all!` uses
  `ManifestYaml.operator_admin_ctx(name, Ezagent.URI.workspace(:system))` —
  `apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex:160`. This is the
  **platform/operator-admin context for publishing reusable templates** (kanban / autoservice / the
  shared hello Definition) available registry-wide — i.e. `system` used exactly as the "admin-privilege
  marker" the retirement keeps. It is NOT the 官网 instance and NOT where user sessions live. **Do not
  touch it in hello A.** (If the platform later moves definition-publishing off `system`, that's a
  separate, broader change.)

---

## 10. Consolidated file:line change map

| # | file:line (main `22fe5436a`) | change | PR |
|---|---|---|---|
| 1 | `config/config.exs:67` | delete `:ezagent_web, hello_workspace: "system"` | 1 |
| 2 | new: `config :ezagent_plugin_hello, :home_workspace, "ezagent"` + accessor (e.g. `EzagentPluginHello.home_workspace/0`) | add single source | 1 |
| 3 | `apps/ezagent_web/.../socialware/chat_feed_controller.ex:92` | read the single key (default `ezagent`) | 1 |
| 4 | `apps/ezagent_web/.../router.ex:207` | comment update | 1 |
| 5 | `credential_bridge.ex:80` (+ moduledoc L1-135, uses at L106,109,114,127-135) | destination reads the accessor; keep zero-arity | 1 |
| 6 | `hello_credential_source_test.exs:91-108,117` | respec asserts home ws (`ezagent`); keep L84-89 | 1 |
| 7 | `config/config.exs:31-46` (+ `config/test.exs:135-141`) | comment updates re bridge/site ws | 1 |
| 8 | `official_site_seed.ex:70` | `@workspace` → accessor | 2 |
| 9 | `official_site_seed.ex:71` | `@name "web"` → `"ezagent-official"` | 2 |
| 10 | `official_site_seed.ex:81,153-161` + moduledoc | `site_uri`/`provision` follow; pass owner; rewrite doc | 2 |
| 11 | `fusion_seed.ex:14,19,28-41,55-61` | `@default_workspace`→accessor; thread owner; drive turn as owner | 2 |
| 12 | `app.ex:63,84,104,198` (+ stale doc L80-82) | `create_app` honors owner/caller; fix `:fixed` comment | 2 |
| 13 | `app.ex:35` (`ensure_app/3`) | thread owner through | 2 |
| 14 | `template/hello_session.ex:48` | thread create-session caller into `create_app` | 2 |
| 15 | `application.ex:221,277,312` | boot doc/log `/hello/web` → `/hello/ezagent-official` | 2 |
| 16 | `official_site_seed_test.exs:4,42,44,46` | respec to `session("ezagent",:hello,"ezagent-official")` | 2 |
| 17 | new integration test (§8 fail-before/pass-after + anon) | add | 2 |
| 18 | `scripts/refresh_hello_site.exs:6,673-675` | operator tool → `ezagent`/`ezagent-official` | 4 (gated) |
| — | `manifest_seed.ex:160` | **NO CHANGE** (out of scope, §9) | — |

---

## 11. PR split

**Single target branch, PRs land in order (phased handoff, receiver merges P1→P2→… onto one branch).**

- **PR-1 — config single source + credential-bridge de-hardcode + config-invariant test.**
  - Add the one `:home_workspace` key + accessor (default `ezagent`); point serve
    (`chat_feed_controller.ex`) at it; delete `:ezagent_web, :hello_workspace`.
  - Re-point the credential-bridge destination at the accessor (keep zero-arity; §6 framing).
  - Respec `hello_credential_source_test.exs` (assert `ezagent`; keep the `refute arity-1`); update
    bridge/site/config moduledocs + comments.
  - Add the invariant test: seed-ws == serve-ws == bridge-dest.
  - **Sequencing note:** PR-1 flips the bridge to seed the `ezagent` curl source *before* PR-2 moves the
    session there. On the single branch this is moot (both land before deploy), but do not deploy PR-1
    alone — it and PR-2 are one shippable unit.

- **PR-2 — seed-as-ezagent-member + `create_app` caller threading + routing + fail-before/pass-after test.**
  - Thread owner/caller through `create_app`/`ensure_app`/`FusionSeed`/`HelloSession.instantiate`.
  - Resolve the owner as the `ezagent` workspace's `created_by` (fail-loud if absent; §4.1).
  - Flip `@workspace`/`@default_workspace`/`@name` (`ezagent`/`ezagent-official`); rewrite moduledocs;
    complete the rename parity audit (§7).
  - Routing rides along unchanged (§5) — confirm via the pass-after test.
  - Add the §8 integration test (member + anon).

- **PR-3 — migration dry-run tooling / staging validation (in-repo, safe).**
  - Verify on a fresh/isolated stack (docker fresh seed) that boot self-heals `ezagent-official` in
    `ezagent`, the greeter relays (member + anon), and the page renders at `/hello/ezagent-official`.
    Agent-browser screenshot is the sign-off bar (memory: ALWAYS agent-browser for UI). No live-node writes.

- **PR-4 — DEPLOY MIGRATION — DESCRIBE ONLY, coordinator-gated, do NOT auto-run.** See §12.

---

## 12. PR-4 — deploy migration (coordinator executes canary → beta → stable manually)

**Context:** `session://system/hello/web` already exists on **canary / beta / stable** (Docker containers
on this host; the *live* session is owned by the separate `Hyprial/ezagent-deploy` repo). This is a live
data migration; **kimi must NOT auto-run it.** Mark PR-4 as coordinator-gated. Steps to spec (per node,
canary first, halt-and-verify between environments):

1. **Provision the new instance in `ezagent`.** Boot with PR-1+PR-2 self-heals `ezagent-official` from
   absence (`OfficialSiteSeed.ensure/0` absence-gate), or run the updated
   `scripts/refresh_hello_site.exs` (now `ezagent`/`ezagent-official`, §7/§10) against the live node's
   BEAM to drive the page. Verify `/hello/ezagent-official` renders + greeter relays (member + anon).
2. **Provision the `ezagent` DeepSeek curl source.** PR-1's bridge seeds `(workspace://ezagent, curl)` at
   boot when `DEEPSEEK_API_KEY` is present. Verify `WorkspaceSharedSource.resolve("workspace://ezagent","curl")`
   is set and the `ezagent-official` `llm` member is born credentialed (a live cold reply, not just the slice).
3. **Per-node member-cap backfill.** Run `mix ezagent.migrate.member_caps --dry-run` then (after review)
   apply — `apps/ezagent_domain_session/lib/mix/tasks/ezagent.migrate.member_caps.ex` (core logic
   `Ezagent.Session.MemberCapMigration`; idempotent, safe on a running node). This backfills the universal
   member-cap onto the new session's members (mirrors #195 Phase M's read-plane member-cap concern; the
   memory `readplane_membercap_lockout` warns a cutover can leave non-owner members with 0 verified caps).
4. **Retire the old `system/hello/web` session** only AFTER the new one is verified live: retract its
   installs / terminate it so nothing normal remains in `system` (the retirement north star). Keep creds.
5. **URL:** decide `/hello/web` redirect vs. hard cutover (§7 / §14).

**Coordinator caveats (from memory):** clear stale home socialware/agent dirs on cutover (keep creds) or
boot may crash-loop; agent-reply cold-start can hold beta/stable; verify each node before advancing.
Never admin-merge a security-sensitive PR on self-review — the credential-touching PR-1 needs the named
review gate (codex, or the opus subagent fallback).

---

## 13. Adversarial-review focus points (call these out so the reviewer attacks the right things)

1. **#6 credential reconciliation vs. #185.** Confirm the single-config destination preserves #185's
   real invariant (no caller-supplied per-invocation redirect; `refute function_exported?(…,1)` green) and
   that Option B is correctly rejected. This is the highest-risk change.
2. **#2 owner threading — correctness AND necessity framing.** The isolation fix does NOT depend on the
   owner (§2a: the check reads only caller/target ws). Verify the review agrees the greeter unmutes on
   the workspace flip alone, so owner-threading is scoped as design/generalization. Then check the owner
   DOES reach `spawn_kind(Session, %{owner_uri:…})` (`app.ex:88-96`) as an `ezagent` principal on BOTH the
   boot-seed and world-UI paths — a missed path leaves a `system`/`ezagent` owner mismatch that, while not
   breaking the greeter, defeats the stated "seed as member" design + the any-user generalization.
3. **Rename completeness (#7).** Any surviving `system/hello/web` or `"web"` literal that keys the URL or
   the absence-gate = a silently-dead 官网. Parity-audit `diff == ∅` against the §7 table.
4. **Routing really is carried by the Definition (#5)** — no hidden workspace-absolute receiver URI.
5. **manifest lane correctly left `system` (#9).**

---

## 14. Open questions / deploy inputs (for the coordinator, not kimi)

- **Founder principal:** the `ezagent` workspace's `created_by` on each live node — confirm it exists
  (PR-2 fails loud if not). Is the founder the right owner, or should the 官网 be owned by a dedicated
  `ezagent`-workspace service user? (Recommendation: founder/owner is fine; owner is only used for
  owner-routing + anon-view-cap granter.)
- **`/hello/web` URL:** redirect alias vs. hard cutover to `/hello/ezagent-official`.
- **`system` retirement scope:** hello A empties `system` of the 官网 instance + hello credential. The
  manifest Definition-publish lane (§9) still uses `system` as the admin marker — confirm that is the
  intended end-state ("`system` = admin-privilege marker only" includes "reusable-template publish
  context").

---

## Addendum: adversarial review outcome + coordinator decisions (2026-07-22)

**Adversarial review verdict: SOUND / ready for kimi.** Traced join→send→greeter→builder/concierge + the anon born-with cap path; NO residual cross-workspace `:missing_cap`. Fold the below before implementing.

### Coordinator decisions (Allen)
- **REDO, not patch.** Reuse the page materials, but RE-IMPLEMENT per ezagent's current capabilities/standards — do NOT carry forward the old workarounds that were hardcoded to dodge then-missing features.
- **Founder principal** = the `ezagent` workspace's real DB owner (`created_by`); if absent OR system-admin, use **`entity://ezagent/user/lin_yilun`** (a real ezagent-workspace user with admin privileges). **NEVER `entity://system/user/admin`** as the 官网 owner.
- **Credential** migrates to `ezagent` too (§6 as written).
- **`/hello/web`** → **hard cutover** to `/hello/ezagent-official`, no redirect.
- **Shared templates STAY in `system`.** Only the 官网 INSTANCE session moves to ezagent; the reusable socialware **definition/template publish** lane (`manifest_seed.ex:160` → `Ezagent.URI.workspace(:system)`) is a platform-admin namespace and is **out of scope** (do not move it).

### Review should-fixes (fold in)
1. **Owner must resolve to a non-admin ezagent founder BEFORE any seed-side workspace auto-creation.** On a fresh/wiped stack the credential bridge creates `ezagent` admin-owned (`credential_bridge.ex:148-149`) before owner resolution → 官网 comes up admin-owned (owner-ws=system ≠ session-ws=ezagent), silently defeating "seed as member." Fix: (a) resolve owner before seed-side `Workspace.create`; (b) treat a system/admin `created_by` as "no valid founder" → fall back to lin.yilun; (c) PR-3's fresh docker harness must seed the home workspace + a non-admin founder FIRST. (Keyless variant: `fusion_seed.ex:87-94` creates `ezagent` with no `created_by` → fail-loud — the harness precondition covers it.)
2. **Acceptance is layered — state it.** hello A (workspace flip + §6 credential) cures the **anonymous** visitor path (the 官网's real audience; born-with `join_cap` is issued under system-admin authority, workspace-independent, verifies in ezagent). The **logged-in ezagent member** join-cap grant (`do_grant_join_cap`) is **#195 Phase M**, out of scope here. Model the fail-before test on an ezagent principal, pass-after on the **anon** path. Do NOT set acceptance as "hello A alone lets a logged-in member join."

### Constraint notes (not blockers)
- §6 test respec: also flip `Workspace.spawn_workspace("system")` / `terminate(entity("system",…))` in `hello_credential_source_test.exs:65,78`, not just the resolve/source_uri asserts.
- Single-source accessor: call `home_workspace()` INLINE (`Keyword.get(opts, :workspace, home_workspace())`), never a compile-time `@attr` (reads config at compile time).
- §2b: on origin/main the anon `join_cap.granted_by` is a HARDCODED `User.admin_uri()` issued under `{:admin, system-admin}` (`anon_user.ex:169-186`) — owner-independent. Do NOT wire the (ezagent) owner into the anon grant; it already verifies workspace-independently.
- §1: anons already pass isolation TODAY on the `system` 官网 (minted into the session's ws). The present-day break is the logged-in ezagent member. Keep the fail-before using an ezagent principal.

### CAVEAT for kimi
Branch from **`origin/main`**, NOT the working tree — the checked-out `spec/orchestrator-session-config-api-and-surfaces` branch has diverged and removed/trimmed several hello files. All spec file:line refs are verified against `origin/main`.
