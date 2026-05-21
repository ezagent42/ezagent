# Phase 4 Completion — Spec 02: Auto-derived CLI via Optimus (`mix esr <kind> <action>`)

**Status:** DRAFT for Allen review. NO CODE YET.
**Closes:** Decision #58 (LiveView ↔ CLI 同构映射 — both surfaces derived from `@interface`) gap. LV is wired (manually, today); CLI is hand-written one-task-per-action (3 tasks so far, ~270 LOC).
**Companion to:** Decision #36 (transports are first-class peers — WS / stdio / MCP; CLI is the operator-facing fourth), Decision #49 (CLI as the reference view — minimal renderer, no UI noise to debug logic against), Spec 01 (Template Domain — landing alongside this PR; both surfaces auto-pick-up new `Ezagent.Template.GenericSession` Class).
**Reading time:** ~10 minutes.

---

## 1. Problem statement

Decision #58 promised: a Behavior author declares an action once in `interface/0`, and it appears in **both** the LiveView admin surface and the CLI surface — no extra code per surface. Today:

- The LV side **does** read `@interface` for the Debug Panel form (`apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin/debug_panel.ex`), but each "real" form (chat send, member add, workspace create, routing rule add) is still hand-built.
- The CLI side is **fully hand-written**: every `mix ezagent.*` task duplicates argv parsing, ctx construction, and `Ezagent.Invocation.dispatch` plumbing.
  - `apps/ezagent_core/lib/mix/tasks/esr.workspace.create.ex` — 73 LOC, parses `members:<csv>` by hand.
  - `apps/ezagent_core/lib/mix/tasks/ezagent.routing.add_rule.ex` — 95 LOC, parses `mention:<uri>` / `receivers:<csv>` by hand.
  - `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` — 319 LOC, but it's an operational invariant grep (not a Behavior action), so stays as-is.

For Phase 4 to land Decision #58 honestly, every action currently registered in `BehaviorRegistry` (today: 9 Workspace + 4 Chat + 2 Identity + 1 Echo = **16 actions across 4 Kinds × 4 Behaviors**) must be reachable from `mix esr ...` **with zero per-action code**. Adding action #17 in a plugin must surface in the CLI on next compile, full stop.

This spec lands a single mega-task (`mix esr`) that walks `BehaviorRegistry.list_all/0` at task-run time, derives an Optimus subcommand tree from each Behavior's `interface/0` schema, parses argv, constructs `%Ezagent.Invocation{}`, dispatches, formats the result.

---

## 2. Design (6 sub-pieces)

### 2.A Top-level command shape

```
mix esr <kind_or_facade> <action> [--<arg>=<val> ...] [--as <user_uri>] [--cast] [--json]
```

Examples (mapped to today's `BehaviorRegistry` contents):

| CLI invocation                                                                                       | Translates to                                                                                                                |
| ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `mix esr workspace add_member --workspace default --member agent://cc-architect`                     | `%Invocation{target: workspace://default/behavior/workspace/add_member, mode: :call, args: %{member: ~U"agent://cc-architect"}}` |
| `mix esr workspace list_members --workspace default`                                                 | `:call` mode (no `--cast` flag), prints returned `members:` list                                                             |
| `mix esr session send --session main --message-sender user://admin --message-body '{"text":"hi"}'`   | `:cast` (Chat `:send` is cast-only per `interface/0` modes; `--cast` redundant)                                              |
| `mix esr session join --session main --member user://allen`                                          | `:call` (Chat `:join` lists both modes; CLI defaults to `:call` so user sees `members:` echo)                                |
| `mix esr user list_caps --user admin`                                                                | `:call`; prints `caps: [...]`                                                                                                |
| `mix esr echo say --echo echo --msg "hello"`                                                         | `:call` (or `--cast` for silent)                                                                                              |
| `mix esr workspace create default --members agent://cc-architect,user://admin`                       | **Facade op** — not a Behavior action; see §2.E                                                                              |
| `mix esr --help`                                                                                     | Lists all Kinds with registered Behavior actions + facade ops                                                                 |
| `mix esr workspace --help`                                                                           | Lists all 9 Workspace Behavior actions + facade ops registered under `workspace`                                             |
| `mix esr workspace add_member --help`                                                                | Per-action help: arg names, types, modes, example                                                                            |

**Two-token entry** (`mix esr <kind> <action>`) keeps the operator-typing pattern. The alternative `mix ezagent.<kind>.<action>` (dot-separated, hand-written-task-style) would require Mix to define a task module per pair, blowing up compile time and forcing macro generation (which the Phase-1 Behavior decision explicitly rejected; same logic applies here).

### 2.B Where `<kind>` comes from

`BehaviorRegistry.list_all/0` returns `[{{Ezagent.Entity.Workspace, :add_member}, Ezagent.Behavior.Workspace}, ...]`. The CLI needs to turn `Ezagent.Entity.Workspace` into the user-facing string `"workspace"`.

**Convention:** every Kind module already declares `Ezagent.Kind.type_name/0` (atom, e.g. `:workspace`, `:user`, `:session`, `:agent`, `:echo`). The CLI uses `to_string(kind_module.type_name())` as the kind segment. No mapping table, no module-name parsing.

`mix esr` boots the registry-owning app (`Application.ensure_all_started(:ezagent_core)` plus opportunistically the chat/echo plugins so their `BehaviorRegistry.register/3` boot calls have fired — see §2.F decision Q-D), then walks `list_all/0`, groups by `kind_module.type_name()`, and builds one Optimus subcommand per kind.

### 2.C `interface/0` → Optimus options translation

The shape grammar is defined by `Ezagent.InterfaceValidator` (`apps/ezagent_core/lib/esr/interface_validator.ex:21-31`). The CLI mapping:

| `@interface` arg type      | Optimus option shape                                | Parser                          | Notes                                                                                                                 |
| -------------------------- | --------------------------------------------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `:string`                  | `value_name: "STR"`, parser: identity               | `& {:ok, &1}`                   |                                                                                                                       |
| `:integer`                 | `parser: :integer`                                  | Optimus built-in                |                                                                                                                       |
| `:boolean`                 | `:flag` (presence = true; `--no-<name>` = false)    | Optimus built-in                |                                                                                                                       |
| `:atom`                    | `value_name: "ATOM"`, custom parser                 | `&String.to_existing_atom/1` wrapped in `{:ok,...}` with rescue → `{:error, "unknown atom: " <> &1}` | Refuse `to_atom` to avoid leaking the atom table.                                                                     |
| `:uri`                     | `value_name: "URI"`, custom parser                  | `Ezagent.URI.parse!/1` wrapped      | Surfaces malformed URI as `{:error, ...}` before dispatch.                                                            |
| `:map`                     | `value_name: "JSON"`, parser: `Jason.decode/1`      | one-shot JSON                   | Repeat-key shorthand (`--<name>.key=val`) is **explicitly deferred** — JSON is unambiguous and round-trip-safe.       |
| `{:list, ty}`              | `multiple: true` — repeat `--<name>` OR comma-separated single occurrence | per-element parser of `ty` | E.g. `--members user://a --members user://b` **or** `--members user://a,user://b`. Either form works; doc shows both. |
| `{:option, ty}`            | Same as `ty`, but `required: false`                 | per `ty`                        | Default `nil`.                                                                                                        |
| `{:tuple, [...]}`          | Single `value_name: "JSON"`, parser: `Jason.decode` → tuple | post-process                | Tuples are rare in `@interface` (only `:instantiate` returns one). For args: punt to JSON; tighten in Phase 5.        |
| `%{field => ty, ...}` (record) | **JSON-only**: `--<name>` accepts JSON, validated via `Ezagent.InterfaceValidator` after parse | post-process | Chat `:send` `message:` is this shape (per `Ezagent.Behavior.Chat.message_schema/0`). Forces operators to construct a JSON envelope. See §2.D for the per-action message envelope helper. |

**Validation re-use:** the CLI does NOT re-implement type checking. Once argv → arg-map, `Ezagent.InterfaceValidator.validate/2` runs at the boundary (same path as dispatch will, but earlier — fail in stdout, not deep in the Kind). This is a **belt-and-suspenders by design**: the dispatch validator still runs at step 5.5; the CLI pre-check just gives nicer error messages.

### 2.D URI construction from the `--<kind>` arg

Every Behavior action targets a specific Kind instance — the URI must be assembled. Convention: **a required `--<kind_type_name>` option** whose value becomes the URI instance segment.

```
mix esr workspace add_member --workspace default --member ...
                              ^^^^^^^^^^^^^^^^^                  → workspace://default
mix esr session send         --session main --message ...
                              ^^^^^^^^^^^^                       → session://main
mix esr user list_caps       --user admin
                              ^^^^^^^^^^^                        → user://admin
```

The CLI assembles:
```
target = URI.parse("<scheme>://<value>/behavior/<behavior_name>/<action>")
```
where:
- `scheme` = `kind_module.type_name() |> to_string()` (e.g. `"workspace"`)
- `value` = the `--<kind_type_name>` arg value
- `behavior_name` = `behavior_module.state_slice() |> to_string()` (e.g. `"workspace"`, `"chat"`, `"identity"`, `"echo"`) — already the convention per `Ezagent.URI.behavior_action/1`
- `action` = the subcommand atom

**Note that `scheme` and `behavior_name` are independent.** A Kind can carry multiple Behaviors (User carries both `:chat` (for `:receive`) and `:identity`). That's why the URI path encodes the Behavior name separately from the Kind scheme.

**Edge case: Echo's instance URI is `agent://echo`** (echo is an Agent-family scheme), but its `kind_module.type_name()` is `:echo` distinct from `agent`. The current `Ezagent.Entity.Echo` returns `:echo` for `type_name/0` per `apps/ezagent_core/lib/esr/entity/echo.ex` — verify before merge. If we need scheme ≠ type_name, the convention is: **`--<type_name>` for the instance segment, but the URI is built from a separate `scheme/0` callback on the Kind module**. Today these match; tomorrow they might not. **Decision question Q-A below.**

### 2.E Facade ops (the things that aren't Behavior actions)

Today's mix tasks include two that are NOT `BehaviorRegistry`-driven:

1. **`mix ezagent.workspace.create <name>`** — spawns a Workspace Kind (no action involved; the Kind doesn't yet exist to invoke an action on). Calls `Ezagent.Workspace.spawn_workspace/2` directly.
2. **`mix ezagent.routing.add_rule <table> <matcher> <receivers>`** — operates on a `Ezagent.Routing.RuleStore`, not a Kind instance. There is no `routing://` Kind today.

These are **facade operations** — they live at the layer above any specific Kind instance. Three options:

| Option | Description | Pro | Con |
| ------ | ----------- | --- | --- |
| (a) **Promote to Behavior actions** | Add a `:create` action to `Ezagent.Behavior.Workspace`; dispatch target is a special `workspace://_facade/behavior/workspace/create` URI (or `workspace://` sans instance). | Truly uniform — `mix esr workspace create` works like every other subcommand. | Forces invention of a "no-instance" URI shape; pollutes the actor model (a Behavior action is supposed to mutate slice state, but `:create` makes a *new* actor). |
| (b) **Separate `facade` namespace** | `mix esr workspace:facade create <name>` or `mix esr workspace.facade create <name>` — Optimus subcommand under the same `workspace` kind, but visually distinct. | Honest about the layering. | Two subcommand styles; users will forget which is which. |
| (c) **First-class facade subcommand peer** | Each Kind has both a Behavior-action subcommand group AND an explicit `facade` subcommand group. `mix esr workspace create` reads from a hand-registered facade map (a 3-line registration call in the owning module, e.g. `EzagentCliFacade.register(Workspace, :create, &Ezagent.Workspace.spawn_workspace/2)`). | Plugin-isolation-safe: plugin author registers a facade op the same way they register a Behavior. Zero per-action CLI code for *both* kinds of op. | Still two registries; but they're symmetric. |

**Recommendation:** **(c)**. It preserves the north star (plugin-isolation — facade ops are plugin-owned, not core-coded), it's symmetric with `BehaviorRegistry`, and the LOC cost is one new module (`Ezagent.CLI.FacadeRegistry`, ~50 LOC) + 2-3 plugin registration lines for migrated tasks.

Migration table (facade ops today → after this PR):

| Today                                                              | After this PR                                                                                                                                          |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mix ezagent.workspace.create <name> [members:<csv>]`                  | `mix esr workspace create <name> [--members ...]` (facade op registered by `EzagentCore.Application`)                                                       |
| `mix ezagent.routing.add_rule <table> <matcher> receivers:<csv>`       | `mix esr routing add_rule --table ... --matcher ... --receivers ...` (facade op registered by `EsrPluginChat.Application`; `routing` is facade-only — no `routing://` Kind exists, so it has no Behavior-action subcommand group) |
| `mix ezagent.check_invariants`                                         | **Stays as-is.** It's not a declarative dispatch — it's a code-grep operational tool. Living at `mix ezagent.check_invariants` (dotted) keeps it out of the auto-generated tree and signals "operations, not actions." |

Spec 01 (Template Domain) note: `mix esr workspace add_template` and `mix esr workspace remove_template` are already Behavior actions on `Ezagent.Behavior.Workspace` (per `interface/0`) — they will appear automatically. The `--template` arg is a `:map` (JSON), so the operator passes `--template '{"class":"session.generic","session_name":"main","members":["user://admin"]}'`. Q2 of Spec 01 (explicit `"class"` field) integrates cleanly with the JSON approach.

### 2.F Ctx, caller, caps

Every `Ezagent.Invocation` needs `ctx.caller`, `ctx.caps`, `ctx.reply`. CLI defaults:

- **`caller`** — `URI.parse("user://admin")` by default. Override via `--as <user_uri>`.
- **`caps`** — looked up by dispatching `mix esr user list_caps --user <caller>` internally (or, for the admin shortcut, `Ezagent.Entity.User.admin_caps/0`). Per memory `feedback_uuid_is_canonical_identifier`, the URI is canonical — the CLI does NOT take a `--caps` override; caps are always derived from the caller's live Identity slice.
- **`reply`** — `{:caller_inbox, self()}`. The mix task process blocks (via `receive` with deadline) for `:call` mode; `:cast` returns immediately with `:ok`.
- **`trace_id`** — auto-generated UUID; included in output if `--json` flag set, so operators can grep audit log.
- **`deadline_ms`** — default 5000, overridable via `--deadline-ms`.

**`--as` security gate:** per Spec brief, `--as <other_user>` is a multi-user testing tool. Production-deployed CLI must **refuse** `--as <non-admin>` unless `EZAGENT_CLI_ALLOW_AS=1` is in the environment. Default-deny. (Per memory `feedback_let_it_crash_no_workarounds`: don't add silent fallbacks. If the env is unset, refuse loudly with stderr explaining why.)

### 2.G Output formatting

- **`:call` success with return** — pretty-print the return map. Default = human (`<field>: <value>` lines, URIs rendered as strings, lists indented). `--json` flag → `Jason.encode!(result, pretty: true)`.
- **`:cast` success** — print `ok` (one word) to stdout; exit 0.
- **`{:error, reason}`** — print `error: <inspect(reason)>` to stderr; exit 1.
- **`{:error, {:invalid_args, violations}}`** — pretty-print each violation: `arg <field_path>: <reason>`; exit 2.
- **`{:error, :unauthorized}`** — exit 3 with `caller <uri> lacks capability <needed>` (looked up from validator).
- **`{:error, :no_such_actor}`** — exit 4 with hint `did you spawn the instance? try: mix esr <kind> create ...`.

This matches Decision #49 ("CLI as reference view") — minimal renderer, predictable exit codes, no UI noise.

### 2.H `:call_stream` mode

`Ezagent.Behavior` declares `:call_stream` as a valid mode (per `interface/0` `modes:` list). No Behavior uses it today. The CLI for Phase 4 **stubs it**: if a user passes `--stream` for an action whose `modes` list includes `:call_stream`, the CLI prints `error: --stream not yet supported (Phase 5)`. The Optimus option declaration includes `--stream` so help text mentions it; the parser shorts-circuits before dispatch. (Better than silently downgrading to `:call`.)

---

## 3. The auto-derive walk (the heart of the spec)

When `mix esr` runs (no specific subcommand), the task does:

```
1. Application.ensure_all_started(:ezagent_core)
2. Application.ensure_all_started(:ezagent_plugin_echo)        # opportunistic
3. Application.ensure_all_started(:ezagent_plugin_chat)        # opportunistic
4. (any other registered Ezagent plugin app — discovered via Application.loaded_applications/0
   filtered by name prefix "esr_plugin_")
5. triples = Ezagent.BehaviorRegistry.list_all/0               # [{{Kind, action}, Behavior}, ...]
6. facade_ops = Ezagent.CLI.FacadeRegistry.list_all/0          # [{kind_type_name, op_name, fn}]
7. tree = build_optimus_tree(triples, facade_ops)
8. Optimus.parse!(tree, System.argv())                     # already-stripped to "esr <kind> <action> ..."
9. dispatch_or_facade(parsed)
```

**Where each subcommand comes from:**

```
optimus_root =
  Optimus.new!(name: "mix esr", subcommands: [
    workspace: subcommand_for_kind(Workspace, [9 actions + facade ops]),
    user:      subcommand_for_kind(User,      [2 Identity actions]),
    session:   subcommand_for_kind(Session,   [3 Chat actions]),
    agent:     subcommand_for_kind(Agent,     [3 actions]),
    echo:      subcommand_for_kind(Echo,      [1 action]),
    routing:   subcommand_for_facade_only(Routing, [add_rule, ...])    # no Behavior actions
  ])
```

Each `subcommand_for_kind` walks its action list, calls `behavior_mod.interface()[action]`, and translates the `args` schema to Optimus options per §2.C, prepending the implicit `--<kind_type_name>` instance arg.

**Caching:** The Optimus tree is rebuilt every `mix esr` invocation. The walk is O(#actions) ≈ 20 today, trivial. No compile-time caching needed (which would defeat the auto-derive promise — rebuilds couple CLI shape to compile order, defeating Decision #58).

---

## 4. UX walkthroughs

### 4.A Operator: add a member to a workspace

**Via LV today** (`workspace_detail_live.ex` add-member form): operator types member URI into a text input, clicks "Add", LV constructs `%Invocation{}` with `target: workspace://default/behavior/workspace/add_member`, args `%{member: ~U"agent://x"}`, dispatch.

**Via CLI after this PR:**
```
$ mix esr workspace add_member --workspace default --member agent://cc-architect
ok
$ mix esr workspace list_members --workspace default
members:
  - user://admin
  - agent://cc-architect
```

Equivalent in every observable: same dispatch path, same Audit row, same telemetry event.

### 4.B Operator: send a chat message

```
$ mix esr session send --session main \
    --message '{"sender":"user://admin","body":{"text":"hello"},"mentions":["agent://cc-architect"]}'
ok
```

(`:send` is cast-only; CLI prints `ok` immediately. Persisted via `MessageStore`, broadcast via PubSub, fan-out per existing Chat invoke flow.)

### 4.C Plugin author: adding a new Behavior action

A plugin author writing, say, `Ezagent.Behavior.Vote` with action `:cast_vote`:

1. Implement `@behaviour Ezagent.Behavior` — add `:cast_vote` to `actions/0`, write `invoke/4` clause, add `cast_vote: %{args: %{candidate: :string}, returns: %{}, modes: [:cast, :call]}` to `interface/0`.
2. Register in their plugin's `Application.start/2`: `BehaviorRegistry.register(Ezagent.Entity.Election, :cast_vote, Ezagent.Behavior.Vote)`.
3. Recompile.
4. `mix esr election cast_vote --election usa-2028 --candidate "ada lovelace"` **just works** — no mix task code, no Optimus registration, no help-text editing.

**Zero CLI-aware code in the plugin.** This is the architectural gate (per memory `feedback_completion_requires_invariant_test` — see §7 below).

### 4.D Operator: discoverability

```
$ mix esr --help
Usage: mix esr <kind> <action> [options]

Kinds with registered actions:
  workspace    9 actions, 1 facade op (create)
  user         2 actions
  session      3 actions
  agent        3 actions
  echo         1 action
  routing      (facade only) 1 op (add_rule)

Run `mix esr <kind> --help` for actions in that kind.

$ mix esr workspace --help
Actions on workspace://<name>:
  list_members         [call]            (no args)
  add_member           [cast,call]       --member URI
  remove_member        [cast,call]       --member URI
  list_templates       [call]            (no args)
  add_template         [cast,call]       --name STR --template JSON
  remove_template      [cast,call]       --name STR
  list_routing_rules   [call]            (no args)
  set_routing_rules    [cast,call]       --rules JSON
  instantiate          [call]            (no args)
Facade ops:
  create               <name> [--members URI,...]
```

---

## 5. Decision questions for Allen

| #   | Question                                                                                                                                                                                                                                                                                                              | Default if unanswered                                                                                                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Q-A | **Facade ops handling** — §2.E options (a) promote to Behavior actions / (b) separate `facade` namespace / (c) **first-class `FacadeRegistry` peer** to `BehaviorRegistry`. Recommendation (c).                                                                                                                       | (c) — symmetric registry, plugin-isolation-preserving.                                                                |
| Q-B | **Where does `mix esr` live?** Two choices: (1) single mega-task at `apps/ezagent_core/lib/mix/tasks/esr.ex` ~300 LOC + helpers, or (2) **new app `apps/ezagent_cli/`** owning the task, walker, formatter, FacadeRegistry. Option 2 keeps `ezagent_core` plugin-isolation-pure (core doesn't depend on Optimus). Recommendation: **(2) new app**. | (2) `apps/ezagent_cli/` — keeps Optimus out of core; core's only concern is the registries. CLI is an adapter, per #13.   |
| Q-C | **Optimus vs hand-rolled** — Optimus (`hex.pm/packages/optimus`) is the standard Elixir CLI lib (subcommands + auto-help + arg parsing). Alternative: write a 200-LOC argv walker. Recommendation: **Optimus** — battle-tested, gives `--help` for free, the cost is one mix.exs line.                                | Optimus.                                                                                                              |
| Q-D | **Plugin app discovery** — §3 step 4 lists "any registered Ezagent plugin app via name-prefix `esr_plugin_`". Alternative: maintain an explicit `Application.get_env(:ezagent_core, :plugins)` list. Prefix-scan is fragile (what about `ezagent_plugin_cc_bridge_v1_prototype`? — also has Behaviors, would need to be included). | **Explicit list** in config — `:ezagent_core, plugins: [:ezagent_plugin_echo, :ezagent_plugin_chat, :ezagent_plugin_cc_bridge_v1_prototype, ...]`. Add a TODO that this list lives in `config/config.exs` and is appended when plugins land. Manual but unambiguous. |
| Q-E | **Kind type-name vs URI scheme** — §2.D edge case. Today `Ezagent.Entity.Echo.type_name/0` returns `:echo` but echo's URI scheme is `agent://`. Does the CLI need to call `kind_module.scheme/0` separately, or is "type_name == scheme" forced by convention going forward?                                              | **Force convention** — add an invariant test that `kind_module.type_name() |> to_string()` matches the scheme each Kind's `uri_for/1` produces. Echo migration: rename `type_name/0` to `:agent`-or-similar OR change its URI to `echo://`. Decide alongside Spec 01. |
| Q-F | **`--as <user>` env-gate** — recommended `EZAGENT_CLI_ALLOW_AS=1` requirement (§2.F). Alternative: always allow (it's a dev tool). Recommendation: **gated**.                                                                                                                                                              | Gated. Default-deny per let-it-crash.                                                                                 |
| Q-G | **`:call_stream` for Phase 4** — §2.H stubs with explicit refusal. Alternative: silently downgrade to `:call`, or omit `--stream` from help text entirely. Recommendation: **stub with refusal** (explicit > silent).                                                                                                  | Stub with refusal.                                                                                                    |
| Q-H | **Help-text source** — Optimus uses `about:` strings per option. Should the CLI auto-derive these from the Behavior module's `@moduledoc`? Or from per-action `@doc`? Or just hard-code a generic "<arg> for <action>"? Recommendation: **per-action `@doc` if present, fallback generic** — pulls from existing module docs that already describe each action. | Per-action `@doc` extraction (best effort, fallback generic). |

---

## 6. Migration / backward compat

| Old surface                                              | New surface                                                                          | Backward compat path                                                                                                  |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `mix ezagent.workspace.create <name> [members:...]`         | `mix esr workspace create <name> [--members ...]` (facade op)                        | **Delete old task in this PR.** Single-PR cutover. Update any docs/scripts in same PR. Grep `apps scripts docs` for callsites. |
| `mix ezagent.routing.add_rule <table> ...`                  | `mix esr routing add_rule --table ... --matcher ... --receivers ...` (facade)        | Same — delete old task, update callsites.                                                                              |
| `mix ezagent.check_invariants`                              | unchanged                                                                            | n/a — operations, not actions; stays at dotted path.                                                                  |
| (none — no CLI for `chat send`, `add_member`, etc)      | All auto-derived. Free new surface.                                                  | n/a — pure addition.                                                                                                  |

**Hard invariant grep** to add to `mix ezagent.check_invariants` (per memory `feedback_completion_requires_invariant_test` + `feedback_enumerate_all_gates_before_deletion`): "no `defmodule Mix.Tasks.Ezagent.<Kind>.<Action>` exists" — if some plugin author tries to hand-roll a per-action task, fail CI with "use `BehaviorRegistry.register/3`; the CLI auto-derives." (Allowlist: `Ezagent.CheckInvariants`, `Ezagent.Workspace.Create` until deletion lands in same PR, `Ezagent.Routing.AddRule` until same.)

---

## 7. Test strategy

| Test                                                                                | Location                                                                              | Asserts                                                                                                              |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Arg coercion unit                                                                   | `apps/ezagent_cli/test/ezagent_cli/coercion_test.exs`                                         | Each type in §2.C table parses correctly; each malformed input returns `{:error, ...}` with intelligible message. URI parser rejects bare strings (regression of P3-D8). |
| Tree builder unit                                                                   | `apps/ezagent_cli/test/ezagent_cli/tree_builder_test.exs`                                     | Given a synthetic `BehaviorRegistry` fixture, `build_optimus_tree/2` produces the expected subcommand structure (count, names, modes). |
| Formatter unit                                                                      | `apps/ezagent_cli/test/ezagent_cli/formatter_test.exs`                                        | `:call` returns → pretty + JSON; `:cast` → "ok"; each error class → correct exit code + message.                     |
| **Integration: workspace add_member end-to-end** ★                                  | `apps/ezagent_cli/test/integration/workspace_add_member_test.exs`                         | Spawn a Workspace, run `Mix.Task.run("esr", ["workspace", "add_member", "--workspace", "X", "--member", "user://t"])`, assert (a) `:sys.get_state` shows new member in slice, (b) audit row written, (c) exit 0. |
| **Plugin-isolation invariant** ★★                                                   | `apps/ezagent_cli/test/integration/plugin_isolation_cli_test.exs` (new)                   | Inline a fake `ProbeBehavior` (in test setup, registered via `BehaviorRegistry.register/3` with `interface/0` returning `%{do_thing: %{args: %{x: :string}, returns: %{result: :string}, modes: [:call]}}`); run `mix esr probe do_thing --probe inst --x hello`; assert result `%{result: "hello"}`. **No `Mix.Tasks.Ezagent.Probe.*` module exists anywhere.** |

★ This is the operator end-to-end equivalent of Spec 01's Loader test — proves dispatch round-trip works.

★★ This is the **architectural gate**. If it passes, Decision #58 is genuinely landed for the CLI half: a plugin can add a Behavior action with zero CLI code and the CLI picks it up. If it fails, the auto-derive promise is broken regardless of how green the rest of the suite is. (Memory `feedback_completion_requires_invariant_test`.)

---

## 8. LOC estimate

| File                                                                          | New / Δ   | LOC    |
| ----------------------------------------------------------------------------- | --------- | ------ |
| `apps/ezagent_cli/mix.exs` (new app)                                              | New       | ~30    |
| `apps/ezagent_cli/lib/ezagent_cli/application.ex`                                     | New       | ~20    |
| `apps/ezagent_cli/lib/ezagent_cli/facade_registry.ex` (Q-A option c)                  | New       | ~50    |
| `apps/ezagent_cli/lib/ezagent_cli/tree_builder.ex` (walks BehaviorRegistry + FacadeRegistry → Optimus tree) | New | ~120   |
| `apps/ezagent_cli/lib/ezagent_cli/coercion.ex` (interface_type → Optimus parser + value coerce) | New | ~80    |
| `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex` (parsed → Invocation → reply receive)  | New       | ~80    |
| `apps/ezagent_cli/lib/ezagent_cli/formatter.ex` (result → stdout, exit codes)         | New       | ~60    |
| `apps/ezagent_cli/lib/mix/tasks/esr.ex` (entry point; ~thin wrapper)              | New       | ~40    |
| `apps/ezagent_core/lib/ezagent_core/application.ex` (register `:create` facade op for Workspace) | Δ | +5     |
| `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex` (register `:add_rule` facade for Routing) | Δ | +5     |
| `mix.exs` root (add `:optimus` dep)                                           | Δ         | +1     |
| `apps/ezagent_core/lib/mix/tasks/esr.workspace.create.ex` (delete)                | Δ         | -73    |
| `apps/ezagent_core/lib/mix/tasks/ezagent.routing.add_rule.ex` (delete)                | Δ         | -95    |
| `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` (add `:no_per_action_task` invariant) | Δ | +30    |
| **Subtotal impl**                                                             |           | **~353 net new** |
| Tests (coercion + tree_builder + formatter + integration + invariant)         | New       | ~280   |
| **Total**                                                                     |           | **~633** |

Fits comfortably in the per-PR budget (Decision #72 red line 1100). Heaviest single file is `tree_builder.ex` (~120) — it's the schema-walk core, kept small by reusing `InterfaceValidator`'s type grammar verbatim.

---

## 9. Dependencies

- **Add `{:optimus, "~> 0.5"}`** to root `mix.exs` `deps/0`. Optimus is BSD-licensed, ~2k LOC, pure Elixir, no transitive deps beyond stdlib. Last release maintained; standard choice across the ecosystem.
- No new runtime deps for `ezagent_core` itself — Optimus lives in `apps/ezagent_cli/mix.exs`.

---

## 10. Interaction with Spec 01 (Template Domain)

Spec 01 lands `Ezagent.Kind.Template` + `Ezagent.TemplateRegistry` + `Ezagent.Template.GenericSession`. After both PRs:

- `mix esr workspace add_template --workspace W --name main --template '{"class":"session.generic","session_name":"main","members":["user://admin"]}'` **just works** via the auto-derive path. The `:add_template` action's `:map` arg type carries the Class-keyed JSON; `Ezagent.Workspace.add_template/3` validates via `TemplateRegistry.lookup(class).validate/1` per Spec 01 §2.D Change 3.
- `mix esr workspace remove_template --workspace W --name main` also free.
- A **new** facade op `mix esr template list` (read-only, lists `TemplateRegistry.registered_template_names/0`) can be added in Spec 01's PR via 3 lines in `EzagentCore.Application` (or wherever — registration is the API).

**Ordering note:** Spec 02 (this) can land **before** or **after** Spec 01. If 02 lands first, `add_template` will already exist as a CLI surface; Spec 01 only needs to add validation. If 01 lands first, Spec 02's auto-derive will pick up the new Class-validated `add_template` with no extra work. **Either order works** — they don't block each other.

---

## 11. What worries me (read this last)

1. **Optimus's `--<arg>=value` vs `--<arg> value` parsing nuance.** Optimus accepts both, but some users mistype `--<arg>value` (no separator). Optimus reports as "unknown option"; the resulting help text may be confusing. Mitigation: integration test for the common mistypes; CLI's own `--help` includes a "common mistakes" section. Low-risk, but mention it in dev docs.

2. **`Application.ensure_all_started/1` startup cost.** Running `mix esr workspace list_members` boots `:ezagent_core` + every plugin every invocation. Today's app set boots in <2s; with `:ezagent_plugin_cc_bridge_v1_prototype` that has more children it could grow. **Mitigation:** allow `EZAGENT_CLI_SKIP_PLUGINS=cc_bridge_v1_prototype` to skip slow plugins for read-only ops. Document this in the CLI's `--help` footer. (Not in the spec body — too operational. Footnote it.)

3. **The `--members` repeat-vs-CSV double form.** §2.C says either works. Optimus's `multiple: true` natively handles `--members A --members B`. CSV-in-single-occurrence requires a custom parser that splits on comma. Implementing both adds a code branch and a small "did you mean?" surface area. **Could drop CSV** and only support repeat. But CSV is the existing `mix ezagent.workspace.create` UX, so dropping it is a soft regression for muscle-memory. **Keeping both** (slight code bloat) preferred. Worth confirming.

4. **`{:tuple, [...]}` arg type punted to JSON.** No Behavior uses tuples as args today (only as returns — `:instantiate`). If a Phase 5 plugin author writes one, they'll get JSON ergonomics out of the box. Not great UX, but valid. Tighten in Phase 5 when there's a real callsite.

5. **`mix esr` shadowing.** Mix tasks named just `esr` (no dot) are uncommon. Verify Mix accepts the form `Mix.Tasks.Esr` (capital E only, no dot) — I believe it does (tasks compose as `<TaskName lowercased>` so `Mix.Tasks.Esr` becomes `mix esr`), but worth a quick smoke test before committing to the design. Trivial to confirm — checking `Mix.Task.run("esr", [])` in iex shows whether the task module is discoverable.

6. **Behavior `interface/0` introspection coverage** — see brief item below. Two arg-type tightenings would make the auto-derive cleaner:
   - `Ezagent.Behavior.Chat`'s `:send` arg `message:` is a nested record (`message_schema/0` private fn). The CLI can JSON-decode it, but the operator must hand-construct the full envelope (`sender`, `body`, `mentions`, `ref`, `inserted_at`). A `--message-text <str>` shorthand that wraps text into `%{sender: caller, body: %{text: <>}, mentions: []}` would be friendlier — but it's a Chat-specific helper, NOT a general auto-derive feature. Reasonable to defer to a Chat-specific facade op (`mix esr session send-text --session S --text T`) registered via FacadeRegistry. **Decision Q-I** (folding into the existing decisions block would push count to 9; skipping for brevity — Allen, raise if you want this called out separately).
   - `Ezagent.Behavior.Workspace`'s `:set_routing_rules` arg `rules:` is `{:list, :map}` with no per-element schema. The CLI takes a JSON list, but no per-rule validation runs. Tightening `interface/0` to `{:list, %{matcher: :map, receivers: {:list, :uri}}}` would let the CLI per-element-validate. Spec-level worry; doesn't block this PR.

---

**END SPEC.** Awaiting Allen's answers to Q-A through Q-H before implementation begins. Spec 01 and this spec can ship in either order; no cross-dependency at the data/contract level.
