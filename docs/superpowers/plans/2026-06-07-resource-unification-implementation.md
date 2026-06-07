# Resource-unification — IMPLEMENTATION PLAN (P0–P3, Codex handoff)

> **For agentic workers:** REQUIRED SUB-SKILLS — load `Skill: ezagent-developer` +
> `Skill: elixir-phoenix-helper` before touching any `apps/**/*.ex`, and follow
> `superpowers:executing-plans` / `superpowers:test-driven-development` task-by-task.
> Steps use checkbox (`- [ ]`) syntax. **This plan is Codex-autonomously-executable
> under the loose-audit handoff model** (the author owns review + E2E + issue filing).
> P0 / P0.5 / P1 / P3 self-merge on green; **P2 is Allen-gated — do NOT auto-merge.**

Date: 2026-06-07
Branch (this plan): `plan/resource-unification`
SPEC: `docs/superpowers/specs/2026-06-07-resource-unification-spec.md` (APPROVED, LOCKED)
SPEC (zh): `docs/superpowers/specs/2026-06-07-resource-unification-spec.zh_cn.md`
Companion (zh): `docs/superpowers/plans/2026-06-07-resource-unification-implementation.zh_cn.md`

---

## Goal

Unify on-disk artifact **addressing for tenant-scoped, content-shaped artifacts**
behind the `Ezagent.UriQuery` seam using the existing
`resource://<ws>/<type>/<name>` scheme, and **lock the raw `Home.path` surface**
so the migration cannot regress. `Ezagent.Home` becomes the **default backend**
behind a hardened, registration-only resolver — not the front door. Boot /
config-eval / operator mix-tasks / OS-handle artifacts (db, cookie, pty-pids,
codex socket) stay on sanctioned raw `Home` (exact-anchor scan exceptions).

## Architecture

A new `ezagent_core` module `Ezagent.Resource.FsResolver` generalizes the proven
socialware pattern (`config_projection.ex` `assert_workspace_authority!/2`):
a **closed per-`<type>` allowlist**, `.`/`..`/separator/NUL rejection **before**
`Path.join`, and an **authorization-bearing** `resolve(uri, scope)` that runs a
per-`<type>` `authority/2` asserting `uri.<ws> == scope.workspace` *before* any
backend resolve. A new scan-gate category `home_path_in_runtime_code` on
`mix ezagent.uri_query.scan` **hard-fails NEW** runtime-app-code `Home.path`
calls against a line-anchored baseline + **exact `Module.function/arity`**
exceptions (no globs). The two remaining tenant-scoped families migrate
risk-ascending: **per-agent config-dir** (P1, byte-identical), then **uploads**
(P2, download-contract + signed-token authz first, then byte move). P3 burns the
baseline to empty. The credential cascade / `Ezagent.Agent.Materializer` hot path
is **untouched** (resolve-then-pass).

## Tech stack

Elixir/OTP umbrella. `Ezagent.UriQuery` (ETS `attr → resolver/1`, fail-loud on
`{:no_resolver, _}`, `:none ≠ {:error,_}`). `Ezagent.URI` (6-scheme allowlist,
workspace-first `resource(ws, type, name)`, 3-segment authority). `Ezagent.Home`
(EZAGENT_HOME path helper). `Ezagent.UriQuery.Scan` + `Mix.Tasks.Ezagent.UriQuery.Scan`
(AST/text scanner already parsing `--fail-category`). Tests: `EzagentCore.DataCase`
/ plain `ExUnit` for resolver + scanner; Phoenix controller tests for uploads.
Signed token (P2): `Phoenix.Token` / `Plug.Crypto` MAC over the URI + TTL.

---

## File Structure (create / modify)

```
apps/ezagent_core/
├── lib/ezagent/resource/
│   └── fs_resolver.ex                      ← NEW (P0)  generic resource:// FS resolver
├── lib/ezagent/uri_query/
│   ├── scan.ex                             ← MOD (P0.5) add home_path_in_runtime_code category
│   ├── scan/home_path_exceptions.ex        ← NEW (P0.5) exact Module.function/arity anchors
│   └── scan/home_path_baseline.ex          ← NEW (P0.5) line-anchored burn-down baseline
├── lib/ezagent/sandbox/config_dir.ex       ← MOD (P1)  build+resolve resource:// URI
└── test/ezagent/
    ├── resource/fs_resolver_test.exs       ← NEW (P0)  R-1..R-4
    ├── uri_query/scan_home_path_test.exs    ← NEW (P0.5) S-1..S-3
    └── sandbox/config_dir_parity_test.exs   ← NEW (P1)  byte-identical parity

apps/ezagent_domain_instance_message/
└── lib/ezagent_domain_instance_message/uri_query_resolvers.ex  ← MOD (P1) re-point resource clause

apps/ezagent_plugin_liveview/
└── lib/ezagent_plugin_liveview/admin_live.ex          ← MOD (P2b) write via resolver

apps/ezagent_web/
├── lib/ezagent_web/
│   ├── uploads/upload_token.ex             ← NEW (P2a) signed-token mint/verify
│   ├── controllers/uploads_controller.ex   ← MOD (P2)  token + ws-segment authz, read via resolver
│   └── router.ex                           ← MOD (P2a) token route (+ back-compat /files/:filename window)
└── test/ezagent_web/
    ├── uploads/upload_token_test.exs        ← NEW (P2a) TTL/binding/replay/expiry
    └── controllers/uploads_controller_test.exs ← MOD (P2) same-filename-2-ws, foreign-ws, round-trip

docs/superpowers/plans/
├── 2026-06-07-resource-unification-implementation.md      ← this file
└── 2026-06-07-resource-unification-implementation.zh_cn.md ← Chinese companion
```

---

## Repo facts (verified on `origin/spec/resource-unification`, avoid these traps)

- `Ezagent.UriQuery.register/2` requires a **1-arity** resolver
  (`is_function(resolver, 1)`, `uri_query.ex:54`) and is one-owner-per-attr
  (`:ets.insert_new`). `resolve/2` normalizes `{:ok,_} | :none | {:error,_}`,
  else `{:invalid_resolver_return,_}` (`uri_query.ex:84-87`). `{:no_resolver,_}`
  is fail-loud. **The `FsResolver` is therefore a plain module API, NOT a
  `UriQuery` attr** — it takes 2 args `(uri, scope)`; the `:config_dir` owner
  delegates to it by passing `{uri, scope}` as the 1-arg payload (P1).
- `Ezagent.URI.resource(ws, type, name)` is **workspace-first** — builds
  `resource://<ws>/<type>/<name>` via `per_tenant/4` → `segment!/1`
  (`uri.ex:425,456-477`). `segment!/1` rejects empty + `/`-bearing segments;
  `validate_3seg_shape!/2` rejects empty `<ws>` host (`uri.ex:490-495`) — **but
  NEITHER rejects `.` / `..` / NUL, and `<type>` is unconstrained.** This is the
  codex-HIGH gap P0 closes in the resolver (not in `URI`, to avoid touching the
  6-scheme core).
- Accessors: `Ezagent.URI.workspace_name/1`, `type/1`, `name/1` return
  `{:ok, str}` | `:error` (`uri.ex:697,741,768`). `new!/1` parses a string.
- `EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir/1` is the
  **single `:config_dir` owner**; its `resource` clause delegates to
  `Ezagent.UriQuery.resolve(:socialware_config_dir, resource_uri)`
  (`uri_query_resolvers.ex:105-107`). P1 re-points this clause; socialware's own
  resolver (`config_projection.ex:130`, attr `:socialware_config_dir`) is untouched.
- `Ezagent.Sandbox.ConfigDir.path/2` (`config_dir.ex:30-36`) computes a **raw**
  `Path.join([Home.path("<ns>-agents"), <ws>, <name>])`; docstring guarantees
  byte-identical layout for `"cc"`. The cascade calls `UriQuery.resolve(:config_dir,…)`
  — but for `entity`/`template` URIs that returns the **stored** string, so the
  cascade is unaffected by the `resource` migration (D4).
- Uploads write: `admin_live.ex:701` `mkdir_p(Home.path("uploads"))`, `:731`
  `Path.join(Home.path("uploads"), stored_name)` (filename-only, **no `<ws>`**);
  handle minted at `:734` via `URI.resource(workspace_name, :uploads, stored_name)`
  (cosmetic). Read: `uploads_controller.ex:108` `Path.join(Home.path("uploads"), safe)`,
  authz `caller_in_attaching_messages?/2`, route `GET /files/:filename`.
- `Mix.Tasks.Ezagent.UriQuery.Scan` already parses `--fail-category` against
  `Ezagent.UriQuery.Scan.known_categories/0` (`ezagent.uri_query.scan.ex:64-79`);
  adding the category atom to `@known_categories` (`scan.ex:28-37`) makes it
  immediately usable. `@default_globs = ["apps/**/*.ex"]` (`scan.ex:39-41`) — so
  `config/runtime.exs` / `config/dev.exs` are **out of scanner scope** (no
  exception needed for them; listed in the exception module for completeness only).
- **Invariant CI gates:** `mix ezagent.check_invariants` and
  `mix ezagent.check_invariants.lifecycle` (`apps/ezagent_core/lib/mix/tasks/`).
  Every PR keeps both green.

---

## Locked contracts (do not re-litigate — SPEC-approved)

1. `FsResolver` is **registration-only** with a **closed per-`<type>` allowlist**;
   an unregistered `<type>` returns **`:none`** (NO implicit Home catch-all, R-1).
2. `resolve/2` is **authorization-bearing**: there is **no `resolve/1`** that
   skips authority. `scope.workspace` always comes from the caller's
   authenticated context, **never** from the URI being resolved (R-3).
3. Unsafe-segment rejection happens **before any `Path.join`** (R-2). `Home.path`
   is reached **only** on the success path with the registered `backend_component` (R-4).
4. P0 registers **zero** real types (dormant); P1 adds config-dir; P2b adds uploads.
5. The scan gate **hard-fails NEW** from the PR it lands in (no warn-then-flip);
   exceptions are **exact `Module.function/arity` anchors — no glob, no dir prefix**;
   the baseline **only ever shrinks** (S-1..S-3).
6. **D4 — DO NOT TOUCH** the credential cascade / `Ezagent.Agent.Materializer`
   hot path (`cascade_runtime.ex`, `materializer.ex` — `atomic_replace`/rollback/
   `recover_orphaned`/`copy_secret_relpaths`). Resolve-then-pass; never push URIs in.
7. **P1 path is BYTE-IDENTICAL** to today's `Sandbox.ConfigDir.path/2` output.
8. **No `home://` (7th scheme).** No db/cookie/pty/codex-socket migration.

---

## Codex coordination (mirrors the #25 unify-uri-query protocol)

- **One `resource-unification` tracking issue per phase** (`gh issue create`,
  label `resource-unification`): P0, P0.5, P1, P2, P3 — each links this plan +
  its SPEC §. The P2 issue title is prefixed **`[Allen-gated]`**.
- **One PR per phase**, each carrying its **explicit acceptance gate** (below) in
  the PR body, branched off `origin/main`.
- **Every PR runs `/codex:adversarial-review`** (static-only, skip mix —
  `feedback_codex_companion_no_mix`: the companion `MIX_HOME` has no deps) **+**
  the scan gate (`mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code`
  from P0.5 on) **+** `mix ezagent.check_invariants` **+**
  `mix ezagent.check_invariants.lifecycle` — all green.
- **Self-merge policy (loose-audit):** **P0 / P0.5 / P1 / P3 may self-merge on
  green.** **P2 is HELD for Allen** — open the PR, run all gates green, request
  Allen's review, **do NOT merge**. Post the `[Allen-gated]` notice on the PR + Feishu.
- **TEST DB only.** NEVER `mix ecto.migrate` against dev/prod; never touch
  dev/prod docker (`feedback_e2e_in_docker_fresh_seed`,
  `feedback_destructive_migration_anti_pattern`). No live-node hacks
  (`feedback_no_hack_use_cli_on_live_node`).
- **Codex sub-step granularity** (`feedback_codex_substeps_not_whole_prs`): if
  Codex orphans a whole-PR job, the author owns the PR and hands Codex bounded
  verifiable sub-steps (e.g. "review only `fs_resolver.ex` for the R-2 traversal
  guard"); never stall.

---

## P0 — Hardened generic `resource://` FS resolver (registration-only)

**Issue:** `resource-unification: P0 generic FS resolver`. **Self-merge on green.**

### Task P0.1 — failing test: unregistered type → `:none` (R-1)

- [ ] Create `apps/ezagent_core/test/ezagent/resource/fs_resolver_test.exs`:

```elixir
defmodule Ezagent.Resource.FsResolverTest do
  use ExUnit.Case, async: true

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  # A test-only type spec registered per-test so P0 ships dormant (zero real types).
  defp scope(ws), do: %{workspace: ws}

  defp with_type(type, type_spec, fun) do
    :ok = FsResolver.register_type(type, type_spec)
    try do
      fun.()
    after
      FsResolver.unregister_type(type)
    end
  end

  defp ok_authority(uri, scope) do
    {:ok, ws} = EzURI.workspace_name(uri)
    if ws == scope.workspace, do: :ok, else: {:error, {:foreign_workspace, ws}}
  end

  test "R-1: unregistered <type> returns :none (no Home catch-all)" do
    uri = EzURI.resource("acme", "never-registered", "x")
    assert FsResolver.resolve(uri, scope("acme")) == :none
  end
end
```

- [ ] Run: `cd apps/ezagent_core && MIX_ENV=test mix test test/ezagent/resource/fs_resolver_test.exs`
- [ ] **Expected fail:** `module Ezagent.Resource.FsResolver is not available`.

### Task P0.2 — minimal impl: module skeleton + registry + resolve algorithm

- [ ] Create `apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex`. Use an ETS
  table owned by `EzagentCore.EtsOwner` (mirror `UriQuery`'s table pattern) OR a
  module-attr registry seeded at boot; **use a private ETS table created lazily**
  for test-registration symmetry. Implement per SPEC §5.1 algorithm (steps 1–5):

```elixir
defmodule Ezagent.Resource.FsResolver do
  @moduledoc """
  Hardened, registration-only generic `resource://<ws>/<type>/<name>` filesystem
  resolver (Resource-unification SPEC §5.1). Generalizes the socialware
  `config_projection.ex` `assert_workspace_authority!/2` pattern to all
  tenant-scoped, content-shaped artifact families.

  Authorization-bearing: `resolve/2` takes the caller's authenticated `scope`
  and runs the per-`<type>` `authority/2` BEFORE any backend resolve. There is
  NO `resolve/1`. `Ezagent.Home` is the *backend*, reached only on the success
  path after R-1..R-3 pass.
  """
  alias Ezagent.URI, as: EzURI

  @table :ezagent_resource_fs_types

  @type scope :: %{required(:workspace) => String.t() | URI.t(), optional(:principal) => URI.t() | nil}
  @type type_spec :: %{
          backend_component: String.t(),
          authority: (URI.t(), scope() -> :ok | {:error, term()})
        }

  @spec register_type(String.t(), type_spec()) :: :ok | {:error, term()}
  def register_type(type, %{backend_component: c, authority: a} = spec)
      when is_binary(type) and type != "" and is_binary(c) and is_function(a, 2) do
    ensure_table!()
    if :ets.insert_new(@table, {type, spec}), do: :ok, else: {:error, {:already_registered, type}}
  end

  @spec unregister_type(String.t()) :: :ok
  def unregister_type(type), do: (ensure_table!(); :ets.delete(@table, type); :ok)

  @spec resolve(URI.t(), scope()) :: {:ok, String.t()} | :none | {:error, term()}
  def resolve(%URI{scheme: "resource"} = uri, %{workspace: _} = scope) do
    with {:ok, ws} <- seg(EzURI.workspace_name(uri), uri),
         {:ok, type} <- seg(EzURI.type(uri), uri),
         {:ok, name} <- seg(EzURI.name(uri), uri) do
      case lookup(type) do
        :none -> :none                                         # R-1: NO Home catch-all
        {:ok, spec} ->
          with :ok <- reject_unsafe([ws, type, name]),         # R-2: before Path.join
               :ok <- spec.authority.(uri, scope) do           # R-3: uri.<ws> == scope.workspace
            {:ok, Path.join([Ezagent.Home.path(spec.backend_component), ws, name])}  # R-4
          end
      end
    end
  end

  def resolve(%URI{} = _non_resource, _scope), do: :none  # not ours

  defp seg({:ok, v}, _uri), do: {:ok, v}
  defp seg(:error, uri), do: {:error, {:malformed_resource_uri, URI.to_string(uri)}}

  defp lookup(type) do
    ensure_table!()
    case :ets.lookup(@table, type) do
      [{^type, spec}] -> {:ok, spec}
      [] -> :none
    end
  end

  # R-2 — reject ".", "..", separator, NUL, and any segment that is not the exact
  # string Ezagent.URI.segment!/1 would have produced (defense in depth).
  defp reject_unsafe(segments) do
    Enum.reduce_while(segments, :ok, fn s, :ok ->
      cond do
        s in [".", ".."] -> {:halt, {:error, {:unsafe_segment, s}}}
        String.contains?(s, "/") -> {:halt, {:error, {:unsafe_segment, s}}}
        String.contains?(s, <<0>>) -> {:halt, {:error, {:unsafe_segment, s}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true]); :ok
      _ -> :ok
    end
  end
end
```

> **Codex note:** the ETS `:ets.new` in `ensure_table!/0` is fine for P0 (dormant,
> test-driven). In P1, when a real type is registered at boot, move table creation
> to `EzagentCore.EtsOwner` (same as `:ezagent_uri_query_registry`) so the table
> survives the registering process — **flag this as a P1 sub-task, verify the
> table owner is a long-lived supervisor child.** Until then, registration is
> per-test (registered → resolved → unregistered) so dormancy holds.

- [ ] Run the P0.1 test → **expected pass** (R-1).
- [ ] `cd apps/ezagent_core && mix format lib/ezagent/resource/fs_resolver.ex test/ezagent/resource/fs_resolver_test.exs`

### Task P0.3 — failing tests: R-2 traversal/NUL/separator before any FS touch

- [ ] Add to `fs_resolver_test.exs`:

```elixir
  test "R-2: .., ., separator, NUL segments fail before Path.join" do
    type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}
    with_type("t-uploads", type_spec, fn ->
      # name = ".." — must be {:error, {:unsafe_segment, ".."}}, never a path
      uri = %URI{scheme: "resource", host: "acme", path: "/t-uploads/..", port: nil}
      assert {:error, {:unsafe_segment, ".."}} = FsResolver.resolve(uri, scope("acme"))

      uri2 = %URI{scheme: "resource", host: "acme", path: "/t-uploads/."}
      assert {:error, {:unsafe_segment, "."}} = FsResolver.resolve(uri2, scope("acme"))

      uri3 = %URI{scheme: "resource", host: "acme", path: "/t-uploads/a" <> <<0>> <> "b"}
      assert {:error, {:unsafe_segment, _}} = FsResolver.resolve(uri3, scope("acme"))
    end)
  end

  test "R-2: table-driven malicious <name>/<type> strings never reach FS" do
    type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}
    with_type("t-uploads", type_spec, fn ->
      for bad <- ["..", ".", "../../etc/passwd", "a/b", "x" <> <<0>>] do
        uri = %URI{scheme: "resource", host: "acme", path: "/t-uploads/" <> bad}
        assert match?({:error, {:unsafe_segment, _}}, FsResolver.resolve(uri, scope("acme"))),
               "expected unsafe-segment rejection for #{inspect(bad)}"
      end
    end)
  end
```

> Note: build URIs as raw `%URI{}` structs (NOT via `EzURI.resource/3`, which
> would `segment!`-reject `a/b` before the resolver sees it) — the test must prove
> the **resolver itself** rejects, since an upload `<name>` arrives as a raw string.

- [ ] Run → some pass already (the impl handles them); confirm `../../etc/passwd`
  is caught by the `/`-contains clause. **Expected: all green.**

### Task P0.4 — failing tests: R-3 authority + R-4 success path

- [ ] Add:

```elixir
  test "R-3: authority mismatch (uri.<ws> != scope.workspace) fails loud, not :none" do
    type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}
    with_type("t-uploads", type_spec, fn ->
      uri = EzURI.resource("victim", "t-uploads", "secret.pdf")
      assert {:error, {:foreign_workspace, "victim"}} = FsResolver.resolve(uri, scope("attacker"))
    end)
  end

  test "R-3: there is no resolve/1 bypassing authority" do
    refute function_exported?(FsResolver, :resolve, 1)
  end

  test "R-4: success path joins Home.path(component)/<ws>/<name>" do
    type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}
    with_type("t-uploads", type_spec, fn ->
      uri = EzURI.resource("acme", "t-uploads", "file.pdf")
      assert {:ok, path} = FsResolver.resolve(uri, scope("acme"))
      assert path == Path.join([Ezagent.Home.path("t-uploads"), "acme", "file.pdf"])
    end)
  end

  test "completeness invariant: every registered type has authority/2" do
    # Registry is empty in P0 (dormant); guard fires when P1/P2 register types.
    for {_type, spec} <- :ets.tab2list(:ezagent_resource_fs_types) do
      assert is_function(spec.authority, 2)
      assert is_binary(spec.backend_component)
    end
  end
```

- [ ] Run full file → **expected: all green.**
- [ ] **Commit:** `feat(resource): hardened registration-only resource:// FS resolver (P0)`

### P0 acceptance gate

R-1..R-4 invariant tests green; **no production call site uses the resolver**
(dormant — zero real types registered); `mix ezagent.check_invariants` +
`mix ezagent.check_invariants.lifecycle` + existing `mix ezagent.uri_query.scan`
unchanged & green. `/codex:adversarial-review` clean. **Self-merge.**

---

## P0.5 — Scan-gate scaffold: `home_path_in_runtime_code` (hard-fail-new + baseline)

**Issue:** `resource-unification: P0.5 home_path scan gate`. **Self-merge on green.**

### Task P0.5.1 — exact-anchor exceptions module (NO globs)

- [ ] Create `apps/ezagent_core/lib/ezagent/uri_query/scan/home_path_exceptions.ex`.
  Each entry is `{path, function_id, line, reason}` where `function_id` is a
  binary `"Module.function/arity"` — **never a glob or dir prefix**. From SPEC §5.2:

```elixir
defmodule Ezagent.UriQuery.Scan.HomePathExceptions do
  @moduledoc """
  Exact `Module.function/arity` + line anchors for sanctioned raw `Home.path`/
  `profile_dir`/`home` callers (Resource-unification SPEC §5.2, Decisions D1/D2).
  NO globs, NO directory prefixes — the scanner test (S-2) rejects any `*` here.

  Each entry: {relative_path, "Module.function/arity", line, reason}.
  """
  @exceptions [
    # config files are outside apps/**/*.ex (scanner does not see them); listed
    # for completeness of the sanctioned surface (SPEC §5.2 note).
    {"config/runtime.exs", "config/runtime.exs:db", 14, "db path at config-eval — UriQuery ETS absent (D1)"},
    {"config/runtime.exs", "config/runtime.exs:db", 17, "db path at config-eval (D1)"},
    {"config/dev.exs", "config/dev.exs:env", 22, "config-eval env logic (D1)"},
    # runtime app code under apps/ — these ARE scanned; exact anchors:
    {"apps/ezagent_core/lib/ezagent/runtime.ex", "Ezagent.Runtime.cookie_path/0", 28, "early boot, pre-supervision (D2)"},
    {"apps/ezagent_core/lib/ezagent/runtime.ex", "Ezagent.Runtime.cookie_path/0", 29, "early boot, pre-supervision (D2)"},
    {"apps/ezagent_core/lib/ezagent_runtime/pid_file.ex", "EzagentRuntime.PidFile.dir/1", 95, "OS pid-file handle, registry-independent (D2)"},
    {"apps/ezagent_core/lib/ezagent_runtime/pid_file.ex", "EzagentRuntime.PidFile.dir/1", 98, "OS pid-file handle (D2)"},
    {"apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex", "Ezagent.Template.CodexAgent.default_app_server_socket_path/1", 892, "OS-handle socket, SUN_LEN short-path, not URI-addressable (D2)"}
    # operator mix-tasks (ezagent.home.*, ezagent.bootstrap, home/migration.ex)
    # live under apps/*/lib/mix/tasks/ — add each as an exact Module.function/arity
    # anchor below per SPEC §5.2 table (NOT a lib/mix/tasks/* glob):
    # {"apps/.../mix/tasks/ezagent.home.init.ex", "Mix.Tasks.Ezagent.Home.Init.run/1", 30, "operator mix-task, app-not-started"},
    # ... (P0.5 fills the full table from the live tree; one anchor per call site)
  ]

  @spec all() :: [{String.t(), String.t(), pos_integer(), String.t()}]
  def all, do: @exceptions

  @doc "S-2 guard: true if any exception entry contains a glob or bare-prefix."
  @spec any_glob_or_prefix?() :: boolean()
  def any_glob_or_prefix? do
    Enum.any?(@exceptions, fn {path, fun_id, _line, _reason} ->
      String.contains?(path, "*") or String.contains?(fun_id, "*") or
        not String.contains?(fun_id, "/")  # must be Module.function/arity (or config:tag)
    end)
  end
end
```

> **Codex sub-task (mechanical):** enumerate the operator mix-task anchors from
> the live tree per SPEC §5.2 table — `Mix.Tasks.Ezagent.Home.Init.run/1`
> (`ezagent.home.init.ex:30,32,33,36,49,79,145,159`), `…Home.Backup.run/1`
> (`:62`), `…Home.Restore.run/1`, `…Home.AdoptDb.run/1` (`:61`),
> `Mix.Tasks.Ezagent.Bootstrap.run/1` (`ezagent.bootstrap.ex:89-92`),
> `Ezagent.Home.Migration` call sites (`home/migration.ex`). One concrete
> `Module.function/arity` + line per call site. Mix-task files **are** under
> `apps/**/*.ex` if they live in `apps/*/lib/mix/tasks/` — verify with
> `grep -rn "Home.path\|profile_dir" apps/*/lib/mix/tasks/` and anchor each.

### Task P0.5.2 — line-anchored baseline (burn-down census)

- [ ] Create `apps/ezagent_core/lib/ezagent/uri_query/scan/home_path_baseline.ex`.
  Census from `grep -rn "Home\.path\|Home\.profile_dir\|Home\.home\b" apps --include=*.ex | grep -v /test/`,
  minus exceptions. Each entry `{path, line, call}`:

```elixir
defmodule Ezagent.UriQuery.Scan.HomePathBaseline do
  @moduledoc """
  Line-anchored burn-down baseline of CURRENT runtime-app-code raw `Home.path`
  callers (Resource-unification SPEC §5.2). A baselined call is tolerated ONLY at
  its recorded anchor; moving/duplicating it fails. P1/P2/P3 REMOVE entries as
  families migrate. When empty, the lockdown is complete. The baseline only ever
  SHRINKS (S-3).
  """
  @baseline [
    {"apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex", 32, "Home.path(\"#{namespace}-agents\")"},     # → removed in P1
    {"apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex", 701, "Home.path(\"uploads\")"}, # → removed in P2b
    {"apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex", 731, "Home.path(\"uploads\")"}, # → removed in P2b
    {"apps/ezagent_web/lib/ezagent_web/controllers/uploads_controller.ex", 108, "Home.path(\"uploads\")"},  # → removed in P2b
    # population-3 (migrated/exempted in P3):
    {"apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/token_store.ex", 120, "Home.path(:credentials)"},
    {"apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex", 143, "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex", 164, "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex", 176, "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/client.ex", 414, "Home.profile_dir()"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex", 165, "Home.path(:credentials)"},
    {"apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex", 176, "Home.path(:plugins)"},
    {"apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex", 708, "Home.path(:logs)"}
  ]

  @spec all() :: [{String.t(), pos_integer(), String.t()}]
  def all, do: @baseline
end
```

> **Codex sub-task:** re-run the census on the PR branch (`origin/main`) right
> before finalizing — line numbers MUST match the live tree at P0.5 land time
> (`feedback_git_pull_before_state_claim`). Any drift = update the anchor.

### Task P0.5.3 — failing test: S-1 new call fails the category

- [ ] Create `apps/ezagent_core/test/ezagent/uri_query/scan_home_path_test.exs`:

```elixir
defmodule Ezagent.UriQuery.ScanHomePathTest do
  use ExUnit.Case, async: true
  alias Ezagent.UriQuery.Scan

  @fixture Path.join(System.tmp_dir!(), "home_path_fixture_#{System.unique_integer([:positive])}.ex")

  setup do
    File.write!(@fixture, """
    defmodule Fixture.NewRawHomeCall do
      def bad, do: Path.join(Ezagent.Home.path("uploads"), "x")
    end
    """)
    on_exit(fn -> File.rm(@fixture) end)
    :ok
  end

  test "S-1: a new unbaselined runtime Home.path call is flagged home_path_in_runtime_code" do
    violations = Scan.scan_paths([@fixture], baseline: [], exceptions: [])
    assert Enum.any?(violations, &(&1.category == :home_path_in_runtime_code))
  end

  test "category is registered in known_categories" do
    assert :home_path_in_runtime_code in Scan.known_categories()
  end
end
```

- [ ] Run → **expected fail** (`:home_path_in_runtime_code` not yet a category).

### Task P0.5.4 — impl: add category to scanner

- [ ] Edit `apps/ezagent_core/lib/ezagent/uri_query/scan.ex`:
  - Add `:home_path_in_runtime_code` to `@known_categories` (`scan.ex:28`).
  - Add an AST finding (mirror `positional_uri_read_finding/3` shape, `scan.ex:134`)
    matching `Ezagent.Home.path/1`, `Ezagent.Home.profile_dir/0`, `Ezagent.Home.home/0`
    (also the `alias … Home` form `Home.path(...)` as in `uploads_controller.ex:108` —
    match on the trailing `.path`/`.profile_dir`/`.home` call against a `Home`-suffixed
    module alias, AST `{{:., _, [{:__aliases__,_, mods}, fun]}, _, args}` where
    `List.last(mods) == :Home and fun in [:path, :profile_dir, :home]`).
  - Subtract the baseline + exceptions (by `{path, line}`) so existing sanctioned
    callers do not fire. Add `:baseline` / `:exceptions` opts to `scan_paths/2`
    defaulting to `HomePathBaseline.all()` / `HomePathExceptions.all()`.

> **Codex note:** the alias-resolution subtlety — `uploads_controller.ex` does
> `alias Ezagent.Home` then `Home.path(...)`, while `admin_live.ex` uses the fully
> qualified `Ezagent.Home.path(...)`. Match BOTH by checking `List.last(mods) == :Home`.
> Add a test for each form. Do NOT match a local `Home` struct field access.

- [ ] Run P0.5.3 test → **expected pass.**

### Task P0.5.5 — S-2 + S-3 tests

- [ ] Add:

```elixir
  test "S-2: every exception is an exact Module.function/arity anchor, no glob/prefix" do
    refute Ezagent.UriQuery.Scan.HomePathExceptions.any_glob_or_prefix?()
  end

  test "S-3: category is GREEN on the live tree (baseline + exceptions cover all callers)" do
    violations =
      Scan.scan()
      |> Enum.filter(&(&1.category == :home_path_in_runtime_code))
    assert violations == [], "unbaselined runtime Home.path callers: #{inspect(violations)}"
  end
```

- [ ] Run → **expected pass** (baseline census is complete). If RED, a caller is
  missing from the baseline — add it (and verify it is genuinely runtime app code).

### Task P0.5.6 — wire `--fail-category` into CI

- [ ] Add to the repo CI workflow (the same step that runs `mix ezagent.uri_query.scan`):
  `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code`. The task
  already supports the flag (`ezagent.uri_query.scan.ex:64-79`); no task code change.
- [ ] **Commit:** `feat(scan): home_path_in_runtime_code hard-fail-new gate + baseline (P0.5)`

### P0.5 acceptance gate

New category GREEN on current tree (S-3); a deliberately-added unbaselined call
turns it RED (S-1 fixture); exceptions are exact anchors (S-2);
`--fail-category home_path_in_runtime_code` wired into CI; `check_invariants(.lifecycle)`
green; `/codex:adversarial-review` clean. **Self-merge.**

---

## P1 — Migrate per-agent config-dir to resolve via `resource://<ws>/<config-type>/<name>`

**Issue:** `resource-unification: P1 config-dir via resolver`. **Self-merge on green.**

*(config-dir BEFORE uploads: it is the exact socialware seam shape already on the
cascade; lower-risk; cascade already URI-addressed, D4.)*

### Task P1.1 — failing test: byte-identical parity

- [ ] Create `apps/ezagent_core/test/ezagent/sandbox/config_dir_parity_test.exs`:

```elixir
defmodule Ezagent.Sandbox.ConfigDirParityTest do
  use ExUnit.Case, async: false   # registers a real type; serialize
  alias Ezagent.Sandbox.ConfigDir
  alias Ezagent.URI, as: EzURI

  test "P1: config_dir path is BYTE-IDENTICAL to the pre-P1 raw Home layout" do
    agent_uri = EzURI.entity("acme", "cc", "worker-1")  # adjust ctor to the canonical agent URI builder
    namespace = "cc"
    # the pre-P1 layout (SPEC §3 / config_dir.ex:15 docstring):
    expected = Path.join([Ezagent.Home.path("cc-agents"), "acme", "worker-1"])
    assert ConfigDir.path(agent_uri, namespace) == expected
  end

  test "P1: foreign-<ws> authority fails loud" do
    # building resource://victim/cc-agents/x and resolving under scope acme must fail.
    uri = EzURI.resource("victim", "cc-agents", "worker-1")
    assert {:error, _} = Ezagent.Resource.FsResolver.resolve(uri, %{workspace: "acme"})
  end
end
```

> **Codex note:** confirm the canonical agent-URI constructor + how
> `Sandbox.ConfigDir.path/2` extracts `<ws>`/`<name>` today (`workspace_segment/1`,
> `name_segment/1` in `config_dir.ex`). The parity test pins the EXACT current
> output — read `config_dir.ex` and reproduce its `<ws>`/`<name>` derivation.

- [ ] Run → parity test should **pass on the current impl** (it's the baseline);
  the authority test **fails** (type not registered yet). This locks the invariant
  before the refactor.

### Task P1.2 — register the config-dir type + move table ownership

- [ ] Move `FsResolver`'s ETS table creation into `EzagentCore.EtsOwner` (the
  long-lived owner of `:ezagent_uri_query_registry`) so a boot-time registration
  survives (P0 codex note). Verify the owner is a supervisor child started in
  `application.ex` before any registration.
- [ ] Register the config-dir type at boot (alongside `seed_uri_schemes/0` /
  resolver registration in `application.ex`), e.g.:
  `FsResolver.register_type("cc-agents", %{backend_component: "cc-agents", authority: &config_dir_authority/2})`
  where `config_dir_authority/2` asserts `uri.<ws> == scope.workspace`.
  Generalize per-namespace (`"<ns>-agents"`) — register the namespaces in use
  (`cc`, `codex`, …) from `Ezagent.Kind.Template.config_dir_namespace/0` catalog.

> **Codex note:** `backend_component` MUST equal `"<ns>-agents"` so the resolver
> joins `Home.path("<ns>-agents")/<ws>/<name>` — byte-identical to today.

### Task P1.3 — re-express `Sandbox.ConfigDir.path/2` through the seam

- [ ] Edit `apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex:30-36`: build
  `EzURI.resource(workspace_segment(agent_uri), "#{namespace}-agents", name_segment(agent_uri))`
  and resolve via `FsResolver.resolve(uri, %{workspace: workspace_segment(agent_uri)})`,
  returning the `{:ok, path}` string. The `scope.workspace` is the **agent's own
  authoritative workspace** (the cascade's authenticated subject — NOT attacker
  supplied), so authority always passes for the legitimate path while a forged
  cross-`<ws>` URI fails (the parity authority test).
- [ ] **The resolved string is byte-identical** → the P1.1 parity test stays green.

### Task P1.4 — re-point the `:config_dir` resolver's `resource` clause

- [ ] Edit `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/uri_query_resolvers.ex:105-107`:
  the `resolve_config_dir(%URI{scheme: "resource"} = uri)` clause tries the generic
  `FsResolver.resolve(uri, scope)` for registered config-dir types FIRST, and on
  `:none` falls through to `Ezagent.UriQuery.resolve(:socialware_config_dir, uri)`.
  Ordering total + fail-loud (a `{:error,_}` from authority propagates, NOT swallowed).

```elixir
  def resolve_config_dir(%URI{scheme: "resource"} = resource_uri) do
    scope = %{workspace: config_dir_scope_workspace!(resource_uri)}  # agent's authoritative ws
    case Ezagent.Resource.FsResolver.resolve(resource_uri, scope) do
      :none -> Ezagent.UriQuery.resolve(:socialware_config_dir, resource_uri)  # socialware-config-object
      other -> other   # {:ok, path} | {:error, reason} (fail loud, never swallowed)
    end
  end
```

> **Codex note (D4 GUARD):** do NOT change `cascade_runtime.ex` or
> `materializer.ex`. The cascade still calls `UriQuery.resolve(:config_dir, uri)`
> and receives a resolved STRING — only *how* the string is produced changes.
> Add an assertion in the PR checklist that `git diff` touches **zero** lines in
> `cascade_runtime.ex` / `materializer.ex`.

- [ ] Remove the `config_dir.ex:32` entry from `HomePathBaseline` (the
  `Home.path("<ns>-agents")` call is now inside `FsResolver`'s success path, which
  is the registered backend — exempt by being the resolver itself; verify the
  scanner does not flag `fs_resolver.ex` — it is the resolver implementation, add
  it to `@default_excluded_paths` like `uri.ex`/`scan.ex` are, `scan.ex:43-47`).

### Task P1.5 — run + verify

- [ ] `cd apps/ezagent_core && MIX_ENV=test mix test test/ezagent/sandbox/config_dir_parity_test.exs test/ezagent/resource/fs_resolver_test.exs`
- [ ] Run existing config_dir + cascade tests:
  `MIX_ENV=test mix test apps/ezagent_core apps/ezagent_domain_instance_message` (config_dir + cascade respawn).
- [ ] `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code` → GREEN (baseline shrank by config_dir).
- [ ] **Commit:** `feat(resource): per-agent config-dir resolves via resource:// seam, byte-identical (P1)`

### P1 acceptance gate

Byte-identical parity test green; foreign-`<ws>` authority fails loud;
cascade/Materializer tests unchanged and green (`git diff` shows zero lines in
`cascade_runtime.ex`/`materializer.ex` — D4); P0.5 baseline shrinks by the
config-dir entry; the config-dir `Home.path` call is gone from runtime app code;
`check_invariants(.lifecycle)` green; `/codex:adversarial-review` clean. **Self-merge.**

---

## P2 — Migrate uploads to STORE via the resolver — DOWNLOAD CONTRACT FIRST  ⚠️ ALLEN-GATED

> **🔒 ALLEN-GATED — do NOT auto-merge.** Open the PR, run ALL gates green,
> request Allen's review, post the `[Allen-gated]` notice on the PR + Feishu, and
> **STOP.** This phase changes a security boundary (download authz → signed token).

**Issue:** `[Allen-gated] resource-unification: P2 uploads via resolver + signed token`.

> **Sequence the contract change BEFORE the byte move** (SPEC §6 P2). Today bytes
> land at `Home.path("uploads")/<stored_name>` (filename-only, **no `<ws>`**,
> `admin_live.ex:731`) and `UploadsController.show/2` authorizes by
> session-participation (`uploads_controller.ex:134`), NOT by `<ws>`.

### P2a — Download contract + workspace-segment authorization (no byte move yet)

#### Task P2a.1 — failing test: signed token TTL/binding/replay/expiry

- [ ] Create `apps/ezagent_web/test/ezagent_web/uploads/upload_token_test.exs`:

```elixir
defmodule EzagentWeb.Uploads.UploadTokenTest do
  use ExUnit.Case, async: true
  alias EzagentWeb.Uploads.UploadToken
  alias Ezagent.URI, as: EzURI

  @uri EzURI.resource("acme", "uploads", "uuid-file.pdf")

  test "mint→verify round-trips the exact ws-scoped URI" do
    token = UploadToken.mint!(@uri, ttl_seconds: 60)
    assert {:ok, verified_uri} = UploadToken.verify(token)
    assert EzURI.stable_key(verified_uri) == EzURI.stable_key(@uri)
  end

  test "token is BOUND to one URI — cannot be replayed for another ws/file" do
    token = UploadToken.mint!(@uri, ttl_seconds: 60)
    {:ok, uri} = UploadToken.verify(token)
    refute EzURI.stable_key(uri) == EzURI.stable_key(EzURI.resource("victim", "uploads", "uuid-file.pdf"))
  end

  test "expired token is rejected" do
    token = UploadToken.mint!(@uri, ttl_seconds: -1)
    assert {:error, :expired} = UploadToken.verify(token)
  end

  test "tampered/forged token is rejected (MAC)" do
    assert {:error, _} = UploadToken.verify("not-a-real-token")
  end
end
```

- [ ] Run: `cd apps/ezagent_web && MIX_ENV=test mix test test/ezagent_web/uploads/upload_token_test.exs`
- [ ] **Expected fail:** `EzagentWeb.Uploads.UploadToken is not available`.

#### Task P2a.2 — impl signed token (mint after authz, bound to URI, TTL)

- [ ] Create `apps/ezagent_web/lib/ezagent_web/uploads/upload_token.ex`. Use
  `Phoenix.Token.sign/verify` (HMAC over `Endpoint` secret) with `max_age` = TTL
  and payload = the URI stable key:

```elixir
defmodule EzagentWeb.Uploads.UploadToken do
  @moduledoc """
  Signed capability token encoding the FULL ws-scoped resource://<ws>/uploads/<name>
  URI (Resource-unification SPEC §6 P2a / OI-1). S3-presigned-URL style:
  short TTL, bound to ONE URI, minted ONLY after authorization, MAC-signed.
  """
  alias Ezagent.URI, as: EzURI
  @salt "ezagent.upload.v1"
  @default_ttl 300  # 5 min — short TTL bounds the bearer-leak window (OI-1.1)

  @spec mint!(URI.t(), keyword()) :: String.t()
  def mint!(%URI{scheme: "resource"} = uri, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)
    # Caller is responsible for authz BEFORE mint (OI-1.3). Payload binds the URI.
    Phoenix.Token.sign(EzagentWeb.Endpoint, @salt, %{uri: EzURI.stable_key(uri)}, max_age: ttl)
  end

  @spec verify(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(EzagentWeb.Endpoint, @salt, token, max_age: :infinity) do
      {:ok, %{uri: key}} -> {:ok, EzURI.new!(key)}
      {:error, :expired} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

> **Codex note on TTL:** `Phoenix.Token.sign` embeds the issue time; `verify` with
> `max_age` enforces expiry. For the `ttl_seconds: -1` expiry test, sign with
> `max_age` then verify with the configured TTL — OR store the TTL in the payload
> and check it in `verify` so `mint!(ttl: -1)` is immediately expired. Choose the
> approach that makes the P2a.1 expiry test pass deterministically; document it.

- [ ] Run P2a.1 → **expected pass.**

#### Task P2a.3 — register uploads type + ws-segment authority

- [ ] Register the `uploads` type on `FsResolver` (backend `"uploads"`,
  `authority/2` = `uri.<ws> == scope.workspace`) at boot.

#### Task P2a.4 — mint-time authz + serve-time re-validation

- [ ] In the mint path (the LiveView/controller endpoint that hands a download
  link), mint a token ONLY after authorization:
  - **internal** (operator/session): live cap-check at mint time;
  - **external customer-feed** (#601/#603 React SPA, viewers with no session/caps):
    gated by the customer-feed **approved-only** visibility — a token is issued
    only for an approved item.
- [ ] At serve time, the controller (a) verifies the token (MAC + TTL), (b) extracts
  the bound `resource://<ws>/uploads/<name>` URI, (c) runs the resolver's
  `authority/2` with the request-mount scope, and (d) **for the feed, re-confirms
  the item is still approved** (revocation lever beyond TTL).
- [ ] **Fix doc drift** (SPEC §6 P2a): one-line comment fix at `capability.ex:556`
  and `admin_live.ex` upload comment — they say `resource://<type>/<workspace>/<name>`
  but the constructor `URI.resource(ws, type, name)` is **workspace-first**.

#### Task P2a.5 — back-compat window for `GET /files/:filename`

- [ ] Keep `GET /files/:filename` (`router.ex:74`) resolving already-minted
  filename-only links during a stated deprecation window (the ONE sanctioned
  shim, N6) — add the new token route alongside it.
- [ ] Test: same-filename-two-workspaces proving the NEW contract disambiguates,
  and the old contract is unambiguous only because today's filenames are
  UUID-prefixed (a regression assertion).
- [ ] **Commit:** `feat(uploads): signed-token download contract + ws-segment authz, doc-drift fix (P2a)`

### P2b — Move the bytes through the resolver

#### Task P2b.1 — failing tests: same-filename-2-ws + foreign-ws + round-trip

- [ ] Edit `apps/ezagent_web/test/ezagent_web/controllers/uploads_controller_test.exs`:

```elixir
  test "P2b: same filename in two workspaces is isolated on disk and on read" do
    # write file "shared.pdf" under ws acme and ws beta via the resolver;
    # assert the two byte paths differ (…/uploads/acme/… vs …/uploads/beta/…)
    # and a download token bound to acme's URI cannot read beta's bytes.
  end

  test "P2b: foreign-<ws> download is denied (authority/2)" do
    token = EzagentWeb.Uploads.UploadToken.mint!(Ezagent.URI.resource("victim", "uploads", "f.pdf"))
    conn = get(build_conn_with_scope("acme"), ~p"/uploads/download?token=#{token}")
    assert conn.status == 403
  end

  test "P2b: upload→download round-trip via the real route" do
    # upload through admin_live → mint token → GET download → bytes match.
  end

  test "P2b: back-compat /files/:filename still resolves within the window" do
    # an already-minted UUID-prefixed filename-only link still downloads.
  end
```

- [ ] Run → **expected fail** (write/read not yet via resolver).

#### Task P2b.2 — write + read via resolver

- [ ] Edit `admin_live.ex:701,731`: replace `Home.path("uploads")` with
  `FsResolver.resolve(EzURI.resource(workspace_name, :uploads, stored_name), %{workspace: workspace_name})`
  → `{:ok, dest}`; `File.mkdir_p!(Path.dirname(dest))`; `File.cp!(tmp_path, dest)`.
  The minted handle (already `URI.resource(workspace_name, :uploads, stored_name)`)
  becomes load-bearing (was cosmetic).
- [ ] Edit `uploads_controller.ex:108`: replace `Path.join(Home.path("uploads"), safe)`
  with the token-verified URI resolved via `FsResolver.resolve(uri, %{workspace: mount_ws})`
  → `{:ok, full}`; keep the existing `safe`/`.`/`..` guard (`uploads_controller.ex:97-99`)
  as defense-in-depth on top of the resolver's R-2.
- [ ] Remove `admin_live.ex:701,731` + `uploads_controller.ex:108` from `HomePathBaseline`.
- [ ] Run P2b.1 → **expected pass.**
- [ ] `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code` → GREEN (baseline shrank by uploads).
- [ ] **Commit:** `feat(uploads): store+read bytes through resolver, ws-scoped layout (P2b)`

> **OI-2 (DECIDED): resolver returns a PATH** (uploads are already files on disk);
> revisit streaming only if a large-upload requirement appears. Do NOT add an
> IO-device return shape.

### P2 acceptance gate

All upload/download tests green; authz is by `<ws>` segment via the signed token
+ resolver `authority/2`; token tests (TTL / binding / replay / expiry) green;
bytes live at `…/uploads/<ws>/<name>`; back-compat link resolves within the
window; baseline shrinks by the uploads entries; `check_invariants(.lifecycle)`
green; `/codex:adversarial-review` clean. **🔒 HELD FOR ALLEN — do NOT merge.**

---

## P3 — Burn down the lockdown baseline

**Issue:** `resource-unification: P3 baseline burn-down`. **Self-merge on green.**

### Task P3.1 — migrate remaining population-3 callers (OI-3 decision)

> **OI-3 (DECIDED): no broad exemptions; the only exemption axis is boot-order,
> NOT "no `<ws>`".** A caller is exempt ONLY if it runs **before the
> SchemeRegistry/UriQuery ETS tables exist** (config-eval / pre-`Application.start`).
> Every other caller goes **through UriQuery**:
> - tenant-scoped content → `resource://<ws>/<type>/<name>`;
> - system/global artifacts → **`system://<type>`** (reused system scheme, still
>   UriQuery-resolved — NOT an exemption).

- [ ] For each remaining baseline entry, decide + implement:
  - `agent_bridge/token_store.ex:120` (per-agent token, tenant-scoped) →
    `resource://<ws>/<type>/<name>` via resolver (register a token `<type>`).
  - `domain/python/server.ex:708` (per-agent log, tenant-scoped) →
    `resource://<ws>/<type>/<name>` (register a log `<type>`).
  - `plugin_feishu/client.ex:164,176,414`, `ws_client.ex:165`,
    `application.ex:176` (global app cred / inbox / plugin config — system-level) →
    `system://<type>` resolved via UriQuery (register a `system://` resolver), OR
    exact-anchor exception IF genuinely boot-order.
  - `domain_identity/application.ex:143` (smtp_config, **read inside
    `Application.start/2`?**) — **VERIFY boot order:** if it reads its credential
    **before** registry seeding (`seed_uri_schemes/0`, `application.ex:183-191`),
    it is a genuine boot-order exemption (exact anchor + reason); otherwise it
    migrates to `system://`. SPEC §10 OI-3 flags this as the one item to verify.

> **Codex note:** identity-app start order — check the umbrella's `applications`
> dependency order + whether the credential read is at module-eval / `start/2`
> top vs. lazily. Document the finding in the PR.

### Task P3.2 — lower baseline to minimal exact-anchor set

- [ ] Remove every migrated entry from `HomePathBaseline`. For each genuine
  boot-order / OS-handle caller, move it from the baseline to `HomePathExceptions`
  as an exact `Module.function/arity` anchor + stated reason.
- [ ] **Goal: `HomePathBaseline.all() == []`.** Update the S-3 test to assert the
  baseline is empty (the completion invariant per
  `feedback_completion_requires_invariant_test`):

```elixir
  test "P3 completion: the home_path_in_runtime_code baseline is EMPTY" do
    assert Ezagent.UriQuery.Scan.HomePathBaseline.all() == []
  end
```

- [ ] **Commit:** `feat(resource): burn down home_path baseline to empty; lockdown complete (P3)`

### P3 acceptance gate

`HomePathBaseline.all() == []`; every remaining runtime `Home.path` call is gone
or an exact-anchor exception with a reason; identity-app boot order verified +
documented; `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code`
GREEN; `check_invariants(.lifecycle)` green; `/codex:adversarial-review` clean. **Self-merge.**

### STOP HERE.

db / runtime cookie / codex socket / pty-pids stay on **sanctioned raw `Home`**
(D2, exact-anchor exceptions). Global creds deferred (D5). No `home://` (D3).

---

## Per-phase PR summary

| Phase | PR scope | Acceptance gate | Merge policy |
|---|---|---|---|
| **P0** | `FsResolver` (registration-only, dormant) | R-1..R-4 green, no prod caller | **self-merge** |
| **P0.5** | `home_path_in_runtime_code` scan gate + baseline | S-1..S-3 green, CI wired | **self-merge** |
| **P1** | config-dir via resolver (byte-identical) | parity green, D4 untouched, baseline −1 | **self-merge** |
| **P2** | uploads: signed-token contract + byte move | token+ws authz green, baseline −uploads | **🔒 ALLEN-GATED** |
| **P3** | population-3 burn-down | baseline empty, identity order verified | **self-merge** |

Every PR: `/codex:adversarial-review` (static-only) + scan gate +
`mix ezagent.check_invariants` + `mix ezagent.check_invariants.lifecycle` green.
TEST DB only; no dev/prod migrate; no dev/prod docker.

## What this plan deliberately does NOT touch

- `Ezagent.Credential.CascadeRuntime` / `Ezagent.Agent.Materializer`
  (`atomic_replace`/rollback/`recover_orphaned`/`copy_secret_relpaths`) — D4,
  resolve-then-pass. PR checklist asserts zero diff lines here in P1.
- `Ezagent.URI` 6-scheme core — the `.`/`..` rejection lives in the resolver, not
  in `segment!/1` (avoids touching invariant #11).
- db / cookie / pty-pids / codex socket — sanctioned raw `Home` (D2).
- A 7th `home://` scheme (D3); global credentials (D5).
