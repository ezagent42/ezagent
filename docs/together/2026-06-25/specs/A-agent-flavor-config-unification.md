# SPEC — A: agent flavor + config unification (finish the flavor-plugin contract)

> Sub-task A of the agent-runtime consolidation (allenwoods). Design converged with @林懿伦 (Feishu, 2026-06-25). This spec is the input to **codex adversarial review** + Claude self-review before implementation. Acceptance = the `/goal` block (§6).

## 1. Problem / north star
**North star (Allen): adding an agent flavor should = adding a plugin, with ZERO edits to core/domain.** Today that's *almost* true — the flavor-plugin registry exists and is wired — but three hold-outs still force core edits or break uniformity. A finishes the contract.

## 2. Current state (code-verified, origin/main @ 1901dd35)
- `Ezagent.Plugin` declares `@callback agent_flavors/0` + `agent_flavor_decl` type. **cc/codex/curl/echo all implement it**; `Plugin.boot/1` registers each into `Ezagent.AgentFlavorRegistry`.
- `Ezagent.AgentFlavorRegistry` (in **ezagent_core**) = ETS `flavor → %{kind, template_class, instance_behaviors}`. It **is consumed** (template_spawn, agent_template, domain_session resolver, workspace/agent_create). (Its moduledoc "nothing reads it yet" is STALE.)
- **behaviors are already flavor-plugin-owned** via the optional `instance_behaviors` 0-arity thunk in the decl (curl uses it; consumed at `workspace/agent_create.ex:437`).
- **`AgentKind` is just `alias Ezagent.Entity.Agent, as: AgentKind`** (cc app) — cosmetic. So **cc / cc-headless / curl are all `kind: Entity.Agent`**.
- **echo is the only outlier**: `agent_flavors` declares `kind: Ezagent.Entity.Echo` — its OWN Kind, not folded onto `Entity.Agent`.
- `Entity.Agent.behaviors/0` is **hardcoded** `base_behaviors() ++ [CurlAgent, CcHeadlessAgent]` — the shared-Kind behavior superset. Folding a new flavor onto `Entity.Agent` currently means editing this line → the remaining plugin-isolation leak.
- `Ezagent.AgentConfig` lives in **ezagent_domain_identity** (deps core only) — cap-gated config CRUD + #17 cascade. domain_agent does NOT dep domain_identity.

## 3. Decisions (Allen-ratified)
- **D1** `Entity.Agent.behaviors/0` becomes **registry-derived** — the union of registered folded-flavor `instance_behaviors` (+ base), not a hardcoded list. → folding a flavor = zero core edit.
- **D2** **echo folds onto `Entity.Agent`** (`kind: Entity.Agent`, `instance_behaviors: fn -> base ++ [Behavior.Echo] end`); retire the standalone `Entity.Echo` Kind. **echo is KEPT** (it's the deterministic no-LLM test fixture behind ~10 e2e/integration tests + seeds). The `python` program-agent is a **separate future flavor plugin** (logged in `docs/futures/todo.md`), NOT bundled here.
- **D3** **Remove the standalone `Ezagent.AgentConfig` access layer**; fold agent config CRUD into **domain.agent**. gaga's console calls domain.agent's config API directly (no preserved facade — "just an interface change"). Caveat to resolve in impl: the #17 credential-cascade coupling must not create a `domain_agent → domain_identity` cycle (split: config-value CRUD → domain.agent; credential-cascade stays identity-side or is injected).
- **D4** **Move `AgentFlavorRegistry` code core → domain.agent** (semantic ownership = physical location). Dep check: domain_agent deps only core+agent_bridge, so domain_session/workspace → domain_agent (readers) is acyclic-safe.
- **D5** **Per-flavor config schema enters the flavor decl** (`agent_flavor_decl`), so the console renders each flavor's config fields generically from the registry.
- **D6** Clean up the `AgentKind` alias → use `Entity.Agent` explicitly (cosmetic, all flavors visibly one Kind).

## 4. Design
**Flavor contract (the one place a flavor plugin declares itself):** extend `agent_flavor_decl` to `%{flavor, kind, template_class, instance_behaviors, config_schema, bridge_adapter}`. A flavor plugin's `agent_flavors/0` is the SOLE thing it must provide; `Plugin.boot/1` registers it. Core/domain reads the registry generically.

**Components**
- `AgentFlavorRegistry` (→ domain_agent): same ETS shape + `config_schema`; ETS owner moves with it (or stays an EtsOwner table re-pointed). `register/1` validates the extended decl.
- `Entity.Agent.behaviors/0`: derive from `AgentFlavorRegistry` — `base_behaviors() ++ Enum.uniq(all registered folded-flavor instance_behaviors)`. (Folded = `kind == Entity.Agent`.) Resolution at the same point it's read today; must be deterministic + boot-order-safe (registry populated before first agent spawn — verify the boot sequence).
- echo plugin: `agent_flavors/0` → `kind: Entity.Agent` + `instance_behaviors`; delete `Entity.Echo`; keep `Behavior.Echo` + template + bridge_adapter. All echo-dependent tests/seeds stay green.
- domain.agent config API: the CRUD surface (read_cascade / read_key / apply_delta / delete_path / repoint equivalents) lives on domain.agent; cap-gating preserved; per-flavor schema from the registry.

**Plugin-isolation invariant (the gate):** a test that asserts no core/domain module hardcodes a `flavor → behaviors` (or `flavor → kind`) mapping — i.e. adding a flavor plugin requires zero edits outside its own dir.

## 5. Risks / open points (for codex review to probe)
- **R1 boot ordering**: behaviors/0 reads the registry — are all flavor plugins registered before the first `Entity.Agent` spawn / before `behaviors/0` is first evaluated (compile-time vs runtime)? If `behaviors/0` is used at compile-time anywhere, registry-derivation breaks.
- **R2 AgentConfig fold cycle**: does the config CRUD pull identity/credential modules such that domain_agent would dep domain_identity? Need the split line.
- **R3 echo fold parity**: does `Entity.Echo` carry any behavior/lifecycle not expressible as an `Entity.Agent` instance_behaviors subset (delivery/bridge transport class)?
- **R4 registry move**: any core module currently reads AgentFlavorRegistry (would force core → domain_agent)? (survey showed readers are in domain_*; confirm none in core.)
- **R5 gaga console contract churn**: removing AgentConfig changes the console's backend calls — coordinate the new domain.agent config API shape with gaga before he wires the panel.

## 6. /goal (acceptance — Allen to set after review)
```
A 完成 = 全部满足：
1. Entity.Agent.behaviors/0 从 AgentFlavorRegistry 推导（base + 已注册 folded flavor
   instance_behaviors 并集），无硬编码 flavor behaviors；折叠一个 flavor 零 core 改动。
2. echo 折叠为 Entity.Agent flavor（instance_behaviors: base++[Echo]），退役 Entity.Echo；
   所有依赖 echo 的测试/seed 仍绿。
3. 去掉独立 Ezagent.AgentConfig，agent config CRUD 收拢进 domain.agent（cap 门控保留），
   per-flavor config schema 进 flavor decl；gaga console 改调 domain.agent config API。
4. AgentFlavorRegistry 代码移到 domain.agent；cc/codex/curl/echo 全 kind: Entity.Agent
   (清掉 AgentKind 别名)；arch gate：无核心硬编码 flavor→behaviors/kind 映射。
验收：全量 mix test 0 失败 + CI 绿；"加 flavor=加 plugin、零 core 改动"不变量测试通过；
echo 相关测试全绿；gaga 能经 domain.agent config API 读写。
```

## 7. PR breakdown (proposed)
- **PR-A1** behaviors/0 registry-derived + plugin-isolation invariant test (D1) — smallest, unblocks the pattern.
- **PR-A2** AgentFlavorRegistry core→domain.agent + AgentKind alias cleanup (D4, D6).
- **PR-A3** echo fold + retire Entity.Echo (D2) — depends on A1 (registry-derived behaviors).
- **PR-A4** AgentConfig fold into domain.agent + config_schema in decl (D3, D5) — coordinate gaga (R5).
- Each PR: four-property DoD + CI green + rebase.
