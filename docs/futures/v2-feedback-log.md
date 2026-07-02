# V2 Feedback Log

> **Status**: ACTIVE — V1 acceptance phase begins 2026-05-21. Allen
> manually tests ezagent V1 (Phase 9 closed); Claude records every
> piece of feedback here verbatim + abstracts the essential cause.
>
> When V2 planning begins, this doc is the input source. Don't
> implement during recording.

## Recording protocol

Each piece of feedback gets one entry with **4 fields**:

1. **原始反馈 (Raw quote)** — Allen's exact words from Feishu (Chinese
   preserved verbatim; no paraphrase, no "what Allen meant"). Includes
   timestamp + Feishu message_id when available.
2. **本质原因 (Abstracted root cause)** — what general property of the
   system or interaction is this surfacing? Aim higher than the
   specific bug. "What category of design is wrong?" not "what line
   of code is wrong?"
3. **V2 影响 (V2 implication)** — does this require a SPEC change,
   architectural shift, new abstraction, removed abstraction, or
   just a per-feature fix? Mark scope: structural / tactical /
   ergonomic.
4. **候选方案 (Candidate solutions)** — 1-3 directions, with the
   trade-offs sketched. NOT a decision; that's V2 planning.

Group entries by **theme** (top-level `##` sections). Theme is
derived from feedback content, not pre-committed. Add new themes
as patterns emerge.

## Themes that will appear (initial guesses, adjustable)

- **URI ergonomics** (3-segment is verbose; do users feel the cost?)
- **Workspace switcher UX** (Keycloak model is principled but is it
  intuitive?)
- **Auth flow surface** (workspace param is fiddly; bare-handle vs
  full URI ergonomics)
- **Admin tooling gaps** (manual mix tasks vs LV CRUD; what's
  missing)
- **Session lifecycle** (when sessions persist; rehydration semantics)
- **Plugin authoring friction** (per `feedback_north_star_plugin_isolation`)
- **Multi-agent orchestration UX** (how Phase 7 orchestrator
  surfaces in V1)
- **Demo / first-run experience** (a new dev runs `mix phx.server`
  — what hits them?)
- **Observability gaps** (when things go wrong, can you tell why?)

---

## V2 planning trigger

When Allen says "开始 V2 规划" (or equivalent), this doc becomes
input to a `superpowers:brainstorming` session that produces:

1. `docs/superpowers/specs/<YYYY-MM-DD>-ezagent-v2-charter.md` —
   theme-by-theme synthesis with V2 goals + non-goals
2. Per-theme SPEC drafts following the Phase 9 pattern
3. A revised PR sequence (likely several phases of V2)

Until then: **record, don't implement**.

---

## Entries

## Architecture gap — No auto-trigger from URI registration to associated template instantiate

### 原始反馈

> [Feishu 2026-05-21 16:11 (GMT+9), msg `om_x100b6fdf4c6a08a0c4eaef4621b7af0`]
> 请注意这不是v2内容，而是v1验收没有通过的内容，需要立即dispatch subagent进行修复：
> 1. 请分析会漏instantiate template的根源是什么，目前kind不会自动帮助plugin注入instantiate template这一步吗？
> 2. 之前cc分裂为channel和pty两个部份，现在改为cc-channel启动是本体，可以带with_pty的命令启动本地Pty。这个对出现这个bug有影响吗？
> 3. not running的UI应该如何修改，Domain.Agent是不是应该提供统一的UI，供显示agent的生命周期？

(The surface bug — created cc_demo shows "Not running" — was fixed in V1 (PR #XXX); this entry records the architectural pattern surfaced by Allen's Q1 + Q3.)

### 本质原因

Two related but distinct architectural gaps surfaced by Allen's V1 acceptance testing:

**Gap 1 (Q1)** — There is no **URI-registration → associated-template-instantiate** hook in the Kind / SpawnRegistry layer. Today's flow:
- `SpawnRegistry.spawn(uri)` → starts a Kind process in supervision tree. Done.
- `Workspace.add_template(name, tmpl_name, tmpl)` → updates DB JSON. Done.
- `Workspace.Loader.load_all/0` → iterates all `session_templates` and invokes template's `instantiate/3`. Only runs at **plugin boot** (chat plugin + cc plugin each run it).

Runtime-added templates have nobody calling instantiate. The V1 fix (PR #XXX) puts the invoke inside `Workspace.add_template/3` itself — but that's a tactical wedge, not a structural answer. The deeper question: **should Kind / SpawnRegistry / Template-registration share a generic "post-registration hook" abstraction**? Today each layer (Kind spawn, template add, workspace template list) manages its own side-effects; the chains aren't composable.

**Gap 2 (Q3)** — `AgentDetailLive.load_status/1` directly calls `Ezagent.PluginCc.PtyServer.find_by_agent_uri` — a Domain UI module **importing Plugin module internals**. This violates the 3-tier architecture (invariant 8: plugins extend core, not other way) and means echo/curl agents have no defined "lifecycle status" surface. V1 fix introduces `Ezagent.Domain.Agent.lifecycle_status(uri)` as flavor-agnostic facade; but **Domain.Agent itself is new** — V1 did not have a unified domain model for "agent" across flavors.

Both share: lack of cross-flavor / cross-layer abstractions for agent lifecycle. Each plugin reinvents (cc has PtyServer.find_by_agent_uri; echo has nothing visible; curl has nothing visible).

### V2 影响

- **Scope**: structural — generic Kind-lifecycle hook abstraction; unified Domain.Agent model with lifecycle phases (`:registered → :instantiated → :alive → :busy → :error → :terminated`)
- **Affects**: `Ezagent.Kind`, `Ezagent.SpawnRegistry`, `Ezagent.TemplateRegistry`, new `Ezagent.Domain.Agent`, plugin lifecycle Behavior contracts, all plugin Application boot paths
- **Blocks**: V2 plugin authoring story — without a generic hook + lifecycle behavior, every new plugin has to reinvent both
- **Related Phase 9 PR/SPEC**: this surfaced after Phase 9 closure
- **V1 tactical fix shipped** (PR #XXX): `Workspace.add_template` chains to instantiate; `Ezagent.Domain.Agent.lifecycle_status/1` introduced as flavor-agnostic facade

### 候选方案

- **A — Kind callback `on_spawn_hook/1`**: add to `@behaviour Ezagent.Kind` an optional callback that runs after KindRegistry registration. cc plugin's Agent Kind implements it to start PtyServer. Trade-off: each Kind owns its own bootstrap, but the hook is opt-in so non-running Kinds (echo, system) don't need to implement.
- **B — Template-driven spawn unification**: eliminate "spawn Kind directly" path entirely. ALL agent Kinds must be spawned via a Template; `SpawnRegistry.spawn(entity://agent/...)` is deprecated in favor of `Template.instantiate(template_uri)`. Trade-off: bigger refactor but eliminates the "spawn Kind without template" failure mode.
- **C — Lifecycle Behavior contract**: define `Ezagent.ActionSet.Lifecycle` with `phase/2`, `transition/3` actions. Every "running" Kind (agent, session) carries this Behavior. `Ezagent.Domain.Agent.lifecycle_status/1` dispatches `?action=lifecycle.phase` to the Kind. Trade-off: explicit lifecycle modeling vs implicit "is supervisor PID alive" — more code but observable + capability-gated.

Recommended V2: **A + C combo**. A solves the "spawn forgot to instantiate associated template" class. C solves the "UI knows about plugin internals" class. B is too big a refactor for V2 unless multi-flavor agent composition becomes a goal.

### 链接

- **V1 tactical fix SHIPPED**: PR #175 (commit `c60cd32`) — Workspace.add_template chains to invoke_template + AgentNewLive spawn order inverted + Domain.Agent.lifecycle_status facade + cc.agent mode/remote-channel dead code removed
- Same-family pattern in Phase 8c: bare-handle bounce → `SessionPrincipal.put/2` invariant
- Q2 clarification from Allen 2026-05-21 16:22: cc plugin original design was channel-as-primary + optional PTY; remote-channel was deferred placeholder; CURRENT direction (per Allen): single local-pty mode, future remote support = separate plugin. PR #175 acted on this.
- Q3 clarification from Allen: Agent UI fix IS V1 work (not V2 deferred); V2 will reference V1's Domain.Agent facade as architecture pattern.
- Test gap CLOSED in PR #175: "AgentNewLive create_agent → BOTH Agent Kind AND PtyServer alive" e2e regression test

## V2 macro charter — Phoenix-Plug-style spawn pipeline (Allen sketch + Claude refinements)

### Allen's V2 macro sketch (Feishu 2026-05-21 16:36, msg `om_x100b6fdf11dbe8a8c333bbaa75d77c7`)

> [verbatim quote]
> defmodule Ezagent.Plugin.Cc.Template.CcAgent do
>   use Ezagent.Kind.Template,
>   use Ezagent.Entity.Agent
>     agent_types: cc,
>     spawns_with: [Ezagent.Domain.Pty.PtyServer]
>     spawns_pipeline: Agent.spawn |> Caps.grant |> Pty.Start |> Channel.connect |>  Session.join

### Refined V2 syntax (Claude — Elixir-realistic)

```elixir
defmodule Ezagent.PluginCc.Template.CcAgent do
  use Ezagent.Kind.Template,
    creates: Ezagent.Entity.Agent,
    flavor: "cc",
    spawns_with: [Ezagent.Domain.Pty.PtyServer]

  spawn_pipeline do
    step Ezagent.Lifecycle.AgentSpawn
    step Ezagent.Lifecycle.CapsGrant
    step Ezagent.Lifecycle.PtyStart
    step Ezagent.Lifecycle.ChannelConnect
    step Ezagent.Lifecycle.SessionJoin
  end

  def required_params, do: [:agent_uri, :cwd]
end
```

### Why these adjustments from Allen's sketch

| Allen's sketch | Refinement | Reason |
|---|---|---|
| `use Foo, use Bar` | one `use` with options | Elixir disallows multiple `use` in one statement; common idiom is single `use` with keyword options |
| `agent_types: cc` (atom) | `flavor: "cc"` (string) | Matches Phase 9 SPEC §5.14 `entity://agent/<flavor>_<name>` URI shape where flavor is a string prefix |
| `Foo \|> Bar \|> Baz` at attribute level | `spawn_pipeline do step Foo; step Bar; ... end` block macro | `\|>` is a runtime operator and can't be evaluated at module-definition time. Phoenix's `pipeline :browser do plug X end` is the canonical Elixir DSL pattern for this |
| `Ezagent.Domain.Pty.PtyServer` (Domain layer) | KEEP — Allen's good call | PTY is a generic capability (cc + future flavors may use); domain layer is the right home (currently in plugin_cc — V2 promotes it) |

### Macro expansion (what it generates)

The `use Ezagent.Kind.Template` macro with `spawn_pipeline` block generates:

1. **`instantiate/3` callback**: chains each pipeline step with proper context passing (think Plug.Conn — each step receives an `%Ezagent.Lifecycle.Context{}` struct and returns `{:ok, context}` or `{:error, reason, context}`)
2. **`flavor_match?/1` helper**: matches URIs against the declared flavor prefix
3. **`Ezagent.Domain.Agent.lifecycle_status/1` integration**: auto-derives phase from the pipeline's furthest-completed step
4. **Pipeline trace / debugging**: each step records into telemetry; debugger UI shows "stuck at PtyStart" instead of "Not running"
5. **Reverse pipeline for terminate/3**: graceful shutdown runs steps in reverse (SessionLeave → ChannelDisconnect → PtyStop → CapsRevoke → AgentDespawn)
6. **Cap-gated**: each step declares the cap it requires (e.g., `PtyStart` requires `pty.start` cap); pipeline halts on first denial

### Why this matters for V2

- **Plugin authoring friction reduced**: cc plugin author writes ~5 lines + 5 lifecycle modules (one per step); macro generates the orchestration
- **Cross-plugin composability**: feishu plugin can add `Ezagent.PluginFeishu.Lifecycle.WebhookRegister` step without forking cc plugin
- **Debuggability**: pipeline trace beats "Not running" mystery — operator sees exactly which step failed
- **No more reverse-spawn-order bugs**: pipeline ordering is declarative + compile-checked
- **Symmetric with terminate**: today there's no graceful agent shutdown; V2 macro generates it for free

### Trade-off

- More macro complexity in `Ezagent.Kind.Template` itself (~200 LOC macro)
- Plugin authors learn a new DSL (mitigated by familiarity with Phoenix Plug)
- Edge cases: dynamic pipelines (template selects steps based on params) — needs design

### Recommended V2 PR sequence

1. Define `Ezagent.Lifecycle.Step` Behaviour (`call/2` + `terminate/2`)
2. Implement `spawn_pipeline` macro in `Ezagent.Kind.Template`
3. Refactor `cc.agent` template to use macro (migration test: behavior preserved)
4. Refactor echo/curl/future plugins to use macro
5. Promote `Ezagent.Domain.Pty` from plugin_cc (PTY = generic capability)
6. CI gate: every plugin Template MUST use the macro (grep gate)

### 链接

- Allen's bug-history question + prevention strategies discussed Feishu 2026-05-21 16:37 (msg `om_x100b6fdf2f46b094c3ada79847ecc1c`) — captured in V1 fix prevention strategies (entry below)

---

## Architectural prevention — How the reverse-spawn-order bug snuck through, how to make it impossible

### 原始反馈

> [Feishu 2026-05-21 16:37 (GMT+9), msg `om_x100b6fdf2f46b094c3ada79847ecc1c`]
> agent spawn 反序问题是怎么出现的，如何预防？

### 本质原因

The bug shipped because **the test suite couldn't distinguish "Kind alive by direct spawn + template-as-config" from "Kind alive via template-as-creator"**. Both states satisfy `KindRegistry.lookup → {:ok, _}`; only when template instantiate is the SOLE creator does the layering invariant hold.

Three contributing factors:

1. **Idempotent instantiate masking the bug**: `cc.agent.instantiate/3` short-circuits when it sees `KindRegistry.lookup → {:ok, _}`. The pre-spawn flow worked because instantiate is "tolerant" — but tolerance ate the architectural invariant.
2. **No "every Agent Kind came from a Template" invariant test**: existing invariants assert workspace binding, URI shape, cap workspace — none assert provenance.
3. **Mental-model leak**: AgentNewLive author (Phase 8c PR-N) thought "Kind = the thing; Template = config". The correct model: "Template = the creator; Kind = the product". Without macro enforcement, every code author re-decides this.

### V2 影响

- **Scope**: structural (macro enforcement) + tactical (invariant test) + skill update
- **Affects**: SpawnRegistry, Kind/Template authoring story, ezagent-developer SKILL.md anti-patterns
- **Blocks**: V2 macro design is the structural answer; needs invariant test + skill update meanwhile

### 候选方案 — 5-layer defence

| Layer | Strategy | When |
|---|---|---|
| 1. Structural | Macro-generated `spawn_pipeline` makes "spawn outside template" impossible at compile time | V2 |
| 2. Invariant test | Runtime: every alive `entity://agent/<flavor>_*` Kind has matching template in some workspace.session_templates | V1 (proposed follow-up PR) |
| 3. Domain API | `Ezagent.Domain.Agent.create(flavor, name, params)` as ONLY user-facing creation API; UI/CLI/API all go through it | V1 fix #175 partial (facade exists; not yet enforced as sole entry) |
| 4. SKILL.md anti-pattern | "Never call SpawnRegistry.spawn(entity://agent/...) directly outside Template.instantiate/3" in ezagent-developer skill | V1 (proposed follow-up PR) |
| 5. CI gate | Static grep: lib/ code calling `SpawnRegistry.spawn(entity://agent/...)` outside template modules fails CI | V1 (proposed follow-up PR) |

**V2's macro (Layer 1) is the structural fix**. Layers 2 + 4 + 5 are V1 follow-ups Allen can authorize (asked Feishu 16:50). Layer 3 is partially done by Fix 2 (Domain.Agent facade); making it the SOLE entry is V2 scope.

### 链接

- Bug origin: Phase 8c PR-N (AgentNewLive creation, 2026-05-20)
- V1 fix: PR #175 (commit `c60cd32`)
- V2 macro: above entry in this doc



### Entry template

```markdown
## <Theme> — <one-line summary>

### 原始反馈

> [Feishu 2026-MM-DD HH:MM, msg `om_xxx`]
> <Allen's exact words, Chinese preserved>

### 本质原因

<1-3 sentences. Not "the button is broken" but "feedback X surfaces
a missing abstraction: the system has no concept of Y, so users have
to do Z manually". Aim higher.>

### V2 影响

- **Scope**: structural | tactical | ergonomic
- **Affects**: <which subsystems / SPEC sections / invariants>
- **Blocks**: <other feedback this depends on, if any>

### 候选方案

- **A**: <approach>; trade-off: <what you give up>
- **B**: <approach>; trade-off: <what you give up>
- **C** (if applicable): <approach>; trade-off: <what you give up>

### 链接

- Related Phase 9 PR/SPEC: <ref if any>
- Related memory: <feedback_xxx if any>
- Related Decision Log entry: #<number> if any
```

---

## Conventions

- **Per memory `feedback_bilingual_docs_convention`**: this doc has a
  `.zh_cn.md` parallel. Both are kept in sync as entries are added.
- **Per memory `feedback_subagent_review_plans`**: when V2 planning
  starts, the SPEC subagent reads BOTH this doc and PHASE 9 SPEC +
  amendments + demo doc.
- **Per memory `feedback_completion_requires_invariant_test`**: V2
  features need invariant tests; this doc identifies what should be
  invariant.
- **No premature implementation**: even if a fix is one-line, record
  it here first. Allen + Claude review the abstraction pass before
  the implementation pass. The point is to find patterns across
  feedback, not to chase individual symptoms.
