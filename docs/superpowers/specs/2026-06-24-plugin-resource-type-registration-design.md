# Plugin-owned `resource://` type registration — design

> Status: design (approach A approved 2026-06-23; rev2 incorporates codex
> adversarial-review — HIGH-1 backend-aliasing, HIGH-2 restart, HIGH-3
> component-name, HIGH-4 R-3 scope, HIGH-5 batch atomicity, HIGH-6 naming,
> HIGH-8 migration). Lead: Allen.
> Supersedes the `HomePathExceptions` anchor for world `layout_dir/0`.

## 1. Problem

`Ezagent.Resource.FsResolver` is the hardened seam for tenant-scoped on-disk
artifacts addressed by `resource://<ws>/<type>/<name>` — it does traversal
rejection, a closed `<type>` allowlist, and a per-`<type>` authority check
before `Ezagent.Home.path/1` is ever touched. Its `<type>` allowlist is built
**once at `Registry.init/1`** from `Registry.boot_registrations/0`, a function
**inside `ezagent_core`**.

Today that function hardcodes flavor-specific types:

```elixir
@config_dir_namespaces ["cc", "codex"]   # → "cc-agents", "codex-agents"
@uploads_type "uploads"
```

with an explicit comment that the cc/codex namespaces are "listed here
statically because the resolver allowlist is immutable at boot and **must not
depend on plugin Application start ordering**." That is a live **tier smell**:
core names plugin concepts (`cc`, `codex`). And it blocks any *new* plugin from
owning a `resource://` type without editing core — which is exactly why the
world plugin's layout store still uses **raw `Ezagent.Home.path("world/layouts")`**
(an exact-anchored `HomePathExceptions` entry, one of the two remaining
`raw_home_path_outside_core`).

**Goal:** let a plugin contribute its own `resource://` `<type>` definitions via
the existing plugin contract — the same way it already contributes Behaviors,
Templates, Flavors, and Routing tables — **without core naming any plugin**, and
**without weakening** the resolver's security property (no runtime swap of a
type's authority function). Then migrate world `layout_dir` onto it (ratchet
`raw_home_path_outside_core` 2 → 1).

## 2. Goals / non-goals

**Goals**
- A `resource_types/0` optional callback on `Ezagent.Plugin`.
- Plugin types published during the existing `Ezagent.Plugin.boot/1` **Phase 2**,
  alongside Behaviors/Templates/Flavors/Routing.
- `Resource.FsResolver.Registry` accepts these via an **owner-only, write-once,
  no-overwrite, no-delete** `register/2` — preserving the anti-authority-swap
  property.
- First adopter: world `LayoutManager` migrates off raw `Home.path`.

**Non-goals (YAGNI / follow-ups)**
- Moving the existing `cc-agents` / `codex-agents` config-dir types out of core
  into the cc/codex plugins. The new mechanism *enables* this cleanup, but
  config-dir is load-bearing for agent spawn (Locked-contract #7, byte-identical
  path) — a separate, carefully-tested PR. Tracked as a follow-up.
- Hot unregister / runtime type removal. Out of scope (V2; would reintroduce the
  mutability the design forbids).
- Any change to `resolve/2`, the traversal guard, or the authority contract.

## 3. The security property, and why Approach A preserves it

The resolver's hardened guarantee (codex round-1..4) is: **no runtime code can
swap or remove a `<type>`'s `authority` function or `backend_component`** — that
would subvert the central FS auth boundary. Today this is enforced structurally:
the ETS table is `:protected` (writable only by the owning `Registry`
GenServer), entries are inserted with `:ets.insert_new/2` (**write-once** — a
duplicate `<type>` raises), and **no post-`init` write message exists**. The
earlier rounds rejected a `seal/0` because a *mutable reopen flag* could be
flipped to re-open the table.

**Approach A keeps every structural defense and removes only "no post-init write
message":** add a `register/2` GenServer call that performs the **same**
`validate_spec/2` + `:ets.insert_new/2` the boot loop already uses, **plus a new
`backend_component`-uniqueness check** (see below — closes the aliasing hole
codex HIGH-1 found).

- **Owner-only** — still the sole writer (it is a call handled in the Registry
  process; non-owner `:ets.insert` on a `:protected` table still raises).
- **Write-once on `<type>`** — `:ets.insert_new/2` makes a second registration of
  an existing `<type>` fail; `register/2` returns `{:error, {:duplicate_type, t}}`.
- **Write-once on `backend_component` (NEW, HIGH-1 fix)** — `register/2` ALSO
  rejects a spec whose `backend_component` is already claimed by any registered
  type: `{:error, {:duplicate_backend, b}}`. Without this, write-once on the key
  alone is insufficient: a plugin could register a *fresh* `<type>` whose
  `backend_component` is `"uploads"` with a *weaker* `authority/2`, then reach the
  same bytes through the new type — a cross-type authority bypass that never
  touches the protected `"uploads"` key. Backend-uniqueness makes the
  (type ↔ backend) mapping a bijection; the authority fn guarding a backend's
  bytes is therefore fixed by whoever registered that backend FIRST.
- **No overwrite, no delete** — there is no update or delete path, in any env
  except the existing `:test`-only `unregister_for_test`.
- **No reopen flag** — nothing mutable gates the decision; the table simply never
  accepts a second write to a key. The round-4 anti-seal concern does not apply.

**Threat analysis of the new capability (adding a *new* type at plugin boot):**
- A plugin **cannot** replace core's or another plugin's type (`<type>`
  write-once + core-registers-first, §5) **nor alias another type's bytes**
  (`backend_component` write-once + core-registers-first). Core's backends
  (`cc-agents`/`codex-agents`/`uploads`) are claimed at `init/1` before any plugin
  boots, so a plugin can never bind a weaker authority to a core backend.
- A plugin supplies its own `authority/2` — acceptable: plugins are first-party,
  in-process, fully-trusted umbrella code (same trust as a plugin defining a
  Behaviour or a spawn fn). Once registered, that authority fn is immutable AND
  the bytes it guards are reachable only through its own type (bijection).
- **Naming convention (HIGH-1/§6 collision hygiene):** plugin-contributed
  `<type>` AND `backend_component` SHOULD be plugin-slug-prefixed
  (`world-layouts`, not bare `layouts`) so two plugins never accidentally collide
  and brick startup. Enforced softly (a lint/test warns on a non-prefixed plugin
  type); core types keep their existing bare names.
- Net: the only new power is "a trusted plugin can append a type+backend pair it
  owns." No cross-type escalation, no authority swap, no backend aliasing.

## 4. Components

### 4.1 `Ezagent.Plugin` — new optional callback

```elixir
@type resource_type_decl :: {type :: String.t(), Ezagent.Resource.FsResolver.type_spec()}
@callback resource_types() :: [resource_type_decl()]
```

Added to `@optional_callbacks`; `__using__` provides `def resource_types, do: []`
+ `defoverridable resource_types: 0` (mirrors the other optional callbacks).

The `type_spec` is the EXISTING resolver type
(`%{backend_component: String.t(), authority: (URI.t(), scope() -> :ok | {:error, term()})}`)
— plugins reuse it, no new shape.

### 4.2 `Ezagent.Plugin.boot/1` — publish in Phase 2

`publish/1` (the private Phase-2 step) gains one more registration pass,
alongside the existing Behavior/Template/Flavor/Routing publishing:

```elixir
case Ezagent.Resource.FsResolver.Registry.register_all(plugin_module.resource_types()) do
  :ok -> :ok
  {:error, reason} ->
    raise ArgumentError,
      "#{inspect(plugin_module)} resource_types → #{inspect(reason)}"
end
```

Whole-batch (`register_all`) so the plugin contributes all its types or none
(HIGH-5: no dangling type if a later decl in the list is bad). Loud failure on a
duplicate/invalid type is correct — a collision is an operator/author error, not
something to swallow (consistent with how `publish/1` already rejects a plugin
`spawns/0`). Because `register_all` validates the whole batch before inserting,
the type only becomes visible once the plugin's entire resource declaration is
accepted.

### 4.3 `Resource.FsResolver.Registry` — owner-only write-once `register/2`

```elixir
# Batch register: ALL specs validated + collision-checked BEFORE any insert
# (HIGH-5: a partial insert can leave a dangling type if a later one fails).
@spec register_all([{String.t(), FsResolver.type_spec()}]) :: :ok | {:error, term()}
def register_all(decls), do: GenServer.call(__MODULE__, {:register_all, decls})

@impl true
def handle_call({:register_all, decls}, _from, state) do
  reply =
    with :ok <- Enum.reduce_while(decls, :ok, fn {type, spec}, _ ->
                  case precheck(type, spec) do
                    :ok -> {:cont, :ok}
                    err -> {:halt, err}
                  end
                end) do
      Enum.each(decls, fn {type, spec} -> true = :ets.insert_new(@table, {type, spec}) end)
      :ok
    end
  {:reply, reply, state}
end

# precheck = validate_spec + type-uniqueness + backend-uniqueness, NO write.
defp precheck(type, spec) do
  with :ok <- validate_spec(type, spec),
       :ok <- (if type_taken?(type), do: {:error, {:duplicate_type, type}}, else: :ok),
       :ok <- (if backend_taken?(spec.backend_component),
                 do: {:error, {:duplicate_backend, spec.backend_component}}, else: :ok) do
    :ok
  end
end
```

`validate_spec/2` and the ETS table layout are unchanged. `register_all/1` is a
serialized front door that **validates + checks BOTH uniqueness axes for the whole
batch, then inserts all (or none)** — so a plugin's partially-bad declaration
list registers nothing (HIGH-5 fix; combined with §4.2's whole-batch publish, a
plugin either contributes all its types or fails boot with nothing registered).
`backend_taken?/1` scans the table for any existing entry with that
`backend_component` (HIGH-1). `boot_registrations/0` (core types) still applies
first at `init/1` via the same prechecks; the moduledoc's "no post-init write"
wording becomes "post-init writes are **append-only, write-once on both `<type>`
and `backend_component`, owner-serialized, all-or-nothing per batch**; no
overwrite, no delete, no reopen flag."

### 4.4 World migration (first adopter)

- `EzagentPluginWorld.Application.resource_types/0` →
  `[{"world-layouts", %{backend_component: "world-layouts", authority: &world_layout_authority/2}}]`.
  **Single-segment `backend_component`** — `"world-layouts"`, NOT `"world/layouts"`
  (the existing `safe_component?/1` rejects `/`; HIGH-3). The resolver joins
  `Home.path("world-layouts")/<ws>/<name>`.
- `world_layout_authority(uri, scope)` asserts `EzURI.workspace_name(uri) ==
  scope.workspace` — same shape as `uploads_authority/2`. Per R-3, `scope` is the
  caller's AUTHENTICATED context, **never derived from `uri`**.
- **R-3 fix (HIGH-4): split the caller scope from the target URI.**
  `LayoutManager.read_layout/2` + `write_layout/3` take the layout's
  `scope_uri` (the target) AND the caller's authenticated `scope` as SEPARATE
  args, then build `resource://<ws>/world-layouts/<name>` and call
  `FsResolver.resolve(uri, scope)`. The current single-URI signatures
  (`read_layout/1`, `layout_path/1`, `Behavior.Layout`) thread the caller scope
  down from the cap-checked Behavior dispatch (the Behavior already has the
  authenticated caller). A test proves a `uri` naming a foreign `<ws>` under a
  different caller `scope` is rejected (not silently resolved).
  `<name>` = the existing `stable_key |> Base.url_encode64`.
- Delete the `layout_dir/0` anchor from `HomePathExceptions`; ratchet
  `raw_home_path_outside_core` **2 → 1** in `arch_baseline_manifest.exs`
  (the codex SUN_LEN socket is the sole remaining, genuinely un-migratable entry).

**On-disk migration (HIGH-8 — non-destructive AND clean 2→1):** the resolved path
moves from `world/layouts/<name>.json` to `world-layouts/<ws>/<name>.json`. To
preserve existing custom layouts WITHOUT leaving a runtime `Home.path` in the read
path, use a **one-shot eager migration** (a `mix ezagent.world.migrate_layouts`
operator task, run once at deploy): it lists `Home.path("world/layouts")/*.json`,
re-keys each under the new `world-layouts/<ws>/<name>` path via the resolver, and
deletes the old tree. After it runs, `LayoutManager`'s runtime read/write go
**purely through `FsResolver.resolve/2`** — no `Home.path` — so
`raw_home_path_outside_core` genuinely ratchets **2 → 1**. The migration task's
own `Home.path("world/layouts")` read is the already-sanctioned *operator
mix-task* class (same as `Ezagent.Home.Migration` / `ezagent.home.*` tasks already
in `HomePathExceptions`), anchored with an "operator migration, app-not-started"
reason — it is NOT runtime code and does not re-grow the runtime gate.

> If Allen prefers minimal effort over preserving existing layouts: skip the
> migration task entirely and accept that pre-migration custom layouts reset to
> `default_layout` once (regenerable; world layouts are recent + low-volume). That
> also lands 2→1 with zero migration code. **Recommended: the one-shot task**
> (preserves operator-authored layouts; tiny, runs once). Open question for Allen.

## 5. Ordering & conflict semantics

- **Core types register first** — `boot_registrations/0` at `Registry.init/1`,
  which runs when `ezagent_core` starts, **before** any plugin (plugins depend on
  core → start later). So a plugin can never shadow a core type (write-once +
  core-first).
- **Plugin types register at that plugin's Phase-2 boot** — no dependence on
  inter-plugin ordering for *correctness*; two distinct plugins owning distinct
  types never interact.
- **Same-type (or same-backend) collision across two plugins** → the second
  plugin's `register_all/1` returns `{:duplicate_type|:duplicate_backend, …}` →
  its `boot/1` raises → loud startup failure naming the offending plugin. To keep
  this from being a footgun (HIGH-6: one plugin bricking startup by claiming a
  name another needs), plugin types/backends are **slug-prefixed by convention**
  (`world-layouts`), and a test/lint flags a plugin declaring a bare
  (non-prefixed) type. Curated first-party plugin set → collisions are
  author-time errors caught loudly, which is the intended behavior.

- **Registry isolated restart (HIGH-2).** Plugin types live in the Registry's ETS,
  appended at plugin boot. If the Registry GenServer alone crashes and restarts
  under `:one_for_one`, `init/1` re-applies only core `boot_registrations/0` —
  plugin types vanish while the plugins stay up (silent partial availability).
  This is a **pre-existing class shared by every plugin-fed registry**
  (`BehaviorRegistry`, `TemplateRegistry`, `AgentFlavorRegistry` are populated the
  same way at Phase-2 boot). **Resolution (PR-1 audited the real siblings):**
  `BehaviorRegistry`/`TemplateRegistry`/`AgentFlavorRegistry` do NOT self-own their
  tables — `EzagentCore.EtsOwner` owns one `:public` table per registry; on an
  isolated `EtsOwner` restart ALL of them come back EMPTY (core + plugin), with no
  replay, relying purely on being a `:permanent` start-critical singleton that
  fails the node loud on a crash-loop. A `:public` table is unusable here (any
  process could `:ets.insert` a forged type spec, defeating the owner-only
  authority contract), so the resolver Registry keeps its self-owned `:protected`
  table (precedent: `Ezagent.NotificationSubscriptions`) and **adopts the identical
  start-critical-singleton posture**: on restart `init/1` re-applies
  `boot_registrations/0` (CORE types self-heal); plugin types are not replayed —
  exactly the siblings' behavior.

  **On the "never silently missing" requirement (codex HIGH):** in the rare window
  after a restart, a vanished plugin type resolves to `:none`. That is **fail-CLOSED
  — `:none` DENIES access, never grants** — so it is an *availability* blip during
  crash-recovery, NOT an authority bypass, and it is narrower than the EtsOwner
  siblings' window (their tables come back fully empty; the resolver's core types
  are already back). For the first adopter (world layouts) a `:none` degrades
  gracefully to `default_layout`. Two hardening fixes make this window vanishingly
  rare: (a) a malformed plugin `resource_types/0` can no longer CRASH the Registry
  (it is rejected as a normal error — codex MEDIUM), removing the main crash
  trigger; (b) resource registration is the LAST `Plugin.boot/1` step, so an
  upstream boot failure never half-registers. A regression test asserts core
  self-heal + that an absent type denies (fail-closed) rather than grants. Full
  cross-app re-publish (true "present again") is a deferred enhancement, not
  required for this fail-closed property.

## 6. Testing

- **Registry write-once unit:** `register_all` succeeds for fresh types; a second
  registration of the same `<type>` → `{:error, {:duplicate_type, _}}`; a spec
  whose `backend_component` is already claimed → `{:error, {:duplicate_backend, _}}`
  (HIGH-1); a malformed spec → `{:error, _}`; the table is unchanged after any
  rejected registration (no overwrite, no partial insert).
- **Batch all-or-nothing (HIGH-5):** a `register_all` batch whose 2nd decl is a
  dup inserts NEITHER decl (the 1st must not be left dangling).
- **Backend-aliasing attack (HIGH-1):** registering a fresh type with
  `backend_component: "uploads"` is rejected — proving a plugin cannot reach a
  core backend's bytes through a weaker-authority alias.
- **Owner-only:** a direct non-owner `:ets.insert(@table, …)` raises (protected).
- **Registry restart (HIGH-2):** the chosen restart treatment (§5) is asserted —
  after the Registry process restarts, a plugin-contributed type is either present
  again or the failure is loud; it is NEVER silently missing.
- **Plugin contract:** a fixture plugin declaring `resource_types/0` →
  `Plugin.boot/1` publishes it and `FsResolver.resolve/2` resolves its URIs; a
  fixture declaring a duplicate of a core type/backend → `boot/1` raises.
- **World R-3 (HIGH-4):** `read_layout`/`write_layout` round-trip under the
  caller's scope; a target `uri` naming a FOREIGN `<ws>` resolved under a
  different caller `scope` is REJECTED (the authority check is independent of the
  URI, not tautological); both-miss falls back to `default_layout`.
- **World migration (HIGH-8):** the one-shot task moves a legacy
  `world/layouts/<name>.json` to `world-layouts/<ws>/<name>.json` and the runtime
  read returns the preserved custom layout (no abandonment).
- **Arch gates:** `raw_home_path_outside_core` scan = 1 after the runtime
  `Home.path` is gone (the one-shot migration task's Home.path is the sanctioned
  operator-mix-task anchor, not runtime); `mix ezagent.check_invariants` green;
  full `mix precommit` EXIT=0 with every suite 0 failures (gate on BOTH
  EXIT=0 AND grep-confirmed per `feedback_precommit_exit_can_mask_failures`).

## 7. Decisions log

- **D1 — Approach A (write-once register) over strict-immutable collect-at-init.**
  Approved by Allen 2026-06-23. Consistent with how every other plugin
  contribution flows (Phase-2 publish); preserves anti-authority-swap via
  write-once + owner-only + no-overwrite/delete; avoids the boot-ordering
  fragility of collect-at-init.
- **D2 — Plugins supply their own `authority/2`.** Acceptable: first-party,
  in-process, fully-trusted code; immutable once registered.
- **D3 — cc/codex config-dir types stay in core for now.** The mechanism enables
  moving them to the plugins, but config-dir is spawn-load-bearing; deferred to a
  separate tested PR (follow-up).
- **D4 — World migration preserves custom layouts** via a one-shot operator
  migration task (default: recommended). Fallback if Allen prefers minimal:
  accept reset-to-default (still lands 2→1). (Revised after codex HIGH-8.)
- **D5 — `backend_component` uniqueness (codex HIGH-1).** `register_all` rejects a
  spec aliasing an already-claimed backend; type↔backend is a bijection so an
  authority fn cannot be bypassed via an alias type. Core backends claimed first.
- **D6 — Registry restart matches the sibling plugin-fed registries (codex
  HIGH-2).** PR-1 audits `BehaviorRegistry`/`TemplateRegistry`/`AgentFlavorRegistry`
  restart handling and adopts the identical posture (no silent partial
  availability); a regression test pins it. Not invented in the abstract.
- **D7 — Plugin types/backends are slug-prefixed by convention (codex HIGH-6)** to
  avoid cross-plugin name collisions bricking startup; a lint/test flags bare
  plugin type names.

## 8. PR breakdown (for the plan)

1. **PR-1 (core infra):** `resource_types/0` callback + `Plugin.boot/1` Phase-2
   `register_all` publish + `Registry.register_all/1` (write-once on type AND
   backend, all-or-nothing) + the Registry-restart treatment matched to the
   sibling registries (D6) + the slug-prefix lint (D7) + tests (write-once,
   backend-alias attack, batch atomicity, restart) + moduledoc update.
   No behavior change to existing types (cc-agents/codex-agents/uploads still via
   `boot_registrations/0`, now flowing through the same prechecks).
2. **PR-2 (world adopter):** world `resource_types/0` (`world-layouts`,
   single-segment backend) + `LayoutManager` read/write take caller scope SEPARATE
   from target URI (R-3, D-HIGH-4) + route through `resolve/2` + one-shot
   `ezagent.world.migrate_layouts` task (D4) + remove the runtime `HomePathExceptions`
   anchor + ratchet manifest 2→1 + tests (R-3 foreign-ws rejection, migration
   round-trip, default fallback).

Each PR: `mix precommit` EXIT=0 (all suites 0 failures, grep-confirmed) +
`check_invariants` green + codex adversarial-review before merge
(`feedback_codex_review_every_pr`).
