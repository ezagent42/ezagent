# spec-2 — tools[] (dispatch-backed) + type-transparent participant / escalation

- **Date:** 2026-06-21
- **Status:** Draft (for codex adversarial review → plan/handoff)
- **Parent design:** `2026-06-21-agent-definition-contract-design.md`
- **Lands on:** `main`. Generalizes the orchestrator MCP-tool mechanism + `add_managed_member`; reuses the type-blind `chat.join` / `Resolver`.
- **Gate owned:** G3 (type-transparent escalation).
- **Depends on:** spec-1 (`flavor.compile` emits the per-flavor MCP config that tool decls land in).

---

## 1. Scope

**In:**
1. `tool_decl` schema in the manifest's `tools[]` — two kinds: `:action` and `:participant`.
2. **tool → MCP injection**: a generic "manifest tool ⇒ MCP server entry whose body is an authorized ezagent dispatch", emitted by `flavor.compile` (cc/codex). The harness calls the MCP tool; ezagent runs the backing dispatch under CapBAC.
3. `:participant` tool — **generalize** `Ezagent.Orchestrator.Tools.add_managed_member` so the participant ref can be an **agent manifest (spawn+join)** OR an **existing entity URI (join only — human/program)**, both ending at the type-blind `chat.join`.
4. Prove **type transparency**: a human member and an agent member are indistinguishable to routing; "can't answer → @operator" routes a human via the same `Resolver`/`chat.join`.

**Out:** the persona/instructions compile (spec-1); versioning (spec-3); arbitrary author-code function tools (rejected — harness's job, P14 risk); the autoservice-specific Turn-takeover UX (`cs_orchestrator.operator_claim` lives on `feat/autoservice-*`; spec-2 proves the routing/membership transparency it relies on, not the Turn UX).

---

## 2. Current state on `main`

| Concern | Module / fn | Note |
|---|---|---|
| orchestrator MCP tools | `Ezagent.Orchestrator.Tools` `run_tool` / `Tools.invoke/2` | tools are already exposed to cc as MCP, backed by dispatch — the pattern we generalize |
| add member (agent) | `Ezagent.Orchestrator.Tools.add_managed_member/4` (`orchestrator/tools.ex:130`) | spawn-from-AgentTemplate then join; we widen the ref |
| join (type-blind) | `Ezagent.Behavior.Session` `chat.join` / `Session.Membership` | works for user OR agent member_uri (verified) |
| routing resolve | `Ezagent.Routing.Resolver.resolve/3`, `Matcher`, `RuleStore` | flat recipient list, no type branch; tokens `$session_members`/`$session_users`/`$mentions` |
| cap chokepoint | `Kind.holds_cap?/2` at dispatch | every `:action` tool is CapBAC-governed here |

**Not on main:** `EzagentPluginAutoservice.Behavior.CsOrchestrator.operator_claim/settle` (Turn takeover) is autoservice-branch. spec-2 delivers the *general* type-transparent participant/escalation; the autoservice Turn UX consumes it.

---

## 3. Design

### 3.1 `tool_decl` schema

```elixir
# tools[] entries
%{name: "notify_owner",     type: :action,
  action: "entity://…?action=notifications.notify", caps: [<cap_template>]}     # → dispatch
%{name: "add_researcher",   type: :participant,
  ref: "agents/researcher" | "entity://ws/user/op", role_name: "researcher"}    # → spawn?+join
```

- `:action` — `action` is a dispatch target (URI?action=behavior.action); `caps` declares the authority the tool needs (granted to the agent's identity at spawn, via spec-1's `caps`).
- `:participant` — `ref` is an **agent manifest** (spawn from it) or an **existing entity URI** (invite). `role_name` slots it into the team.

### 3.2 tool → MCP injection (the universal seam)

`flavor.compile` (cc/codex), given the resolved manifest's `tools[]`, emits **one MCP server entry per tool** into the backend's MCP config. Each entry's handler is an ezagent endpoint that, on invocation by the harness, builds an `%Invocation{}` and dispatches.

**CapBAC — manifest caps NEVER reach `ctx.caps` (codex P1-1).** The runtime authorizes `ctx.caps` *before* the `holds_cap?` Identity-slice check (`kind/runtime.ex:405` runs `granted_via_ctx_caps?` ahead of `granted_via_holds_cap?` at `:409`). So a tool endpoint must **NOT** put the manifest's declared `caps` into the dispatch `ctx` — that would let tenant-authored YAML self-authorize. Instead:

```
harness calls MCP tool ─▶ ezagent tool endpoint ─▶ %Invocation{target, args, ctx:{caller: agent_uri, caps: []}} ─▶ dispatch
                                                                                  └── ctx.caps EMPTY → authz falls to
                                                                                      holds_cap?(agent's Identity slice)
```

- The agent's authority lives in its **Identity slice**, granted at spawn from the manifest's `caps` via the Identity grant path (spec-1 §3.1). The tool dispatch carries an **empty `ctx.caps`**, so `holds_cap?/2` checks the agent's *actually-granted* caps — manifest YAML can declare a desire, never an authorization.
- `:action` → dispatch to the declared Behavior action; authorized iff the agent's Identity holds the cap. A tool whose cap was never granted is rejected at the chokepoint.
- `:participant` → the participant flow (§3.3).
- **No silent drop on tool-less flavors (codex P2-7):** a flavor with no MCP tool transport (e.g. raw curl) and a **non-empty** `tools[]` must **fail `compile`** (or surface an explicit `:tools_unsupported` degraded warning on the owner-notify path, Invariant #9) — unless each such tool is marked `optional: true`. Silently dropping declared tools violates P18 (no silent drops).

### 3.3 `:participant` — generalize `add_managed_member`

**Design requirement:** an invited participant must end up **able to participate** in the session (send/receive/leave) with **session-scoped authority only** — never a workspace-wide grant, never a bare join that leaves a human unable to act. `add_managed_member`'s spawned-agent path already establishes this; the new "invite an existing entity" path must reach the **same end-state** (join authority + session-scoped participation), whether the invitee is a brand-new non-member human, an existing user, or a program.

```
add_participant(ref, role_name, opts):
  preflight {:within_session, S} cap                  # fail-closed before any spawn
  ref = agent manifest  ⇒ spawn (spec-1), then admit
  ref = existing URI    ⇒ admit (no spawn)
  admit = provision session-scoped join + participation authority, then join as `role_name`
  on failure after a fresh spawn ⇒ compensate (terminate + revoke)
```

The end-state is **type-blind** (same for human/agent/program). 

> **Plan-time (not spec):** the exact provisioning path — which `Membership` entry point admits a *brand-new non-member* invitee, and from whose authority the session-scoped grant is minted — is resolved against the live `membership.ex`/`tools.ex` join code during planning, per the CapBAC principles (granter authority, no over-grant). The spec fixes the *requirement* (session-scoped participation, no over-grant, no bare-join), not the call sequence.

### 3.4 Type-transparent escalation

"Can't answer → @operator" is **not** a special escalation path: `operator` is an existing human member; a routing rule (or a `:participant`/`:action` tool) routes to it through the **same** `Resolver`/`chat.join`. spec-2 asserts indistinguishability; the autoservice Turn-takeover (claim/settle) is a downstream consumer.

---

## 4. Invariants / CI gates

- **G-INV-5** Every `tools[]` body is a dispatch — no tool executes author code in-process (P14; grep-gate: no eval/apply of manifest-supplied code).
- **G-INV-6** Tool dispatch carries **`ctx.caps = []`** — manifest-declared `caps` are NEVER injected into a dispatch ctx (codex P1-1). Authorization is `holds_cap?/2` against the agent's Identity grants only. (grep-gate: no manifest cap flows into `%Invocation{ctx: %{caps: …}}`.)
- **G-INV-7** `:participant` runs join-authority provisioning + participation-cap mounting (`Membership.provision_join_authority`/`mount_participation_caps`) for BOTH spawn-and-invite paths; participation caps are session-scoped, not workspace-wide; fresh-spawn failure compensates (terminate + revoke) — no orphan.
- **G-INV-8** Routing/membership never branch on entity type (existing invariant; spec-2 must not introduce a type check).
- **G-INV-9** A non-empty `tools[]` on a tool-less flavor fails compile or surfaces an explicit degraded warning (P18 no-silent-drop) — never silently dropped.

---

## 5. VERIFICATION

### E2E
- **G3** — in one session: add a `:participant` with `ref = agent manifest` (spawns+joins an agent) and a `:participant` with `ref = entity://…/user/op` (invites the human). Assert: both sit in `slice.members` indistinguishably; a `$session_members` fan-out reaches both via the same `Resolver`; an "escalate to @operator" tool routes to the human through `chat.join`'s path (no type branch); **the invited human can send/receive/leave the session (participation provisioned) but holds NO workspace-wide cap** (scope check); **a manifest declaring an `:action` cap the agent was never granted is DENIED at the chokepoint** (`ctx.caps` is empty; `holds_cap?` fails).

### Unit / integration
- `tool_decl` validation (`:action` requires `action`+`caps`; `:participant` requires `ref`).
- tool → MCP entry emission for cc/codex; curl emits none.
- `:action` dispatch denied when agent lacks the cap (CapBAC).
- `add_participant` with manifest ref (spawn+join) and URI ref (join only); join-failure compensation leaves no orphan.

### Falsifiers (must stay red)
- a tool invocation that runs author code rather than a dispatch; **a manifest-declared cap that authorizes a dispatch via `ctx.caps`** (P1-1); an `:action` tool that reaches its Behavior without a cap check; **an invited human who cannot send/receive/leave, OR who receives a workspace-wide grant** (P1-2 over/under-grant); a routing path that treats the human member differently from the agent member; an orphan agent after a failed participant join; **a tool-less flavor silently dropping a non-empty `tools[]`** (P2-7).

---

## 6. Dependencies & risks

- **spec-1** must land first (`compile` is where tools become MCP config).
- **curl/no-MCP flavors**: a non-empty `tools[]` fails compile or surfaces an explicit degraded warning (§3.2, G-INV-9) — never silently inert.
- **autoservice Turn UX** (`operator_claim`) is on a sibling branch — G3 verifies the transparency it depends on, not the Turn lifecycle itself.
