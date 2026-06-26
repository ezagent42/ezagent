# SPEC — Starting KB (knowledge-base) capability — retrieval-first

> **Status: design doc, NOT implementation.** Resolves the lead's placement
> question for a *starting* KB capability. Centered on **WHERE the KB store
> lives** (the load-bearing decision), not the full ingest/governance lifecycle.
>
> **rev 3 (2026-06-26) — store REWORKED to a SEPARATE, PORTABLE per-KB sqlite
> file.** The lead's defining constraint: **KB data must be ISOLATED from
> ezagent's own database.** ezagent's DB is PostgreSQL; KB data must NOT be
> mixed into it — it lives in a **separate sqlite store** so it is
> **independently accessible + migratable**: copy the file, move it, inspect it
> outside the app, with zero entanglement with ezagent's schema/migrations. This
> supersedes rev 2 (Postgres FTS — wrong, it entangled KB into ezagent's PG DB)
> and rev 1 (py-role + chromadb — too heavy). New store: **per-KB sqlite file**;
> **FTS5** for the keyword MVP; **sqlite-vec** for the semantic upgrade — both in
> the SAME portable sqlite file. Placement re-evaluated native-vs-py below (§3.0)
> → **native Elixir wins for the MVP.** Built on the role-foundation
> (`docs/together/2026-06-25/specs/role-foundation-design.md`) + the
> kanban-as-role `native`-flavor precedent. Next: codex adversarial-review →
> plan → implement.

## 0. The lead's question, answered up front

> **"Can KB be built on a py-agent or on the native `Entity.Agent`? — and (rev
> 3) KB data must be a SEPARATE, PORTABLE sqlite store, NOT in ezagent's
> Postgres DB."**

**Recommendation: a native Elixir `plugin_kb` — a `kb` ROLE × the `native`
flavor on the unified `Entity.Agent` — that owns a SEPARATE per-KB sqlite file
(FTS5 for keyword MVP), addressed via `resource://`.** No Python subprocess, no
ezagent-Postgres entanglement, no embeddings for the MVP, one hex dep
(`exqlite`/`ecto_sqlite3`). The sqlite file IS the portable, isolated artifact
the constraint demands.

This keeps the **same role × flavor on `Entity.Agent` resolution Allen reached
for kanban** (`kanban-as-role-spec.md`): a non-chat capability = *role × flavor
on `Entity.Agent`*, never its own Kind. KB picks flavor = **`native`** (pure-BEAM,
no external engine); the **store** is a separate sqlite file per KB (NOT the
agent's Kind snapshot, NOT ezagent's Postgres).

**Tiering (the load-bearing reframe), all in ONE portable sqlite file:**

| Tier | Store (separate sqlite file) | Retrieval | Embeddings? | Python? | New dep |
|---|---|---|---|---|---|
| **MVP — `kb` (keyword)** | sqlite **FTS5** (core sqlite, no extension) | keyword / lexical | **none** | **none** | one hex dep (`exqlite`) |
| **Upgrade — `vec-kb` (semantic)** | **sqlite-vec** extension, SAME file | vector / semantic | **embedding API** (local optional) | none (native) *or* py at this tier only | sqlite-vec C extension |

The isolation win is the whole point: the sqlite file is **wholly plugin-owned**,
with **zero rows in ezagent's Postgres** and **zero ezagent migrations** — copy
`kb.sqlite` and you have moved/backed-up/inspected the entire KB.

---

## 1. North star + scope

### 1.1 What we are building

A **retrieval-first** KB: an agent you (a) feed documents to and (b) ask a
query, getting top-k relevant chunks back. Nothing more. This is the biggest
true greenfield parity gap — no FTS, no vectors, no embedding, no RAG, and no
sqlite dependency anywhere in the repo today (verified: zero `exqlite`/
`ecto_sqlite3`/`sqlite-vec`/`tsvector`/`pgvector` on `origin/main`).

### 1.2 MVP scope (retrieval-only, keyword, separate sqlite)

| In scope (MVP = `kb` keyword) | Out of scope (deferred — §7) |
|---|---|
| **ingest** one doc → chunk → INSERT into the per-KB sqlite FTS5 table | source-management over MANY sources |
| **store**: a SEPARATE sqlite file per KB (FTS5 virtual table) | **semantic** retrieval (the `vec-kb` / sqlite-vec upgrade) |
| **query**: a query string → FTS5 `MATCH` → top-k ranked chunks | re-index / migration |
| persistence + **portability**: the sqlite file is the durable artifact | governance (per-source ACL, retention, retrieval audit) |
| **data isolation**: NOTHING in ezagent's Postgres DB | hybrid / re-ranking / federation |
| one consuming agent reaching KB via dispatch + a kb MCP tool | streaming / incremental re-embed |
| caps gating ingest vs query separately | a local embedding model (vec-kb may use one; not MVP) |

### 1.3 Non-goals

- **NOT in ezagent's Postgres / pgvector** — the constraint is the opposite:
  KB data is a distinct, portable sqlite artifact.
- Not a Python subprocess for the MVP (FTS5 is core sqlite, needs none).
- Not a new URI scheme, not a new Kind, not a new domain app.
- MVP does NOT do semantic search — keyword FTS5 only (semantic = the named
  upgrade tier).

---

## 2. What already exists we build on (verified on origin/main)

Reuse, don't rebuild:

1. **`Ezagent.Role` + `Ezagent.RoleRegistry` (#54, role-foundation)** + the
   **`native` flavor on `Entity.Agent`** (kanban-as-role precedent;
   `apps/ezagent_plugin_native/`). A Role is the flavor-agnostic sandbox-content
   recipe; `native`'s host Kind is `Entity.Agent` with NO sidecar/subprocess. KB
   = a `kb` recipe (`behaviors: [Behavior.Kb]`, `passive: true`) × `native`.

2. **RF-1 per-instance behavior dispatch — IMPLEMENTED on main (code-verified).**
   `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex` admits a recipe-loaded
   behavior iff it is a loaded validated real Behavior (`real_behavior?/1` =
   `Code.ensure_loaded?` + `Ezagent.Behavior.new_style?`) — the comment states it
   "**REPLACES the prior ∩ behaviors_of gate for undeclared recipe-loaded
   behaviors**"; `resolve_action/3` is static-first then per-instance fallback;
   `authz_check` independently gates privilege. So **`Entity.Agent` does NOT need
   to declare `Behavior.Kb`** — exactly as `kanban-as-role-spec.md` line 70
   claims. (No host-Kind edit needed.)

3. **`Ezagent.Resource.FsResolver` (`resource://<ws>/<type>/<name>`)** + the
   **plugin `resource_types/0` declaration** (`Ezagent.Plugin`'s
   `resource_type_decl`, registered via `FsResolver.Registry.register_all/1`,
   write-once; types SHOULD be plugin-slug-prefixed — the D7 collision guard).
   The hardened FS seam (R-1 closed allowlist, R-2 traversal guard, R-3
   caller-scope authority, R-4 Home is the backend). KB uses it BOTH for the
   **source docs** (a `kb-source` type) AND for the **sqlite store file** (a
   `kb-store` type — the per-KB sqlite path is `resource://`-addressed, §4.2).

4. **The MCP transport pattern** (`Ezagent.Orchestrator.McpServer`). The
   precedent for exposing a capability to a consuming LLM agent as a tool —
   though it is orchestrator-shaped (§5.3).

5. **Dispatch + per-instance CapBAC** (`kind/runtime.ex`:
   `resolve_action` → `instance_set_gate` → `authz_check`, reading
   `required_caps()[action]`). `kb`'s `:query` / `:ingest` are gated here.

6. **`passive`-actor isolation (RF-6)** — the gates that make a data actor
   non-chat. KB is passive.

> **One new dependency.** The MVP adds `exqlite` (or `ecto_sqlite3` for the Ecto
> surface) — a small, well-maintained hex package. This is native's only real
> cost, and it is far lighter than the py path's subprocess + uv-install +
> bindings. ezagent's own DB stays Postgres; the sqlite dep is used ONLY for the
> isolated KB stores.

---

## 3. Placement: native-vs-py + the options

### 3.0 Native Elixir vs py-role for the separate sqlite store (the crux)

The lead asked which is cleaner given the store is an independent sqlite file.
**Native Elixir wins for the FTS5 MVP.** The reasoning:

- **The constraint is about THE FILE, not the language.** Isolation,
  portability, independent-migratability are properties of the sqlite file —
  identical whether Elixir or Python opens it. "Needs a separate file path" does
  NOT imply "needs Python."
- **FTS5 is core sqlite** — no extension, no embeddings, no ML. So the MVP needs
  nothing Python is uniquely good at. Native opens the file via a connection
  handle; that is the lightest thing that satisfies the constraint.
- **py's only genuine edge — mature `sqlite-vec` bindings — belongs to the
  DEFERRED `vec-kb` tier**, not the MVP. Deciding the MVP on a deferred tier's
  needs would be backwards.
- **The lead's through-line is "lighter"** (py-chromadb too heavy → "lightest,
  portable"). A Python subprocess per KB is the heaviest option on the table; it
  re-introduces the whole rev-1 subprocess machinery (activate/2 reopen holes,
  subprocess security surface, dep supply chain, uv-install) that the rev-1 codex
  review enumerated. Native = open a file.
- **The one real native gap — and its fix.** A `native`-flavor kb-agent does NOT
  get py's `config_dir` (native/kanban allocates none). The lead explicitly
  offered "*or addressed via `resource://`*": the sqlite file lives under a
  `resource://<ws>/kb-store/<agent>` Home component
  (`<Home>/kb-stores/<ws>/<agent>/kb.sqlite`) — the FsResolver pattern already
  specced for `kb-source`. More addressable than a config_dir path, and it
  removes the only pull toward py.
- **Connection lifecycle is lighter than a subprocess.** The sqlite connection
  is a `Behavior.Kb` **transient** opened in `activate/2` and rebuilt on every
  start (the standard two-container Lifecycle model) — it cannot half-fail the
  way a subprocess respawn can, and there is no "reopen the index from disk"
  cold-load hole (sqlite IS the disk file; opening it is the whole operation).

**At the `vec-kb` promotion** (deferred), re-evaluate: native sqlite-vec needs
`exqlite`'s `load_extension` to load the sqlite-vec C extension (achievable but
to be verified at that point); py's sqlite-vec bindings are more mature. That is
the ONE place py legitimately competes — and it is deferred (§3.3, §9).

### 3.1 Option A — native `plugin_kb`, separate sqlite FTS5 — RECOMMENDED (MVP)

A native Elixir `plugin_kb` declaring a `kb` Role × `native` flavor on
`Entity.Agent`, owning:
- a **separate per-KB sqlite file** (`resource://…/kb-store/…`) with an **FTS5**
  virtual table for the corpus,
- a thin **`Behavior.Kb`** with `:ingest` (write) and `:query` (read) actions
  that open the sqlite file (transient) + run FTS5 SQL via `exqlite`,
- a **kb MCP tool** so LLM agents can call query,
- a **`kb-source` FsResolver type** for source-doc reads at ingest.

**Pros**
- **Satisfies the isolation/portability constraint by construction.** The
  corpus is a standalone sqlite file: copy/move/inspect it outside the app; zero
  rows in ezagent's Postgres; zero ezagent migrations. This is the cleanest
  possible expression of "KB data is a distinct, portable artifact."
- **Lightest viable retrieval.** FTS5 is built into sqlite. The MVP is a thin
  Behavior + a kb MCP tool + two resource-type registrations + one hex dep. No
  Python, no subprocess, no uv-install, no chromadb/faiss, no local model, no
  ezagent-schema change.
- **In-process, in the BEAM.** `Behavior.Kb` opens the sqlite connection and
  queries it directly — no JSON-RPC, no subprocess to keep alive. The connection
  is a transient rebuilt on `activate/2` (lighter + safer than subprocess
  respawn).
- **Reuses role-foundation + native flavor wholesale** (RF-1 no-declaration
  dispatch, native CapMint policy RF-8, list-by-role RF-7, passive isolation
  RF-6) + the FsResolver seam (now for the store file too).
- **Clean upgrade seam to semantic.** The consumer contract (kb MCP tool +
  `kb.query` dispatch action, §5) is stable; the sqlite-vec upgrade adds a vector
  table to the SAME file behind it (§3.3).

**Cons / risks — and how this SPEC resolves each**

| Risk | Resolution |
|---|---|
| **Keyword-only retrieval quality** | FTS5 is lexical, not semantic. Accepted MVP limitation + the explicit `vec-kb` trigger (§3.3). |
| **One new hex dep (`exqlite`)** | Small, well-maintained; native's only real cost; far lighter than the py subprocess stack. ezagent's own DB stays Postgres. |
| **Where the file lives + addressing** | `resource://<ws>/kb-store/<agent>` → `<Home>/kb-stores/<ws>/<agent>/kb.sqlite` via a `kb-store` FsResolver type (R-1..R-4). Per-KB, tenant-scoped, portable. See §4.2. |
| **Connection lifecycle / concurrency** | The connection is a `Behavior.Kb` transient (re-opened on `activate/2`). sqlite serializes writes (one writer); the `:in_process` dispatch through the agent's process already serializes KB actions per agent — no contention within one KB. Cross-KB = separate files, no shared lock. WAL mode for read-during-write if needed. |
| **How OTHER agents query it** | kb MCP tool (LLM consumer) + agent-to-agent dispatch (universal back end), both CapBAC-gated. §5. |
| **Ingest path** | `:ingest` reads the source via FsResolver (cap-gated, traversal/symlink-guarded), chunks, INSERTs into the FTS5 table (which indexes automatically). §4.4. |
| **Security** | No subprocess + no arbitrary-code surface (the rev-1 np-whitelist concern is moot). Remaining: ingest FS read (FsResolver + symlink guard), SQL safety (parameterized FTS5 `MATCH`, never string-built), and the store-file path being `resource://`-confined (no arbitrary sqlite path). §6. |

### 3.2 Option B — py-role (python + sqlite + sqlite-vec) — NOT for the MVP

A `kb` py-role: a per-agent Python subprocess opening the sqlite file with the
stdlib `sqlite3` + the `sqlite-vec` Python bindings.

**Why not for the MVP (but kept on the table for vec-kb):**
- For **FTS5** it buys nothing — FTS5 is core sqlite, reachable natively via
  `exqlite` with no Python — and costs the entire subprocess stack (uv-install,
  activate/2 reopen lifecycle, subprocess security surface, dep supply chain).
  Heaviest option for the lightest tier.
- The portability/isolation constraint is satisfied by the FILE regardless of
  language, so py earns nothing there.
- **It legitimately competes only at the `vec-kb` tier**, where `sqlite-vec`'s
  Python bindings are more mature than loading the C extension into `exqlite`.
  So: revisit py **at vec-kb promotion** if native sqlite-vec extension-loading
  proves painful — NOT before. For the MVP: native.

### 3.3 Option C — `vec-kb`: sqlite-vec in the SAME file (the SEMANTIC UPGRADE tier)

When keyword FTS5 proves insufficient (synonym/paraphrase misses), upgrade
`kb` → `vec-kb` **in the same separate sqlite file, same plugin, same consumer
contract**:
- Load the **sqlite-vec** extension; add a `vec0` virtual table (vectors) to the
  SAME `kb.sqlite` file — keeping vectors **portable + isolated** alongside the
  FTS5 corpus (the whole KB stays one movable file).
- At ingest, call an **embedding API** (routed through the existing credential
  cascade; a local model is an OPTION since the store is already a separate
  concern, but NOT required) and store the returned vector. At query, embed the
  query and run a sqlite-vec nearest-neighbour search; optionally **hybrid**
  (FTS5 prefilter + vector re-rank) — no consumer change.
- **Native-vs-py is re-decided HERE** (the one place py's bindings matter):
  native = `exqlite` `load_extension` of sqlite-vec; py = the mature `sqlite-vec`
  Python bindings. Defer the call to promotion time.
- **Backfill story (must be explicit at promotion, codex rev-2 finding):**
  existing FTS5-only chunks have no vector → a backfill pass embeds them, OR
  queries fall back to FTS5 for un-embedded chunks (null-vector handling). Stated
  now so the upgrade is genuinely non-destructive.

### 3.4 Option D — standalone `ezagent_domain_kb` (DEFERRED)

A dedicated domain app. **Gate to promote:** independent KB lifecycle (KBs
created/versioned/retired decoupled from agents) / cross-workspace governance
(shared curated KB, per-source ACLs, retention, audited retrieval) / a separate
scaling axis. None true for retrieval-first MVP (a KB is one agent's portable
sqlite file). Per three-tier + YAGNI, defer. Migration is non-destructive: the
consumer contract (§5) is the stable seam.

### 3.5 Decision summary

```
starting KB (retrieval-first, MVP) = role `kb` × flavor `native` on Entity.Agent
  owned by                = a native Elixir plugin (plugin_kb)
  STORE                   = a SEPARATE per-KB sqlite FILE (resource://…/kb-store/…)
                            — isolated from ezagent's Postgres, portable (copy the file)
  retrieval               = sqlite FTS5 (MATCH/rank) — KEYWORD
  embeddings / Python     = NONE (FTS5 MVP); one hex dep (exqlite)
  source-doc reads        = resource:// kb-source type via FsResolver (cap-gated)
  consumption (LLM agent) = kb MCP tool (recommended); dispatch = universal back end
  cap model               = kb.query (action :query) ≠ kb.ingest (action :ingest), fail-closed
  persistence/portability = the sqlite file IS the durable, movable artifact
  passive                 = true (RF-6)
UPGRADE: vec-kb = sqlite-vec in the SAME file + embedding API (local model optional);
         re-decide native-vs-py at promotion (py's bindings only matter here).
NOT: ezagent Postgres / pgvector (violates isolation); py-role for the MVP (too heavy);
     domain_kb (until independent lifecycle / cross-ws governance / separate scaling).
```

### 3.6 The MVP delta (what is NEW vs reused) — honest cost

Reused wholesale: the `native` flavor + role-foundation (RF-1/4/5a/6/7/8) the
kanban path exercises, the FsResolver seam (now for two types), the MCP pattern,
dispatch + CapBAC. **What the MVP must NEWLY build:**

| New artifact | Tier | ~Size | Why |
|---|---|---|---|
| `exqlite` (or `ecto_sqlite3`) hex dep | dep | one dep | open the separate sqlite files (NOT for ezagent's PG DB) |
| `Behavior.Kb` (`:query` / `:ingest`) + sqlite open/FTS5 SQL | plugin Elixir | thin | two cap-distinct dispatch actions over the per-KB file |
| `kb` role recipe + `roles/0` registration | plugin Elixir | tiny | recipe = `[Behavior.Kb]`, passive, requested caps |
| `native` CapMint policy entry for the kb caps | plugin Elixir | tiny | fail-closed grant of `kb.query`/`kb.ingest` (RF-8) |
| `kb-store` + `kb-source` FsResolver types (plugin `resource_types/0`) | plugin decl | tiny | the store file path + the source doc path, slug-prefixed |
| kb MCP tool | cc/plugin Elixir | small | the MCP catalog is orchestrator-shaped — NEW work (§5.3) |
| FTS5 schema bootstrap (create the virtual table on first open) | plugin Elixir | tiny | `CREATE VIRTUAL TABLE … USING fts5(...)` if absent |

Pure Elixir + one hex dep, no Python, no ezagent-schema change.

---

## 4. Recommended design — native sqlite FTS5

### 4.1 The recipe (`kb`)

`Ezagent.Role` recipe, code-seeded via a `roles/0` callback on `plugin_kb`:

```elixir
%{
  name: "kb",
  passive: true,                       # RF-6: data actor, not a chat principal
  behaviors: [Ezagent.Behavior.Kb],    # the sqlite/FTS5 state half — actions :query + :ingest
  requested_caps: [                    # §6 — fail-closed; granted by native CapMint policy
    %{behavior: Ezagent.Behavior.Kb, action: :query},
    %{behavior: Ezagent.Behavior.Kb, action: :ingest}
  ],
  session_template: nil
}
```

Composed via `Role.Compose.materialize(recipe, :native)` at create; the `native`
CapMint policy (RF-8) grants exactly the requested caps (fail-closed). RF-1
admits `Behavior.Kb` on `Entity.Agent` WITHOUT a host-Kind declaration (§2.2),
provided it is a real new-style Behavior.

### 4.2 The store — a SEPARATE, PORTABLE per-KB sqlite file

- **Where:** `resource://<ws>/kb-store/<agent>` → resolved by a `kb-store`
  FsResolver type to `<Home>/kb-stores/<ws>/<agent>/kb.sqlite`. One sqlite file
  per kb-agent. Tenant-scoped (the `<ws>` segment + R-3 authority).
- **Why this satisfies the constraint:** the file is wholly plugin-owned —
  **nothing in ezagent's Postgres, no ezagent migration touches it.** Backup =
  copy the file; move a KB = move the file; inspect = open it with any sqlite
  tool outside the app. Independent accessibility + migratability, by
  construction.
- **Why `resource://`, not config_dir:** a `native` kb-agent gets no config_dir
  (kanban precedent); `resource://kb-store` is the addressable, authorized,
  traversal-guarded home the lead offered as the alternative — and it reuses the
  exact FsResolver pattern KB already needs for sources.
- **Schema (inside the sqlite file):** an FTS5 virtual table, e.g.
  `CREATE VIRTUAL TABLE chunks USING fts5(text, source_uri UNINDEXED,
  chunk_index UNINDEXED, tokenize='…')` (tokenizer = §9.4 decision). FTS5
  maintains the inverted index automatically on INSERT.
- **No ezagent tenancy columns needed inside the file** — the file IS the
  tenant boundary (one file per kb-agent in a workspace-scoped path). `source_uri`
  is stored for provenance, not isolation.

### 4.3 Persistence + portability (the constraint, satisfied)

The corpus is the sqlite file — durable by construction; survives BEAM/agent
restart with no in-memory rebuild. `Behavior.Kb` opens the file as a **transient
connection** in `activate/2` (re-opened on every start: fresh spawn / supervisor
restart / cold-load — the two-container Lifecycle model), then runs SQL per
action. No "reopen the index" hole (sqlite IS the file). The agent's Kind
snapshot persists only lightweight config (chunk size, default `k`, the
`kb-store` URI) + `last_*` observability — never the corpus. **The portability
requirement is the headline property to prove** (test §8.9: copy the file, open
it standalone, the corpus is intact + queryable).

### 4.4 Ingest path (source docs via `resource://` + FsResolver)

Ingest takes a **source reference** (`resource://<ws>/kb-source/<name>`), not
inline bytes (inline fine for tiny test docs; the reference path uses the FS auth
seam):

- Register a **`kb-source` type** via the plugin `resource_types/0` declaration
  (slug-prefixed; registered through `FsResolver.Registry.register_all/1`,
  write-once) with a per-type `authority/2` (R-3) + a `Home` backend (R-4);
  traversal rejected by R-2.
- `Behavior.Kb`'s `:ingest` handler resolves the source URI → authorized on-disk
  path via `FsResolver.resolve/2` under the caller's authenticated scope (NEVER
  from the URI), **realpath-checks against symlink escape** (§6), reads the
  bytes, chunks (simple size/overlap chunker for MVP), and INSERTs rows into the
  per-KB sqlite FTS5 table (a parameterized `INSERT`, never string-built).
- **One source's lifecycle (in scope even though many-source MANAGEMENT is
  deferred):** re-ingesting an existing `source_uri` **replaces** that source's
  rows (`DELETE FROM chunks WHERE source_uri = ?; INSERT …` in one sqlite
  transaction) — idempotent, no silent duplication. Deferred: the management
  surface over many sources.

### 4.5 Query path

`:query` (read) takes a query string + optional `k`:
- runs `SELECT text, source_uri, chunk_index, rank FROM chunks WHERE chunks
  MATCH ? ORDER BY rank LIMIT ?` — the query string + `k` bound as
  **parameters** (the FTS5 `MATCH` operand is a bound value, never concatenated
  → injection-safe, §6). FTS5's built-in `rank` (bm25) supplies the score.
- returns top-k **hits with provenance**: `%{text, score, source_uri,
  chunk_id}` (§5.4).

### 4.6 Behaviors — one thin `Behavior.Kb` (the cap split requires it)

Two cap-distinct actions so a query-only consumer cannot mutate the corpus.

> **Action-name convention (codex-corrected, store-independent).** The dispatch
> URI is `entity://<ws>/agent/<id>?action=kb.query` — `Ezagent.URI` parses that
> to action **`:query`** (the `kb.` segment is the behavior-NAME hint, dropped at
> resolution; `behavior_set.ex` resolves by the ACTION atom). So the Behavior
> declares actions **`:query`** / **`:ingest`** (NOT `:kb_query`/`:kb_ingest`).
> The **caps** are the subjects `{Behavior.Kb, :query}` / `{Behavior.Kb,
> :ingest}` (informally "kb.query" / "kb.ingest"). The "kb" namespace lives in
> the behavior module + cap subject, not the action atom.

- `:query` (cap subject `{Behavior.Kb, :query}`, mode `:call`) and `:ingest`
  (cap subject `{Behavior.Kb, :ingest}`, mode `:call`) — two actions, two caps,
  so **CapBAC gates ingest vs query at the dispatch layer** (`kind/runtime.ex`
  `resolve_action` → `instance_set_gate` → `authz_check` reading
  `required_caps()[action]`).
- Each handler is **thin**: open the per-KB sqlite (transient), run the FTS5
  SQL, persist the lightweight `last_*`. No subprocess, no JSON-RPC.
- The sqlite **connection is a transient** (two-container Lifecycle): opened in
  `activate/2`, rebuilt on every start. `Behavior.Kb` declares `actions/0`
  (`:query`/`:ingest`), `required_caps/0`, `data_owner/1`, and is a real
  new-style Behavior (so RF-1's `real_behavior?` admits it, §2.2).

A single chat-`receive` path was rejected: one cap, collapses the read/write
distinction — the one security property that must hold even at MVP.

---

## 5. How an agent CONSUMES KB

### 5.1 The options

- **kb MCP tool** — expose query (and, cap permitting, ingest) as MCP tools the
  consuming LLM agent calls.
- **Agent-to-agent dispatch** — dispatch
  `entity://<ws>/agent/<kb-instance>?action=kb.query` directly
  (`Ezagent.Invocation.dispatch/1`) — the universal native path (kanban reads
  its board via dispatch).

### 5.2 Recommendation

**For the LLM-agent consumer (the primary RAG use case): the kb MCP tool**, so
the model decides *when* to retrieve via a typed tool. **Agent-to-agent dispatch
is the universal back end** the MCP tool dispatches `kb.query` *through*; non-LLM
callers use dispatch directly. Both gate `kb.query` / `kb.ingest` via CapBAC.

### 5.3 The MCP surface is NEW WORK — and the existing one is orchestrator-shaped

Codex-verified: `Ezagent.Orchestrator.McpServer` is NOT a generic
dispatch-to-any-action adapter. It is the **cc orchestrator's** transport — a
**hard-coded** tool catalog (`tool_catalog.ex`) forwarding fixed tools to the
per-orchestrator `SessionManager`, authenticated by a **bridge token** (the
orchestrator's connection credential), NOT by threading an arbitrary caller's
caps. So the plan must pick ONE:

1. **Extend the orchestrator catalog** — add kb tools to `tool_catalog.ex` +
   the `SessionManager` `run_tool` switch; smallest, but couples KB to the cc
   orchestrator + uses the bridge-token authority model.
2. **A KB-scoped MCP server** — a new transport that authenticates the calling
   agent and dispatches `kb.query`/`kb.ingest` with THAT agent's caps; cleaner,
   plugin-owned; more new code.
3. **A generalized plugin tool-catalog** — the reusable version of (2); larger.

**The cap-threading model is the load-bearing decision** (option 1 = bridge-token
/ orchestrator authority; option 2/3 = caller's own caps). Recommend **option 1
for the MVP** (smallest path to RAG-over-MCP) with option 2 as the clean
follow-up — **plan decision, confirm with the lead** (§9.7). Dispatch-direct
(§5.1) is always available to in-BEAM callers gating on their own caps.

### 5.4 Result schema (define the minimum now)

`kb.query` returns top-k hits with provenance: each hit is
`%{text: chunk, score: float, source_uri: "resource://…/kb-source/…",
chunk_id: id}`. Provenance is non-negotiable even at MVP (cite/trace; enables
later governance without re-ingest). `score` is FTS5 bm25 `rank` for the MVP; at
`vec-kb` it becomes the vector similarity — same field, different scorer.

---

## 6. Cap model + security

### 6.1 Caps (fail-closed, separated by mutation)

- **`kb.query`** (action `:query`) — read. **`kb.ingest`** (action `:ingest`) —
  write. Distinct so a query-only consumer cannot mutate the corpus. Requested
  in the recipe, granted by the `native` CapMint policy (RF-8, fail-closed) at
  `Workspace.grant_initial_caps`.

### 6.2 Security model (native sqlite — small surface)

The native path eliminates the rev-1 subprocess attack surface entirely (no
Python, no arbitrary-code risk, no dep/model supply chain, no subprocess FS
confinement). Remaining surface:

- **SQL safety.** The FTS5 `MATCH` operand + every INSERT value are **bound
  parameters** (`exqlite` prepared statements) — user input is data, NEVER
  concatenated into SQL. No raw `MATCH` string assembly.
- **Store-file confinement.** The sqlite file path comes ONLY from the
  `kb-store` FsResolver type (R-1..R-4) — a caller can never name an arbitrary
  sqlite path (no "open `/etc/…`"). The store URI is derived from the kb-agent's
  own identity, not caller input.
- **Source FS reads (ingest).** FsResolver R-1..R-4 authorize the source path in
  Elixir (scope from the caller's authenticated context, never the URI), R-2
  rejects traversal, **and the read realpath-checks the resolved file to reject a
  `kb-source` symlink escaping the backend root.**
- **Tenancy / isolation.** One sqlite file per kb-agent under a workspace-scoped
  `resource://` path — cross-tenant access is structurally impossible (you cannot
  resolve another workspace's `kb-store` URI under your scope, R-3). This is a
  STRONGER isolation story than a shared table filtered by `workspace_uri`.
- **Ingest bounds.** Max source size + max chunks per ingest, so a pathological
  doc cannot bloat the file / exhaust memory.
- **Poisoned-document / prompt-injection.** Retrieved chunks feed an LLM
  consumer; a malicious doc can carry instructions. MVP carries provenance
  (§5.4) so the consumer can attribute/distrust + treats retrieved text as
  untrusted data — stated as a known limitation, not solved.
- **(vec-kb tier only)** sqlite-vec is a C extension loaded into the sqlite
  connection — loading native extensions is a privilege; restrict to the vetted
  sqlite-vec library, loaded by the plugin, never a caller-named extension.

---

## 7. Explicitly deferred

| Deferred | Why deferred | When to revisit |
|---|---|---|
| **`vec-kb` semantic (sqlite-vec in the same file + embedding API)** | keyword FTS5 is the lightest MVP; vectors cost an extension + embeddings | keyword retrieval proves insufficient (synonym/paraphrase misses) |
| **ezagent Postgres / pgvector** | RULED OUT by the isolation constraint — KB must NOT live in ezagent's DB | n/a (constraint, not a deferral) |
| **py-role (python + sqlite-vec bindings)** | too heavy for FTS5; buys nothing the MVP needs | ONLY re-evaluated at vec-kb promotion if native extension-loading is painful |
| **`domain_kb` (Option D)** | YAGNI; a starting KB is one agent's portable file | independent lifecycle / cross-ws governance / separate scaling axis |
| **source-management** (list/refresh/dedupe MANY sources) | not needed to prove retrieval — single-source create/overwrite IS in scope (§4.4) | KBs accrete many sources operators must curate |
| **re-index / migration / tokenizer change** | one tokenizer/config for MVP | changing the FTS5 tokenizer or adding vectors on a populated file |
| **governance** (per-source ACL, retention, retrieval audit) | the cap split + per-file isolation is enough for MVP | cross-agent shared KB (= the domain trigger) |
| **hybrid (FTS5+vector) / re-ranking / federation** | top-k FTS5 is the MVP | lands naturally with vec-kb |
| **auto-RAG prompt injection** | model-asks-via-MCP is the MVP | prompt-pipeline phase |

---

## 8. Test plan

The acceptance gate must *fail* if the architectural claims are unmet:

1. **Round-trip (the core).** Create a `kb`×`native` agent → ingest a known doc
   → `kb.query` with terms in the doc → top-k hit contains the expected chunk +
   provenance. (Proves chunk + sqlite store + FTS5 retrieve.)
2. **Persistence across restart.** Ingest → restart the agent (supervisor + a
   cold-load path) → query → content STILL retrievable (the sqlite file +
   `activate/2` re-open; no in-memory dependency crept in).
3. **Cap separation.** Only `kb.query` → REFUSED `kb.ingest` (`:cap_denied`);
   neither → both refused. (Fail-closed + mutation separation.)
4. **Source authority + symlink (FsResolver).** Ingest
   `resource://victimWS/kb-source/x` under attacker scope fails R-3; a `..`
   fails R-2 before backend touch; a symlinked source escaping the root is
   rejected (§6).
4b. **Re-ingest = replace.** Ingest source `<name>` twice → query returns ONE
   copy of each chunk (DELETE-by-source_uri then INSERT, §4.4).
4c. **Result schema + provenance.** Hits carry `source_uri` + `score` +
   `chunk_id` (§5.4).
4d. **SQL safety.** A query string with FTS5/SQL metacharacters (`"`, `*`, `AND
   1=1`, `'; DROP …`) is treated as DATA (bound param) — no error, no injection,
   lexical matches only.
5. **Store-path confinement.** No caller-supplied path can make `Behavior.Kb`
   open a sqlite file outside the `kb-store` FsResolver backend.
6. **Passive isolation (RF-6).** Not @-mentionable, not `:join`-able, does not
   receive ambient chat — only `kb.*` dispatch + the MCP tool reach it.
7. **MCP consumption.** An LLM-shaped consumer reaches the kb tool, which
   dispatches `kb.query` into the kb-agent with the caller's caps (per the §5.3
   option chosen).
8. **No Python / no ezagent-PG entanglement / no new Kind/domain.** Arch/grep
   gate: MVP adds no Python subprocess, NO rows/tables in ezagent's Postgres for
   KB data, no new Kind, no new domain.
9. **PORTABILITY (the constraint, headline).** After ingest, COPY the
   `kb.sqlite` file out, open it with a standalone sqlite tool (or a second
   process), and assert the corpus + FTS5 index are intact + queryable WITHOUT
   the ezagent app — proving the KB is an independent, portable artifact.

Live e2e (agent-browser sign-off): create a kb-agent, ingest a doc via CLI/UI,
query, screenshot the retrieved result.

---

## 9. Open questions for the lead

1. **Retrieval tier for MVP — FTS5-only, or sqlite-vec immediately?**
   Recommendation: **FTS5-only MVP** (no embeddings — lightest, matches "kb not
   vec-kb"). Embedding question becomes "**embedding API vs NONE**": MVP = none;
   `vec-kb` = an embedding API call (a local model is an OPTION at that tier, not
   required). Confirm FTS5-only start.
2. **Vector backend (for the upgrade): sqlite-vec — confirmed.** sqlite-vec in
   the SAME sqlite file (keeps vectors portable + isolated). pgvector/chromadb/
   faiss are OFF the table (pgvector violates the isolation constraint).
   Confirm.
3. **Native Elixir vs py for the store.** Recommendation: **native (`exqlite`)
   for the FTS5 MVP** (lightest; the constraint is about the file, not the
   language); **re-decide native-vs-py at vec-kb promotion** (py's sqlite-vec
   bindings are the one real advantage, and that tier is deferred). Accept one
   hex dep (`exqlite`/`ecto_sqlite3`)? Or do you want py from the start to keep
   one toolchain for the eventual sqlite-vec?
4. **FTS5 tokenizer — flag: bilingual content (MVP-relevant, NOT a harmless
   defer).** FTS5's default `unicode61` tokenizer does NOT segment Chinese (no
   whitespace word boundaries), so EN-only tokenization indexes zh_cn poorly →
   immediate false negatives + a forced re-index later. Given the team's content
   is bilingual (EN + zh_cn), decide BEFORE creating the table: the **ICU**
   tokenizer, or `tokenize='trigram'` (works across scripts, MVP-simple), or
   EN-only-now-with-an-explicit-reindex-plan. Recommend `trigram` for an
   MVP that handles both scripts with zero extra extension.
5. **Store addressing + one-KB-per-agent.** Recommendation: `resource://<ws>/
   kb-store/<agent>` → `<Home>/kb-stores/<ws>/<agent>/kb.sqlite`, one KB per
   kb-agent (so "create a KB" = "create a kb×native agent"). Confirm — and
   confirm the `resource://kb-store` addressing over a config_dir path.
6. **MCP integration point** (§5.3) — option 1 (extend orchestrator catalog,
   bridge-token authority) for the MVP vs option 2 (KB-scoped MCP server,
   caller-caps)? Recommend option 1 for MVP, option 2 follow-up.
7. **/goal acceptance criteria** — Allen to set; §8 is the proposed superset.
   Confirm the PORTABILITY test (§8.9) + cap-separation (§8.3) + the
   no-ezagent-PG-entanglement gate (§8.8) are load-bearing (they encode the
   constraint).

```
kb-retrieval-first 完成 = role kb × flavor native on Entity.Agent（native plugin_kb，独立 sqlite 文件）：
1. kb role recipe（[Behavior.Kb] + :query/:ingest（cap kb.query/kb.ingest）+ passive:true）经 roles/0 注册；
   native flavor 经现有 create 路径 per-instance 加载（RF-1 已实现，无需 host Kind 声明）。
2. STORE = 每个 KB 一个独立 sqlite 文件（resource://…/kb-store/…），与 ezagent 的 Postgres 完全隔离、可移植（拷文件即搬库）；
   FTS5 虚拟表；ingest 一篇文档 → kb.query（MATCH/bm25 rank）返回 top-k + provenance。
3. 持久化/可移植 = sqlite 文件本身；重启零丢失，无内存索引；NO Python / NO embeddings / 仅一个 hex 依赖(exqlite)。
4. cap 分离：:query ≠ :ingest，fail-closed；FsResolver 鉴权（kb-source + kb-store，R-1..R-4）+ symlink 防护；
   SQL 安全（参数化 MATCH/INSERT）；store-path 限定（不可开任意 sqlite 路径）。
5. passive 隔离 (RF-6 三闸)；kb MCP tool 消费；dispatch 为通用后端。
6. MVP 不进 ezagent Postgres / pgvector（隔离硬约束）；不引入 Python / chromadb / 新 Kind / 新 domain。
验收：全量 mix test 0 失败 + CI 绿；live e2e（agent-browser）create+ingest+query+截图；
     可移植性测试：拷出 kb.sqlite，脱离 app 用 sqlite 工具打开仍可查。
UPGRADE: vec-kb = 同一 sqlite 文件内 sqlite-vec + embedding API（本地模型可选）；native-vs-py 留到 promotion 再定。
DEFER: domain_kb、source-mgmt(many)、re-index、governance、hybrid/re-rank。
```

---

## 10. Revision history + codex-review record

- **rev 1 (withdrawn)** — py-role + chromadb + sentence-transformers. Codex
  verdict accept-with-changes; withdrawn as too heavy.
- **rev 2 (superseded)** — native Postgres FTS in ezagent's DB. Codex verdict
  accept-with-changes (placement SOUND), but it **violated the data-isolation
  constraint** the lead then clarified: KB must NOT live in ezagent's Postgres.
  Carried-forward fixes that are store-INDEPENDENT and remain valid in rev 3:
  the action-namespace correction (`kb.query` → action `:query`, cap `kb.query`)
  and the RF-1 no-declaration finding (code-verified).
- **rev 3 (this doc, 2026-06-26)** — SEPARATE PORTABLE sqlite store (the lead's
  isolation constraint). Store = a per-KB sqlite file (`resource://kb-store`),
  isolated from ezagent's Postgres; FTS5 keyword MVP (native Elixir, one hex
  dep, no Python); sqlite-vec in the SAME file as the semantic upgrade
  (native-vs-py re-decided at promotion). The spine (cap split, MCP-decision,
  resource:// sources, passive isolation, provenance, test structure) carries
  over; rev-2's Postgres-ownership ambiguity is gone (the file is wholly
  plugin-owned).

### Codex adversarial-review (rev 3, 2026-06-26)

_(populated after the codex run — see report)_
