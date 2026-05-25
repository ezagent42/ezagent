---
name: elixir-phoenix-helper
description: Use this skill whenever a task involves Elixir, OTP, Phoenix, LiveView, Ecto, or BEAM code. Triggers include writing or reviewing any `.ex`/`.exs`/`.heex` file, GenServer/Supervisor/Task/Registry/DynamicSupervisor design, Phoenix controllers/plugs/router/contexts/LiveView/Scopes/streams/uploads, Ecto schemas/changesets/queries/Multi/migrations, PubSub/Channel/Presence, mix.exs/deps, debugging BEAM/ETS/latency, OTP app or umbrella architecture, reviewing or refactoring or migrating code to Elixir 1.19 / Phoenix 1.8 conventions, spotting anti-patterns (non-assertive access, boolean/primitive obsession, scattered process interfaces) or deprecated APIs (Logger.warn, Supervisor.Spec, Phoenix.View, HTTPoison, use Mix.Config, current_user vs current_scope). Also trigger when the user mentions Elixir idioms (pipe operator, `with` chains, `{ok, _}` tuples, pattern matching in function heads), says 'let it crash', or pastes BEAM-looking code. Use even when 'elixir' or 'phoenix' is mentioned briefly.
---

# Elixir / OTP / Phoenix Helper

Produce Elixir, OTP, and Phoenix code the way an experienced Elixir engineer would: idiomatic, process-aware, version-accurate, and test-covered. The skill is anchored on OTP core (deepest reference) and supplemented with equally rigorous guides for Phoenix web, Ecto, real-time, and testing.

**Default version targets (adjust based on project's `mix.exs`):**
- Elixir 1.19+ / Erlang OTP 27+
- Phoenix 1.8+ / LiveView 1.1+
- Ecto 3.12+

If the project is older, query Context7 for the pinned version and adapt. Key breaking-level changes to watch: Phoenix 1.8 introduces **Scopes** as a first-class pattern for authorization (context functions now take `scope` as first argument); Phoenix 1.8 ships a **single-layout + `<Layouts.app>` function component** pattern (no more `root.html.heex` + `app.html.heex` nested dance); Elixir 1.19 adds **type inference across anonymous functions and protocols**, so stale `@spec`s will start emitting warnings.

---

## 🛑 STOP — Before writing ANY code

The two steps below are **mandatory** and run **before** you output a single line of Elixir. Skipping them is the single biggest source of bad output. This is not a suggestion.

**Step 1 — Check project-local rules.** Look for `AGENTS.md` at repo root. If found, read it. Also check `usage_rules.md`, `CLAUDE.md`, `.rules/`. Project rules override this skill.

**Step 2 — Query Context7 for every library the code will touch.** Yes, every time. Yes, even if you "know" the API. Yes, even for small snippets.

```
Context7:resolve-library-id { libraryName: "phoenix_live_view" }
Context7:query-docs { context7CompatibleLibraryID: "...", topic: "streams", tokens: 5000 }
```

**If you are about to type `defmodule` without having done Step 2, stop and do Step 2 first.**

Your training data predates Phoenix 1.8 scopes, LiveView 1.1 features, Ecto 3.12 changes, the `Req` / `Finch` / `Jason` consolidation, and many smaller API changes. Writing without Context7 = writing 2023 Elixir in 2026. The only exceptions are stdlib-only code (`Enum`/`Map`/`String`/`Process`), trivial renames, and pure-logic helpers.

---

## When to use this skill

Any task touching Elixir code or BEAM ecosystem. Examples:

- "Write a GenServer that caches rate-limit tokens" → OTP core
- "Create a LiveView for a kanban board with drag-and-drop" → phoenix-web
- "Design the supervision tree for a worker pool" → OTP core (architecture)
- "Review this Ecto query" → ecto
- "Why is my Channel dropping messages?" → realtime (debug)
- "Refactor this module to be more idiomatic" → any, plus this file's Idioms section
- Anything involving `mix.exs`, `.ex`, `.exs`, `.heex`, `.leex`, `.exs`

## Mandatory first steps (detailed)

**Step 1 and Step 2 above are the short version.** Here are the details.

### 1. Check for project-local LLM rules

Phoenix 1.8+ generates `AGENTS.md` at the project root — this is a file of project-specific Elixir/Phoenix rules the project maintainers want LLMs to follow. It may have been edited from the default. Also check for `usage_rules.md` (from the `usage_rules` Hex package, which aggregates rules across all deps). If either exists:

- **Read it and obey it.** Project rules override this skill's generic guidance when they conflict.
- **Mention at the top of the response** that you have read it, so the user knows the advice is project-aware.

Look for (in order):
1. `AGENTS.md` at repo root (Phoenix 1.8+ default)
2. `usage_rules.md` or `.rules/` directory
3. `CLAUDE.md` or `.claude/` directory
4. `.cursorrules` or similar agent-specific configs

If none of these exist, proceed with this skill's defaults.

### 2. Query Context7 for every library touched

Elixir and Phoenix move fast. Training data is often stale on Phoenix 1.8 Scopes, the `<Layouts.app>` function component, LiveView 1.1 features, Ecto 3.12 changes, and Hex package APIs in general. **Before writing any non-trivial code that uses a library, query Context7.** This is the single highest-leverage step — it is what separates outputs that compile and match current conventions from outputs that look right but silently use deprecated patterns.

### Workflow (every code task)

```
1. Context7:resolve-library-id { libraryName: "phoenix_live_view" }
   → returns ID like "/phoenixframework/phoenix_live_view"

2. Context7:query-docs {
     context7CompatibleLibraryID: "/phoenixframework/phoenix_live_view",
     topic: "streams",          # narrow the scope — don't pull the whole manual
     tokens: 5000               # keep small; iterate if needed
   }
```

### Common library IDs

These are starting guesses — always verify with `resolve-library-id` before querying if you are unsure:

| Purpose | Library | Typical topic keywords |
|---|---|---|
| Web framework | phoenix | "router", "controller", "scopes", "context", "verified_routes" |
| Reactive UI | phoenix_live_view | "streams", "components", "hooks", "uploads", "live_component" |
| DB / ORM | ecto | "changeset", "multi", "preload", "migrations", "query" |
| Real-time | phoenix_pubsub, phoenix presence | "subscribe", "broadcast", "track" |
| Jobs | oban | "workers", "unique", "cron", "telemetry" |
| Email | swoosh | "composition", "adapters" |
| HTTP client | req | "streaming", "plugins", "retry" |
| Testing | ex_unit | "doctest", "capture_log", "async" |
| Mocking | mox | "defmock", "expect", "verify_on_exit" |
| Property testing | stream_data | "check all", "generators" |

### When it is OK to skip Context7

Only for: stdlib only code (`Enum`, `Map`, `String`, `Process`, `Kernel` — these are stable), trivial renames, or boilerplate that does not touch a library API. **When in doubt, query.** A 5-second Context7 call is much cheaper than generating code that uses a 2-year-old API.

## Core workflow for any code task

1. **Read project rules.** Check for `AGENTS.md`, `usage_rules.md`, `CLAUDE.md`. Obey them over generic skill defaults.
2. **Understand the task and its boundary.** Is this a pure function? A long-running process? A piece of a Context? A LiveView? A Channel? The abstraction determines everything downstream.
3. **Pick the right abstraction.** Do not reach for GenServer if a function works. Do not reach for `Agent` if `GenServer` is already closer. See [otp-core.md → Choosing an abstraction](references/otp-core.md).
4. **Query Context7** for every library the code touches.
5. **Write the module** with proper naming (`MyApp.Context.Submodule`) and a minimal public API surface. In Phoenix 1.8+ contexts, thread `scope` as the first argument for any function that reads or writes user-owned data.
6. **Write ExUnit tests alongside** — never skip unless the user explicitly says "no tests". Add doctests for pure functions with clear input→output mappings.
7. **Add `@moduledoc` and `@spec`** on key public modules — see Style below for the threshold.
8. **Run the Idioms checklist** (bottom of this file) before finalizing.

## Workflow for review / refactor tasks

When the user says "review this code", "make this more idiomatic", "refactor this", or pastes a snippet that looks pre-1.15: **load [anti-patterns.md](references/anti-patterns.md) before responding**. That file has the full checklist of things to scan for (deprecated APIs, assertiveness, complex `with/else`, boolean/primitive obsession, process misuse, N+1, scope leaks, test gaps) and the before/after rewrites. Do not try to recall these from memory — the reference is comprehensive and version-current.

After producing the refactor, **always check: does the original code have tests?** If not, call it out explicitly and offer to add them (or add them if in scope). A review that upgrades code without tests leaves it just as fragile as before. This includes: new context functions should get corresponding tests, refactored controllers should get `ConnCase` tests, and any behavior change should have a test that would have caught the old behavior.

## Core Elixir idioms (non-negotiable)

These are not preferences. They are how Elixir is written. If output violates any of these, the output is wrong and needs revision before returning to the user.

1. **Fallible functions return `{:ok, result}` or `{:error, reason}`.** Do not raise for expected failures. Bang variants (`foo!/1`) wrap the tuple form and raise — provide both only when both are useful.
2. **Use `with` for happy-path chains.** Do not nest `case`.
   ```elixir
   with {:ok, user}    <- fetch_user(id),
        {:ok, profile} <- load_profile(user),
        {:ok, feed}    <- build_feed(profile) do
     {:ok, feed}
   end
   ```
3. **Pattern match in function heads** over `if`/`case` in the body.
   ```elixir
   def handle(:ok),              do: :done
   def handle({:error, reason}), do: {:retry, reason}
   ```
4. **Pipes (`|>`) when threading data through 3+ steps.** Do not force a pipe for 1–2 steps — a plain nested call is fine and sometimes clearer.
5. **Let it crash.** Do not wrap every call in `try/rescue`. Let the supervisor restart. Rescue is for known, handleable external failures (e.g. a parser that legitimately raises).
6. **Immutability.** Never mutate. Return new values. Use `Map.put/3`, `Map.update!/3`, `update_in/3`.
7. **`@impl true`** on every behaviour callback (GenServer, Supervisor, `Phoenix.LiveView`, `Phoenix.Channel`, any `@behaviour` module). Skipping this silently breaks specs and dialyzer.
8. **Module naming:** `MyApp.Domain.Context.Module`. Contexts are nouns. Modules inside a context are focused. Follow `MyApp.Accounts.User`, not `MyApp.UserModel`.
9. **Never `String.to_atom/1` on untrusted input** — atom table is global and unbounded. Use `String.to_existing_atom/1` or a whitelist.
10. **`Enum` for bounded collections; `Stream` for large/infinite** or when composing many transformations before a terminal operation.
11. **Tagged tuples for process state transitions** (`{:ready, data}`, `{:loading, _}`). Makes `handle_call/3` / `handle_info/2` pattern match cleanly.
12. **`@behaviour` + `@impl`** for pluggable contracts (adapters, strategies). Prefer behaviours over ad-hoc module contracts.
13. **`with` chains handle the unhappy path explicitly** when necessary:
    ```elixir
    with {:ok, user}    <- fetch_user(id),
         {:ok, profile} <- load_profile(user) do
      {:ok, profile}
    else
      {:error, :not_found} -> {:error, :user_missing}
      {:error, reason}     -> {:error, reason}
    end
    ```
14. **Avoid `else` branches in `with` that just re-raise or re-wrap unchanged.** Let the original `{:error, _}` pass through.
15. **`defp` for private; `def` only when the function is part of the module API.** Every `def` is a public commitment.
16. **Phoenix 1.8+: thread `scope` through context functions.** `list_posts(scope)`, `get_post!(scope, id)`, `create_post(scope, attrs)`, `subscribe_posts(scope)`. The scope (typically `%MyApp.Accounts.Scope{user: user, organization: org}`) flows from the LiveView/controller via `socket.assigns.current_scope` or `conn.assigns.current_scope`. This makes secure-by-default data access structural rather than remembered. See [phoenix-web.md → Scopes](references/phoenix-web.md).

## Style: balanced (calibrated for this user)

| Element | Threshold |
|---|---|
| `@moduledoc` | Required on public modules (anything used outside the current file/context). Optional on private helpers. Use `@moduledoc false` on deliberately-internal modules so the linter does not complain. |
| `@doc` | On public functions of public modules. Skip `defp`. |
| `@spec` | On public functions of public modules; on every GenServer/Supervisor/LiveView/Channel callback. Skip one-liner helpers. |
| Custom `@type` | When used in ≥2 function specs; otherwise inline the type. |
| Tests | **Always.** See Testing below. |
| Credo | Assume project uses `mix credo --strict`; do not introduce new warnings. |
| Dialyzer | Aim for clean specs; do not over-annotate. Run `mix dialyzer` before finalizing if project has it. |
| Formatter | Always output formatter-clean code (`mix format` conventions — 2-space indent, no trailing whitespace, etc.). |

## Testing: always include ExUnit + doctests

Tests are part of every code generation. No exceptions unless the user explicitly opts out.

- **File location:** `test/my_app/context/module_test.exs` mirrors `lib/my_app/context/module.ex`.
- **`describe/2` blocks** grouped by function name (`describe "insert_user/1"`).
- **Doctests** for pure functions:
  ```elixir
  @doc """
  Adds two numbers.

      iex> MyApp.Math.add(2, 3)
      5
  """
  def add(a, b), do: a + b
  ```
  Then: `doctest MyApp.Math` at the top of the test file.
- **GenServer:** test via the public client API, not `handle_call/3` directly.
- **LiveView:** use `Phoenix.LiveViewTest` — `live/2`, `render_click/2`, `render_submit/2`, `render_hook/3`.
- **Ecto:** wrap in the sandbox: `Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)`.
- **Channel:** use `Phoenix.ChannelTest` — `socket/3`, `subscribe_and_join/3`, `push/3`, `assert_push/3`.
- **Async tests (`async: true`) by default**, except when testing processes with shared global state (named processes, application env changes, ETS tables with fixed names). Document the reason if opting out.
- **StreamData property tests** when invariants matter more than examples (parsers, serializers, round-trips).

See [testing.md](references/testing.md) for full patterns including Mox, `capture_log`, and async gotchas.

## Pitfalls Claude tends to fall into (avoid)

These are the actual high-frequency mistakes Claude makes in Elixir code. Check against this list before finalizing:

1. **Writing Ruby-flavored Elixir.** Long `if` / `else` chains where pattern matching in function heads is cleaner.
2. **Forgetting `@impl true`.** Leads to silent spec drift and no compile-time callback verification.
3. **Over-reaching for GenServer.** If there is no state, a function module is correct. A pure module beats a stateful process.
4. **Wrong supervisor strategy.** Default is `:one_for_one`. Use `:rest_for_one` only when later children depend on earlier ones. Use `:one_for_all` only when siblings genuinely must restart together.
5. **Domain logic in controllers or LiveViews.** Put it in a Context. Controllers and LiveViews are thin adapters for HTTP and WebSocket respectively.
6. **`cast` where `call` is needed** (loses backpressure and errors) or **`call` where `cast` is needed** (blocks on fire-and-forget).
7. **Preload misses → N+1 queries in Ecto.** Always preload associations the view will access. See [ecto.md](references/ecto.md).
8. **`Enum.map/2` over a query result when it should be `Ecto.Query.select/3`.** Push work into SQL when possible.
9. **Business logic in `render/1`** (LiveView). Compute in `handle_event/3` or `handle_params/3`, assign, then render reads assigns.
10. **`String.to_atom/1`** on any untrusted input → atom table exhaustion.
11. **Ignoring `{:noreply, state, timeout | :hibernate}`** opportunities in long-lived GenServers with bursty traffic.
12. **Not using `Ecto.Multi`** when 2+ DB operations must be atomic.
13. **Phoenix 1.8 context functions without `scope` as first arg** → data leakage across users/tenants. Generators (`mix phx.gen.live`, `mix phx.gen.html`) produce scope-aware code by default; hand-written contexts must follow the same pattern.
14. **`Phoenix.PubSub.broadcast/3` without scoping topic by tenant or scope** → cross-tenant message leaks. Phoenix 1.8 convention: `Blog.subscribe_posts(scope)` that internally builds the topic from `scope.user.id` or `scope.organization.id`.
15. **Nested `root.html.heex` + `app.html.heex` layout pattern** — deprecated in Phoenix 1.8. Use a single root layout + explicit `<Layouts.app flash={@flash}>` function component call inside each LiveView's `render/1`.
16. **Creating a `Registry` when a named GenServer is sufficient**, or vice versa — `Registry` shines when there are many dynamic processes of the same kind.
17. **Not leveraging `Process.send_after/3`** for periodic work inside a GenServer; instead spinning up a separate Task or external scheduler.
18. **Forgetting to `Process.monitor/1`** when linking is inappropriate — a GenServer that `spawn_link`s user-supplied work crashes on user error, which is rarely desired.
19. **Putting everything in the `application` callback `start/2`** instead of a proper supervision tree with `children` and a clear strategy.

## When to load which reference

Load the reference file **before** writing code in that domain. The refs hold version-accurate patterns and recipes; do not guess from training knowledge alone.

| If the task involves… | Load |
|---|---|
| GenServer, Supervisor, Task, Agent, DynamicSupervisor, Registry, supervision tree design, process linking/monitoring, application structure, umbrella vs poncho | [references/otp-core.md](references/otp-core.md) ← **deepest reference** |
| Controllers, plugs, `Phoenix.Router`, Phoenix 1.8 Scopes, `live_session`, LiveView, LiveComponent, streams, hooks, form components, uploads, `<Layouts.app>` function component, daisyUI theming | [references/phoenix-web.md](references/phoenix-web.md) |
| Schemas, changesets, queries, associations, preload, `Ecto.Multi`, migrations, sandbox, multi-tenancy | [references/ecto.md](references/ecto.md) |
| `Phoenix.PubSub`, `Phoenix.Channel`, `Phoenix.Presence`, socket auth, topic scoping, soft-realtime delivery | [references/realtime.md](references/realtime.md) |
| ExUnit patterns, doctest, Mox, StreamData, sandbox, `capture_log`, async gotchas | [references/testing.md](references/testing.md) |
| **Reviewing / refactoring / migrating existing code**, spotting non-assertive map access, non-assertive truthiness, complex `with/else`, boolean obsession, primitive obsession, deprecated APIs (`Logger.warn`, `Supervisor.Spec`, `Phoenix.View`, `HTTPoison`, `use Mix.Config`, `current_user` vs `current_scope`, etc.) | [references/anti-patterns.md](references/anti-patterns.md) |
| `defmacro`, `__using__/1`, `quote`/`unquote`, macro hygiene, DSL design, whether a macro is the right tool at all (usually: no) | [references/macros.md](references/macros.md) |

## Response conventions

- **Language:** match the user's language for explanations. Code comments stay in English (Elixir convention).
- **Length:** show the module + test file. Do not pre-explain. Let the code carry the weight. Add a short "why" paragraph only when a non-obvious pattern was chosen.
- **File boundaries:** when generating 2+ files or >~40 lines of code, use `create_file` / artifacts rather than inline code blocks — Elixir projects expect real files at real paths, and users benefit from being able to drop them in directly.
- **Mix context:** if no `mix.exs` or project context is given, ask once whether the user has an existing project or wants a fresh `mix new` / `mix phx.new` scaffold.
- **Version awareness:** whenever a response depends on a specific Phoenix/LiveView/Ecto version, state it explicitly ("Phoenix 1.7+", "LiveView 1.0"). If Context7 was queried, briefly note that the code matches the queried docs.

## The "is this idiomatic?" checklist (run before finalizing)

**Hard checks (if any fails, stop and fix):**
- [ ] 🛑 `AGENTS.md` / `usage_rules.md` / `CLAUDE.md` read and honored (if present)?
- [ ] 🛑 Context7 consulted for every library touched?
- [ ] 🛑 ExUnit tests written? (Doctests on pure functions where applicable.) If reviewing existing untested code, test gap is explicitly flagged.

**Idioms:**
- [ ] Fallible functions return `{:ok, _} / {:error, _}`?
- [ ] Happy-path chains use `with`?
- [ ] Pattern matching in function heads where it reads cleaner than `if`?
- [ ] `@impl true` on every behaviour callback?
- [ ] `@moduledoc` + `@spec` on key public modules/functions?
- [ ] No Ruby/JS-flavored constructs?
- [ ] Supervisor strategy justified (default `:one_for_one` unless there is a reason)?
- [ ] No `String.to_atom/1` on untrusted input?

**Phoenix 1.8 specifics:**
- [ ] Context functions take `scope` as first argument for user-owned data?
- [ ] PubSub topics are scope-derived (not hard-coded global strings)?
- [ ] LiveView uses `<Layouts.app>` function component pattern (not the old nested-layout approach)?

**Polish:**
- [ ] Formatter-clean (run mental `mix format` pass)?

If any box is unchecked and the reason is not deliberate, revise before returning the code.
