# Phase 4 Completion — Spec 01: Template Domain (`Ezagent.Kind.Template`)

**Status:** DRAFT for Allen review. NO CODE YET.
**Closes:** Decision #64 (Template Class + Instance double model) gap left after Phase 4d.
**Companion to:** Decision #107 (`:instantiate` returns data, not effects) and #108 (`Ezagent.SpawnRegistry` runtime DI pattern).
**Reading time:** ~6 minutes.

---

## 1. Problem statement

Phase 4 shipped **Workspace as a Template *Instance*** (per Decision #64): a `workspace://name` URI carrying `members`, `session_templates`, and `routing_rules` as persisted state, with `:instantiate` walking `members` and re-spawning each via `Ezagent.SpawnRegistry`.

But Decision #64's **Class** half — *plugin-author-written module that declares "I am a template; here is how to validate me and how to instantiate me"* — was never landed. Consequences:

- `apps/ezagent_core/lib/esr/behavior/workspace.ex:121-131` (`:instantiate`) **ignores `session_templates` entirely**. Only `{:member, URI}` tuples are emitted; `session_templates` is dead JSON on disk.
- `apps/ezagent_core/lib/esr/workspace.ex:108-123` (`add_template/3`) accepts any map; no `validate/1` is ever called. Bad templates persist silently and fail (or no-op) at boot.
- `apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspace_detail_live.ex:149-158` renders templates as inert JSON — there is nothing to render *about*, because the field has no behaviour.
- Plugin authors have **no path** to declare "this Workspace should auto-create these Sessions on boot." Phase 6 (CC PTY plugin) will need per-instance config (`cwd`, `model`, `args`) for each managed Session and, without this spec, will invent its own sidecar table — re-creating the "sidecar config tables" anti-pattern explicitly called out in the north star.

This spec lands the **Class** layer + a first concrete Class (`Ezagent.Template.GenericSession`) and wires it through `:instantiate` and `Loader`. After this, `session_templates` actually does something on restart.

---

## 2. Design (4 sub-pieces)

### 2.A `Ezagent.Kind.Template` behaviour

**Where:** `apps/ezagent_core/lib/esr/kind/template.ex` (parallel to `apps/ezagent_core/lib/esr/kind.ex`).

**Why a Kind-namespaced behaviour rather than a top-level `Ezagent.Template`:** Templates are *meta-Kinds* — a Template instantiates Kinds. Living under `Ezagent.Kind.*` signals "this is a contract about the Kind ecosystem," parallel to `Ezagent.Kind` (the Kind contract itself) and `Ezagent.Kind.Server` (the runtime).

**Callbacks:**

| Callback                                                          | Purpose                                                       | Pure? | When called                                                |
| ----------------------------------------------------------------- | ------------------------------------------------------------- | ----- | ---------------------------------------------------------- |
| `template_name() :: String.t()`                                   | Stable id (e.g. `"session.generic"`). Snapshot-safe per #62.  | pure  | `TemplateRegistry.register/2` (boot)                       |
| `validate(template_data :: map()) :: :ok \| {:error, term()}`     | Reject bad shapes before persistence.                         | pure  | `Ezagent.Workspace.add_template/3` facade, before Store write. |
| `instantiate(template_name :: String.t(), template_data :: map(), workspace_uri :: URI.t()) :: {:ok, [URI.t()]} \| {:error, term()}` | Effectful: spawns the Kinds + returns their URIs so Loader can record them. | effectful | `Ezagent.Workspace.Loader.spawn_child({:template, ...})`. |

**Shape rationale:**

- `validate/1` is **pure** so the Workspace facade can call it *before* writing to SQLite. Bad templates fail fast at user-action time, not silently at next boot. (Memory `feedback_let_it_crash_no_workarounds`: prefer structural fix over post-hoc warning logs.)
- `instantiate/3` returns `{:ok, [URI.t()]}` — a list, not a single URI — because a single Template can spawn multiple Kinds (e.g., a "Session + 2 Agents + connection" template). The list lets `Loader` log per-URI success/failure with the same shape it uses for `{:member, uri}` entries.
- The `template_name` argument to `instantiate/3` is passed even though the Class module already knows it via `template_name/0`. Reason: the Workspace's `session_templates` map keys the data by **user-chosen instance name** (e.g. `"main"`, `"backup"`), distinct from the **Class name** (`"session.generic"`). Phase 5+ may want both for telemetry/audit. See decision Q2 below.

**Default `validate/1`:** `@optional_callbacks [validate: 1]` with a default of `:ok`. Per memory `feedback_let_it_crash_no_workarounds` we prefer strict validation, but forcing every Class author to write `def validate(_), do: :ok` for trivial cases is friction without payoff. See decision Q1.

---

### 2.B `Ezagent.TemplateRegistry`

**Where:** `apps/ezagent_core/lib/esr/template_registry.ex` (parallel to `apps/ezagent_core/lib/esr/spawn_registry.ex`).

**Shape:** ETS-backed `:set` table, owned by `EzagentCore.EtsOwner`. Key = `template_name` string. Value = Class module atom.

| Item                       | `SpawnRegistry`                                       | `TemplateRegistry`                                                    |
| -------------------------- | ----------------------------------------------------- | --------------------------------------------------------------------- |
| Key                        | URI scheme (`"agent"`)                                | Template Class name (`"session.generic"`)                             |
| Value                      | 1-arity fn (`URI -> {:ok, pid}`)                      | Class module (`Ezagent.Template.GenericSession`)                          |
| Owner-pid check?           | No (boot-only)                                        | No (boot-only)                                                        |
| Re-registration semantics  | Late-binding plugins win (last-writer)                | **Strict: error on duplicate `template_name`** (see decision Q3)      |
| Lookup miss                | `{:error, {:no_spawn_fn, scheme}}`                    | `{:error, {:no_template_class, name}}`                                |

**API surface (no code, just shape):**

- `register(template_class_module)` — reads `module.template_name/0`, inserts. **Takes module only** (not name + module) so the source of truth for `template_name` stays on the Class module. (Avoids a class of "registered under wrong name" bugs that the SpawnRegistry shape *can* hit.)
- `lookup(template_name)` — `{:ok, module} | :error`
- `registered_template_names/0` — for `mix ezagent.template.list` debugging.

**EtsOwner change:** add `{Ezagent.TemplateRegistry, :set}` to `@tables` list in `apps/ezagent_core/lib/ezagent_core/ets_owner.ex:32-39`.

**Plugin author registration call (illustration):**
```elixir
# In EsrPluginChat.Application.start, alongside register_spawn_fns/0:
:ok = Ezagent.TemplateRegistry.register(Ezagent.Template.GenericSession)
```
Same boot-window as `SpawnRegistry.register/2`. See decision Q4 for ordering.

---

### 2.C First concrete: `Ezagent.Template.GenericSession`

**Where:** `apps/esr_plugin_chat/lib/esr/template/generic_session.ex` (in **chat plugin**, not core — see Q5).

**Class contract:**

- `template_name/0` returns `"session.generic"`.
- `template_data` shape it accepts:
  ```
  %{
    "session_name" => String.t(),       # required — becomes session://<name>
    "members"      => [String.t()],     # URI strings to dispatch chat/join for
    "routing_rules" => [map()] | nil    # optional — Phase 5 wires; v1 ignored with warning if present
  }
  ```
- `validate/1` checks: `session_name` is non-empty string; `members` is list of URI-parsable strings; rejects unknown top-level keys (strict — surfaces typos).
- `instantiate/3` steps:
  1. Build `session_uri = URI.parse("session://#{session_name}")`.
  2. `Ezagent.SpawnRegistry.spawn(session_uri)` (idempotent, returns existing if alive).
  3. For each member URI string: `URI.parse` then dispatch `chat/join` (cast, fire-and-forget — PendingDelivery absorbs not-yet-ready membership per existing Phase 2 pattern).
  4. Return `{:ok, [session_uri]}`. Member URIs are **not** in the returned list because they're not spawned by this Class — they're joined into an already-spawned Session, and they may or may not yet exist as live Kinds (their spawning is the `{:member, URI}` path's responsibility, in the same Workspace).

**Why this Class first:** proves the end-to-end contract works with the existing Chat plugin's actual primitives (`session://`, `:join`). Zero new concepts. And it gives every Workspace a useful day-1 capability: "declare a Session by name + members, auto-recreate on boot."

---

### 2.D Workspace `:instantiate` extension + Loader integration

**Change 1 — `apps/ezagent_core/lib/esr/behavior/workspace.ex` (~15 LOC delta in `:instantiate` clause):**

Current returns `children = members |> Enum.map(fn uri -> {:member, uri} end)`.

New returns:
```
children =
  (members |> Enum.map(fn uri -> {:member, uri} end)) ++
  (session_templates |> Enum.map(fn {tmpl_name, tmpl_data} -> {:template, tmpl_name, tmpl_data} end))
```
Order matters: members first so any Session-Template member dependencies are already alive when `chat/join` fires. (Cast + PendingDelivery makes this not *strictly* necessary, but reduces inbox noise.)

**Change 2 — `apps/ezagent_core/lib/esr/workspace/loader.ex` (~20 LOC delta — add a second `spawn_child/1` clause):**

```
defp spawn_child({:template, tmpl_name, tmpl_data}) do
  case Ezagent.TemplateRegistry.lookup(class_name_from_data_or_convention(tmpl_data, tmpl_name)) do
    {:ok, class} ->
      case class.instantiate(tmpl_name, tmpl_data, workspace_uri_in_scope) do
        {:ok, uris} -> {tmpl_name, {:ok, uris}}
        err         -> log_and_return(tmpl_name, err)
      end
    :error -> log_and_skip(tmpl_name)   # see Migration § below
  end
end
```
(The `workspace_uri_in_scope` capture requires passing `decoded.uri` into `spawn_child/1` — small refactor of current `Enum.map(children, &spawn_child/1)` to a closure or 2-arg fn.)

**Change 3 — `apps/ezagent_core/lib/esr/workspace.ex` `add_template/3` (~10 LOC delta):**

Before `Store.update_templates/2`, call `Ezagent.TemplateRegistry.lookup(class_name) |> case ... do {:ok, class} -> class.validate(tmpl); :error -> {:error, {:no_template_class, class_name}} end`. Returns `{:error, ...}` to caller (LV / mix task) so bad templates never reach SQLite.

This is the **fail-fast structural fix** per memory `feedback_let_it_crash_no_workarounds` — vs. the current state where any map gets persisted and the boot-time warning is the first signal.

**Question that bites here:** how does `add_template/3` know which Class name to look up? Two options — see decision Q2 below.

---

## 3. UX changes

**`workspace_detail_live.ex` templates section (currently lines 149-158, read-only JSON pre-block):**

| Aspect           | Phase 4d (today)                                  | Phase 4-completion (this spec)                                                                                                            |
| ---------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Display          | Raw `Jason.encode!(..., pretty: true)` `<pre>`    | Per template: name + Class name + member count + status badge ("alive" / "pending" / "no Class registered")                               |
| Edit             | None (no `add_template` UI surface exists)        | **Out of scope this PR** — stays read-only; add stub button "Add template (CLI: `mix ezagent.workspace.add_template ...`)" for discoverability |
| Validation error | N/A (no edit)                                     | When user adds via mix task or future LV form, surface `{:error, ...}` from `validate/1` clearly                                          |
| Class list       | N/A                                               | Footer: "Registered Template Classes: session.generic, ..." sourced from `TemplateRegistry.registered_template_names/0`                   |

**Critically: no live editor in this PR.** A live editor is Phase 5 work (needs JSON-schema-driven form UI). What this PR delivers UX-wise is **observability** ("does my template have a registered Class? are its spawned Kinds alive?") plus the actual behavior ("templates now do something on restart").

The "stub button" pattern matches existing facade (e.g. `add_member` is also CLI-only in Phase 4d).

---

## 4. Dev-author experience

**A plugin author writing a new Template Class:**

1. Create a module implementing `@behaviour Ezagent.Kind.Template` (3 callbacks: `template_name/0`, `validate/1`, `instantiate/3`).
2. Add one line to their plugin `Application.start/2`: `Ezagent.TemplateRegistry.register(MyPlugin.Template.Whatever)`.
3. That's it. Workspaces can now reference `template_name` in their `session_templates` map; Loader will instantiate at boot.

**API surface they touch:** 1 behaviour (3 callbacks), 1 registration function. Identical mental model to `SpawnRegistry` for Kinds — which is the point: **plugin isolation north star is preserved** — `ezagent_core` never references `MyPlugin.Template.Whatever`.

**What they do NOT have to do:** modify Workspace, modify Loader, modify Store schema (templates are still opaque `map()` in DB), modify any UI code.

---

## 5. Decision questions for Allen

| #  | Question                                                                                                                                                                                                                                                                                                                                  | Default if you don't answer                                          |
| -- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Q1 | `validate/1`: **required** callback or **optional with `:ok` default**? Required forces every Class author to think about it (good); optional reduces friction for trivial cases.                                                                                                                                                          | Optional with `:ok` default                                          |
| Q2 | How does `session_templates` map an instance entry to a Class? Options: (a) **convention** — the user-chosen template name *is* the Class name (i.e., `"session.generic" => %{...}` — keys *are* Class names, lose ability to have two instances of same Class); (b) **explicit Class field** in `template_data` (`%{"class" => "session.generic", ...}`); (c) **tuple-key in Workspace** (`%{"main" => {"session.generic", %{...}}}` — store layer changes). | (b) — explicit `"class"` field. Lowest persistence-schema impact, allows multiple instances. |
| Q3 | `TemplateRegistry.register/1`: **strict** (error on duplicate `template_name`) or **late-binding wins** (like `SpawnRegistry`)?                                                                                                                                                                                                            | Strict. Two plugins claiming the same Class name is a real bug, not a feature. |
| Q4 | When `Loader.load_all/0` runs (chat plugin start callback), what if a Workspace declares a template whose Class hasn't been registered yet (e.g., another plugin starts later)? Options: (a) log + skip (current member-miss pattern); (b) defer to a "second-pass Loader" after all plugins ready (Phase 5 gate); (c) crash boot.       | (a) log + skip now; (b) is a Phase 5 deferral item.                  |
| Q5 | `Ezagent.Template.GenericSession` lives in **chat plugin** (it dispatches `chat/join`, depends on `session://` scheme) per Decision #106 logic. Confirm?                                                                                                                                                                                       | Yes, chat plugin.                                                    |
| Q6 | Should `instantiate/3` be **idempotent** (called every boot — Class is responsible for "already alive → no-op")? Current `SpawnRegistry.spawn/1` is. The proposed `GenericSession.instantiate` relies on `SpawnRegistry.spawn` idempotency to be safe. **Behaviour contract should require it.**                                          | Required: instantiate MUST be idempotent. Spec it in `@doc`.         |
| Q7 | Template **removal** semantics: `Workspace.remove_template/2` today just drops the map entry. After this spec, should it also tear down the Kinds spawned by `instantiate/3`? Hard problem (we don't track which URIs came from which template). **Spec recommends: removal only stops *future* instantiations; live Kinds stay** — explicit "stop_workspace" is the way to kill them. | Removal is config-only; live Kinds untouched.                        |

---

## 6. Migration / backward compat

The Phase 4d demo Workspace already has a `session_templates` entry in production-ish dev DB. After this PR ships:

| Scenario                                                                                  | Behavior                                                                                                                                          |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Existing template entry has shape Q2-option-b expects (`%{"class" => "session.generic", ...}`) | Validates + instantiates on next boot. No migration script needed.                                                                              |
| Existing template entry is missing `"class"` field                                        | `Loader.spawn_child({:template, ...})` logs `Workspace.Loader: template "X" missing "class" field, skipping`, continues. **No crash, no data loss.** |
| Existing template entry references unregistered Class name                                | Loader logs `Workspace.Loader: no Template Class registered for "Y" in workspace "Z", skipping`, continues.                                       |
| User wants to migrate old-shape entry                                                     | `mix ezagent.workspace.set_template <workspace> <name> <json>` — already exists via `add_template` facade; PR adds doc note.                          |

**Phase 4d demo template should be updated** to the new shape in the same PR, as a one-line data fix in whichever seed/demo script created it. Verify: `grep -rn "session_templates" apps/*/lib apps/*/priv` finds the seed.

---

## 7. Test strategy

| Test                                                                  | Location                                                                              | Asserts                                                                                                              |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `TemplateRegistry` unit                                               | `apps/ezagent_core/test/esr/template_registry_test.exs` (new)                             | register/lookup/duplicate-error/list                                                                                 |
| `Ezagent.Kind.Template` behaviour                                         | covered transitively                                                                  | n/a (it's a behaviour, not a module with logic)                                                                      |
| `Ezagent.Template.GenericSession` unit                                    | `apps/esr_plugin_chat/test/esr/template/generic_session_test.exs` (new)               | `validate/1` rejects bad shapes; `instantiate/3` spawns Session + dispatches joins; idempotent re-call               |
| `Ezagent.Workspace.add_template/3` validation                             | `apps/ezagent_core/test/esr/workspace_test.exs` (extend)                                  | Returns `{:error, ...}` when Class not registered or `validate/1` fails; SQLite row absent on rejection              |
| **Phase 4 invariant test EXTENSION** ★                                | `apps/ezagent_core/test/integration/plugin_isolation_workspace_test.exs` (extend)         | Inline a fake `ProbeTemplate` Class (alongside existing inline `ProbeKind`); declare it in a Workspace's `session_templates`; verify after teardown+`Loader.load_all/0` the spawned URI is alive — *purely via runtime registration, no ezagent_core code references the fake Class*. |

★ **This is the architectural gate** (per memory `feedback_completion_requires_invariant_test`). If this extension passes, Decision #64's Class half is genuinely landed — a plugin author can write a Template Class with zero core changes and it survives restart. If it fails, plugin isolation is broken regardless of how green the rest of the suite is.

The existing test at `apps/ezagent_core/test/integration/plugin_isolation_workspace_test.exs:88-147` already proves this for **members**; adding the templates parallel completes the contract.

---

## 8. LOC estimate

| File                                                                            | New / Δ | LOC      |
| ------------------------------------------------------------------------------- | ------- | -------- |
| `apps/ezagent_core/lib/esr/kind/template.ex`                                        | New     | ~40      |
| `apps/ezagent_core/lib/esr/template_registry.ex`                                    | New     | ~80      |
| `apps/ezagent_core/lib/ezagent_core/ets_owner.ex`                                       | Δ       | +2       |
| `apps/ezagent_core/lib/esr/behavior/workspace.ex` (`:instantiate` extension)        | Δ       | +15      |
| `apps/ezagent_core/lib/esr/workspace/loader.ex` (`{:template, ...}` clause + workspace_uri threading) | Δ       | +25      |
| `apps/ezagent_core/lib/esr/workspace.ex` (`add_template/3` validation)              | Δ       | +12      |
| `apps/esr_plugin_chat/lib/esr/template/generic_session.ex`                      | New     | ~90      |
| `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex` (1 register line)     | Δ       | +1       |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspace_detail_live.ex` (UX 3.A)  | Δ       | +30      |
| **Subtotal impl**                                                               |         | **~295** |
| Tests (TemplateRegistry + GenericSession + facade extension + invariant ext)    | New + Δ | ~220     |
| **Total**                                                                       |         | **~515** |

Implementation LOC fits comfortably within the per-PR budget (Decision #72 red line 1100). Tests roughly mirror impl, weighted toward the invariant extension.

---

## 9. What worries me (read this last)

1. **Loader workspace_uri threading.** `apps/ezagent_core/lib/esr/workspace/loader.ex:55-77` currently passes `decoded.uri` only to `instantiate_via_dispatch`. The new `spawn_child({:template, ...})` clause needs `workspace_uri` to pass into `Class.instantiate/3`. This is a benign refactor (closure over `decoded.uri`), but it changes the signature of `spawn_child/1` from a private 1-arg helper to a 2-arg form — easy to get wrong if I just glance at it. **Not a redesign signal**, just a "review carefully" flag.

2. **`add_template/3` Class lookup needs Q2 answered.** If we go with Q2 option (b) (explicit `"class"` field), then `Ezagent.Workspace.add_template/3` needs the template map to *already contain* the `"class"` key when called. Mix task UX: `mix ezagent.workspace.add_template <ws> <tmpl_name> --class session.generic --data '{"session_name":"foo","members":[]}'`. Not awful, but worth confirming this is the shape Allen wants before plumbing it through.

3. **The "members vs. template-spawned URIs" duplication risk.** Today a Workspace might list `session://main` in `members` AND have a `GenericSession` template that also spawns `session://main`. Both code paths will `SpawnRegistry.spawn` it; SpawnRegistry idempotency saves us. But the conceptual overlap is real — should Workspace UI warn when a template's likely-spawned URI is also listed as a member? **Phase 5 polish, but worth a TODO comment.**

4. **The current `:instantiate` interface declaration** at `apps/ezagent_core/lib/esr/behavior/workspace.ex:150` says `returns: %{children: {:list, :tuple}}`. The new mixed-arity tuples (`{:member, URI}` is 2-tuple, `{:template, name, data}` is 3-tuple) still satisfy `:tuple` but make the interface less self-documenting. Consider tightening to `{:list, {:tuple, [{:atom_in, [:member, :template]}, ...]}}` — but `Ezagent.InterfaceValidator` may not support that depth today. **Spec-level worry, doesn't block this PR.**

5. **No worry about Decision #109 (snapshot vs config persistence).** Templates are config (live in `session_templates` JSON column); Kinds spawned by templates have their own per-Kind persistence policy (currently `:ephemeral` for everything except snapshots). Clean separation; this spec does not perturb #109.

---

**END SPEC.** Awaiting Allen's answers to Q1–Q7 before implementation begins.
