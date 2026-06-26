# SPEC — Starting KB (knowledge-base) capability — retrieval-first

> **Status: design doc, NOT implementation.** Resolves the lead's placement
> question for a *starting* KB capability. Centered on **WHERE** KB lives, not
> the full ingest/governance lifecycle.
>
> **rev 2 (2026-06-26) — placement REWORKED to the NATIVE Postgres path.** The
> lead's ground-truth correction: the DB is **PostgreSQL** (`ezagent_core`
> deps `postgrex` + `ecto_sql ~> 3.13`; `EzagentCore.Repo` is
> `Ecto.Adapters.Postgres` — verified), so the lightest viable KB is **Postgres
> full-text search (FTS), pure Elixir, NO Python, NO embeddings, NO new heavy
> dep.** The earlier rev-1 recommendation (py-role + chromadb +
> sentence-transformers) is **withdrawn** as too heavy — it stood up a whole
> Python subprocess + uv-install + local-model stack for what Postgres already
> does in-DB. Built on the **role-foundation**
> (`docs/together/2026-06-25/specs/role-foundation-design.md`, on main) and the
> kanban-as-role precedent (`native` flavor on `Entity.Agent`). Next: codex
> adversarial-review of this rev → (if accepted) plan → implement.

## 0. The lead's question, answered up front

> **"Can KB be built directly on a py-agent (retrieval-only for now)? Or
> directly on the native `Entity.Agent`? — and (rev 2) the py-role + chromadb
> + sentence-transformers is too heavy; rework around native Postgres."**

**Recommendation: build the starting KB as a NATIVE Elixir plugin
(`plugin_kb`) using Postgres FTS — a `kb` ROLE × the `native` flavor on the
unified `Entity.Agent`, with the corpus stored in Postgres tables (`tsvector`)
and queried via Ecto.** No Python, no subprocess, no embeddings, no new heavy
dependency — the FTS MVP is a single Ecto migration + a thin Behavior + a kb
MCP tool.

This is the **same role × flavor on `Entity.Agent` resolution Allen reached for
kanban** (`kanban-as-role-spec.md`, 2026-06-25): a non-chat capability becomes
*role × flavor on `Entity.Agent`*, never its own Kind. KB picks flavor =
**`native`** (kanban's flavor — pure-BEAM/Elixir, no external engine), and
unlike kanban (board = Kind snapshot) its corpus lives in **Postgres tables**
because a KB is a *queryable corpus* you run FTS over, not a small in-memory
tree.

**Tiering (the load-bearing reframe):**

| Tier | What | Retrieval | Embeddings? | Python? | New dep |
|---|---|---|---|---|---|
| **MVP — `kb` (keyword)** | Postgres FTS (`tsvector`/`tsquery` via Ecto) | keyword / lexical | **none** | **none** | **none** |
| **Upgrade — `vec-kb` (semantic)** | pgvector extension, same Postgres | vector / semantic | **embedding API call** (no local model) | **none** | pgvector extension only |

The lead's framing — "kb (sqlite/pgsql) not vec-kb" — maps exactly: **start
with `kb` (Postgres FTS keyword)**; promote to `vec-kb` (pgvector + an
embedding **API**, never a local model / chromadb / faiss) only when keyword
retrieval proves insufficient.

The py-role path (rev 1) and a standalone `ezagent_domain_kb` are both
**deferred / withdrawn** (§3).

---

## 1. North star + scope

### 1.1 What we are building

A **retrieval-first** KB: an agent you can (a) feed documents to and (b) ask a
query, getting back the top-k most relevant chunks. Nothing more. This is the
minimum that delivers retrieval to the rest of the platform and the biggest
true greenfield parity gap — there is **no FTS, no pgvector, no embedding, no
RAG anywhere in the repo today** (verified: zero `tsvector`/`tsquery`/`pgvector`
hits on `origin/main`).

### 1.2 MVP scope (retrieval-only, keyword)

| In scope (MVP = `kb` keyword) | Out of scope (deferred — §7) |
|---|---|
| **ingest** one doc (text/markdown) → chunk → store rows | source-management over MANY sources (list/dedupe/refresh) |
| **index**: a Postgres `tsvector` column (generated/`GIN`-indexed) | **semantic** retrieval (that's the `vec-kb` upgrade tier) |
| **query**: a query string → `tsquery` → top-k ranked chunks | re-index / migration |
| persistence = Postgres rows (transactional, survives restart for free) | governance (per-source ACL, retention, retrieval audit) |
| one consuming agent reaching KB via dispatch + a kb MCP tool | hybrid (FTS+vector) / re-ranking / federation |
| caps gating ingest vs query separately | streaming / incremental re-embed |

The defer list is the *governance + lifecycle + semantic* surface — exactly
what justifies the `vec-kb` upgrade or a `domain_kb` later (§3). Keeping it out
is what lets the starting KB be FTS-in-a-plugin, not a vector stack.

### 1.3 Non-goals

- Not a Python subprocess, not chromadb/faiss, not a local embedding model.
- Not a new URI scheme, not a new Kind, not a new domain app.
- MVP does NOT do semantic search — keyword FTS only (the explicit, lighter
  starting point; semantic is the named upgrade tier).

---

## 2. What already exists we build on (verified on origin/main)

Reuse, don't rebuild:

1. **PostgreSQL + Ecto, one repo.** `EzagentCore.Repo`
   (`Ecto.Adapters.Postgres`) is the single application repo, used cross-app;
   migrations live in `apps/ezagent_core/priv/repo/migrations/`. Postgres FTS
   (`to_tsvector` / `plainto_tsquery` / `ts_rank` + a `GIN` index) is a
   **built-in** — no extension, no dependency. The KB corpus table is one
   migration. (pgvector, for the upgrade tier, is a Postgres *extension* enabled
   per-DB — still no Elixir dep beyond a thin type, no Python.)

2. **`Ezagent.Role` + `Ezagent.RoleRegistry` (#54, role-foundation)** + the
   **`native` flavor on `Entity.Agent`** (kanban-as-role precedent). A Role is
   the flavor-agnostic sandbox-content recipe (`behaviors`, `requested_caps`,
   `passive`, …); the `native` flavor's host Kind is `Entity.Agent` with NO
   sidecar/subprocess. KB = a `kb` recipe (`behaviors: [Behavior.Kb]`,
   `passive: true`) × `native`, materialized at create. The kanban-as-role spec
   already resolved every shared concern (per-instance behavior loading via
   RF-1, native CapMint policy via RF-8, list-by-role via RF-7, passive
   isolation via RF-6) — KB rides all of it.

3. **`Ezagent.Resource.FsResolver` (`resource://<ws>/<type>/<name>`).** The
   hardened, registration-only, authorization-bearing FS seam (R-1 closed
   allowlist, R-2 traversal guard, R-3 caller-scope authority, R-4 Home is the
   backend). Where ingest reads operator-supplied **source documents** by URI
   (§4.4). (FTS retrieval itself never touches the FS — only ingest does, to read
   the source bytes once.)

4. **The MCP transport pattern** (`Ezagent.Orchestrator.McpServer` — pure
   transport, zero authority; a FIXED tool catalog whose `tools/call` decodes →
   dispatches a known action with the caller's caps). The precedent for
   exposing a capability to a consuming LLM agent as a tool (§5).

5. **Dispatch + per-instance CapBAC** (`kind/runtime.ex`:
   `lookup_behavior` → `instance_set_gate` → `authz_check`). `kb.query` /
   `kb.ingest` are gated here because `Behavior.Kb` declares them as distinct
   actions with distinct `required_caps` (§6).

6. **`passive`-actor isolation (RF-6)** — the mention-resolver / `:join` /
   receive-routing gates that make a data actor non-chat. KB is passive.

---

## 3. Placement: the options evaluated

### 3.1 Option A — KB-as-native-`plugin_kb` (Postgres FTS) — RECOMMENDED (MVP)

A native Elixir `plugin_kb` (the lead is fine with the name) declaring a `kb`
Role × the `native` flavor on `Entity.Agent`. The plugin owns:
- a **Postgres corpus table** (`kb_chunks`) with a `tsvector` FTS column,
- a thin **`Behavior.Kb`** with `:kb_ingest` (write) and `:kb_query` (read)
  actions backed by Ecto queries,
- a **kb MCP tool** so LLM agents can call `kb_query`,
- a **`kb-source` FsResolver type** for source-doc reads at ingest.

**Pros**
- **Lightest viable retrieval.** Postgres FTS is built into the DB the platform
  already runs. The MVP is ONE Ecto migration + a thin Behavior + an MCP tool +
  a resource-type registration. **No Python, no subprocess, no uv-install, no
  chromadb/faiss, no local model, no new heavy dep.**
- **Persistence is free + transactional.** Chunks are Postgres rows; they
  survive BEAM/agent restart with zero extra wiring (no config_dir index to
  reopen, no cold-load respawn hole, no atomic-write hand-rolling — the DB does
  it). This is strictly simpler than the rev-1 on-disk-index persistence story.
- **In-process, in the BEAM.** `Behavior.Kb` runs in the agent Kind's dispatch
  process and talks to `EzagentCore.Repo` directly — no JSON-RPC round-trip, no
  `:in_process_sync` transport, no subprocess to keep alive.
- **Reuses role-foundation + native flavor wholesale** (the kanban-as-role
  path) — per-instance behavior load (RF-1), native CapMint policy (RF-8),
  list-by-role (RF-7), passive isolation (RF-6).
- **Clean upgrade seam to semantic.** The consumer contract (the kb MCP tool +
  `kb.query` dispatch action, §5) is stable; swapping the FTS query for a
  pgvector ANN query behind it is a storage-layer change, not a consumer change
  (§3.3).

**Cons / risks — and how this SPEC resolves each**

| Risk | Resolution |
|---|---|
| **Keyword-only retrieval quality** | FTS is lexical, not semantic — it misses synonyms/paraphrase. That is the *accepted MVP limitation* and the explicit trigger for the `vec-kb` upgrade (§3.3). For many KBs (docs, code, structured text) keyword retrieval is genuinely sufficient; start there, measure, promote if needed. |
| **Corpus table tenancy** | `kb_chunks` carries `workspace_uri NOT NULL` (invariant #14) + the per-tenant isolation gates, and a `kb_agent_uri` (owning kb-agent) column. Rows are scoped to the owning kb-agent + workspace; queries filter on both. |
| **Where the corpus lives vs Kind snapshot** | Unlike kanban (small tree = Kind snapshot), a KB corpus is a queryable table — it lives in Postgres rows, NOT the agent's Kind snapshot. The agent's snapshot holds only lightweight `last_*` observability + config (chunk size, k). See §4.3. |
| **How OTHER agents query it** | **kb MCP tool** for the LLM-consumer (recommended), agent-to-agent **dispatch** as the universal back end (§5). Both gate `kb.query` / `kb.ingest` through CapBAC. |
| **Ingest path** | A distinct **`kb.ingest`** cap + action reads the source via FsResolver (cap-gated, traversal/symlink-guarded), chunks, and INSERTs rows; FTS `tsvector` is a generated/triggered column so indexing is automatic. See §4.4. |
| **Concurrency** | Postgres handles concurrent reads/writes natively (MVCC + the `GIN` index). No single-subprocess serialization bottleneck (a rev-1 con that simply disappears on the native path). |
| **Security** | No subprocess + no arbitrary-code surface at all (the rev-1 np-whitelist concern is moot). The remaining surface is the ingest FS read (FsResolver R-1..R-4 + symlink guard) and SQL safety (Ecto parameterized queries — never string-built `tsquery`). See §6. |

### 3.2 Option B — KB-as-`py`-role (chromadb / sentence-transformers) — WITHDRAWN

The rev-1 recommendation: a `kb` py-role holding a chromadb/faiss index +
sentence-transformers in a per-agent Python subprocess.

**Why withdrawn (lead-decided 2026-06-26):**
- **Far too heavy for a starting capability.** It stands up a Python subprocess
  per kb-agent, a uv-install of hundreds of MB of ML deps, a local embedding
  model download, and an on-disk vector store — to do retrieval the existing
  Postgres can do natively for keyword (FTS, zero deps) and natively for
  semantic (pgvector + an embedding *API*, no local model).
- **Re-invents persistence the DB already gives.** The rev-1 on-disk-index
  persistence story (config_dir reopen, atomic writes, corrupt-index handling,
  cold-load degraded path — codex must-fixes #3/#4) all evaporate when chunks
  are Postgres rows.
- **A subprocess security surface for no benefit.** np-whitelist confinement,
  FS confinement of the Python process, dep/model supply chain (codex
  must-fix #5) — all gone on the native path.

The ML ecosystem being "native to Python" is a real fact, but it does NOT apply
to the MVP (FTS needs no ML) and is satisfied for the upgrade tier by an
embedding **API** (the model runs at the provider, the BEAM just stores the
returned vector in pgvector). A local Python ML stack is only justified if we
ever need *offline / in-house* embeddings at scale — a far-future, not-MVP
concern. **Do not build the py-role KB.**

### 3.3 Option C — `vec-kb`: pgvector + embedding-API (the SEMANTIC UPGRADE tier, not MVP)

When keyword FTS proves insufficient (synonym/paraphrase misses matter),
upgrade `kb` → `vec-kb` **in the same Postgres, same plugin, same consumer
contract**:
- Enable the **pgvector** extension (per-DB `CREATE EXTENSION vector`); add a
  `vector` column to `kb_chunks` (or a sibling table) + an ANN index
  (`ivfflat`/`hnsw`).
- At ingest, call an **embedding API** (the model runs at the provider; routed
  through the existing credential cascade) and store the returned vector. At
  query, embed the query string via the same API and run a pgvector
  nearest-neighbour search.
- **No local sentence-transformers, no chromadb/faiss, no Python.** pgvector is
  a Postgres extension; the only Elixir touch is a thin vector type + the API
  client (which the platform's credential infra already supports for other LLM
  calls).

This is *far lighter* than chromadb/faiss because it reuses the DB and offloads
the model to an API. The consumer (kb MCP tool + `kb.query` action) is
unchanged — `vec-kb` is a storage/scoring swap behind a stable seam, optionally
a **hybrid** (FTS prefilter + vector re-rank) without touching consumers.

### 3.4 Option D — standalone `ezagent_domain_kb` (DEFERRED)

A dedicated domain app owning KB as a first-class concern.

**When it would be justified (the gate to promote):**
- **Independent KB lifecycle** — KBs created/versioned/retired decoupled from
  agents (a curated index is a long-lived shared asset).
- **Cross-workspace / cross-agent governance** — many agents share one curated
  KB with per-source ACLs, retention, audited retrieval; the KB outlives any
  agent.
- **A separate scaling axis** — ingest/query scale independently of agent count
  (dedicated index servers, sharding, replicas).

None is true for retrieval-first MVP, where a KB is one agent's corpus. Per the
three-tier rule + YAGNI, defer. The migration is non-destructive: the consumer
contract (§5) is the stable seam; behind it the corpus can move FTS → pgvector
→ a dedicated domain without consuming agents changing.

> **Note on `plugin_kb` vs `domain_kb`.** The MVP is a **plugin** (owns the
> Behavior + tables + MCP tool + resource type) — NOT a domain. A domain
> (Option D) is promoted only at the governance/lifecycle gate above. The
> per-tenant `kb_chunks` table living under `ezagent_core` migrations (where all
> migrations live) does not make it core-tier logic — the *ownership* (schema,
> behavior, MCP tool) is the plugin's; the migration file location is a repo
> convention. (The plan must confirm a plugin-owned schema is acceptable under
> the three-tier rules, or pick the sanctioned home for plugin tables.)

### 3.5 Decision summary

```
starting KB (retrieval-first, MVP) = role `kb` × flavor `native` on Entity.Agent
  owned by                = a native Elixir plugin (plugin_kb)
  retrieval               = Postgres FTS (tsvector/tsquery via Ecto) — KEYWORD
  corpus storage          = Postgres table kb_chunks (workspace_uri NOT NULL, GIN)
  embeddings / Python     = NONE (FTS MVP)
  source-doc reads        = resource:// kb-source type via FsResolver (cap-gated)
  consumption (LLM agent) = kb MCP tool (recommended); dispatch = universal back end
  cap model               = kb.query (read) ≠ kb.ingest (write), fail-closed
  persistence             = Postgres rows (transactional, free across restart)
  passive                 = true (RF-6: not @-mentionable/joinable/chat-receiving)
UPGRADE: vec-kb = pgvector extension + embedding API (NOT chromadb/faiss/local model),
         same DB + same consumer contract; promote when keyword retrieval insufficient.
WITHDRAWN: py-role + chromadb + sentence-transformers (too heavy; rev-1).
DEFER: domain_kb until independent lifecycle / cross-ws governance / separate scaling.
```

### 3.6 The MVP delta (what is NEW vs reused) — honest cost

Reused wholesale (zero new code): `EzagentCore.Repo` + Postgres FTS built-ins,
the `native` flavor + role-foundation (RF-1/4/5a/6/7/8) the kanban path already
exercises, the FsResolver seam, the MCP transport pattern, dispatch + CapBAC.
**What the MVP must NEWLY build:**

| New artifact | Tier | ~Size | Why |
|---|---|---|---|
| `kb_chunks` Ecto migration (`tsvector` + `GIN` + `workspace_uri`) | core migration | tiny | the corpus table; FTS column generated/triggered |
| `Behavior.Kb` (`:kb_query` / `:kb_ingest`) + Ecto queries | plugin Elixir | thin | two cap-distinct dispatch actions over the table |
| `kb` role recipe + `roles/0` registration | plugin Elixir | tiny | recipe = `[Behavior.Kb]`, passive, requested caps |
| `native` CapMint policy entry for the kb caps | plugin Elixir | tiny | fail-closed grant of `kb.query`/`kb.ingest` (RF-8) |
| kb MCP tool (`kb_query`/`kb_ingest`) | cc/plugin Elixir | small | the MCP catalog is FIXED — KB tools are new entries (§5.3) |
| `kb-source` FsResolver type + source storage path | core registration + plugin | tiny | ingest reads the source doc (§4.4) |

Pure Elixir, no Python, no heavy dep — and meaningfully smaller than rev-1
(no `kb.py`, no vector backend, no model packaging, no subprocess lifecycle).

---

## 4. Recommended design — native FTS

### 4.1 The recipe (`kb`)

`Ezagent.Role` recipe, code-seeded via a `roles/0` callback on `plugin_kb`:

```elixir
%{
  name: "kb",
  passive: true,                       # RF-6: data actor, not a chat principal
  behaviors: [Ezagent.Behavior.Kb],    # the FTS state half — :kb_query + :kb_ingest
  requested_caps: [                    # §6 — fail-closed; granted by native CapMint policy
    %{behavior: Ezagent.Behavior.Kb, action: :kb_query},
    %{behavior: Ezagent.Behavior.Kb, action: :kb_ingest}
  ],
  session_template: nil
}
```

Composed via `Role.Compose.materialize(recipe, :native)` at create (the kanban
path); the `native` flavor's CapMint policy (RF-8) grants exactly the requested
caps (fail-closed). No `script`, no config_dir, no subprocess — `native` host
is `Entity.Agent` with the kb behaviors loaded per-instance (RF-1).

> **Gate (inherited from kanban-as-role HIGH-1):** `effective_set/2` intersects
> with the host Kind's declared `behaviors_of/1`, and `instance_set_gate` only
> admits DECLARED behaviors. So the `native` flavor's host Kind
> (`Entity.Agent`) must DECLARE `Behavior.Kb` in its `behaviors/0` (the same
> constraint kanban's behaviors hit). The plan must wire this declaration.

### 4.2 The corpus table (`kb_chunks`)

One Ecto migration under `apps/ezagent_core/priv/repo/migrations/`:

- columns: `id`, `workspace_uri` (NOT NULL — invariant #14), `kb_agent_uri`
  (the owning kb-agent instance), `source_uri` (provenance — the
  `resource://…/kb-source/…` it came from), `chunk_index`, `text`, and an FTS
  column.
- **FTS column**: a `tsvector` — either a `GENERATED ALWAYS AS
  (to_tsvector('english', text)) STORED` generated column (cleanest), or a
  trigger-maintained column. Indexed with a **`GIN`** index for fast
  `@@ tsquery` search.
- per-tenant isolation: every query filters `workspace_uri` + `kb_agent_uri`;
  the table satisfies the per-tenant gates like other phase-9 tables.

(For the `vec-kb` upgrade: add a `vector` column + an ANN index in a follow-up
migration; no change to the FTS columns.)

### 4.3 Persistence (free)

The corpus is Postgres rows — durable + transactional by construction. An agent
restart, supervisor restart, or BEAM cold-load loses nothing: `Behavior.Kb`
queries `EzagentCore.Repo` on each action; there is no in-memory index to
rebuild, no config_dir to reopen, no atomic-write or corrupt-index handling to
hand-roll. The agent's Kind snapshot persists only lightweight config
(`chunk_size`, default `k`) + `last_*` observability — never the corpus. **This
is the single biggest simplification vs the rev-1 py path** (which had a whole
on-disk-index persistence sub-problem; here it is just "rows in a table").

### 4.4 Ingest path (source docs via `resource://` + FsResolver)

Ingest takes a **source reference**, not raw bytes inline (inline is fine for
tiny test docs but bypasses the FS auth seam). The source lives as
`resource://<ws>/kb-source/<name>`:

- Register a **`kb-source` type** in `FsResolver.Registry.boot_registrations/0`
  (R-1 immutable allowlist) with a per-type `authority/2` asserting the URI's
  `<ws>` is authoritative for the ingesting caller's scope (R-3), backed by a
  `Home` component (R-4); traversal rejected by R-2.
- `Behavior.Kb`'s `:kb_ingest` handler resolves the source URI → authorized
  on-disk path via `FsResolver.resolve/2` under the caller's authenticated
  scope (NEVER from the URI being resolved), **realpath-checks against symlink
  escape** (§6), reads the bytes, chunks (a simple size/overlap chunker for
  MVP), and `Repo.insert_all`s the rows. The `tsvector` is auto-maintained
  (generated/trigger), so indexing needs no extra step.
- **One source's lifecycle (in scope even though many-source MANAGEMENT is
  deferred):** re-ingesting an existing `source_uri` **replaces** that source's
  rows (`DELETE WHERE source_uri = … ; INSERT …` in one transaction) — keyed by
  `source_uri`, idempotent, no silent duplication. Deferred: the management
  surface over many sources (list/refresh/orphan GC).

### 4.5 Query path

`:kb_query` (read) takes a query string + optional `k`:
- builds a `tsquery` via **`plainto_tsquery`** (or `websearch_to_tsquery`) — a
  **parameterized** Ecto fragment, never string-concatenated (SQL-injection
  safe, §6),
- runs `WHERE fts @@ query AND workspace_uri = … AND kb_agent_uri = …`
  ORDER BY `ts_rank(fts, query)` DESC LIMIT k,
- returns top-k **hits with provenance**: `%{text, score, source_uri,
  chunk_id}` (§5.4).

### 4.6 Behaviors — one thin `Behavior.Kb` (the cap split requires it)

Two cap-distinct actions so a query-only consumer cannot mutate the corpus:

- `:kb_query` (cap `kb.query`, mode `:call`) and `:kb_ingest` (cap `kb.ingest`,
  mode `:call`) — two actions, two caps, so **CapBAC gates ingest vs query at
  the dispatch layer** (`kind/runtime.ex` `instance_set_gate` → `authz_check`),
  where caps are actually checked.
- Each handler is **thin**: it runs an Ecto query against `EzagentCore.Repo`
  and persists the lightweight `last_*` result. No subprocess, no JSON-RPC.
- `Behavior.Kb` declares `required_caps/0` (`kb_query`/`kb_ingest`) +
  `data_owner/1` per the caps-data-ownership contract.

A single chat-`receive` path was rejected: it gives only one cap and collapses
the read/write distinction — the one security property that must hold even at
MVP.

---

## 5. How an agent CONSUMES KB

### 5.1 The options

- **kb MCP tool** — expose `kb_query` (and, cap permitting, `kb_ingest`) as MCP
  tools the consuming LLM agent calls, via the established MCP transport pattern
  (transport holds zero authority; the dispatch into the kb-agent carries the
  caller's caps).
- **Agent-to-agent dispatch** — the consumer dispatches
  `entity://<ws>/agent/<kb-instance>?action=kb.query` directly
  (`Ezagent.Invocation.dispatch/1`) — the universal native path (kanban reads
  its board via dispatch).

### 5.2 Recommendation

**For the LLM-agent consumer (the primary RAG use case): the kb MCP tool.** An
LLM agent already speaks MCP; surfacing `kb_query` as a typed tool lets the
model decide *when* to retrieve, without the platform injecting retrieval into
the prompt pipeline. **Agent-to-agent dispatch is the universal back end** — the
MCP tool dispatches `kb.query` *through* it. Non-LLM callers (a view, a batch
job, another behavior) use dispatch directly. Both gate `kb.query` / `kb.ingest`
through CapBAC.

### 5.3 The MCP surface is NEW WORK (not free)

`Ezagent.Orchestrator.McpServer` is a **fixed tool catalog** — it dispatches
only known tool atoms, NOT a generic dispatch-to-any-action adapter. So the MVP
must NEWLY register `kb_query` / `kb_ingest` as catalog entries whose executor
dispatches the `kb.*` action into the kb-agent, threading the caller URI + caps.
Whether the KB tools live in the orchestrator catalog or in a KB-scoped MCP
server is a plan decision.

### 5.4 Result schema (define the minimum now)

`kb.query` returns top-k hits with provenance: each hit is
`%{text: chunk, score: float, source_uri: "resource://…/kb-source/…",
chunk_id: id}`. Provenance is non-negotiable even at MVP — a RAG consumer must
cite/trace, and it makes later source-management/governance possible without
re-ingest. (`score` is `ts_rank` for FTS; for `vec-kb` it becomes the vector
similarity — same field, different scorer.)

---

## 6. Cap model + security

### 6.1 Caps (fail-closed, separated by mutation)

- **`kb.query`** — read: query → top-k. Granted to consumers.
- **`kb.ingest`** — write: add a source. A distinct cap so a query-only
  consumer cannot mutate the corpus.

Caps are **requested** in the recipe and **granted** by the `native` flavor's
CapMint policy (RF-8, fail-closed: only requested `{behavior, action}` pairs
pass) at `Workspace.grant_initial_caps` (the granter-context layer).

### 6.2 Security model (native — far smaller surface than the py path)

The native path **eliminates** the rev-1 subprocess attack surface entirely (no
Python, no arbitrary-code risk, no dep/model supply chain, no FS confinement of
a subprocess). The remaining surface:

- **SQL safety.** The `tsquery` is built via a **parameterized** Ecto fragment
  (`plainto_tsquery`/`websearch_to_tsquery` with a bound parameter) — the query
  string is data, NEVER string-concatenated into SQL. No raw `tsquery` parsing
  of user input as SQL.
- **Source FS reads (ingest).** FsResolver R-1..R-4 authorize the source path in
  Elixir (scope from the caller's authenticated context, never the URI), R-2
  rejects traversal, **and the ingest read realpath-checks the resolved file to
  reject a `kb-source` that is a SYMLINK escaping the backend root.**
- **Tenancy.** Every query/ingest filters `workspace_uri` + `kb_agent_uri`; no
  cross-tenant corpus access. The table carries `workspace_uri NOT NULL`
  (invariant #14) and rides the per-tenant isolation gates.
- **Ingest bounds.** A max source size + max chunks per ingest, so a
  pathological doc cannot exhaust the DB / connection pool.
- **Poisoned-document / prompt-injection.** Retrieved chunks are fed to an LLM
  consumer; a malicious ingested doc can carry instructions. MVP carries
  provenance (§5.4) so the consumer can attribute/distrust, and treats retrieved
  text as untrusted data in prompt assembly — stated as a known limitation, not
  solved.
- **(vec-kb tier only)** an embedding-API credential + egress — routed through
  the existing credential cascade; no new secret-handling pattern.

---

## 7. Explicitly deferred

| Deferred | Why deferred | When to revisit |
|---|---|---|
| **`vec-kb` semantic (pgvector + embedding API)** | keyword FTS is the lightest MVP; embeddings cost an API + an extension | keyword retrieval proves insufficient (synonym/paraphrase misses) |
| **py-role + chromadb/faiss + local model** | WITHDRAWN — too heavy; Postgres does FTS natively + pgvector does vectors natively | only if offline/in-house embeddings at scale are ever required |
| **`domain_kb` (Option D)** | YAGNI; a starting KB is one agent's corpus | independent KB lifecycle / cross-ws governance / separate scaling axis |
| **source-management** (list/refresh/dedupe MANY sources) | not needed to prove retrieval — single-source create/overwrite IS in scope (§4.4) | when KBs accrete many sources operators must curate |
| **re-index / migration** | one analyzer/config for MVP | changing the FTS config or embedding model on a populated KB |
| **governance** (per-source ACL, retention, retrieval audit) | the cap split (query≠ingest) + tenancy is enough for MVP | cross-agent shared KB (= the domain trigger) |
| **hybrid (FTS+vector) / re-ranking / federation** | top-k FTS is the MVP | retrieval-quality tuning phase (lands naturally with vec-kb) |
| **auto-RAG prompt injection** | model-asks-via-MCP is the MVP | prompt-pipeline phase |

---

## 8. Test plan

The acceptance gate must *fail* if the architectural claims are unmet:

1. **Round-trip (the core).** Create a `kb`×`native` agent → ingest a known doc
   → `kb.query` with terms in the doc → assert the top-k hit contains the
   expected chunk + provenance. (Proves chunk + store + FTS retrieve.)
2. **Persistence across restart.** Ingest → restart the agent (supervisor + a
   cold-load path) → query → content STILL retrievable. (Trivially true on the
   native path since it's Postgres rows — the test asserts no in-memory
   dependency crept in.)
3. **Cap separation.** A consumer with only `kb.query` is REFUSED `kb.ingest`
   (`:cap_denied`); neither → both refused. (Fail-closed + mutation separation.)
4. **Source authority + symlink (FsResolver).** Ingesting
   `resource://victimWS/kb-source/x` under attacker scope fails R-3; a `..`
   segment fails R-2 before any backend touch; a symlinked source escaping the
   backend root is rejected (§6 realpath check).
4b. **Re-ingest = replace.** Ingest source `<name>` twice → query returns ONE
   copy of each chunk (DELETE-by-source_uri then INSERT, §4.4).
4c. **Result schema + provenance.** `kb.query` hits carry `source_uri` +
   `score` + `chunk_id` (§5.4).
4d. **SQL safety.** A query string containing `tsquery`/SQL metacharacters
   (`' OR 1=1`, `& | !`) is treated as DATA (parameterized) — no error, no
   injection; returns lexical matches only.
5. **Tenancy.** Two kb-agents in different workspaces with overlapping content
   → each query returns only its own workspace's chunks.
6. **Passive isolation (RF-6).** The kb-agent is NOT @-mentionable, NOT
   `:join`-able, does NOT receive ambient chat — only `kb.*` dispatch + the MCP
   tool reach it.
7. **MCP consumption.** An LLM-shaped consumer reaches `kb_query` via the MCP
   tool, which dispatches `kb.query` into the kb-agent with the caller's caps
   (transport holds none).
8. **No Python / no heavy dep / no new Kind/domain.** An arch/grep gate
   asserting MVP adds no Python subprocess, no chromadb/faiss, no new Kind, no
   new domain (the "starting KB is native FTS in a plugin" invariant).

Live e2e (agent-browser sign-off): create a kb-agent, ingest a doc via CLI/UI,
query, screenshot the retrieved result.

---

## 9. Open questions for the lead

1. **Retrieval tier for MVP — FTS-only, or FTS + the `vec-kb` upgrade
   immediately?** Recommendation: **FTS-only MVP** (no embeddings at all — the
   lightest path, matches "kb not vec-kb"). The embedding question is therefore
   "**embedding API vs NONE**": MVP = none; `vec-kb` (when promoted) = an
   embedding **API call** (never a local model / sentence-transformers).
   Confirm FTS-only start.
2. **Vector backend (for the eventual upgrade): pgvector — confirmed.** pgvector
   (Postgres extension, same DB) is recommended; chromadb/faiss are off the
   table unless we ever LEAVE Postgres. Confirm pgvector is the semantic path.
3. **`plugin_kb` vs `plugin_veckb` naming + scope.** Recommendation: name it
   `plugin_kb`, with the `vec-kb` semantic tier as a later capability INSIDE the
   same plugin (same tables, same consumer contract) rather than a separate
   plugin. OK, or do you want a distinct `plugin_veckb` for the semantic tier?
4. **FTS config (analyzer/language) — flag: bilingual content.** MVP uses
   Postgres `'english'` text-search config, which does NOT segment Chinese (CJK
   has no whitespace word boundaries, so `to_tsvector('english', …)` indexes
   Chinese poorly). Given the team's content is often bilingual (EN + zh_cn),
   the plan likely needs the `'simple'` config + n-gram, or the `zhparser`/
   `pg_jieba` extension, for Chinese. Decide: English-only MVP (defer CJK), or
   bilingual from the start (adds a Postgres extension — still no Python)?
5. **Corpus table placement + multi-KB-per-workspace.** `kb_chunks` keyed by
   `kb_agent_uri` + `workspace_uri` supports many kb-agents per workspace.
   Confirm one-KB-per-agent is the MVP unit (a kb-agent = a KB), so "create a KB"
   = "create a kb×native agent". Also: is a plugin-owned schema (table under
   core migrations, logic in the plugin) acceptable, or is there a sanctioned
   home for plugin-owned tables?
6. **/goal acceptance criteria** — Allen to set; §8 is the proposed superset.
   Confirm the tenancy (§8.5) + cap-separation (§8.3) + SQL-safety (§8.4d) tests
   are load-bearing.

```
kb-retrieval-first 完成 = role kb × flavor native on Entity.Agent（native plugin_kb，Postgres FTS）：
1. kb role recipe（[Behavior.Kb] + kb.query/kb.ingest caps + passive:true）经 roles/0 注册；
   native flavor 经现有 create 路径 per-instance 加载（kanban-as-role 同一条路；host Kind 声明 Behavior.Kb）。
2. kb_chunks 表（tsvector + GIN + workspace_uri NOT NULL）经 Ecto migration 建立；
   ingest 一篇文档 → kb.query（tsquery/ts_rank）返回 top-k 命中 + provenance。
3. 持久化 = Postgres rows（重启零丢失，无内存索引）；NO Python / NO embeddings / NO 新重依赖。
4. cap 分离：kb.query ≠ kb.ingest，fail-closed；FsResolver source 鉴权 (R-1..R-4) + symlink 防护；
   SQL 安全（参数化 tsquery）；tenancy（workspace_uri 过滤）。
5. passive 隔离 (RF-6 三闸)；kb MCP tool 消费（transport 零授权）；dispatch 为通用后端。
6. MVP 不引入 Python / chromadb / faiss / 本地模型 / 新 Kind / 新 domain。
验收：全量 mix test 0 失败 + CI 绿；live e2e（agent-browser）create+ingest+query+截图。
UPGRADE: vec-kb = pgvector + embedding API（非 chromadb/faiss/本地模型），同库同契约。
DEFER: domain_kb、source-mgmt(many)、re-index、governance、hybrid/re-rank。
```

---

## 10. Revision + codex-review record

**rev 2 (2026-06-26) — placement reworked to native Postgres (lead direction).**
The rev-1 py-role + chromadb + sentence-transformers recommendation is
WITHDRAWN as too heavy. Ground truth verified: `ezagent_core` deps `postgrex` +
`ecto_sql ~> 3.13`; `EzagentCore.Repo` = `Ecto.Adapters.Postgres`; zero
`tsvector`/`pgvector` on `origin/main` (genuine greenfield). New recommendation:
**Postgres FTS native (`plugin_kb`, role kb × flavor native) for the keyword
MVP — no Python, no embeddings, no new heavy dep**; **pgvector + embedding-API
as the semantic `vec-kb` upgrade tier** (not chromadb/faiss/local model). The
cap split (`kb.query` ≠ `kb.ingest`), MCP-tool consumption, FsResolver source
reads, passive isolation, and result-schema provenance are carried over from
rev 1; the persistence / subprocess-security / dep-supply-chain concerns that
dominated the rev-1 codex review are **dissolved** by the native path (corpus =
Postgres rows; no subprocess).

> rev-1 (withdrawn) codex verdict was accept-with-changes on the py path; this
> rev replaces the placement entirely, so a fresh codex adversarial-review of
> the native design was run — outcome recorded below.

### Codex adversarial-review (rev 2, 2026-06-26)

_(populated after the codex run — see report)_
