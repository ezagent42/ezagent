# SPEC — Starting KB (knowledge-base) capability — retrieval-first

> **Status: design doc, NOT implementation.** Resolves the lead's placement
> question for a *starting* KB capability. Centered on **WHERE** KB lives, not
> the full ingest/governance lifecycle. Built on the **role-foundation**
> (`docs/together/2026-06-25/specs/role-foundation-design.md`, on main) and the
> **py flavor** (`apps/ezagent_plugin_py`, py-agent P4/P4b, on main). Next:
> codex adversarial-review of this doc → (if accepted) plan → implement.

## 0. The lead's question, answered up front

> **"Can KB be built directly on a py-agent (retrieval-only for now)? Or
> directly on the native `Entity.Agent`?"**

**Recommendation: build the starting KB as a `kb` ROLE on the `py` flavor of the
unified `Entity.Agent` Kind** — i.e. Option 1, the lead's lean. This is NOT a
third thing alongside "py-agent" and "native Entity.Agent": on `main` a py-agent
**already IS** the unified `Entity.Agent` (P4b folded `py` onto `Entity.Agent`,
curl precedent), and a *role* is what fills that agent's sandbox. So the two
options the lead phrased as alternatives are actually one axis:

- **flavor = `py`** (HOW it executes): a per-agent `Ezagent.Domain.Python`
  subprocess, so the embedding/vector libraries run native to Python.
- **role = `kb`** (WHAT it does): an operator-authored `agent.py` holding a
  vector index + an embed/query path, plus its requested caps and a behavior
  subset — composed onto `Entity.Agent` exactly the way **`np` already is a
  py-role today** (`apps/ezagent_plugin_py/priv/python/np.py`).

The "native `Entity.Agent`" option the lead names (Option 2) means flavor =
`native` (in-BEAM, pgvector). We recommend **against** it for the *starting*
capability (analysis in §3.2). A standalone `ezagent_domain_kb` (Option 3) is
**explicitly deferred** (§3.3).

This is the **same resolution Allen already reached for kanban**
(`kanban-as-role-spec.md`, 2026-06-25): a non-chat capability becomes
*role × flavor on `Entity.Agent`*, never its own Kind. KB is the embedding/
retrieval instance of that pattern; the only flavor difference is kanban chose
`native` (pure-BEAM state) and KB chooses `py` (the ML ecosystem lives in
Python).

---

## 1. North star + scope

### 1.1 What we are building

A **retrieval-first** KB: an agent you can (a) feed documents to and (b) ask a
natural-language query, getting back the top-k most relevant chunks. Nothing
more. This is the minimum that delivers RAG to the rest of the platform and the
biggest true greenfield parity gap — there is **no pgvector / embedding / RAG
anywhere in the repo today** (verified: zero hits for `pgvector`, embedding, or
a vector-index dependency on `origin/main`).

### 1.2 MVP scope (retrieval-only)

| In scope (MVP) | Out of scope (deferred — §7) |
|---|---|
| **ingest** one doc (text/markdown) into the index | source-management (list/dedupe/refresh sources) |
| **embed** the doc's chunks (one embedding model) | **re-index** / model-swap / migration |
| **query**: NL question → top-k chunk hits | governance (per-source ACLs, retention, audit of retrieval) |
| persistence of the index across BEAM/subprocess restart | hybrid / re-ranking / multi-index federation |
| one consuming agent reaching KB (the recommended path, §5) | cross-workspace KB sharing |
| caps gating ingest vs query separately | streaming / incremental re-embed on doc edit |

The defer list is deliberately the *governance + lifecycle* surface — exactly
what would justify a `domain_kb` later (§3.3). Keeping it out is what lets the
starting KB be a role, not a domain.

### 1.3 Non-goals

- Not an Elixir-native vector store. The ML ecosystem
  (`sentence-transformers` / `faiss` / `chromadb`) is Python's; we reuse it
  rather than reimplement embeddings/ANN in the BEAM.
- Not a new URI scheme, not a new Kind, not a new domain app.

---

## 2. What already exists we build on (verified on origin/main)

Reuse, don't rebuild. Every piece the starting KB needs is on `main`:

1. **The `py` flavor on the unified `Entity.Agent`**
   (`apps/ezagent_plugin_py`). It is the GENERAL script-driven Python host: a
   per-agent `Ezagent.Domain.Python` subprocess (one per agent Kind, keyed by
   the agent URI), driven by a single JSON-RPC `receive` method
   (`EzagentPluginPy.BridgeAdapter`, transport class `:in_process_sync`). The
   STATE half is `Ezagent.Behavior.PyAgent` (`:py_sync_result` persists
   `last_*` + replies into the session; `:py_reset` / `:py_configure`); the
   subprocess self-heals on every start via `activate/2` →
   `AgentLifecycle.ensure_alive/1`. **`np` is already a py-role** doing
   whitelisted compute — KB is the same shape with a different script + caps.

2. **`Ezagent.Role` + `Ezagent.RoleRegistry` (#54, role-foundation).** A Role is
   the **flavor-agnostic sandbox-content recipe**: `script`, `skills`,
   `plugins`, `prompt`, `behaviors`, `requested_caps`, `session_template`, and a
   `passive` flag. `RoleRegistry.register/1` seeds a code-declared role via the
   `roles/0` plugin callback (the `OrchestratorRole.recipe/0` exemplar). KB =
   one more recipe.

3. **The py create-time config_dir + script channel**
   (`Ezagent.Template.PyAgent`). py is the first non-credentialled flavor that
   ALLOCATES a per-agent `config_dir` (`<Home>/py-agents/<ws>/<name>/`) via the
   canonical `provision_and_instantiate` seam, and writes the operator script to
   `<dir>/agent.py` at create. **The installed dir is the natural home for the
   KB's persisted index** (§4). Script is **immutable post-create**
   (`install_script/2` refuses a differing rewrite with `:script_immutable`) —
   the injection gate is reused for free.

4. **`Ezagent.Resource.FsResolver` (`resource://<ws>/<type>/<name>`).** The
   hardened, registration-only, authorization-bearing FS seam (R-1 closed
   allowlist, R-2 traversal guard, R-3 caller-scope authority, R-4 Home is the
   backend). The place to register a `kb-source` type when ingest needs to read
   operator-supplied **source documents** by URI (§4.3). Note: FsResolver is for
   *source bytes addressed by URI*, NOT for the vector index itself — see §4 for
   why those differ.

5. **The MCP transport pattern** (`Ezagent.Orchestrator.McpServer` — pure
   transport, zero authority; `tools/call` → decode → SessionManager →
   bridge-token-verified `run_tool`). The precedent for exposing a capability to
   a consuming LLM agent as a tool (§5).

6. **`passive`-actor isolation (RF-6)** — the mention-resolver / `:join` /
   receive-routing gates that make a data actor non-chat. KB is passive.

---

## 3. Placement: the three options evaluated

### 3.1 Option 1 — KB-as-`py`-role (RECOMMENDED)

A `kb` Role (`Ezagent.Role` recipe) composed onto the `py` flavor of
`Entity.Agent`. The recipe's `script` is `kb.py`: a Python script holding the
vector index in process, registering the `receive` entrypoint that branches
ingest vs query (the np `pick_method` precedent — the chat→method heuristic
lives IN the script). Persistence + consumption + caps detailed in §4–§6.

**Pros**
- **Fastest to working retrieval.** Nothing new in Elixir. `np` proves the
  whole flavor path (create → config_dir → script → subprocess → `receive` →
  reply) works end-to-end today; KB swaps the script + caps.
- **ML libs are native.** `sentence-transformers` / `faiss` / `chromadb` are
  the mature, maintained stack and they are *Python*. We meet them where they
  live (uv installs deps from the script's `# /// script` header, like np pulls
  numpy/sympy).
- **Reuses the role-foundation + py flavor wholesale.** The recipe model, the
  per-agent config_dir, the script-immutability injection gate, the
  subprocess self-heal, the passive-actor gates — all already merged.
- **Zero Elixir vector infra.** No pgvector dep, no new migration, no
  per-tenant vector table to add to the `workspace_uri NOT NULL` invariant set.
- **Symmetric with kanban-as-role.** One consistent answer ("non-chat
  capability = role × flavor on `Entity.Agent`") rather than a special case.

**Cons / risks — and how this SPEC resolves each**

| Risk | Resolution |
|---|---|
| **Where does the index live?** | The per-agent **`config_dir`** (`<Home>/py-agents/<ws>/<name>/`). The vector store (e.g. a chromadb persistent dir, or a faiss `.index` + a sidecar metadata file) writes under that dir. It is per-agent, tenant-scoped by construction, and already allocated by the py create seam. See §4. |
| **Persistence across restart** | The index is **on disk in config_dir**, not in BEAM snapshot. `activate/2` re-spawns the subprocess from the SAME installed script and SAME `cwd`/config_dir on every start (fresh / supervisor restart / cold load), so `kb.py` reopens the existing on-disk index. The BEAM Kind snapshot persists only lightweight `last_*` metadata, never the vectors. See §4.2. **This is the one genuinely new sub-problem vs np** (np is stateless across calls; KB carries durable on-disk state) — §4.2 + the test plan §6 nail it. |
| **How do OTHER agents query it?** | **MCP tool, recommended over agent-to-agent dispatch** for the LLM-consumer case; agent-to-agent dispatch remains the native path for non-LLM callers. See §5 for the decision + rationale. |
| **Concurrency** | The `:in_process_sync` transport serializes `receive` calls through the agent's dispatch process + the single per-agent subprocess. MVP accepts serial ingest/query (one subprocess, one index, no shared mutable state across agents). Parallel query throughput is a deferred scaling concern (§7), addressable later by fronting multiple read-replica kb-agents. |
| **py subprocess security model** | The **np whitelist precedent governs ingest/query**, with one explicit extension: KB legitimately needs filesystem reads (the source doc) + heavy ML deps. The script does NOT `eval`/`exec` untrusted input; the embedding model + ANN library are the only compute; source reads go through a **bounded, cap-gated, traversal-checked path** (§4.3 + §6 security). The `MAX_INPUT_LEN` + Elixir-side `:rpc_timeout` + subprocess tear-down defenses from np carry over verbatim. |
| **Ingest path** | A distinct **`kb.ingest` cap** + a `receive` branch (or a dedicated method — §5.2) that takes a source ref, chunks + embeds + writes to the index. Separate cap from query so a query-only consumer can't mutate the index. See §4.3 + §6. |

### 3.2 Option 2 — KB-as-native-`Entity.Agent`-capability (in-BEAM, pgvector)

A `kb` role on the **`native`** flavor (kanban's flavor) + an Elixir
`Behavior.Kb` using pgvector for the vector column + ANN search.

**Pros**
- In-process, no subprocess, no JSON-RPC round-trip.
- Transactional with the DB; the index lives in Postgres alongside other
  tenant data.

**Cons (why we do NOT pick it for the starting capability)**
- **The embedding story is still Python anyway.** pgvector stores + searches
  vectors but does NOT *produce* them. You still need an embedding model, which
  in Elixir means either (a) calling an external embedding API (a network dep +
  credential cascade) or (b) `Bumblebee`/`Nx` + an ONNX/transformers model in
  the BEAM (heavy, immature for this use, and still not the maintained
  sentence-transformers stack). So Option 2 does NOT remove Python from the ML
  path — it splits it: Python (or an API) for embeddings, Postgres for storage.
  That is *more* moving parts than Option 1, not fewer.
- **Adds a pgvector dependency + a per-tenant vector table.** New extension,
  new migration, a new table that must satisfy invariant #14
  (`workspace_uri NOT NULL`) and the per-tenant isolation gates. Real Elixir
  infra to build and gate, for a *starting* capability.
- **Slower to first retrieval.** Building the Elixir behavior + pgvector schema
  + the embedding bridge is strictly more work than authoring `kb.py`.
- It is the **right destination if/when** transactional consistency with other
  BEAM state, or in-process query latency, become hard requirements — but those
  are not MVP requirements (§7 names the trigger).

**Verdict:** defer. Revisit when retrieval latency / transactionality with BEAM
state is a proven requirement, by which point pgvector is a targeted upgrade of
the storage layer behind a stable consumer contract (§5), not a from-scratch
build.

### 3.3 Option 3 — standalone `ezagent_domain_kb` (EXPLICITLY DEFERRED)

A dedicated domain app owning KB as a first-class concern (its own Kind(s),
lifecycle, scaling axis).

**When it would be justified (the gate to promote):**
- **Independent KB lifecycle** — KBs created/versioned/retired on a cadence
  decoupled from agents (an index is a long-lived shared asset, not one agent's
  sandbox).
- **Cross-workspace / cross-agent governance** — many agents share one
  curated KB with per-source ACLs, retention policy, and audited retrieval; the
  KB outlives any single agent.
- **A separate scaling axis** — ingest throughput and query QPS need to scale
  independently of agent count (dedicated index servers, sharding, replicas).

None of these is true for *retrieval-first MVP*, where a KB is exactly "one
agent's sandboxed index." Per the three-tier rule (`three-tier-structure.md`)
and YAGNI, a domain app is unjustified until the capability needs an identity
and lifecycle independent of the agent that holds it. **Do not build it yet.**
The migration path is non-destructive: the consumer contract (§5) is the stable
seam; behind it the index can move config_dir → pgvector → domain without the
consuming agents changing.

### 3.4 Decision summary

```
starting KB (retrieval-first) = role `kb` × flavor `py` on Entity.Agent
  index storage           = per-agent config_dir (on-disk vector store)
  source-doc reads        = resource:// kb-source type via FsResolver (cap-gated)
  consumption (LLM agent) = MCP tool (recommended); dispatch = native fallback
  embedding model         = local sentence-transformers (MVP); API = config option
  cap model               = kb.query (read) ≠ kb.ingest (write), fail-closed
  persistence             = on-disk index reopened by activate/2 re-spawn
  passive                 = true (RF-6: not @-mentionable/joinable/chat-receiving)
DEFER: native/pgvector (Opt 2) until latency/txn need; domain_kb (Opt 3) until
       independent lifecycle / cross-ws governance / separate scaling axis.
```

---

## 4. Recommended design — KB-as-`py`-role

### 4.1 The recipe (`kb`)

`Ezagent.Role` recipe, code-seeded via a `roles/0` callback on the py plugin
(or a small `ezagent_plugin_kb` that only *declares* the role — placement TBD
in the plan; the role is flavor-agnostic by construction so it can live with the
py plugin). Shape (illustrative):

```elixir
%{
  name: "kb",
  passive: true,                       # RF-6: data actor, not a chat principal
  script: <kb.py contents>,            # RF-5b content→config_dir channel
  behaviors: [],                       # see §4.4 — reuse PyAgent's state half
  requested_caps: [                    # §6 — fail-closed; minted by py CapPolicy
    %{behavior: Ezagent.Behavior.PyAgent, action: :py_sync_result},
    # + the kb-specific caps (kb.query / kb.ingest) — see §6
  ],
  session_template: nil
}
```

Composed via `Role.Compose.materialize(recipe, :py)` at create; the py flavor's
`EzagentPluginPy.CapPolicy.for_recipe/1` mints exactly the requested caps
(fail-closed — a cap the recipe didn't ask for is dropped). This is the
**identical mechanism `np` uses**; only the script + caps differ.

### 4.2 Index storage + persistence (the one new sub-problem)

- **Where:** the vector index persists **on disk under the agent's
  `config_dir`** (`<Home>/py-agents/<ws>/<name>/`). Concretely a chromadb
  persistent client rooted there, OR a faiss `index.faiss` + a `chunks.jsonl`
  metadata sidecar — the MVP picks ONE (recommend chromadb for the
  persist-and-reopen simplicity; faiss if we want to avoid a server-ish dep).
- **Why config_dir, not FsResolver, not BEAM snapshot:**
  - *Not BEAM snapshot* — vectors are large + binary; snapshotting them through
    the Kind would bloat every persist and defeat the point of an ANN library.
    The Kind snapshot persists only the lightweight `last_*` observability
    triple (np precedent), never the index.
  - *Not `resource://`/FsResolver* — FsResolver resolves **URI-addressed source
    bytes** for *callers naming a path*. The index is private subprocess-owned
    state the script writes/reads directly via its `cwd`; no external caller
    should name the raw index file. (FsResolver IS used for the *source docs*
    being ingested — §4.3.)
  - *config_dir* — already per-agent, already tenant-scoped, already allocated
    by the py create seam, already the `cwd` handed to the subprocess.
- **Reopen across restart:** `Behavior.PyAgent.activate/2` re-spawns the
  subprocess from the SAME `script_path` + `cwd` on every start (the #113
  cold-restart fix). `kb.py` opens its persistent store from `cwd` at startup,
  so a restarted kb-agent finds its existing index with zero extra wiring. **The
  test plan (§6) asserts exactly this**: ingest → restart the agent → query
  returns the ingested content. This is the property np never needed (np is
  stateless), so it is the headline thing the SPEC must prove.

### 4.3 Ingest path (source docs via `resource://` + FsResolver)

Ingest takes a **source reference**, not raw bytes inline (bytes inline is fine
for tiny test docs but does not scale and bypasses the FS auth seam). The
source doc lives as `resource://<ws>/kb-source/<name>`:

- Register a **`kb-source` type** in `FsResolver.Registry.boot_registrations/0`
  (the immutable-after-boot allowlist — R-1) with a per-type `authority/2`
  asserting the URI's `<ws>` is authoritative for the ingesting caller's scope
  (R-3), backed by a `Home` component (R-4). Traversal is rejected by R-2.
- The **Elixir** side (the PyAgent state half / a thin ingest action) resolves
  the source URI → on-disk path via `FsResolver.resolve/2` under the caller's
  authenticated scope, then hands the *resolved, authorized* path (or the bytes)
  to the subprocess's ingest method. The subprocess never resolves URIs itself
  (no ambient FS authority in Python).
- `kb.py` chunks + embeds + writes to the config_dir index.

This keeps the FS-authority decision in the hardened Elixir seam and the
ML work in Python — the same split-of-responsibility as the rest of py.

### 4.4 Behaviors — reuse, don't add

The MVP needs **no new Elixir Behavior if query/ingest can ride the existing
`receive` → `:py_sync_result` round-trip** (the np shape: chat text in, reply
out). That gives query-via-chat for free. The decision point (resolved in §5):
*ingest* and *programmatic query* want a richer, cap-distinct surface than a
single chat `receive`, which argues for either (a) a tiny `Behavior.Kb` with
`:kb_ingest` / `:kb_query` actions (separate caps), or (b) additional JSON-RPC
methods exposed through the MCP tool surface. The SPEC recommends **(a) a
minimal `Behavior.Kb`** so ingest vs query are cap-distinct *at the dispatch
layer* (where CapBAC actually gates), with the heavy work delegated to the
subprocess. This is the only Elixir code the MVP adds, and it is thin
(persist-and-delegate, like PyAgent's handlers).

---

## 5. How an agent CONSUMES KB

Two candidate surfaces; both already have precedent in the repo.

### 5.1 The options

- **MCP tool** — expose `kb_query` (and, cap permitting, `kb_ingest`) as MCP
  tools the consuming LLM agent calls, via the established orchestrator MCP
  transport pattern (`McpServer` → SessionManager → bridge-token-verified
  `run_tool`). The transport holds zero authority; the bridge token is the
  consumer's credential; the dispatch into the kb-agent carries the caller's
  caps.
- **Agent-to-agent dispatch** — the consumer dispatches
  `entity://<ws>/agent/<kb-instance>?action=kb.query` directly
  (`Ezagent.Invocation.dispatch/1`), the universal native path (kanban reads its
  board via dispatch `get_tree`).

### 5.2 Recommendation

**For the LLM-agent consumer (the primary RAG use case): MCP tool.** An LLM
orchestrator/worker already speaks MCP; surfacing `kb_query` as a tool means the
model can decide *when* to retrieve, with a typed schema, without the platform
having to inject retrieval into the prompt pipeline. This is exactly the
abstraction the orchestrator tool-catalog established, and it is the contract
other RAG systems expose to models.

**Agent-to-agent dispatch remains the native substrate** — it is what the MCP
tool dispatches *through* (the MCP transport ultimately dispatches a
`kb.query` action into the kb-agent, the same way the orchestrator MCP tools
dispatch into SessionManager). Non-LLM callers (a view, a batch job, another
behavior) use dispatch directly. So this is not either/or: **MCP tool is the
ergonomic front door for models; dispatch is the universal back end.** Both gate
through CapBAC on `kb.query` / `kb.ingest`.

Defer: a "auto-RAG" mode where retrieval is injected into every turn without the
model asking — that is a prompt-pipeline concern, not a starting-KB concern.

---

## 6. Cap model + security

### 6.1 Caps (fail-closed, separated by mutation)

- **`kb.query`** — read: NL query → top-k. Granted to consumers.
- **`kb.ingest`** — write: add a source to the index. A distinct cap so a
  query-only consumer cannot mutate the index.
- **`:py_sync_result`** on `:agent` — the existing internal re-dispatch cap the
  base `:receive` grant authorizes (reused verbatim from PyAgent).

Caps are **requested** in the recipe and **minted** by the py
`CapPolicy.for_recipe/1` (fail-closed: only requested `{behavior, action}` pairs
pass; the recipe is the whole allow-list). Minting happens at
`Workspace.grant_initial_caps` (RF, the granter-context layer), NOT in the
agent's own `create/1`. The kb-agent presents its OWN narrow inline cap on the
concrete reply session for any chat reply (the np `maybe_reply_effect`
precedent — no `system://` wildcard, Decision #154).

### 6.2 Subprocess security model (np precedent + KB extensions)

The np `_SAFE_NAMES` whitelist + "no raw `eval`/`exec`" invariant is the
baseline. KB legitimately needs more than np (it reads files + runs ML), so the
model is stated explicitly:

- **No arbitrary code execution from query/ingest input.** The query string is
  passed to the embedding model as *data* (embedded, then ANN-searched); it is
  never `eval`'d. The ingest path chunks + embeds *bytes*; it never executes
  source content.
- **Filesystem reads are bounded + Elixir-authorized.** The subprocess does NOT
  resolve URIs or roam the FS. Source paths are resolved + authorized in the
  Elixir FsResolver seam (R-1..R-4) and handed in; the subprocess reads only the
  config_dir index (its `cwd`) + the explicitly-passed, already-authorized
  source path.
- **Input length cap + timeout + tear-down** carry over from np
  (`MAX_INPUT_LEN`, `Domain.Python.call/4` `:rpc_timeout`, subprocess tear-down
  on unhealthy). Embedding a pathological input is bounded by the timeout.
- **Dependency surface is declared in the script header** (`# /// script` uv
  deps), the same audited, explicit channel np uses for numpy/sympy. An arch
  note: ML deps are large; the plan must confirm the uv install is acceptable
  at agent-create latency (or pre-warm), but that is a plan/perf concern, not a
  security hole.

---

## 7. Explicitly deferred

| Deferred | Why deferred | When to revisit |
|---|---|---|
| **pgvector / native flavor (Opt 2)** | embedding is still Python; adds Elixir infra; slower to first retrieval | proven need for in-process query latency or txn-consistency with BEAM state |
| **`domain_kb` (Opt 3)** | YAGNI; a starting KB is one agent's sandbox | independent KB lifecycle / cross-ws governance / separate scaling axis |
| **source-management** (list/refresh/dedupe sources) | not needed to prove retrieval | when KBs accrete many sources operators must curate |
| **re-index / model-swap / migration** | one model, one index for MVP | when changing embedding models on a populated KB |
| **governance** (per-source ACL, retention, retrieval audit) | the cap split (query≠ingest) is enough for MVP | cross-agent shared KB (= the domain trigger) |
| **hybrid search / re-ranking / federation** | top-k vector search is the MVP | retrieval-quality tuning phase |
| **parallel-query scaling** | `:in_process_sync` serial is fine for one consumer | QPS pressure → read-replica kb-agents or domain (Opt 3) |
| **auto-RAG prompt injection** | model-asks-via-MCP is the MVP | prompt-pipeline phase |

---

## 8. Test plan

The acceptance gate must *fail* if the architectural claims are unmet:

1. **Round-trip (the core).** Create a `kb`×`py` agent → ingest a known doc →
   `kb.query` with a question whose answer is in the doc → assert the top-k hit
   contains the expected chunk. (Proves embed + store + retrieve.)
2. **Persistence across restart (the headline new property).** Ingest → restart
   the agent (supervisor restart AND simulated cold-load via `activate/2`) →
   query → assert the ingested content is STILL retrievable. (Proves
   config_dir on-disk index + `activate/2` reopen. This is what np never needed.)
3. **Cap separation.** A consumer with only `kb.query` is REFUSED `kb.ingest`
   (`:cap_denied`); a consumer with neither is refused both. (Proves fail-closed
   + mutation separation.)
4. **Source authority (FsResolver).** Ingesting `resource://victimWS/kb-source/x`
   under attacker scope fails the R-3 authority check; a traversal segment
   (`..`) fails R-2 BEFORE any backend touch.
5. **Passive isolation (RF-6).** The kb-agent is NOT @-mentionable, NOT
   `:join`-able as a member, does NOT receive ambient chat — only direct
   `kb.*` dispatch + the MCP tool path reach it.
6. **MCP consumption.** An LLM-shaped consumer reaches `kb_query` through the
   MCP tool surface and the call dispatches `kb.query` into the kb-agent with
   the caller's caps (transport holds none).
7. **No new vector infra in Elixir.** An arch/grep gate asserting MVP adds no
   pgvector dep, no new per-tenant vector table, no new Kind/domain (the
   "starting KB is a role" invariant).

Live e2e (agent-browser sign-off, per project standard): create a kb-agent,
ingest a doc through the UI/CLI, query, screenshot the retrieved result.

---

## 9. Open questions for the lead

1. **Embedding model — local vs API for MVP?** Recommendation: a *local*
   sentence-transformers model (no network/credential dep, deterministic
   offline tests). But local models add ~hundreds of MB to the uv install +
   first-run download latency. Acceptable, or prefer an embedding API (adds the
   credential cascade)? This is the single biggest perf/dependency lever.
2. **Vector store — chromadb vs faiss?** chromadb = simplest persist/reopen,
   slightly heavier dep + more "server-ish." faiss = leaner, but we hand-manage
   the metadata sidecar + persistence. Recommend chromadb for MVP simplicity;
   want the leaner faiss path instead?
3. **`Behavior.Kb` (thin Elixir actions) vs ride the existing `receive` only?**
   §4.4/§5.2 recommend a minimal `Behavior.Kb` so ingest≠query is cap-distinct
   at the dispatch layer. Accept the small amount of new Elixir, or insist on
   *zero* new Elixir (query-via-chat-`receive` only, ingest via a separate
   admin path)?
4. **Plugin placement of the `kb` role** — declare it inside `ezagent_plugin_py`
   (no new app, role is flavor-agnostic) vs a new `ezagent_plugin_kb` that only
   *declares* the role + the `kb-source` FsResolver type + (optionally)
   `Behavior.Kb`? Recommend the latter for a clean owner of the KB concern
   without it being a *domain*; confirm.
5. **uv install latency at create** — heavy ML deps installed on first agent
   create. Accept create-time install (like np), or pre-warm a shared venv /
   bake the deps? (Perf, not correctness — but shapes the create UX.)
6. **/goal acceptance criteria** — Allen to set the completion gate (the §8
   test plan is the proposed superset). Confirm the persistence-across-restart
   test (§8.2) is the load-bearing one.
```
kb-retrieval-first 完成 = role kb × flavor py on Entity.Agent：
1. kb role recipe (script kb.py + kb.query/kb.ingest caps + passive:true) 经 roles/0 注册；
   py flavor 经现有 create 路径 per-instance 加载，index 持久化于 config_dir。
2. ingest 一篇文档 → kb.query 返回 top-k 命中（embed+store+retrieve）。
3. 重启 agent 后 index 仍可检索（config_dir on-disk + activate/2 reopen）。
4. cap 分离：kb.query ≠ kb.ingest，fail-closed；FsResolver source 鉴权 (R-1..R-4)。
5. passive 隔离 (RF-6 三闸)；MCP tool 消费 kb_query（transport 零授权）。
6. MVP 不引入 pgvector / 新 per-tenant vector 表 / 新 Kind / 新 domain。
验收：全量 mix test 0 失败 + CI 绿；live e2e（agent-browser）create+ingest+query+截图。
DEFER: pgvector(Opt2)、domain_kb(Opt3)、source-mgmt/re-index/governance。
```
