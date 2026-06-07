# Resource-unification — SPEC

Date: 2026-06-07
Status: SPEC (authored from the codex-reviewed discussion on
`discuss/resource-unification`, rounds 1 + 2). Design is LOCKED; this document
specifies the implementation.
Branch: `spec/resource-unification`
Predecessor: `docs/superpowers/specs/2026-06-07-resource-unification-discussion.md`
Related invariants: #11 (URI shape / 6-scheme allowlist / 3-segment authority),
#14 (per-tenant `workspace_uri NOT NULL`), the `unify-uri-query` CI gate
(`mix ezagent.uri_query.scan`).

---

## 1. Problem

`Ezagent.Home.path/1` is the de-facto path API the whole codebase calls for
on-disk artifacts. It returns a bare `<profile_dir>/<component>` string with no
tenancy structure and no resolution seam. Meanwhile the project already has a
working addressing seam — `Ezagent.UriQuery` (an ETS registry of
`attr → resolver/1`) — but only **one** artifact family actually routes its
filesystem access through it: socialware config objects, via
`apps/ezagent_domain_socialware/lib/ezagent/socialware/config_projection.ex`.

Two structural problems follow:

1. **No structural tenancy on tenant-scoped artifacts.** Uploads and per-agent
   config dirs *are* tenant-scoped and *do* have a natural workspace, but their
   bytes are addressed by raw `Home.path("uploads")` / `Home.path("<ns>-agents")`
   strings. Tenancy is enforced (when at all) by ad-hoc, per-call-site logic —
   e.g. uploads downloads authorize by session-participation, not by the URI's
   workspace segment (`apps/ezagent_web/.../uploads_controller.ex:134`).
2. **No bypass control.** Any developer can call `Ezagent.Home.path/1` for any
   purpose; there is no gate distinguishing a sanctioned boot/operator call from
   a new tenant-artifact call that should have gone through the resolver. Drift
   back toward raw paths is unchecked.

The proven socialware pattern shows the right shape: address by
`resource://<ws>/<type>/<name>`, resolve to a path at the `UriQuery` seam,
re-assert tenancy by comparing the URI's structural `<ws>` segment against the
loaded artifact's own `workspace_uri`
(`config_projection.ex` `assert_workspace_authority!/2`). The work is to
**generalize that one proven instance** to the other tenant-scoped families, and
to **lock the raw `Home.path` surface** so the migration cannot regress.

### What is NOT the problem (explicit scope ceiling)

This is **not** "every byte through `resource://`". Boot-critical and OS-handle
artifacts (the SQLite db, the runtime cookie, pty pid-files, the codex
app-server socket) are **not** tenant-scoped and several are needed **before any
URI machinery exists**. Forcing them through `resource://` requires a sentinel
`<ws>`, which re-opens the invariant-#11 authz hole. They stay on raw `Home`.
See §4 (Decisions D2, D3) and the non-goals.

---

## 2. Goals & Non-goals

### Goals

- **G1.** Unify on-disk artifact *addressing for tenant-scoped, content-shaped
  artifacts* behind the `Ezagent.UriQuery` seam, using the existing
  `resource://<ws>/<type>/<name>` scheme. `Ezagent.Home` becomes the **default
  backend** behind a generic resolver for those `<type>`s — not the front door.
- **G2.** Ship a **hardened, registration-only** generic `resource://`
  filesystem resolver: a closed per-`<type>` allowlist, explicit `.`/`..`/unsafe
  segment rejection, and a per-`<type>` authority check. No implicit Home
  catch-all.
- **G3.** Migrate the two remaining tenant-scoped families behind the resolver,
  in risk-ascending order: **per-agent config-dir first**, then **uploads**
  (with its download-contract + authorization fix shipped first).
- **G4.** Lock down new raw `Home.path`/`profile_dir`/`home` calls **in runtime
  application code** via a new `home_path_in_runtime_code` category on the
  existing `mix ezagent.uri_query.scan` gate — hard-failing *new* calls
  immediately against a line-anchored baseline of today's callers, with
  exact-anchor exceptions for the sanctioned boot/operator/OS-handle surface.
  Burn the baseline down as families migrate.

### Non-goals

- **N1. Do NOT add a 7th scheme (`home://`).** It is shape-isomorphic to the
  existing `system://`, costs scheme-matching clauses at ~6 sites plus an
  invariant-#11/SPEC amendment, and the candidate artifacts have **no URI
  consumer today**. (Decision D3.)
- **N2. Do NOT route db / runtime cookie / pty-pids / codex socket through
  `resource://`** (or any tenant scheme). They stay on raw `Home`, which is a
  *sanctioned* surface (the scan gate exempts them by exact anchor). (D2.)
- **N3. Do NOT make `Home.path/1` private / fully internal.** Early-boot
  (`config/runtime.exs`) and operator mix-tasks call it *before
  `Application.start/2`*, when the `UriQuery`/`SchemeRegistry` ETS tables do not
  yet exist. A literal "no raw path API survives" breaks boot. (D1.)
- **N4. Do NOT touch the credential cascade hot path** —
  `Ezagent.Credential.CascadeRuntime` /
  `Ezagent.Agent.Materializer` (`atomic_replace` / rollback /
  `recover_orphaned` / `copy_secret_relpaths`). They consume *resolved path
  strings* and already sit **above** `UriQuery.resolve(:config_dir, …)`
  (`cascade_runtime.ex:74,107`). Resolve-then-pass; never push URIs into them.
  (D4.)
- **N5. Do NOT migrate global credentials** to `resource://`. They are not
  naturally tenant-scoped; routing them through a per-tenant scheme invents a
  fake `<ws>` (the exact authz hole #11 prevents). Deferred. (D5.)
- **N6. No back-compat shims for the addressing itself** beyond the one
  explicitly required download back-compat window in P2 (see §6 P2). Per
  `feedback_let_it_crash_no_workarounds`, the migration deletes legacy
  byte-paths rather than running both.

---

## 3. Current state (source-verified anchors)

| Family | Today's byte path | Routes via `UriQuery.resolve`? | Tenant-scoped? |
|---|---|---|---|
| socialware-config-object | `config_projection.ex` projects to a transient dir | **YES** (`:socialware_config_dir`, delegated from `:config_dir`) | yes |
| per-agent config_dir | `Sandbox.ConfigDir.path/2` → `Home.path("<ns>-agents")/<ws>/<name>` (`config_dir.ex:30-36`) | NO (computed as a raw path; the cascade calls `UriQuery.resolve(:config_dir, …)` but for `entity`/`template` URIs the resolver returns the *stored* string, it does not go through a `resource://` FS resolver) | yes |
| uploads (write) | `admin_live.ex:701,731` `Path.join(Home.path("uploads"), stored_name)`; handle minted at `:733` `Ezagent.URI.resource(workspace_name, :uploads, stored_name)` | NO (handle is cosmetic; bytes are raw `Home.path`, **no `<ws>` in byte path**) | yes |
| uploads (read) | `uploads_controller.ex:108` `Path.join(Home.path("uploads"), safe)`; authz by `caller_in_attaching_messages?/2` (`:134`), route `GET /files/:filename` (`router.ex:74`) | NO | yes (but authz is by session, not by `<ws>`) |
| db (SQLite) | `config/runtime.exs:14,17` `Home.path(:db)` | NO — **config-eval, pre-`Application.start`** | no |
| runtime cookie | `runtime.ex:28-29` `Home.profile_dir()/runtime/cookie` | NO — early boot | no |
| codex app-server socket | `codex_agent.ex:880-892` `default_app_server_socket_path/1` → `Home.path("codex")/<sha256 slug>/app-server.sock` | NO — OS handle, SUN_LEN ≈104B short-path constraint | per-agent shape, but **not** content-addressable |
| pty-pids | `Home.path(...)` | NO — OS handle | per-deployment shape |
| logs / plugins / snapshots / inbox | `Home.path(...)` | NO | no / engine-internal |

**Key facts the design rests on (each verified):**

- `Ezagent.UriQuery` (`uri_query.ex`): `register/2` is one-owner-per-attr
  (`:ets.insert_new`, fail-loud on duplicate); `resolve/2` fail-loud on
  `{:error, {:no_resolver, attr}}`; `:none` ≠ `{:error, _}`; resolver return is
  normalized (`{:ok,_} | :none | {:error,_}`, else `{:invalid_resolver_return,_}`).
- `Ezagent.URI.resource/3` → `per_tenant("resource", ws, type, name)`
  (`uri.ex:425,456`). `per_tenant/4` calls `segment!/1` (`uri.ex:460-477`),
  which **rejects empty + slash-bearing segments** and the empty-`<ws>` host
  (`validate_3seg_shape!/2` `uri.ex:490-495`) — **but does NOT reject `.`/`..`
  and does NOT constrain `<type>` to a catalog.** This is the codex-HIGH gap P0
  closes.
- The `:config_dir` resolver has a single owner,
  `EzagentDomainInstanceMessage.UriQueryResolvers` (`uri_query_resolvers.ex:28`).
  Its `resource` clause (`:105-107`) **delegates to**
  `Ezagent.UriQuery.resolve(:socialware_config_dir, resource_uri)`. This is the
  existing extension seam P1/P2 reuse.
- `seed_uri_schemes/0` (`application.ex:183-191`) seeds exactly the six SPEC
  §5.6 schemes (`entity workspace session template resource system`) into
  `SchemeRegistry` **inside `Application.start/2`**. `home://` would be a 7th
  seed — rejected (N1).
- `config/runtime.exs:14` runs `File.mkdir_p!(Ezagent.Home.path(:db))` at
  config-eval, before the supervision tree (hence before the `UriQuery`/
  `SchemeRegistry` ETS tables exist). This is the boot-order hard constraint
  (D1).

---

## 4. Decisions (with rationale)

### D1 — Scope "everything through UriQuery" to RUNTIME APP CODE only.

**Decision.** The binding invariant is: *every runtime-application-code
filesystem access for a tenant-scoped artifact goes through `UriQuery`;
boot/config-eval and operator mix-tasks keep a sanctioned raw `Home` surface.*
Allen's round-2 phrasing "route EVERYTHING through UriQuery first" is recorded
but **rejected as literally stated**.

**Rationale.** `config/runtime.exs:14` resolves the db path at config-eval —
*before* `Application.start/2`, so before `EzagentCore.EtsOwner` creates the
`:ezagent_uri_query_registry` / `:ezagent_scheme_registry` tables and before any
domain resolver registers. `UriQuery.resolve(:db, …)` there would hit
`{:no_resolver, :db}` and fail loud at the worst possible moment (release boot,
before supervision). The same holds for every operator mix-task that runs with
no application started (`ezagent.home.*`, `ezagent.bootstrap`,
`home/migration.ex`). Therefore the resolver seam **cannot** be the universal FS
front door; the universe it governs is runtime app code.

### D2 — db / cookie / pty-pids / codex socket stay on raw `Home` (sanctioned).

**Decision.** Keep all four on `Ezagent.Home`. Do not route them through any
URI scheme. Mark each as an exact-anchor exception in the scan gate (§5), with a
stated reason. **STOP** the migration before them.

**Rationale.** db + cookie are non-tenant node singletons needed before any
workspace exists (no `<ws>` to name them). The codex socket and pty-pids *do*
have a per-agent/per-deployment shape, but their binding constraint is
**deterministic identity + short OS path (codex SUN_LEN ≈104B requires the
sha256 short slug at `codex_agent.ex:892,901`) + deployment isolation +
cleanup** — NOT content-addressability. A generic Home-backed FS resolver
preserves none of those. None of the four is ever *fetched by URI*, so a URI
handle buys nothing.

### D3 — Drop `home://`; do NOT add a 7th scheme.

**Decision.** No `home://`. If a node-singleton ever genuinely needs a URI
handle, reuse the existing `system://` scheme on demand.

**Rationale.** `home://<type>[/<name>]` is *shape-isomorphic* to `system://`
(which already supports both 1- and 2-segment shapes via `system_principal/1`).
A 7th scheme is a permanent tax: every scheme-matching site (`workspace_of`,
snapshot classification `kind/snapshot.ex`, persistence `persistence.ex:78`,
capability `:any` list `capability.ex:960`, `path_for_routing`) grows a `home`
clause forever, and a new scheme falls through the no-op catch-all
`validate_3seg_shape!(_uri, _raw), do: :ok` (`uri.ex:529`) — i.e. **no
structural validation by default**, a path-traversal / category-confusion
target. Invariant #11 caps the universe at six schemes; a 7th is a SPEC
amendment with no consumer to justify it. (If `home://` is ever revived it
requires, as hard prerequisites before any scheme seed: a closed type catalog,
bespoke `.`/`..`/slash rejection, single-resolver ownership, and a `home` clause
audited into every scheme-matching site.)

### D4 — Do NOT touch the credential cascade / Materializer hot path.

**Decision.** The cascade and Materializer consume resolved path *strings* and
already sit above `UriQuery.resolve(:config_dir, …)` (`cascade_runtime.ex:74,107`).
The migration changes *how a path is produced* (Home call vs. generic resolver),
which requires **zero** change to this code. Never push URIs into the
Materializer; resolve-then-pass.

**Rationale.** The Materializer's `atomic_replace`/rollback/`recover_orphaned`
invariant is the single highest-risk surface. It is URI-addressing-agnostic by
construction. Dragging it "URI-native" is high-risk, low-reward churn.

### D5 — Defer global credentials.

**Decision.** Global creds are not naturally tenant-scoped; routing them through
`resource://<ws>/...` invents a fake `<ws>` or special-cases the empty-`<ws>`
guard — exactly the authz hole #11 exists to prevent. Marginal benefit; defer
unless a concrete need appears.

### D6 — Answer to Allen's explicit question: can `Home.path(:db)` use a `system://` URI?

**Decision: NO — not via runtime `UriQuery` resolution.**

The db path is needed at `config/runtime.exs:14` (config-eval), *before* any
registry/ETS exists (D1). A `system://` URI is only useful if something
*resolves* it, and resolution lives in `UriQuery` (runtime ETS) — which is
absent at that point. Boot-order forbids it.

The db (and the runtime cookie) therefore stay on **raw `Home` (sanctioned
exempt)**. A `system://db/main` handle *could* in principle exist only as a
**cosmetic** string resolved by a **pure function with no ETS** (the way
`system_principal/1` is pure) — but there is **no consumer** that needs a db URI
handle today, so we do not introduce one. This is a recorded decision with the
boot-order rationale, not a deferral pending design.

---

## 5. The hardened resolver contract & the scan-gate category

### 5.1 Generic `resource://` filesystem resolver (P0)

A new module — proposed `Ezagent.Resource.FsResolver` in `ezagent_core`
(generalizing the socialware pattern; socialware keeps its own *projecting*
resolver for `socialware-config-object`, which materializes content rather than
naming a stored dir).

**Registration-only with a CLOSED per-`<type>` allowlist.** Each `<type>` is
explicitly registered with:

```elixir
@type scope :: %{
        # the authenticated workspace the caller is acting within (URI or name).
        # For config-dir, the agent's authoritative workspace; for uploads, the
        # caller's request-scoped workspace from the controller/LiveView mount.
        required(:workspace) => URI.t() | String.t(),
        # optional principal for richer per-type checks (socialware re-loads the
        # object and compares its workspace_uri; it may ignore this field).
        optional(:principal) => URI.t() | nil
      }

@type type_spec :: %{
        # the Home component the bytes live under, e.g. "uploads" or "cc-agents"
        backend_component: String.t(),
        # per-type authority check: receives BOTH the URI AND the caller's
        # authenticated scope, and asserts the URI's structural <ws> segment is
        # authoritative for THIS caller. A pure `(URI.t() -> ...)` is insufficient
        # (codex HIGH): a resolver with no caller context cannot tell who is
        # asking, so anyone able to mint resource://victim/uploads/name would get
        # a path. The scope is the authorization context.
        authority: (URI.t(), scope() -> :ok | {:error, term()})
      }
```

**The resolver is authorization-bearing, not authorization-optional.**
`resolve/2` takes the caller's authenticated `scope` as a required argument and
runs the per-`<type>` `authority/2` against it BEFORE any backend resolve. There
is no `resolve/1` that skips authz. Call sites obtain `scope.workspace` from
their authenticated context (the agent's workspace for config-dir; the
controller/LiveView-mount workspace for uploads) — never from the URI being
resolved (that would be circular). This is what makes "move upload authz to the
resolver" sound: the URI's `<ws>` segment must EQUAL `scope.workspace`, so a
forged `resource://victim/uploads/name` resolved under scope `attacker` fails
authority.

**Resolution algorithm** for `resolve(uri, scope)` where
`uri = resource://<ws>/<type>/<name>`:

1. **Reject malformed:** `uri.scheme == "resource"` and the URI parses to a
   3-segment `<ws>/<type>/<name>` via `Ezagent.URI.workspace_name/1`,
   `Ezagent.URI.type/1`, `Ezagent.URI.name/1`. Any `:error` → `:none` (not ours)
   for an unrecognized shape; a structurally-`resource` URI missing a segment →
   `{:error, {:malformed_resource_uri, …}}`.
2. **Allowlist check:** if `<type>` is **not** a registered `type_spec` →
   `:none` ("not a type this resolver owns"; the single `:config_dir` owner then
   falls through to socialware's resolver, exactly as today). **No implicit Home
   catch-all** — an unregistered `<type>` NEVER resolves to a Home path.
3. **Unsafe-segment rejection (BEFORE any `Path.join`):** reject `<ws>`,
   `<type>`, `<name>` if any equals `"."` or `".."`, contains a path separator,
   contains a NUL, or (defense-in-depth) is not the exact segment string
   `segment!/1` would have produced. `Path.join` is never reached with an
   unsafe segment. (Closes the codex-HIGH gap: `segment!/1` does not reject
   `.`/`..`.)
4. **Authority check:** run the `type_spec.authority` function for `<type>` as
   `authority.(uri, scope)`. It compares the URI's structural `<ws>` segment
   against `scope.workspace` (and, for socialware, re-loads the object and
   compares its `workspace_uri`). On `{:error, reason}` → `{:error, reason}`
   (fail loud; a cross-tenant mismatch is fatal, never a silent `:none`).
5. **Backend resolve:** `{:ok, Path.join([Ezagent.Home.path(backend_component),
   <ws>, <name>])}`. (Home is the *backend*, reached only after 1–4.)

**Wiring:** the single `:config_dir` owner
(`EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir/1`) already
delegates the `resource` clause to `:socialware_config_dir` (`:105-107`). P0
introduces the generic resolver but does NOT yet rewire `:config_dir`; P1
re-points the `resource` clause to try the generic resolver's registered types
first (config-dir types), falling through to socialware for
`socialware-config-object`. Ordering is explicit and total — every `resource`
config-dir URI matches exactly one registered owner or fails loud.

**Threading `scope` through the `:config_dir` UriQuery attribute.** The
`UriQuery` resolver shape is 1-arg (`resolver/1`), and the cascade calls
`UriQuery.resolve(:config_dir, uri)` today. To carry the caller's authenticated
scope without breaking that shape, the `:config_dir` `resource` clause passes
`{uri, scope}` as the resolver arg when delegating to the generic FS resolver,
and `scope.workspace` for config-dir is the **agent's authoritative workspace**
(derived from the agent/template URI the cascade is materializing, which IS the
authenticated subject of the cascade — not attacker-supplied). The socialware
delegation is unchanged: socialware re-loads the immutable object and compares
its stored `workspace_uri`, so it is self-authorizing and ignores `scope`.
Uploads (P2) call the generic resolver directly with the request-mount scope, so
they do not depend on the `:config_dir` attribute at all. (Exact arg-tuple shape
pinned in P1; the invariant is: the generic resolver always receives a scope and
always runs `authority/2`.)

**Properties (acceptance invariants for the resolver):**

- **R-1.** No `resource://` URI with an unregistered `<type>` ever resolves to a
  filesystem path (returns `:none`).
- **R-2.** No `<ws>`/`<type>`/`<name>` segment equal to `.`/`..` or containing a
  separator/NUL ever reaches `Path.join` (returns `{:error,_}` before resolve).
- **R-3.** Every registered `<type>` has a non-trivial `authority/2`; resolution
  always runs it with the caller's `scope`; a workspace-segment mismatch
  (`uri.<ws> != scope.workspace`) fails loud (no silent `:none` swallowed as
  "not mine"). There is no `resolve/1` that bypasses authority.
- **R-4.** `Home.path` is called only on the success path *after* R-1..R-3 pass,
  and only with the registered `backend_component`.

### 5.2 Scan-gate category `home_path_in_runtime_code` (P0.5)

Extend `Ezagent.UriQuery.Scan` (`scan.ex`) with a new category added to
`@known_categories` (`scan.ex:28-37`) and surfaced through the existing
`mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code`
mechanism (`ezagent.uri_query.scan.ex:64-79` already parses
`--fail-category`).

**What it flags.** Any call to `Ezagent.Home.path/1`,
`Ezagent.Home.profile_dir/0`, or `Ezagent.Home.home/0` in a production `.ex`
file under `apps/` (the scanner's existing `@default_globs`) that is **not** on
the exact-anchor exception list AND **not** on the line-anchored baseline.

**Hard-fail-NEW from the moment it lands.** P0.5 wires
`--fail-category home_path_in_runtime_code` into CI immediately. It does NOT
warn-then-flip. A new or moved runtime `Home.path` call that is neither
exempt-by-anchor nor on the baseline fails CI on the PR that introduces it.

**Exact module/function/line anchor exceptions — NO globs, NO directory
allowlist.** A directory-shaped or glob exception (e.g. "all of
`lib/mix/tasks/`" or `ezagent.home.*`) could let an OS-handle file or a newly
added task become a broad raw-path escape hatch — a NEW `Home.path` call added
under a globbed task file would evade the hard-fail-new gate (codex MEDIUM).
Therefore every exception is a concrete `Module.function/arity` + line anchor,
each carrying a stated reason. The full enumerated set (no `*`, no prefix
match) — pinned here, not "to be pinned later":

| Anchor (exact `Module.function/arity` @ line) | Reason |
|---|---|
| `config/runtime.exs` (lines 14, 17) | db path at config-eval — `UriQuery` ETS absent (D1) |
| `config/dev.exs` (line 22) | deliberately inlines env logic at config-eval |
| `Ezagent.Runtime.cookie_path/0` (`runtime.ex:28-29`) + node-name fn | early boot, pre-supervision |
| `EzagentRuntime.PidFile.dir/1` (`runtime/pid_file.ex:95-98`, `Home.profile_dir/0`) | OS pid-file (the "pty-pids" handle) — node/agent pid files, registry-independent (D2) |
| `Mix.Tasks.Ezagent.Home.Init.run/1` + its `Home.path`/`profile_dir` helpers (`ezagent.home.init.ex:30,32,33,36,49,79,145,159`) | operator mix-task, app-not-started |
| `Mix.Tasks.Ezagent.Home.Backup.run/1` (`ezagent.home.backup.ex:62`) | operator mix-task |
| `Mix.Tasks.Ezagent.Home.Restore.run/1` (`ezagent.home.restore.ex`, `Home.*` call sites) | operator mix-task |
| `Mix.Tasks.Ezagent.Home.AdoptDb.run/1` (`ezagent.home.adopt_db.ex:61`) | operator mix-task |
| `Mix.Tasks.Ezagent.Bootstrap.run/1` (`ezagent.bootstrap.ex:89,90,91,92`) | operator mix-task |
| `Ezagent.Home.Migration` `Home.*` call sites (`home/migration.ex`) | operator migration tooling |
| `EzagentPluginCodex` `Ezagent.Template.CodexAgent.default_app_server_socket_path/1` (`codex_agent.ex:880-892`) | OS-handle socket, SUN_LEN short-path, not URI-addressable (D2) |

> **P0.5 implementation note:** the exact line numbers above are a snapshot
> against `origin/main` at spec time; P0.5 pins each as a `Module.function/arity`
> anchor (line as secondary), and the scanner test (S-2) asserts every exception
> entry is a concrete module+function — **rejecting any entry that contains a
> glob (`*`) or a bare path prefix**. Adding a new exception requires a new
> concrete anchor + stated reason, reviewed in its PR.

> The config files (`config/runtime.exs`, `config/dev.exs`) are outside
> `apps/**/*.ex`, so the scanner does not see them today. P0.5's category is
> defined over the `apps/` globs; the config-file callers are listed here for
> completeness of the sanctioned surface and need no scanner exception. If the
> scanner globs are ever widened to include `config/`, these become exact
> anchors with the stated reason.

> The config files (`config/runtime.exs`, `config/dev.exs`) are outside
> `apps/**/*.ex`, so the scanner does not see them today. P0.5's category is
> defined over the `apps/` globs; the config-file callers are listed here for
> completeness of the sanctioned surface and need no scanner exception. If the
> scanner globs are ever widened to include `config/`, these become exact
> anchors with the stated reason.

**Line-anchored baseline (burn-down list).** The category ships with an explicit
baseline file enumerating every *current* runtime-app-code `Home.path` call site
(file + line + the exact call), e.g. `Sandbox.ConfigDir.path/2`
(`config_dir.ex:31`), `admin_live.ex:701,731`, `uploads_controller.ex:108`,
plus the remaining population-3 callers (cc/codex templates, feishu client,
python server, agent_bridge token_store, identity application). The baseline is
a burn-down list, NOT a blanket pass: a baselined call is tolerated only at its
recorded anchor; moving or duplicating it fails. P3 removes each entry as its
family migrates. When the baseline is empty the lockdown is complete.

**Acceptance invariants for the gate:**

- **S-1.** A *new* runtime `Home.path` call (not exempt, not baselined) fails
  `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code`.
- **S-2.** Every exception is an exact `Module.function/arity` + line anchor
  with a stated reason; a scanner test **rejects any exception entry containing a
  glob (`*`) or a bare path/directory prefix**, mechanically enforcing the
  exact-anchor guarantee.
- **S-3.** The baseline only ever shrinks (P3); the exception surface is never
  widened.

---

## 6. Phases (PRs with acceptance gates)

Risk-ascending, dependency-correct. Each phase is one PR (or a small PR set);
each carries `/codex:adversarial-review` per `feedback_codex_review_every_pr`.

### P0 — Hardened generic `resource://` FS resolver (registration-only)

- **Build** `Ezagent.Resource.FsResolver` per §5.1 (registration-only, closed
  per-`<type>` allowlist, `.`/`..`/separator/NUL rejection before `Path.join`,
  per-type `authority/2`). Register **zero** types initially (or only a test
  type) — this PR introduces the mechanism, not a migration.
- **Do NOT** rewire `:config_dir` yet; socialware delegation is untouched.
- **Tests (TDD):** unit tests for R-1..R-4 — unregistered type → `:none`;
  `.`/`..`/`a/b`/NUL segments → `{:error,_}` before any FS touch; authority
  mismatch → fail loud; success path joins `Home.path(component)/<ws>/<name>`.
  A property/table test enumerating malicious `<type>`/`<name>` strings.
- **Acceptance gate:** R-1..R-4 invariant tests pass; no production call site
  uses the resolver yet (it is dormant); `mix ezagent.check_invariants` +
  existing `uri_query.scan` unchanged.

### P0.5 — Scan-gate scaffold: `home_path_in_runtime_code` (hard-fail-new + baseline)

- **Extend** `Ezagent.UriQuery.Scan` with the `home_path_in_runtime_code`
  category (§5.2): AST/text match on `Ezagent.Home.path|profile_dir|home`,
  minus the exact-anchor exceptions, minus the line-anchored baseline.
- **Wire** `--fail-category home_path_in_runtime_code` into CI immediately
  (hard-fail-new).
- **Author** the baseline (the current population-3 census) and the exact-anchor
  exception list with stated reasons; pin the exact pty-pid OS-handle anchor.
- **Tests:** S-1 (a synthetic new call in a fixture fails the category); S-2
  (exceptions are exact anchors, asserted structurally); S-3 (baseline-only-
  shrinks guard — a test that the baseline file matches the live scan, so adding
  a call without baselining fails, and removing a migrated call requires baseline
  edit).
- **Acceptance gate:** the new category is GREEN on the current tree (baseline
  covers all existing callers); a deliberately-added unbaselined call turns it
  RED in CI.

### P1 — Migrate per-agent config-dir to resolve via `resource://<ws>/<config-type>/<name>`

*(config-dir BEFORE uploads: it is the exact socialware seam shape already on
the cascade — the cascade calls `UriQuery.resolve(:config_dir, …)` today — and
is lower-risk; the cascade is already URI-addressed, D4.)*

- **Register** a config-dir `<type>` (e.g. the existing `"<ns>-agents"`
  component, generalized) on the P0 resolver, with an `authority/2` that asserts
  the URI's `<ws>` segment against the agent's workspace.
- **Re-express** `Sandbox.ConfigDir.path/2` (`config_dir.ex:30-36`) to build a
  `resource://<ws>/<ns>-agents/<name>` URI and resolve it through the seam, with
  `Home.path("<ns>-agents")` as the registered backend. The resolved string is
  byte-identical to today's layout (`config_dir.ex` docstring guarantees
  byte-identical for `"cc"`).
- **Re-point** the `:config_dir` resolver's `resource` clause
  (`uri_query_resolvers.ex:105-107`) to try the generic resolver's registered
  config-dir types first, falling through to `:socialware_config_dir`. Ordering
  total + fail-loud.
- **D4 untouched:** the Materializer/cascade keep consuming the resolved string;
  no URI is pushed into them.
- **Remove** the migrated `Home.path("<ns>-agents")` call from the P0.5 baseline.
- **Tests:** a **byte-identical parity test** — `Sandbox.ConfigDir.path/2`
  output == the pre-P1 path for the same agent URI + namespace; the existing
  config_dir resolver tests; an authority test (foreign `<ws>` → fail loud); the
  cascade respawn path resolves the same dir.
- **Acceptance gate:** parity test green; cascade/Materializer tests unchanged
  and green; P0.5 baseline shrinks by the config-dir entry; the config-dir
  `Home.path` call is gone from runtime app code.

### P2 — Migrate uploads to STORE via the resolver — DOWNLOAD CONTRACT FIRST

> **Sequence the contract change BEFORE the byte move.** Today bytes land at
> `Home.path("uploads")/<stored_name>` (filename-only, **no `<ws>`**;
> `admin_live.ex:731`) and `UploadsController.show/2` authorizes by
> session-participation (`uploads_controller.ex:134`), NOT by the URI's `<ws>`.
> Moving bytes to `Home.path("uploads")/<ws>/<name>` while the route stays
> `GET /files/:filename` (`router.ex:74`) makes the URL unable to resolve the
> path and makes same-filename-across-workspaces ambiguous.

**P2a — Download contract + workspace-segment authorization (no byte move yet):**

- **Change the download contract** so the request carries/recovers the full
  **workspace-first** `resource://<ws>/uploads/<name>` URI — constructed via
  `Ezagent.URI.resource(ws, :uploads, name)` (workspace-first; see §5.1 and the
  doc-drift fix below), NOT a `resource://uploads/<ws>/<name>` type-first form
  (which the resolver would mis-parse as workspace=`uploads`, type=`<ws>`,
  causing an allowlist miss + wrong authority check — codex HIGH). Mechanism:
  e.g. route `GET /files/:ws/:name` or a signed token encoding the full URI;
  exact form decided in the PR (OI-1), but it MUST carry the `<ws>` segment in
  workspace-first order.
- **Move authorization** to operate on that exact URI's `<ws>` segment via the
  resolver's `authority/2` for the `uploads` type — called as
  `authority.(uri, %{workspace: request_scope_workspace})` where the request
  scope comes from the authenticated controller/LiveView mount, NOT from the URI
  — replacing / augmenting `caller_in_attaching_messages?/2`. The check is
  `uri.<ws> == scope.workspace`.
- **Back-compat window:** keep `GET /files/:filename` resolving for already-
  minted filename-only links during a stated deprecation window (the ONE
  sanctioned shim, N6), with a regression test for the **same filename in two
  workspaces** proving the new contract disambiguates and the old contract is
  unambiguous only because today's filenames are UUID-prefixed.
- **Fix the stale doc drift** flagged in round 2: `capability.ex:556` /
  `admin_live.ex` comments say `resource://<type>/<workspace>/<name>` while the
  constructor `URI.resource(ws, type, name)` is **workspace-first**. One-line doc
  fix in this PR.

**P2b — Move the bytes through the resolver:**

- **Register** the `uploads` `<type>` on the P0 resolver (backend component
  `"uploads"`, `authority/2` = workspace-segment check).
- **Write** uploads via the resolver
  (`resolve(resource://<ws>/uploads/<name>)` → `Home.path("uploads")/<ws>/<name>`),
  replacing `admin_live.ex:701,731`.
- **Read** uploads via the resolver in the controller, replacing
  `uploads_controller.ex:108`.
- **Remove** the uploads `Home.path("uploads")` calls from the P0.5 baseline.
- **Tests:** same-filename-two-workspaces (write + read isolation); foreign-`<ws>`
  download denied; back-compat link still resolves within the window;
  upload→download round-trip; resolver `authority/2` enforced.
- **Acceptance gate:** all upload/download tests green; authz is by `<ws>`
  segment; bytes live at `…/uploads/<ws>/<name>`; baseline shrinks by the
  uploads entries.
- **Open sub-question (carried from discussion, decide in P2b):** does uploads
  need a *streaming-friendly* resolver return (path vs. IO device) so large
  uploads don't round-trip through a materialized temp dir like socialware does?
  Default: return a path (uploads are already files on disk; only socialware
  *projects* a transient dir). Revisit only if a large-upload requirement
  appears.

### P3 — Burn down the lockdown baseline

- With config-dir (P1) and uploads (P2) migrated, **remove their baseline
  entries** (already done incrementally in P1/P2) and migrate the remaining
  population-3 callers (cc/codex templates' *tenant-scoped* config writes, feishu
  client, python server, agent_bridge token_store, identity application) **only
  where they are tenant-scoped content** — each either moves behind the resolver
  (registering its `<type>`) or, if it is genuinely a sanctioned non-tenant /
  OS-handle surface, converts to an exact-anchor exception with a stated reason.
- **Acceptance gate:** the `home_path_in_runtime_code` baseline is **empty**;
  every remaining `Home.path` call in runtime app code is either gone or an
  exact-anchor exception with a reason. The lockdown is complete and scoped to
  app code.

### STOP HERE.

db / runtime cookie / codex socket / pty-pids stay on **sanctioned raw `Home`**
(D2, exact-anchor exceptions). Global creds deferred (D5). No `home://` (D3).

---

## 7. Resolution algorithm (consolidated reference)

```
resolve(:config_dir, {uri, scope}):              # single owner, uri_query_resolvers.ex
  case uri.scheme:
    "template" | "entity" -> stored config_dir string                # unchanged
    "resource"            -> Resource.FsResolver.resolve(uri, scope)  # P1: generic first
                             |> on :none -> resolve(:socialware_config_dir, uri)
    _                     -> :none
  # scope.workspace for config-dir = the agent's authoritative workspace
  # (the cascade's authenticated subject), NOT attacker-supplied.

Resource.FsResolver.resolve(uri = resource://<ws>/<type>/<name>, scope):   # §5.1
  1. parse 3 segments               -> else :none / {:error, :malformed_resource_uri}
  2. <type> in allowlist?           -> else :none              # R-1, NO Home catch-all
  3. segments safe?                 -> else {:error, _}        # R-2, before Path.join
       (reject ".", "..", separator, NUL; must equal segment!/1 output)
  4. type_spec.authority(uri, scope) -> else {:error, _}       # R-3, uri.<ws> == scope.workspace
  5. {:ok, Path.join([Home.path(backend_component), <ws>, <name>])}  # R-4

# uploads (P2) call Resource.FsResolver.resolve(uri, %{workspace: mount_ws})
# directly from the controller/LiveView — request-scoped, not via :config_dir.
```

---

## 8. Testing strategy

- **Unit (TDD per phase):** resolver R-1..R-4 (P0); scan category S-1..S-3
  (P0.5); config-dir byte-identical parity + authority (P1); uploads
  same-filename-two-workspaces + workspace-segment authz + back-compat (P2).
- **Invariant tests (the gates that fail when the architectural goal is unmet,
  per `feedback_completion_requires_invariant_test`):**
  - *Resolver completeness:* a test that enumerates every registered `<type>`
    and asserts (a) it has an `authority/2`, (b) an unregistered type returns
    `:none`, (c) `.`/`..`/separator segments never reach `Path.join`. This fails
    if anyone adds an implicit catch-all or a type without authority.
  - *Lockdown:* the `home_path_in_runtime_code` category is GREEN on the tree
    and a fixture with an unbaselined runtime `Home.path` call is RED — the gate
    that fails when a dev re-introduces a bypass.
- **No live-node hacks** (`feedback_no_hack_use_cli_on_live_node`); operator
  paths exercised via `mix ezagent`. **E2E faces production**
  (`feedback_e2e_faces_production`): the uploads round-trip is tested through the
  real controller route + authz, not a harness shortcut.

---

## 9. Acceptance criteria (whole spec)

1. A generic `resource://` FS resolver exists, is **registration-only**, rejects
   unregistered `<type>` (`:none`), rejects `.`/`..`/separator/NUL before any
   `Path.join`, and runs a per-`<type>` authority check (R-1..R-4 green).
2. The `home_path_in_runtime_code` scan category hard-fails any **new**
   runtime-app-code `Home.path`/`profile_dir`/`home` call from the PR it lands
   in, with exact-anchor exceptions (no directory allowlist) and a burn-down
   baseline (S-1..S-3 green).
3. Per-agent config-dir resolves via the resolver with a byte-identical path
   (parity test green); the cascade/Materializer hot path is untouched (D4).
4. Uploads store + download through the resolver, authorized by the `<ws>`
   segment, with the download-contract change shipped **before** the byte move
   and a same-filename-two-workspaces regression test green.
5. The lockdown baseline is **empty** at P3; remaining `Home.path` callers in
   runtime app code are either migrated or exact-anchor exceptions with reasons.
6. db / cookie / codex socket / pty-pids remain on sanctioned raw `Home`; no
   `home://` scheme was added; global creds were not migrated.

---

## 10. Open items needing the user's decision

- **OI-1 (download contract form, P2a).** Route-shape change
  (`GET /files/:ws/:name`) vs. a signed-token-carrying-the-full-URI approach.
  Both satisfy "the request carries the `<ws>` segment"; the spec mandates the
  property, not the mechanism. Recommendation: explicit route segments (simplest,
  inspectable, no token-signing surface). **Decision deferred to the P2 PR**, but
  flag if Allen has a preference.
- **OI-2 (uploads streaming return, P2b).** Path vs. IO-device resolver return
  for large uploads. Default = path (uploads are already on-disk files). Revisit
  only on a large-upload requirement.
- **OI-3 (P3 scope of "remaining population-3 callers").** Some callers
  (feishu client, python server, agent_bridge token_store, identity application)
  may be tenant-scoped content (→ migrate) or sanctioned infra (→ exact-anchor
  exception). Each is adjudicated in P3 per the D2 test ("is it content
  addressable by `<ws>`?"). No blanket rule; flagged so the P3 PR enumerates each
  with its verdict.

> **User-assist steps flagged** (per `feedback_flag_user_assist_steps`): none of
> P0–P3 requires a human action to *implement*; the E2E acceptance for P2
> (uploads round-trip through the real route) can run in the disposable/docker
> E2E stack with seeded users — no operator credential supply needed.
