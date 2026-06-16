# #54 deferral (1) — thread role caps + behaviors into the agent spawn path

> Branch `task/54-d1-caps-behaviors-spawn`. Builds on PR-2 (#803) which wired the
> role's **content** (skills) into the cc orchestrator seam.
>
> **OUTCOME: this lands the fail-closed authorization+mint MECHANISM + the
> empirical proof that DELIVERY is blocked on an architecture Decision. It does
> NOT wire role caps (or behaviors) into the live spawn — both are blocked by ONE
> shared root cause (below). Per the task's "if you hit a Decision, STOP and
> report it — don't decide it yourself", the delivery seam awaits Allen.**

## The decisive finding: role caps and role behaviors are ONE problem

Both are **per-instance composition supplied at `Kind.spawn`**:

- behaviors → `init_args[:behaviors]` → `Ezagent.Kind.BehaviorSet.init_set/2`
  (intersected with the Agent Kind's declared `behaviors/0` superset);
- caps → `init_args[:initial_caps]` → `Ezagent.Behavior.Identity.init_slice/1`
  (the agent's **born-with** caps).

The `curl` flavor reaches both because it calls `Ezagent.Kind.spawn(Entity.Agent,
init_args)` **directly** inside its `instantiate/3` (see `curl_agent.ex` —
`behaviors: Entity.Agent.curl_behaviors()`). The `cc` flavor spawns its Agent
Kind via `Ezagent.SpawnRegistry.spawn_detailed(agent_uri)` whose registered
scheme fn is **arity 1 (URI only)** — it can pass NEITHER `:behaviors` NOR
`:initial_caps`. That single contract is the shared blocker for both halves of
#54 deferral (1).

## What was investigated (verified against current code)

- **Seam with full grant ctx:** `Ezagent.Entity.Agent.TemplateSpawn.spawn_after_cascade/6`
  is the only domain-side post-cascade step with all four CapMint axes together
  (`instance_uri`, `spawned_by_uri` = granter, `workspace_uri`, resolved `flavor`).
  The cc plugin path (`CcAgent.instantiate/3` = `(tmpl_name, tmpl, workspace_uri)`)
  has **no granter** and cannot resolve the role recipe (cc-side `OrchestratorRole`,
  unreachable from domain). So caps cannot thread cc-side; they must be domain-side.
- **No existing grant-at-spawn seam.** Per `docs/notes/pr6-desired-skills-caps.md`:
  "no call site reads `content.default_caps` to grant the spawned agent identity
  caps." `desired_caps` data is threaded but its live grant is a deferred PR-5
  (`reconfigure`) consumer. `Orchestrator.Caps` grants caps to the ORCHESTRATOR
  itself (caller=owner / workspace-admin via wildcard-behavior caps), not to a
  spawned worker.

## The mechanism that IS implemented + proven (unwired)

`Ezagent.Entity.Agent.TemplateSpawn.grant_role_caps/5` (`@doc false`, retained as
EVIDENCE, **not called** in production):

1. role requested caps ride content as `role_requested_caps` (a list of
   `%{behavior:, action:}` request templates — distinct from `default_caps`
   [structural, unconsumed] and `desired_caps` [direct additive grant, PR-5]).
   It survives `resolve_cascade_content` (augments via `Map.put`, no whitelist).
2. `Ezagent.Role.new/1` → `Ezagent.Role.Materialize.materialize/4` — reuses the
   fail-closed flavor-Kind derivation (rejects `:any`/nil/non-atom) + `CapMint`.
3. **policy = granter-delegation** (the only NEW logic beyond core #800): read the
   granter's `:identity` caps ONCE via core `Ezagent.Kind.get_slice/2` (fail-closed
   → empty set on any miss) and keep only caps the granter holds
   (`Capability.matches?/2`). It does NOT honor Kind-specific `holds_cap?`
   overrides — granter-delegation by LITERAL held caps. You cannot delegate what
   you don't hold; forward-compatible with a future per-flavor policy.

**Proven fail-closed (the task's checkable property — `RoleCapsMechanismTest`,
5/0):** a requested cap the granter does NOT hold is rejected by CapMint BEFORE
any grant; a wildcard `%{behavior: :any, action: :any}` is dropped by CapMint
`well_formed?` (never minted, never granted); an unknown flavor degrades
best-effort (grants nothing). A correct rejection is NOT a `role_degraded`. This
property — "caps are fail-closed; a degraded role never grants a wildcard" —
holds unconditionally.

## Why DELIVERY is blocked — for the realistic caps (the architecture Decision)

> **Corrected after codex adversarial-review (incorporated, see below): delivery
> is NOT universally blocked. It is blocked for caps whose behavior's
> `data_owner` resolves to the AGENT ITSELF; it already works today for
> behaviors whose `data_owner → :any`.**

Every minted cap is `kind: :agent` + a CONCRETE `behavior` (CapMint drops
wildcard-behavior requests). The `identity.grant_cap` chokepoint authorizes a
concrete cap by the **data-owner of the cap's `behavior` at the target
instance**:

- **`data_owner = self` behaviors (Identity-family).** `Identity.data_owner(uri)
  = uri` — an agent owns its own identity. The grant requires `caller == owner`
  or `holds_admin_caps?`. The granter (owner / orchestrator) is NOT the agent,
  and no reachable materialization principal holds the bootstrap wildcard
  `holds_admin_caps?` needs (`template-materialize` has a `:user`-kind
  `grant_cap`, not the bootstrap `[:any,:any,:any,:any]`). → **`:grant_not_owner`.**
  `RoleCapsMechanismTest`'s "delivery blocker" case proves this with the admin
  (wildcard-holding) granter: the Identity cap is authorized + minted, the grant
  is REFUSED.
- **`data_owner → :any` behaviors (e.g. `Behavior.WorkspaceUserAdmin`).** The
  chokepoint routes these to `require_workspace_admin`, which
  `template-materialize`'s `cap(:workspace, Workspace, :any)` already satisfies →
  the grant **succeeds today**.

So peer-grant delivery is **asymmetric by `data_owner`**, not uniformly blocked.
Whether the realistic role caps (the design's "PTY/bridge-driving cap") are
deliverable today depends on which `data_owner` their behaviors resolve to — a
weigh-point for the Decision below.

## codex adversarial-review — incorporated (one HIGH, folded in)

codex correctly found that (a) the "delivery always blocked / always
`:grant_not_owner`" claim was too strong (the `data_owner → :any` path above),
and (b) the unwired `grant_caps_to_worker/3` grants minted caps one-by-one with
NO rollback, so a MIXED requested-cap list (a `data_owner → :any` cap that grants
+ an Identity cap that fails `:grant_not_owner`) would leave a PARTIAL grant while
returning `role_degraded` — i.e. "a degraded role grants NOTHING" does NOT hold
for mixed lists. Both are corrected here: the claim is narrowed to the data-owner
boundary, and **multi-cap atomicity** is recorded as an explicit option-(b)
constraint (NOT fixed — building revoke-on-failure into unwired evidence would be
over-engineering, and option (a) makes the function moot). The task's gate
(wildcard never minted; unauthorized rejected before grant) is unaffected — codex
confirmed it.

## Options for Allen (do NOT decide here)

- **(a) Born-with `initial_caps`** (correct model — caps are the agent's own
  initial caps, symmetric with curl's `:behaviors`). Requires: widen the arity-1
  `SpawnRegistry.spawn_detailed/1` scheme-fn contract to carry `init_args`
  (touches the codex-hardened atomic `:started`/`:already_started` signal) AND
  move cap minting AHEAD of `instantiate` (mint needs granter/workspace ctx that
  only `spawn_after_cascade` has today, but `Kind.spawn` runs inside
  `instantiate`) + thread minted caps into the Template-Class data map. This is
  the same contract change that unblocks role BEHAVIORS.
- **(b) Peer-grant** (what the mechanism tries): for `data_owner = self` caps
  (Identity-family) add a materialization SystemPrincipal authorized to grant a
  CONCRETE cap onto a fresh agent identity (a catalog/authority change), OR relax
  the `grant_cap` data-owner clause for spawn-time materialization. **Two
  constraints:** (1) a **data-owner asymmetry** — `data_owner → :any` caps
  already grant via the existing workspace-admin path, only `data_owner = self`
  caps are blocked; (2) **multi-cap atomicity** — `grant_caps_to_worker` grants
  one-by-one with no rollback, so a mixed list can partially deliver; a real
  option-(b) needs all-or-nothing (revoke-on-failure, which itself can fail).
  These constraints are why option (b) is a workaround, not the model.
- **(c)** something else Allen sees.

## Not regressed / not touched

- `OrchestratorRole.recipe` stays `requested_caps: []` / `behaviors: []` —
  production threads zero (zero regression); populating it = an authority change
  (a separate Decision).
- The live spawn lane (`spawn_after_cascade`) has NO dead/degrading call — the
  mechanism is referenced only by its test.
- The persisted-role-Template-Kind / `template://` SpawnRegistry resolver
  (deferral (2)) is untouched.
