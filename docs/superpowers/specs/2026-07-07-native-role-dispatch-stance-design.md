# Native-role reachability — the two-surface model, hello `rebuild`, and the composite-responder question

**Status:** rev1 — design spec (not an implementation plan). Settles #1201 item ②
as a DESIGN DECISION (already made by the lead; recorded and elaborated here, not
relitigated), turns item ③ into a concrete hello action, and folds item ⑦ in for
analysis with one explicit lead-decision box (§4.3).
**Authority:** `docs/together/2026-07-06/handoffs/system-mechanism-feedback.md`
(items ②③⑦, Appendix B, and the coordinator's X-analysis).
**Baseline:** every file:line claim in this spec re-verified against main
`dcabf6174` (post #1208/#1212/#1213/#1215).
**Lineage:** orchestration-as-socialware reference design
(`2026-07-06-orchestration-as-socialware-design.md`, SOUND rev4) · hello substrate
migration B' (#1208) · M1 declarative routing (#1212) · role-slot P1–P3.

---

## 0. Decision record (lead decision — settled, recorded here)

**② resolves as (b): caller-dispatch.** Native-flavor members have NO
chat-delivery/`:receive` surface **by design**; they react via DISPATCH of their
declared recipe actions. Option (a) — opening an in-process chat-receive path for
the native flavor — is **rejected**: it fights the explicit design stance already
written into the code (`EzagentPluginHello.BridgeAdapter` moduledoc,
`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/bridge_adapter.ex:8-14`,
verified verbatim on main: *"`native` has NO adapter, so a native agent's chat is
dropped (`:no_sandbox_respawn_state`) and a role behavior's own `:receive` never
runs"*), and it fights the orchestration reference design's judgment-at-endpoints
rule (§4 of that spec: the table never calls a model; interpretation lives in
LLM-backed endpoints).

The X this spec settles: **which reachability surface belongs to which member
class — stated as a documented invariant instead of tribal knowledge.** Today the
boundary exists only as one adapter moduledoc plus e2e forensics in jjkysy's
handoff; #1201 ② demonstrated that a competent implementation team read
"routing granted, delivery dropped" as a bug for days. That cost is the spec's
justification.

## 1. The two-surface model (normative)

A session member is reachable on up to two surfaces:

| surface | what it is | who has it | mechanism |
|---|---|---|---|
| **Dispatch** | invocation of a DECLARED action of the member's composed behavior set, by name, with typed args | **every member, any flavor** (guaranteed once T1 lands — §2) | `Ezagent.Router.dispatch(%Cmd{})` / `Ezagent.Invocation.dispatch/1`; agent-facing via manifest action tools (`Ezagent.AgentManifest.Tools.dispatch_action/4`); authorized by capabilities on the `:agent` axis |
| **Delivery (`:receive`)** | the session chat fan-out — free-text messages routed by the session table and handed to the member for INTERPRETATION | **adapter-flavor members only, by design** — flavors that register an `Ezagent.AgentBridge.Adapter` (today: `cc`/`cc-headless`, `codex`, `py`, `curl`, `hello`) | `chat.send` → routing table → `agent.receive` → `Ezagent.ActionSet.Agent.Receive` (hardwired on the unified `Entity.Agent`) → per-flavor `AgentBridge` adapter → the flavor's runtime |

### 1.1 The invariant

> **I-1 (two-surface reachability).** A member's dispatch surface is universal:
> any materialized member's declared recipe actions are dispatchable, regardless
> of flavor. A member's delivery surface exists **iff** its flavor registers an
> `AgentBridge` adapter. The `native` flavor registers none, **by design**: a
> chat message routed to a native-flavor member is dropped at the bridge
> (`agent_bridge.ex` — `load_sandbox_respawn/1` returns
> `{:error, :no_sandbox_respawn_state}`; main `dcabf6174` ~line 270), and this
> drop is CORRECT behavior, not a defect.

> **I-2 (no behavior-level `:receive` on the unified host).** On
> `Ezagent.Entity.Agent`, the `:receive` action resolves to
> `Ezagent.ActionSet.Agent.Receive` (the fan-out hook), which hands DOWN to the
> flavor adapter. A role behavior's own `action(:receive, …)` declaration is
> therefore never the chat entry point for a role × flavor member. Corollary:
> a role behavior that wants to be reachable declares actions under names that
> do not collide with the base behavior set (the existing
> `sync_result_action/1` uniqueness pattern —
> `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:340-346` —
> is this same rule applied to adapter results).

### 1.2 Why (rationale, normative)

1. **Judgment lives at endpoints** (orchestration spec §4). A free-text chat
   message requires an interpreter. Adapter flavors have one: an LLM runtime
   (cc/codex/py) or a purpose-built in-process router (`hello` flavor's
   `:in_process_sync` adapter feeding `EzagentPluginHello.Router`). A native
   role behavior is deterministic Elixir; giving it the delivery surface makes
   plugin code a message interpreter, which re-creates exactly the app-private
   orchestration-engine pattern the reference design retires — every native
   behavior would grow its own `from_user?`/loop-guard/intent-parsing shims
   (the pre-#1208 hello shape).
2. **Loop safety.** The delivery surface fans out; an endpoint that both
   receives chat and emits chat needs loop discipline (hop budget, self-guards).
   Dispatch is a directed edge with an explicit caller, explicit action, and a
   cap check — loops require a deliberately built cycle of grants.
3. **Auditability.** Dispatch lands in the invocation audit with caller, action,
   and cap; free-text delivery to code that greps the text does not. #1201's own
   forensics (invocations audit showing zero `agent.receive`) worked BECAUSE the
   boundary is where it is.
4. **The alternative was tried and measured.** The (b) pattern is already
   production-proven in this ecosystem (kanban pm board-dispatch; dealscout v2
   `refresh_page` e2e, per the handoff), while (a) has no implementation and
   would additionally require inventing interpretation semantics for code.

### 1.3 What this makes illegal

- "Fixing" the bridge drop for native members (adding a native adapter, a
  default adapter, or a bypass around `Agent.Receive`) — regression-locked by
  test T-2 (§6).
- Routing rules whose receiver is a native-flavor role, EXPECTING chat
  semantics. (The rule itself is not rejected — receivers resolve at delivery
  time and role assignment can change flavor; but delivery to a native member
  drops, and the routing trace must say so legibly: builder-verify BV-6.)
- Free-message interpretation inside a role behavior (`text` grepping in a
  `handle_receive`) for native roles. Interpretation belongs to adapter-flavor
  roles; native roles expose verbs.

## 2. Dependency: T1 (declared interface, not re-specified)

This spec RELIES on T1 (`docs/spec-t1-materialize-behavior-fold`, in progress in
parallel) landing first. The interface this spec consumes, stated once:

> **T1 interface:** *a materialized member's recipe actions are dispatchable* —
> both materialization paths (workspace `agent_create --role` via
> `Recipe.Compose`, AND the socialware Definition/template path) mount the
> recipe's declared behaviors on the spawned instance, so a first dispatch of a
> recipe action never returns `{:unknown_action, _}`.

Without T1, the dispatch half of I-1 is aspirational on the socialware path
(#1201 ⑬: `template_team.ex`→TemplateSpawn spawns `:kind_base` with
`behaviors: nil`; the `Ezagent.Kind.mount/3` hand-patch is the sanctioned
workaround). This spec does not re-design T1's mechanism; if T1's landed shape
renames the interface, §3 and the tests in §6 track it (builder-verify BV-1).

## 3. Item ③ — hello exposes `rebuild` as a dispatchable action

### 3.1 Current state (verified on main `dcabf6174`)

- `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_builder.ex:54-62` —
  `handle_receive` gated by `from_user?(msg)` at **:55**; `from_user?/1` defined
  at **:74** (`Ezagent.URI.type?(uri, :user)`). #1208 and #1215 did NOT move
  these lines (#1215 was PTY-only).
- The gate is **doubly dead** for the agent-triggered path: (i) by I-2 the
  builder's `handle_receive` is not the chat entry point on the unified host at
  all; (ii) even if it were, `from_user?` drops every agent sender. Opening the
  gate — option (a) — would change nothing without ALSO violating I-1. This is
  why (a) is rejected as a mechanism and not merely disfavored as a style.
- The working page-generation path today is plugin-internal: the
  `hello`-flavor orchestrator's adapter → `EzagentPluginHello.Router.route/3` →
  `Generator.generate/2` in a supervised Task. That path is trusted in-process
  plugin code, not a member-facing surface.

### 3.2 Design: the `rebuild` action

`Ezagent.ActionSet.HelloBuilder` declares a second action:

```elixir
action(:rebuild,
  args: %{session_uri: :string, instruction: :string},
  returns: %{},
  caps: [:rebuild],
  modes: [:cast],
  description: "Regenerate/edit the session page from an instruction (agent- and operator-facing door)"
)
```

- **Semantics:** `handle_rebuild` validates args and hands to the existing
  generation entry (`EzagentPluginHello.Generator.start/2`,
  `generator.ex:35-36` — fire-and-forget supervised Task). No new generation
  machinery; the action is a DOOR onto the path the orchestrator already uses.
  Same-session guard: `session_uri` must be a session the builder is a member
  of (fail loud otherwise) — the action is a verb on THIS builder, not a
  generic page-generation RPC.
- **Naming:** `:rebuild` does not collide with the `Entity.Agent` base behavior
  action namespace (I-2 corollary). Builder-verify BV-2 confirms at impl time.
- **`:receive` and the `from_user?` gate stay as they are.** The gate is not
  opened (rejected (a)) and not deleted in this spec: it is the fail-closed
  half of a dead door, and deleting the whole `handle_receive` is hello-plugin
  cleanup that belongs to the hello demo-shape migration, not to this design.
  What this spec fixes is that `rebuild` becomes the ONLY sanctioned
  agent-facing door.
- **Recipe:** `hello_builder_recipe/0`
  (`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:135-141`)
  adds `%{behavior: Ezagent.ActionSet.HelloBuilder, action: :rebuild}` to
  `requested_caps`, so materialization mints the cap on the `:agent` axis
  (RoleStep → `CapMint.mint/3`, `role_step.ex:168-199` — mints `kind: :agent`).

### 3.3 Who may dispatch it (the cap story)

Dispatching `builder.rebuild` requires holding a capability for
`(kind: :agent, action: :rebuild, instance: <builder instance>)`. Three caller
classes, in order of arrival:

1. **The session owner / operator** — grant via the existing owner grant paths;
   `GrantRecipeCaps.grant_recipe_caps/4` with `instance_overrides`
   (`ezagent.agent.grant_recipe_caps.ex:139`, on main) already expresses
   "cap locked to the builder instance, granted into the operator". This works
   TODAY, post-materialization.
2. **A peer agent member** (the dealscout shape: crawler finishes → dispatches
   `rebuild`). The agent-facing mechanism exists: manifest action tools
   dispatch with empty `ctx.caps` and authorization falls through to
   `holds_cap?/2` against the DISPATCHER's identity slice
   (`agent_manifest/tools.ex:1-33`) — so the peer must have the cap granted
   into its identity. Post-materialization grant by the owner works today
   (same as class 1, one manual step).
3. **Declaratively, at install time** — "role R may dispatch role B's
   `rebuild`" written in the Definition. This is BLOCKED on #1201 ⑤ (symbolic
   instance references: the builder's instance URI does not exist at
   declaration time; the socialware materialization path still calls the 3-arg
   grant, `definition_agents.ex:337`). **Declared dependency, out of scope
   here**: this spec requires only that the cap SHAPE (`:agent` axis, action,
   instance) is the one ⑤'s mechanism will mint, so no rework lands when ⑤
   does.

Fail-closed default: nobody but the builder itself (self-cap from the recipe
mint) holds `rebuild` after materialization. Every additional dispatcher is an
explicit grant. This is the same posture as every other recipe action; `rebuild`
gets no special ambient reachability.

### 3.4 The transitional dealscout shim retires

Per the handoff, dealscout's `DealScoutPageRefreshAlt` (its own v2 dispatch-door
around the same generation need) deletes in favor of a one-line dispatch of
hello's `rebuild` once this lands. That retirement is the acceptance evidence
that ③ actually settled ② for composites (their stated plan, recorded here as
the cross-repo consumer).

## 4. Item ⑦ — composite sessions with no conversational responder

### 4.1 What ⑦ is under the two-surface model

"Owner speaks in a composite (uses-hello) session; nothing answers" is not a
routing defect and not an instance of ② — it is the absence of any member
holding the DELIVERY surface with a rule pointing owner-traffic at it. The
two-surface model names it precisely: a composite whose declared roles are all
native-flavor (or whose adapter-flavor roles have no matching rule) has a
session where the dispatch surface is fully populated and the delivery surface
has no subscriber for human free-text.

### 4.2 What M1 already gives composites (analysis: mechanism is sufficient)

Verified on main: the declarative vocabulary to fix ⑦ per-app EXISTS —

- `{:from_role, role_name}` runtime matcher (#1212;
  `apps/ezagent_core/lib/ezagent/routing/matcher.ex:52,73-76,178-180`), member
  context threaded at live-chat time.
- Role receivers (`{:role, name}` expansion at delivery time — shipped).
- The hello demo definition itself is the worked example: `viewer → responser`
  at position 0
  (`apps/ezagent_domain_session/lib/ezagent/socialware/demo/hello.ex:140-158`),
  with `responser` declared as an ADAPTER flavor (`"py"`) — consistent with
  I-1: the role that answers free text must be an adapter-flavor role.

So a composite CAN declare its responder today: one `from_role(<human role>) →
[role: responser]` rule plus one adapter-flavor responser role in its own
Definition. **No new mechanism is required for ⑦.** What remains is pure
policy:

### 4.3 ⚖ LEAD DECISION BOX — default-responder policy (not decided here)

> **Question:** when a Definition declares human-fillable roles but its merged
> rule set gives human free-text no adapter-flavor receiver, what should
> install do?
>
> **(A) Warn-only (Conformance).** Extend the orchestration spec's §3.2
> role-DAG analysis with a "mute composite" check: human-role source with no
> path to an adapter-flavor receiver → install WARNING naming the roles.
> Zero magic; authors stay responsible; jjkysy's "no `always`-rule backstop"
> red line is preserved. Cost: a naive composite still ships mute, just
> knowingly.
>
> **(B) Reject install** on the same check. Fail-closed and consistent with
> the platform's posture elsewhere, but it FORCES every pipeline-style
> socialware (agents-only, deliberately conversation-free, operated via
> dispatch) to declare a responser it doesn't want — unless the check exempts
> definitions with no human roles, which narrows but doesn't eliminate the
> false-positive class (owner is always implicitly present in a session).
>
> **(C) Defer to M2 (orchestrator socialware as default front desk).** The
> orchestration reference design already plans a default-installed
> orchestrator socialware; its responser-class role becomes every session's
> conversational fallback, and ⑦ dissolves for composites that `requires:`
> it. Cleanest end-state, but M2/M3 are not scheduled, so ⑦ stays open
> meanwhile.
>
> **Recommendation (for the lead to confirm or override):** A now, C as the
> end-state; B rejected for the pipeline false-positive. A is one Conformance
> check, is subsumed cleanly by C later, and decides no policy it can't
> un-decide.
>
> **Decision:** ⟨lead⟩ — notified to main on this spec's first push.

## 5. Tension record — declarative table vs. imperative caller-dispatch

The orchestration-as-socialware reference design prefers routing expressed as
TABLE DATA; ②-as-practiced (this spec's (b)) is an imperative dispatch coded in
the caller (Router task, peer-agent tool call). Both are judgment-at-endpoints —
the tension is only about WHERE the edge "when X happens, builder rebuilds" is
written: in the Definition (inspectable, conflict-analyzable, trace-covered) or
in caller code (invisible to the role-DAG analysis and the routing trace).

**Chartered follow-up direction (in-scope to describe, out-of-scope to
design):** a rule whose receiver is an **action invocation** rather than a chat
delivery —

```yaml
- match: {type: and, items: [{type: from_role, arg: responser},
                             {type: text_matches, arg: "^\\[need-build\\]"}]}
  receivers: [{role: builder, invoke: rebuild, args: {instruction: $message.text}}]
```

Delivery-time semantics: resolve `{:role, builder}` on the member edge as
today, then instead of `agent.receive`, dispatch the named action with args
projected from the message envelope, under a cap MINTED TO THE RULE at install
(the Definition, being the installed authority, is the grantable principal —
this is where ⑤'s symbolic-instance work and this follow-up meet). That gives
native members TABLE reachability without ever giving them a delivery surface —
I-1 survives intact; the table stays model-free; the imperative caller-dispatch
of §3 becomes the compatible degenerate case. To be designed in its own spec
once T1 + ⑤ have landed and the M1 trace exists to observe it; NOT a
prerequisite for anything in §3.

Until then, the boundary rule for authors: **cross-member "when X then verb"
edges SHOULD ride the table when expressible as chat to an adapter-flavor role,
and MAY be caller-dispatch where the target is native** — with the §3.3 cap
story making every such edge at least audit-visible even though table-invisible.

## 6. Invariant tests (the completion gate)

- **T-1 (③ e2e, positive):** materialized hello session (Definition path,
  post-T1); a non-builder principal holding a granted `rebuild` cap dispatches
  `builder.rebuild` with an instruction → `Generator` runs → the session's
  Surface/Turn page artifact is regenerated. Asserts the full (b) chain on the
  REAL socialware materialization path, not a hand-mounted fixture.
- **T-2 (the by-design half, regression lock):** native-flavor member joined
  to a session + a routing rule targeting its role; send a matching chat
  message → assert (i) routing resolved the member (rule hit), (ii) the bridge
  DROPPED delivery (`:no_sandbox_respawn_state` / no-adapter class), (iii) the
  member behavior's `handle_receive` did NOT run, (iv) invocation audit shows
  zero `agent.receive` for the member. Test name and comment must state this
  is I-1's by-design half, so nobody "fixes" it accidentally. This is the
  tribal-knowledge → executable-invariant conversion.
- **T-3 (gate stays closed):** direct-invoke `HelloBuilder.handle_receive`
  with an agent-sender message → no generation started (`from_user?`
  false-path). Cheap unit lock on the rejected (a).
- **T-4 (cap fail-closed):** dispatch `builder.rebuild` without the cap →
  authorization error, no generation; with the owner-granted cap → authorized.
- **T-5 (⑦, conditional on §4.3 = A or B):** Definition with a human role and
  no adapter-flavor receiver for its traffic → Conformance emits the mute-
  composite warning (A) or rejects (B). Written only after the lead decides.

## 7. Builder-verify notes (impl residue — verify at build time, not design)

- **BV-1:** T1's landed interface name/shape for "recipe actions dispatchable
  post-materialization" — align §3.2's recipe wiring and T-1's setup with what
  T1 actually merged (branch `docs/spec-t1-materialize-behavior-fold`; its spec
  file did not exist on main at this spec's baseline).
- **BV-2:** `:rebuild` absent from `Entity.Agent.base_behaviors()` action
  namespace (I-2 corollary); if collided, pick a unique name per the
  `sync_result_action` pattern.
- **BV-3:** exact `hello_builder.ex` gate lines at impl time (─ :55/:74 at
  `dcabf6174`; #1208/#1215 verified to not have moved them, but the file WILL
  move under the hello demo-shape migration).
- **BV-4:** `Generator.start/2` vs `Generator.generate/2` as the correct
  fire-and-forget entry for `handle_rebuild` (both exist; `start/2` wraps the
  Task supervisor — `generator.ex:35-36,165-166`).
- **BV-5:** args schema for dispatch-from-manifest-tools: confirm
  `session_uri` round-trips as string through `dispatch_action/4` and Cmd args
  the way other actions do.
- **BV-6:** routing-trace drop legibility — when the M1 trace records the T-2
  drop, the reason should read as the I-1 class (`no_delivery_surface(native)`
  or the existing `:no_sandbox_respawn_state`), not a generic failure; small
  naming item at the trace call site.
- **BV-7:** the demo hello Definition (`socialware/demo/hello.ex`) declares
  builder/responser as `"py"` flavor while the plugin's own roles run native —
  T-1 must pin WHICH shape it materializes and assert against that one.

## 8. Non-goals

- Re-specifying T1 (declared dependency, §2).
- Designing the table-triggered action invocation (§5 — chartered follow-up
  direction only).
- Designing ⑤'s symbolic instance references (declared dependency of §3.3
  class 3).
- Deciding the §4.3 default-responder policy (lead decision box).
- Deleting `HelloBuilder.handle_receive` / the `from_user?` gate (hello
  cleanup, separate change).
- Any change to adapter flavors' delivery semantics.

## 9. Review status

rev1 — pending codex adversarial review (architecture-level).
