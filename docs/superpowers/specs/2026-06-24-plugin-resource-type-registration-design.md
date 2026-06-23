# Plugin-owned `resource://` type registration — design

> Status: design (approved approach A, 2026-06-23). Lead: Allen.
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
`validate_spec/2` + `:ets.insert_new/2` the boot loop already uses.

- **Owner-only** — still the sole writer (it is a call handled in the Registry
  process; non-owner `:ets.insert` on a `:protected` table still raises).
- **Write-once** — `:ets.insert_new/2` makes a second registration of an
  existing `<type>` fail; `register/2` returns `{:error, {:duplicate_type, t}}`.
  `Plugin.boot/1` turns that into a loud boot failure (it already raises on bad
  declarations).
- **No overwrite, no delete** — there is no update or delete path, in any env
  except the existing `:test`-only `unregister_for_test`.
- **No reopen flag** — nothing mutable gates the decision; the table simply never
  accepts a second write to a key. The round-4 anti-seal concern does not apply.

**Threat analysis of the new capability (adding a *new* type at plugin boot):**
- A plugin can only register types it declares; it **cannot** replace core's or
  another plugin's type (write-once + core-registers-first, see §5 ordering).
- A plugin supplies its own `authority/2` — acceptable: plugins are first-party,
  in-process, fully-trusted umbrella code (same trust as a plugin defining a
  Behaviour or a spawn fn). Once registered, that authority fn is immutable.
- Net: the only new power is "a trusted plugin can append a type it owns." No
  cross-type escalation, no authority swap. The property that mattered is intact.

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
Enum.each(plugin_module.resource_types(), fn {type, spec} ->
  case Ezagent.Resource.FsResolver.Registry.register(type, spec) do
    :ok -> :ok
    {:error, reason} ->
      raise ArgumentError,
        "#{inspect(plugin_module)} resource_types: #{inspect(type)} → #{inspect(reason)}"
  end
end)
```

Loud failure on a duplicate/invalid type is correct — a type collision is an
operator/author error, not something to swallow (consistent with how `publish/1`
already rejects a plugin `spawns/0`).

### 4.3 `Resource.FsResolver.Registry` — owner-only write-once `register/2`

```elixir
@spec register(String.t(), FsResolver.type_spec()) :: :ok | {:error, term()}
def register(type, spec), do: GenServer.call(__MODULE__, {:register, type, spec})

@impl true
def handle_call({:register, type, spec}, _from, state) do
  reply =
    case validate_spec(type, spec) do
      :ok ->
        if :ets.insert_new(@table, {type, spec}), do: :ok,
          else: {:error, {:duplicate_type, type}}
      {:error, _} = err -> err
    end
  {:reply, reply, state}
end
```

`validate_spec/2` and the ETS table are unchanged — `register/2` is a thin,
serialized, write-once front door reusing both. `boot_registrations/0` (core
types) still applies first at `init/1`; the moduledoc's "no post-init write"
wording is updated to "post-init writes are **append-only, write-once,
owner-serialized** via `register/2`; no overwrite, no delete, no reopen flag."

### 4.4 World migration (first adopter)

- `EzagentPluginWorld.Application.resource_types/0` →
  `[{"world-layouts", %{backend_component: "world/layouts", authority: &world_layout_authority/2}}]`
  where `world_layout_authority/2` asserts `URI workspace == scope.workspace`
  (world layouts are workspace-scoped; same shape as `uploads_authority/2`).
- `LayoutManager.layout_path/1` resolves
  `resource://<ws>/world-layouts/<scope_key>` via `FsResolver.resolve/2` with the
  caller's scope, instead of `Path.join(Home.path("world/layouts"), …)`.
  `<ws>` = the scope_uri's workspace; `<scope_key>` = the existing
  `stable_key |> Base.url_encode64` name.
- Delete the `layout_dir/0` anchor from `HomePathExceptions`; ratchet
  `raw_home_path_outside_core` **2 → 1** in `arch_baseline_manifest.exs`
  (the codex SUN_LEN socket is the sole remaining, genuinely un-migratable entry).

**On-disk compatibility:** the resolved path changes from
`world/layouts/<scope_key>.json` to `world/layouts/<ws>/<scope_key>.json` (the
resolver ws-partitions). This is **non-destructive**: `read_layout/1` already
falls back to `default_layout/1` on any miss, so a pre-migration custom layout
resets to default once (regenerable). No data-loss path; called out so it is not
a surprise. (World layouts are a recent, low-volume store.)

## 5. Ordering & conflict semantics

- **Core types register first** — `boot_registrations/0` at `Registry.init/1`,
  which runs when `ezagent_core` starts, **before** any plugin (plugins depend on
  core → start later). So a plugin can never shadow a core type (write-once +
  core-first).
- **Plugin types register at that plugin's Phase-2 boot** — no dependence on
  inter-plugin ordering for *correctness*; two distinct plugins owning distinct
  types never interact.
- **Same-type collision across two plugins** → the second `register/2` returns
  `{:duplicate_type, …}` → that plugin's `boot/1` raises → loud startup failure
  naming the offending plugin + type. Deliberate; never silent.

## 6. Testing

- **Registry write-once unit:** `register/2` succeeds for a fresh type; a second
  `register/2` of the same type → `{:error, {:duplicate_type, _}}`; a malformed
  spec → `{:error, _}`; the table entry is unchanged after a rejected dup
  (no overwrite).
- **Owner-only:** a direct non-owner `:ets.insert(@table, …)` raises (protected).
- **Plugin contract:** a fixture plugin module declaring `resource_types/0` →
  `Plugin.boot/1` publishes it and `FsResolver.resolve/2` then resolves its URIs;
  a fixture declaring a duplicate of a core type → `boot/1` raises.
- **World migration:** `LayoutManager.write_layout/2` then `read_layout/1`
  round-trips through the resolver under the scope's workspace; an authority
  mismatch (foreign ws) is rejected; a missing file falls back to
  `default_layout/1`.
- **Arch gates:** `raw_home_path_outside_core` scan = 1 after the anchor removal;
  `mix ezagent.check_invariants` green; full `mix precommit` EXIT=0 with every
  suite 0 failures (gate on BOTH per `feedback_precommit_exit_can_mask_failures`).

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
- **D4 — World migration is non-destructive** via the existing default-layout
  fallback; no migration script.

## 8. PR breakdown (for the plan)

1. **PR-1 (core infra):** `resource_types/0` callback + `Plugin.boot/1` Phase-2
   publish + `Registry.register/2` write-once + tests + moduledoc update.
   No behavior change to existing types (cc-agents/codex-agents/uploads still via
   `boot_registrations/0`).
2. **PR-2 (world adopter):** world `resource_types/0` + `LayoutManager` routes
   through `resolve/2` + remove `HomePathExceptions` anchor + ratchet manifest
   2→1 + world layout round-trip tests.

Each PR: `mix precommit` EXIT=0 (all suites 0 failures) + `check_invariants` green
+ codex adversarial-review before merge (`feedback_codex_review_every_pr`).
