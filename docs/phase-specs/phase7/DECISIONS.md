# Phase 7 — Implementation-time DECISIONS

**Status:** INITIALIZED 2026-05-18 (empty; will accrete during PR sequence).
**Purpose:** Capture judgment calls made DURING implementation that weren't in the SPEC. SPEC contains the LOCKED design; DECISIONS records the in-the-trenches "I chose X over Y because Z" that come up when actually writing code.

When a SPEC ambiguity is hit:
1. Try to resolve in-PR without escalating (most cases)
2. Write a DECISIONS row capturing the choice + reasoning
3. If the choice is architecturally significant (changes a Phase 7 invariant or contradicts the SPEC), block on Allen and document the dialogue

When a SPEC contradiction is hit:
1. Stop. Don't pick one arbitrarily.
2. Feishu Allen with the contradiction + recommendation.
3. Document the resolution here once decided.

Decisions promote to ARCHITECTURE.md Decision Log at Phase 7 closeout (7-4 PR 53) if they have lasting architectural significance.

---

## Decision template

```markdown
### IMPL-7-N: Brief title (PR # / date)

**Context:** What was happening in the code that forced a choice.
**Options considered:**
  - A: ...
  - B: ...
**Choice:** A (or B, or hybrid).
**Reasoning:** Why this one. Cite SPEC sections if relevant.
**Promote to Decision Log?** Yes/No, with justification.
```

---

## Decisions

### IMPL-7-1: Session→workspace back-edge via a registry, not a slice field (PR 31 / 2026-05-18)

**Context:** PR 31 implementation revealed that `Ezagent.Behavior.Chat.invoke(:send, ...)` at `chat.ex:116` calls `Ezagent.Routing.Resolver.resolve/3` without passing `workspace_uri`, silently dropping workspace scoping at the production dispatch path. To fix, we need to know the workspace a given session belongs to. Today there is **no session→workspace lookup API** anywhere in the codebase (subagent audit confirmed: no `find_workspace`/`workspace_for_session`/`owning_workspace`; `Workspace.Store` has `members` map but no `sessions` mapping; `Workspace.Loader.spawn_child` spawns sessions but doesn't record the back-edge).

**Options considered:**
- **A — Add `workspace_uri` to Chat slice for Session-context.** Cheaper (no new module); but requires changing `Chat.init_slice/1` to accept `workspace_uri`, threading it through `SpawnRegistry.spawn/1` (currently URI-only, no init args), updating every Template Class that spawns Sessions, and migrating existing snapshots. Couples the slice shape to a workspace concept that the Chat Behavior shouldn't intrinsically know about.
- **B — New `Ezagent.WorkspaceRegistry` ETS-backed registry** with `bind(session_uri, workspace_uri)` + `lookup(session_uri)` API. Workspace.Loader populates at spawn time (one line); chat.ex:116 reads. Cleanly decoupled. Default for unbound sessions = `nil` = global fallback (preserves today's behavior, no migration).

**Choice:** B (registry).

**Reasoning:**
- SpawnRegistry.spawn/1 stays a URI-only contract (Decision #65 invariant: no Kind-specific args in spawn signature)
- Chat slice stays focused on chat state (members, monitors, last_seen); workspace is orthogonal
- No migration needed — unbound sessions transparently fall back to today's "no scope" semantics
- Matches the existing ETS-Registry pattern (KindRegistry / BehaviorRegistry / RoutingRegistry / TemplateRegistry)
- Plugin authors writing new Template Classes call `WorkspaceRegistry.bind/2` once after their `SpawnRegistry.spawn/1` — documented in plugin authoring guide

**Implementation surface (PR 31 final scope):**
1. New `apps/ezagent_core/lib/esr/workspace_registry.ex` — ETS owner, `bind/2`, `unbind/1`, `lookup/1`, `list_all/0`
2. `EzagentCore.EtsOwner` adds `{Ezagent.WorkspaceRegistry, :set}` to owned tables (boot-time creation)
3. `apps/ezagent_domain_workspace/lib/esr/workspace/loader.ex` `spawn_child({:template, ...})` and `invoke_template` paths call `WorkspaceRegistry.bind(session_uri, workspace_uri)` for each spawned session URI
4. `apps/ezagent_domain_chat/lib/esr/behavior/chat.ex:116` reads `workspace_uri = Ezagent.WorkspaceRegistry.lookup(session_uri)` and passes `workspace_uri:` opt to `Resolver.resolve/4` (nil falls back to global = today's behavior)
5. New `apps/ezagent_domain_chat/test/integration/workspace_isolation_test.exs` — drives the real Loader → Chat.invoke(:send) → Resolver path; asserts rule scoped to `workspace://A` doesn't fire for message in `workspace://B`; negative control: nil-scoped rule fires from both

**Promote to Decision Log?** Yes — `WorkspaceRegistry` becomes a permanent fifth Registry family (Kind / Behavior / Routing / Template / Workspace). Document at Phase 7 closeout (PR 53) as Decision #135 (the first new Decision after Phase 6's #132-#134).
