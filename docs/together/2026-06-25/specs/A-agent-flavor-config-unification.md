# SPEC — A: agent flavor + config unification (finish the flavor-plugin contract)

> Sub-task A of the agent-runtime consolidation (allenwoods). Design converged with @林懿伦 (Feishu, 2026-06-25) through brainstorm + a codex adversarial review (see `A-codex-adversarial-review.md`) that revised it. Acceptance = the `/goal` block (§6).

## 1. Problem / north star
**North star (Allen): adding an agent flavor = adding a plugin, ZERO edits to core/domain — and a machine gate that keeps it that way.** Today the flavor-plugin registry exists and is wired, but flavor logic has **leaked into core** (the generic `Kind.Template` knows about agent flavors) and the shared-Kind behavior superset is hardcoded. A finishes the contract AND locks it with an arch gate.

## 2. Current state (code-verified, origin/main @ 8a6dfa7d; cross-checked against gaga's `handoffs/agent-runtime-situation.md`)
> gaga's 现状分析 frames it as 3 orthogonal dimensions — **entrance protocol** × **Kind runtime** × **sidecar**. A owns Kind-runtime + flavor + config; B owns sidecar; C owns entrance/LocalRuntime. 6 AI flavors (cc, cc-headless, codex, codex-remote, curl, echo); **5/6 share `Entity.Agent`**, only echo has its own Kind.
- `Ezagent.Plugin.agent_flavors/0` + `agent_flavor_decl` (`%{flavor, kind, template_class, instance_behaviors}`); `Plugin.boot/1` registers into `Ezagent.AgentFlavorRegistry`. cc/codex/curl/echo all declare it; registry IS consumed.
- behaviors are flavor-plugin-owned via the optional `instance_behaviors` thunk (curl uses it; consumed at `workspace/agent_create.ex:437`).
- **`AgentKind` = `alias Entity.Agent`** (cosmetic). cc/cc-headless/curl all `kind: Entity.Agent`; echo = `Entity.Echo`.
- **Flavor leaked into core**: `Ezagent.AgentFlavorRegistry`/`AgentFlavorResolver`/`AgentFlavorAttributes` live in **ezagent_core**; core's generic `Kind.Template` calls them via `maybe_store_agent_flavor`/`delete_agent_flavor` (`kind/template.ex`). ETS owned by `ets_owner.ex:68,73`; `plugin.ex:469` registers. Domain readers: domain_agent (delivery/receive/curl_agent/template_spawn), domain_session (uri_query_resolvers), domain_workspace (agent_create).
- `Entity.Agent.behaviors/0` = hardcoded `base_behaviors() ++ [CurlAgent, CcHeadlessAgent]`.
- `Ezagent.AgentConfig` (in **ezagent_domain_identity**, deps core) → `Ezagent.Socialware.ConfigStore` (also identity). **world already calls AgentConfig** (`world/agent_actions.ex`, `identity_data.ex` + 2 tests). echo is **test-only** (zero production-flow dependency outside its own plugin; ~77 test/seed refs).

## 3. Decisions (Allen-ratified, post-review)
- **D1** `Entity.Agent.behaviors/0` becomes **registry-derived** (base + union of registered folded-flavor `instance_behaviors`), with a **boot-order guarantee** (all flavor plugins registered before the first `:kind_base` capture — else the cold-restart bug class #110/#113/#114 returns; `BehaviorSet.init_set/2` intersects + first spawn persists).
- **D3** **Replace** `Ezagent.AgentConfig` with a **domain.agent config API** (NOT delete): domain.agent exposes the agent-facing config surface (wrapping identity's `ConfigStore`/cascade); **world migrates its calls** to it. `domain_agent → domain_identity` is acyclic-safe (identity doesn't dep agent).
- **D4 (now)** **De-leak core + move the flavor cluster to domain.agent, locked by an arch gate:**
  - (a) Invert core `Kind.Template`'s flavor coupling: `maybe_store_agent_flavor`/`delete_agent_flavor` call a **registered Template hook/behaviour** (implemented in domain.agent), so core no longer references `AgentFlavorAttributes`.
  - (b) Move `AgentFlavorRegistry` + `AgentFlavorResolver` + `AgentFlavorAttributes` + their ETS tables + boot registration from core → domain.agent. Domain readers already can dep domain.agent; the only core reader (Kind.Template) is decoupled by (a).
  - (c) **Add arch gate `no_flavor_refs_in_core` (baseline 0)**: `ezagent.arch.scan` flags any `apps/ezagent_core/**` reference to `AgentFlavor*` / flavor-specific symbols. **This gate is the future-proof guarantee** — any future flavor leak into core fails CI.
- **D5** Per-flavor **config schema** enters `agent_flavor_decl` (console renders fields generically from the registry).
- **D6** Drop the `AgentKind` alias (use `Entity.Agent` explicitly).
- **echo → DELETE, via py-agent-first (sequenced FOLLOW-UP sub-task, not in A — see §8).**

## 4. Design (A core)
**D4** is the spine: after (a)+(b), domain.agent owns the entire flavor subsystem; core is flavor-blind; (c) locks it. The Template hook is a small behaviour (`store_flavor_attrs/2` + `delete_flavor_attrs/1`) registered like other plugin/domain seams. **D1** then derives `behaviors/0` from the (now domain.agent-resident) registry, guarding boot order. **D3** adds a domain.agent config-API module over identity's ConfigStore; world swaps its 2 call sites. **D5** extends the decl + registry value. **D6** is cosmetic.

**Plugin-isolation invariant (the gate, §D4c):** core has zero flavor references; adding a flavor plugin touches only its own dir. This is the machine guarantee Allen asked for.

## 5. Risks (for implementation vigilance)
- **R1 boot-order (D1)** — registry must be fully populated before first `:kind_base` capture; echo/curl `after_boot` seeding is an early read. Add an explicit ordering guarantee + a regression test.
- **R2 core Kind.Template inversion (D4a)** — Kind.Template is used by ALL kinds; the hook inversion must preserve exact current behavior (store/delete flavor attrs on template instantiate/delete). High blast radius → test thoroughly.
- **R3 registry move (D4b)** — ETS ownership + boot registration move; verify no boot race (registry available before first read) and that `plugin_world/identity_data.ex` (a reader) still resolves.
- **R4 D3 dep edge** — adding `domain_agent → domain_identity`: confirm identity never deps agent (verified: it doesn't) so no cycle.

## 6. /goal (acceptance — Allen sets after review)
```
A 完成 = 全部满足：
1. core 不再引用任何 flavor 符号：arch gate no_flavor_refs_in_core 基线=0 且通过；
   AgentFlavorRegistry/Resolver/Attributes + ETS + boot 注册都在 domain.agent；
   core Kind.Template 经注册回调存/删 flavor attrs（不直接调 AgentFlavorAttributes）。
2. Entity.Agent.behaviors/0 从 registry 推导（base + 已注册 folded flavor instance_behaviors
   并集），无硬编码 flavor behaviors；有 boot 顺序保证 + 回归测试（冷重启不丢 behavior）。
3. AgentConfig 由 domain.agent 的 config API 替代（保留 cap 门控）；world 调用已迁移；
   per-flavor config schema 进 flavor decl。
4. cc/codex/curl 全 kind: Entity.Agent（清掉 AgentKind 别名）。
验收：全量 mix test 0 失败 + CI 绿；no_flavor_refs_in_core gate 通过；
"加 flavor=加 plugin、零 core 改动"不变量测试通过；world config 面板经 domain.agent API 读写。
（echo 仍存在，作为 §8 跟进删除——A 不动 echo。）
```

## 7. PR breakdown (A)
- **PR-A1** D4a — invert core `Kind.Template` flavor coupling via a registered Template hook (domain.agent implements). Behavior-preserving.
- **PR-A2** D4b+D4c — move flavor cluster core→domain.agent + ETS + boot; add `no_flavor_refs_in_core` gate (baseline 0). Depends on A1.
- **PR-A3** D1 — behaviors/0 registry-derived + boot-order guarantee + cold-restart regression test. Depends on A2.
- **PR-A4** D5 — config_schema in `agent_flavor_decl` + registry value.
- **PR-A5** D3 — domain.agent config API + migrate world's calls off `Ezagent.AgentConfig`. Coordinate gaga (he's wiring the console against the config contract).
- **PR-A6** D6 — drop AgentKind alias (trivial; may fold into A2).
- Each PR: four-property DoD + CI green + rebase. A2/A3 are the high-blast-radius ones.

## 8. Follow-up sub-task (sequenced AFTER A) — echo → py-agent → delete echo
Build a `python` program-agent flavor as a NEW flavor plugin (kind: Entity.Agent, folded; replies by loading+running a py script; **uses the shared `Behavior.Agent.Receive`** + a `PyAgent` flavor behavior — so it does NOT override `:receive` and avoids the `{Entity.Agent,:receive}` CapabilityRegistry collision that blocked folding echo). Provide a trivial `echo.py` so py-agent is a deterministic no-LLM test fixture. Migrate echo's ~77 test/seed refs → py-agent, then **delete echo + `Entity.Echo`**. Depends on A's unified flavor contract. Its own spec.
