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

## Codex adversarial-review findings (2026-06-07) + resolutions

The plan was reviewed by `/codex:adversarial-review` (static-only). Verdict
`needs-attention`; all findings folded in:

- **[CRITICAL] config-dir authority circular for resource URIs.** P1.4 derived
  `scope.workspace` from the same `resource_uri` being authorized → tautological
  check (a forged `resource://victim/cc-agents/x` would resolve under scope
  `victim`). **Resolved:** (a) `Sandbox.ConfigDir.path/2` derives `auth_ws` from
  the **agent_uri** (the authenticated subject) and *constructs* the resource URI
  from it (P1.3); (b) the `:config_dir` attribute **rejects bare config-dir
  `resource://` URIs** (`{:error, :config_dir_resource_requires_scope}`) — only
  the self-authorizing socialware-config-object is allowed bare; scoped config-dir
  resolution requires an external `{uri, scope}` payload (P1.4). Negative
  regression test added.
- **[HIGH] signed token verified with `max_age: :infinity`.** **Resolved:** TTL
  pinned — verify NEVER uses `:infinity`; non-positive TTL rejected at mint
  (except a test-only override); a 24h hard outer ceiling; a default-token-expiry
  test proving a normal token is not valid forever (P2a.1/P2a.2).
- **[HIGH] resolver allowlist mutable from arbitrary runtime code.** **Resolved:**
  the type table is `:protected`, owned by an `FsResolver.Registry` GenServer (the
  sole writer); `register_type/2` is boot-only; `unregister_type/1` is test-only
  (compiled out of `:prod`). Mutability tests added (P0.2/P0.4).
- **[MEDIUM] exact-anchor gate not mechanically exact.** **Resolved:** S-2 now
  validates strict `Module.function/arity` (regex), positive line, concrete `.ex`
  path; and a cross-check test (`home_call_anchor_matches?/3`) asserts each anchor
  maps to **exactly one** live Home call enclosed by the named function — anchor
  subtraction is by enclosing-function identity, not `{path, line}` alone (P0.5.1/P0.5.4/P0.5.5).

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

  # WRITE-GATED registry (codex HIGH): the table is :protected — only THIS module's
  # owning process may write. register_type/2 runs ONLY during supervised boot
  # (asserted via boot_phase?/0); there is NO production unregister. Arbitrary
  # runtime code cannot insert/replace/delete a type spec, so the central FS auth
  # boundary is not mutable global state. See ownership note below.
  @spec register_type(String.t(), type_spec()) :: :ok | {:error, term()}
  def register_type(type, %{backend_component: c, authority: a} = spec)
      when is_binary(type) and type != "" and is_binary(c) and is_function(a, 2) do
    unless boot_phase?(), do: raise(RuntimeError, "FsResolver.register_type/2 is boot-only")
    # writes go through the owning GenServer/EtsOwner (protected table):
    Ezagent.Resource.FsResolver.Registry.insert_new(type, spec)
  end

  # unregister_type/1 is TEST-ONLY (compiled out of :prod via Mix.env or a module
  # attribute guard); there is no production unregister path (codex HIGH).
  if Mix.env() != :prod do
    @spec unregister_type(String.t()) :: :ok
    def unregister_type(type), do: Ezagent.Resource.FsResolver.Registry.delete(type)
  end

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
    case :ets.lookup(lookup_table(), type) do  # read-only; table owned by Registry
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

  defp lookup_table, do: :ezagent_resource_fs_types  # :protected, owned by Registry
end

# Write-gated owner — the ONLY writer of the :protected type table (codex HIGH).
defmodule Ezagent.Resource.FsResolver.Registry do
  @moduledoc false
  use GenServer
  @table :ezagent_resource_fs_types
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  @impl true
  def init(:ok) do
    # :protected — readable by anyone (resolve/2 reads), writable ONLY here.
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end
  def insert_new(type, spec), do: GenServer.call(__MODULE__, {:insert_new, type, spec})
  if Mix.env() != :prod, do: (def delete(type), do: GenServer.call(__MODULE__, {:delete, type}))
  @impl true
  def handle_call({:insert_new, type, spec}, _from, st) do
    {:reply, (if :ets.insert_new(@table, {type, spec}), do: :ok, else: {:error, {:already_registered, type}}), st}
  end
  if Mix.env() != :prod do
    @impl true
    def handle_call({:delete, type}, _from, st), do: (:ets.delete(@table, type); {:reply, :ok, st})
  end
end
```

> **Codex note (registry mutability, HIGH):** the type table is `:protected`,
> owned by `Ezagent.Resource.FsResolver.Registry` (a GenServer), so **only that
> process writes** — arbitrary runtime code cannot insert/replace/delete a type
> spec (which would change an `authority` fn or `backend_component` after boot and
> subvert the central FS auth boundary). `register_type/2` is **boot-only**
> (`boot_phase?/0` guard) and `unregister_type/1` is **test-only** (compiled out
> of `:prod`). Add the `Registry` GenServer to the `ezagent_core` supervision tree
> in `application.ex` **before** any registration runs (alongside / before
> `seed_uri_schemes/0`). `boot_phase?/0` reads an app-env flag set true only while
> `Application.start/2` is running its child spec (or: assert the caller is the
> Registry's own boot via a one-shot). For P0 the registry starts but registers
> zero real types (dormant); tests register via a test-only path.

> **`boot_phase?/0`:** implement as `Application.get_env(:ezagent_core,
> :fs_resolver_boot_phase, false)` flipped true inside the supervised boot child
> and false after, OR simpler: make `register_type` accept only calls originating
> from `application.ex`'s boot sequence (a private boot token). Pin the exact
> mechanism in P0; the invariant is **no post-boot production registration**.

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

  test "registry table is :protected — arbitrary code cannot write it (codex HIGH)" do
    info = :ets.info(:ezagent_resource_fs_types)
    assert info[:protection] == :protected
    # a direct insert from this (non-owner) process raises ArgumentError.
    assert_raise ArgumentError, fn -> :ets.insert(:ezagent_resource_fs_types, {"forged", %{}}) end
  end

  test "register_type/2 is boot-only; no post-boot production registration" do
    # Outside boot phase, register_type raises (or the test-only path is required).
    # (Exact assertion depends on the boot_phase?/0 mechanism pinned in P0.2.)
    assert function_exported?(Ezagent.Resource.FsResolver.Registry, :insert_new, 2)
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

  @doc """
  S-2 guard: returns the list of MALFORMED exception entries (empty = all valid).
  Each entry must (codex MEDIUM): be a concrete existing `.ex` file (or a config
  file tag), a positive line, and a strict `Module.function/arity` id (regex
  `^[A-Z][\\w.]*\\.[a-z_][\\w?!]*/\\d+$`) — NO `*`, NO directory/path prefix.
  """
  @fun_id_re ~r/^[A-Z][\w.]*\.[a-z_][\w?!]*\/\d+$/
  @spec malformed_entries() :: [tuple()]
  def malformed_entries do
    Enum.reject(@exceptions, fn {path, fun_id, line, _reason} ->
      config_tag? = String.starts_with?(path, "config/")
      valid_path = (config_tag? or String.ends_with?(path, ".ex")) and not String.contains?(path, "*")
      valid_fun = config_tag? or (Regex.match?(@fun_id_re, fun_id) and not String.contains?(fun_id, "*"))
      valid_line = is_integer(line) and line > 0
      valid_path and valid_fun and valid_line
    end)
  end

  @spec any_glob_or_prefix?() :: boolean()
  def any_glob_or_prefix?, do: malformed_entries() != []
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
  - Subtract the baseline + exceptions so existing sanctioned callers do not fire.
    Add `:baseline` / `:exceptions` opts to `scan_paths/2` defaulting to
    `HomePathBaseline.all()` / `HomePathExceptions.all()`.
  - **Anchor matching (codex MEDIUM):** subtract an exception ONLY when the AST
    finding at `{path, line}` is enclosed by a `def`/`defp` whose computed
    `Module.function/arity` EQUALS the exception's `fun_id` — not by `{path, line}`
    alone (a changed call at the same line, or a broad path, must NOT be silently
    exempted). Expose `home_call_anchor_matches?/3(path, fun_id, line)` for the S-2
    cross-check test: parse the file's AST, find the `Home.path|profile_dir|home`
    call at `line`, walk up to its enclosing module + function head, and assert the
    derived `Module.function/arity` == `fun_id` AND that there is exactly one such
    call at that anchor.

> **Codex note:** the alias-resolution subtlety — `uploads_controller.ex` does
> `alias Ezagent.Home` then `Home.path(...)`, while `admin_live.ex` uses the fully
> qualified `Ezagent.Home.path(...)`. Match BOTH by checking `List.last(mods) == :Home`.
> Add a test for each form. Do NOT match a local `Home` struct field access.

- [ ] Run P0.5.3 test → **expected pass.**

### Task P0.5.5 — S-2 + S-3 tests

- [ ] Add:

```elixir
  test "S-2: every exception is a strict Module.function/arity anchor (no glob/prefix)" do
    assert Ezagent.UriQuery.Scan.HomePathExceptions.malformed_entries() == []
  end

  test "S-2 (codex MEDIUM): each apps/ exception matches EXACTLY one current Home call" do
    # Cross-check: for every apps/**/*.ex exception, the scanner must find a real
    # Home.path/profile_dir/home call at that {path, line}, enclosed by a function
    # whose Module.function/arity equals the anchor. A stale/duplicate/broad anchor
    # that does not map to exactly one live call FAILS.
    for {path, fun_id, line, _reason} <- Ezagent.UriQuery.Scan.HomePathExceptions.all(),
        String.ends_with?(path, ".ex"), String.starts_with?(path, "apps/") do
      assert Ezagent.UriQuery.Scan.home_call_anchor_matches?(path, fun_id, line),
             "exception #{fun_id} @ #{path}:#{line} does not map to exactly one Home call"
    end
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

  test "P1 (codex CRITICAL): bare config-dir resource:// at :config_dir is rejected, NOT self-scoped" do
    # A forged resource://victim/cc-agents/x arriving bare at the :config_dir attr
    # must NOT resolve to a path by deriving scope from itself.
    uri = EzURI.resource("victim", "cc-agents", "worker-1")
    assert {:error, :config_dir_resource_requires_scope} =
             Ezagent.UriQuery.resolve(:config_dir, uri)
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

### Task P1.2 — register the config-dir type at boot

- [ ] The `Ezagent.Resource.FsResolver.Registry` GenServer (P0) already owns the
  `:protected` table and is in the supervision tree; confirm it starts in
  `application.ex` **before** the boot-time registration step.
- [ ] Register the config-dir type at boot (alongside `seed_uri_schemes/0` /
  resolver registration in `application.ex`), e.g.:
  `FsResolver.register_type("cc-agents", %{backend_component: "cc-agents", authority: &config_dir_authority/2})`
  where `config_dir_authority/2` asserts `uri.<ws> == scope.workspace`.
  Generalize per-namespace (`"<ns>-agents"`) — register the namespaces in use
  (`cc`, `codex`, …) from `Ezagent.Kind.Template.config_dir_namespace/0` catalog.

> **Codex note:** `backend_component` MUST equal `"<ns>-agents"` so the resolver
> joins `Home.path("<ns>-agents")/<ws>/<name>` — byte-identical to today.

### Task P1.3 — re-express `Sandbox.ConfigDir.path/2` through the seam

- [ ] Edit `apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex:30-36`. **The
  scope MUST come from an authenticated subject DISTINCT from the URI being
  resolved (codex CRITICAL — otherwise the `uri.<ws> == scope.workspace` check is
  tautological).** `Sandbox.ConfigDir.path/2` already receives the **`agent_uri`**
  as its authenticated subject — the cascade passes the *real* agent it is
  materializing, not an attacker-minted resource URI. So derive `scope.workspace`
  from the **agent's authoritative workspace** independently (e.g.
  `Ezagent.Capability.workspace_of(agent_uri)` or `workspace_segment(agent_uri)`
  of the AGENT URI), THEN build the `resource://` URI from that same authenticated
  workspace, THEN resolve:

```elixir
  def path(%URI{} = agent_uri, namespace) when is_binary(namespace) and namespace != "" do
    auth_ws = workspace_segment(agent_uri)          # authenticated subject = the AGENT uri
    name    = name_segment(agent_uri)
    res_uri = Ezagent.URI.resource(auth_ws, "#{namespace}-agents", name)
    {:ok, path} = Ezagent.Resource.FsResolver.resolve(res_uri, %{workspace: auth_ws})
    path
  end
```

  Here `auth_ws` is derived from the **agent_uri** (the subject), and the
  `resource://` URI is *constructed* from it — so a caller cannot forge a
  cross-`<ws>` resource URI: the URI's `<ws>` is, by construction, the agent's own
  workspace. The authority check is non-tautological because the resource URI is
  *derived from* the authenticated subject, not *supplied alongside* it.
- [ ] **The resolved string is byte-identical** → the P1.1 parity test stays green.

### Task P1.4 — re-point the `:config_dir` resolver's `resource` clause

- [ ] Edit `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/uri_query_resolvers.ex:105-107`.
  **CRITICAL (codex):** the `:config_dir` attribute receives a *bare* arg today, so
  a generic config-dir `resource://` URI arriving here has **no separate
  authenticated subject** — deriving scope from the URL itself would be tautological
  (the exact hole codex flagged). Therefore the `:config_dir` `resource` clause
  does **two distinct things**:
  1. **socialware-config-object** (`<type> == "socialware-config-object"`) — these
     are **self-authorizing**: socialware re-loads the immutable object and compares
     its stored `workspace_uri` (`config_projection.ex:158`), so a bare URI is safe.
     Delegate to `:socialware_config_dir` exactly as today (unchanged).
  2. **config-dir types** (`"<ns>-agents"`) — these are NOT self-authorizing.
     **They MUST arrive with an external scope as a `{uri, scope}` tuple payload**
     (SPEC §5.1 "Threading `scope` through the `:config_dir` UriQuery attribute").
     A bare `%URI{}` for a config-dir type at this attribute is **rejected**
     (`{:error, :config_dir_resource_requires_scope}`) — there is no scope-from-URI
     fallback. The only legitimate config-dir caller is `Sandbox.ConfigDir.path/2`
     (P1.3), which builds the URI from the authenticated agent and resolves the
     resolver **directly** (not via this attribute) — so in practice config-dir
     `resource://` URIs do not flow through `:config_dir` as bare URIs at all.

```elixir
  # bare URI: only socialware-config-object is self-authorizing (re-loads + compares
  # workspace_uri). Any other resource <type> at this attr lacks an authenticated
  # scope → reject (codex CRITICAL: no scope-from-URI fallback).
  def resolve_config_dir(%URI{scheme: "resource"} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, "socialware-config-object"} ->
        Ezagent.UriQuery.resolve(:socialware_config_dir, uri)  # self-authorizing, unchanged
      {:ok, _config_dir_type} ->
        {:error, :config_dir_resource_requires_scope}          # no tautological self-scope
      :error ->
        :none
    end
  end

  # scoped payload: config-dir types resolved with an EXTERNAL authenticated scope.
  def resolve_config_dir({%URI{scheme: "resource"} = uri, %{workspace: _} = scope}) do
    case Ezagent.Resource.FsResolver.resolve(uri, scope) do
      :none -> Ezagent.UriQuery.resolve(:socialware_config_dir, uri)
      other -> other   # {:ok, path} | {:error, reason} — fail loud, never swallowed
    end
  end
```

> **Why this closes the hole:** the resolver's `authority/2` is only meaningful
> when `scope.workspace` is independently authenticated. P1.3's `Sandbox.ConfigDir`
> derives it from the **agent_uri** (the subject) and resolves the resolver
> directly; the `:config_dir` attribute never accepts a bare config-dir resource
> URI and self-derives a scope. Add a **negative regression test**: resolving
> `UriQuery.resolve(:config_dir, EzURI.resource("victim", "cc-agents", "x"))`
> (bare, from an `acme` context) returns `{:error, :config_dir_resource_requires_scope}`
> — proving no cross-tenant path is produced.

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

  test "non-positive TTL is rejected at mint (no accidental infinite token)" do
    assert_raise ArgumentError, fn -> UploadToken.mint!(@uri, ttl_seconds: 0) end
    assert_raise ArgumentError, fn -> UploadToken.mint!(@uri, ttl_seconds: -1) end
  end

  test "expired token is rejected (explicit test override + verify)" do
    token = UploadToken.mint!(@uri, ttl_seconds: -1, __test_allow_nonpositive__: true)
    assert {:error, :expired} = UploadToken.verify(token)
  end

  test "default-TTL token is NOT valid forever (codex HIGH)" do
    # A token minted with the DEFAULT ttl must be rejected after elapsed time.
    token = UploadToken.mint!(@uri)
    # simulate elapsed time past @default_ttl (clock seam or Phoenix max_age: 0):
    assert {:error, :expired} = UploadToken.verify_at(token, now() + 10_000)
    # ^ verify_at/2 is a test seam (verify/1 delegates to verify_at(token, now()))
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

  # PINNED TTL DESIGN (codex HIGH — no infinite max_age): the TTL is stored IN the
  # payload and enforced at verify against the token's embedded issue time. verify
  # NEVER uses max_age: :infinity. mint! rejects non-positive TTL except via an
  # explicit test-only override, so a normal token always expires after @default_ttl.
  @spec mint!(URI.t(), keyword()) :: String.t()
  def mint!(%URI{scheme: "resource"} = uri, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)
    unless ttl > 0 or Keyword.get(opts, :__test_allow_nonpositive__, false) do
      raise ArgumentError, "upload token TTL must be positive; got #{inspect(ttl)}"
    end
    # Caller is responsible for authz BEFORE mint (OI-1.3). Payload binds URI + TTL.
    Phoenix.Token.sign(EzagentWeb.Endpoint, @salt, %{uri: EzURI.stable_key(uri), ttl: ttl})
  end

  @spec verify(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def verify(token) when is_binary(token) do
    # Phoenix.Token embeds the signing timestamp; verify with a generous outer
    # bound, then enforce the PAYLOAD ttl against elapsed age (finite, per-token).
    case Phoenix.Token.verify(EzagentWeb.Endpoint, @salt, token, max_age: max_outer_age()) do
      {:ok, %{uri: key, ttl: ttl}} ->
        # Phoenix.Token returns {:ok, payload} only within max_outer_age; we re-check
        # the per-token ttl. (Implementation note: sign with max_age: ttl directly is
        # the simpler equivalent — `verify(..., max_age: ttl_from_payload)` is not
        # possible since ttl is inside the token; so EITHER (a) sign with max_age:ttl
        # and verify with max_age: :token_default reading the embedded stamp, OR
        # (b) embed issued_at in the payload and compare here. Pin ONE in P2a.2.)
        if token_fresh?(token, ttl), do: {:ok, EzURI.new!(key)}, else: {:error, :expired}
      {:error, :expired} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end

  defp max_outer_age, do: 86_400  # 24h hard ceiling — no token outlives this regardless
end
```

> **Codex note (TTL, HIGH — pin ONE mechanism in P2a.2):** the SIMPLEST correct
> form is `Phoenix.Token.sign(endpoint, salt, %{uri: key}, max_age: ttl)` +
> `Phoenix.Token.verify(endpoint, salt, token, max_age: ttl_at_verify)` where the
> verify-side `max_age` must be **finite and ≤ the mint TTL** — NEVER `:infinity`.
> Because the verify side cannot read the payload TTL before verifying, use a
> **fixed `@default_ttl` on both sides** (mint and verify use the same constant)
> so a normal token always expires after `@default_ttl`. The `ttl_seconds: -1`
> expiry test uses the `__test_allow_nonpositive__` override OR signs a token with
> a back-dated stamp. **Add a default-token-expiry test** that proves a token
> minted with the default TTL is rejected after elapsed time (use
> `Phoenix.Token.verify(..., max_age: 0)` to simulate, or a clock seam). The
> invariant the test enforces: **a default token is NOT valid forever.**

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
