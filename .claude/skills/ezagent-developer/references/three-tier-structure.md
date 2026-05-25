# Three-tier project structure

Every contribution lives in one of three tiers. Knowing which tier you're in tells you what dependencies you may take, what abstractions you may reach for, and what reviewers will look for.

## Tier 1 — `core` (`apps/ezagent_core/`)

**Primitives only.** No domain logic, no Kinds with business semantics. Modules here are reused by every domain + plugin. The `Ezagent.*` namespace owner.

Includes:
- URI parser + `Ezagent.URI.SchemeRegistry` (`apps/ezagent_core/lib/ezagent/uri.ex`, `apps/ezagent_core/lib/ezagent/uri/scheme_registry.ex`)
- Registries: `KindRegistry`, `BehaviorRegistry`, `SpawnRegistry`, `TemplateRegistry`, `RoutingRegistry`, `WorkspaceRegistry`
- Dispatch: `Ezagent.Invocation`, `Ezagent.Kind.Runtime`, `Ezagent.Kind`, `Ezagent.Behavior`
- Capability: `Ezagent.Capability`, `Ezagent.Capability.*`
- Persistence infra: `Ezagent.EtsOwner` (`apps/ezagent_core/lib/ezagent_core/ets_owner.ex`), `Ezagent.Audit`, `Ezagent.MessageStore`, `Ezagent.Message`, `Ezagent.ReadyGate`, `Ezagent.PendingDelivery`, `Ezagent.Snapshot.*`
- Routing infra: `Ezagent.Routing.Resolver`, `Ezagent.Routing.RuleStore`, `Ezagent.Routing.Matcher`
- Workspace primitive: `Ezagent.Workspace.*` (Kind contract + Loader; no plugin-specific behavior)
- SystemPrincipal catalog: `Ezagent.SystemPrincipal.Catalog` (closed 14-URI allowlist; introduced by PR-CC-1 ambient-authority removal — 2026-05-25)

**Rules**:
- `core` may NOT depend on any `domain_*` or `plugin_*` app.
- Adds new abstractions ONLY when shared by ≥2 downstream tiers.

## Tier 2 — `domain` (`apps/ezagent_domain_*/`)

**First-class domain Kinds + Behaviors.** Load-bearing — you cannot uninstall a domain app without breaking the system. The vocabulary that ezagent is FOR.

Apps:
- `ezagent_domain_chat` — Session Kind, Agent Kind, Chat Behavior, SessionTemplate, AgentTemplate, GenericSession Template Class, orchestrator tools, FeishuOutbound Behavior (moved here in PR #143, see invariant 8)
- `ezagent_domain_identity` — User Kind, Identity Behavior, ApiKeys Behavior, UserCredentials Behavior (set_password), UserTokens Behavior (mint/list/revoke), Entity facade (`Ezagent.Entity.authenticate/2`), Users provisioning, Token + ApiKey tables. Feishu UserBinding + SessionBinding Behaviors live here as per-Kind chokepoints (PR #355 case study).
- `ezagent_domain_workspace` — Workspace Kind, Workspace Loader, DefaultRules, WorkspaceUserAdmin Behavior (privileged `:create_user` carved out from generic Workspace per PR #356 codex r1 CRIT)
- `ezagent_domain_python` — Python sidecar runner (PyProcess wrapper around erlexec)
- `ezagent_domain_ui` — UI primitives library (`Ezagent.UI.IdeShell`, button/card/badge/status_dot/uri_chip/modal/...); shadcn-inspired; consumed by `ezagent_plugin_liveview` + `ezagent_web`
- `ezagent_domain_external_mirror` — outbound mirror Domain (Adapter / Binding / Worker / facade) — see invariant 15

**Rules**:
- `domain_*` MAY depend on `core` and on other `domain_*` apps as needed (with care to avoid cycles — `domain_identity` cannot depend on `domain_chat`, see invariant 6).
- Adds first-class Kinds/Behaviors only.

## Tier 3 — `plugin` (`apps/ezagent_plugin_*/`)

**Optional features.** Each plugin is a separate OTP app and can be added or removed without core/domain changes. The north-star property: "future devs work on different plugins without coordination" (per Allen's `feedback_north_star_plugin_isolation`).

Apps:
- `ezagent_plugin_cc` — Claude Code agents (cc.agent Template Class, PtyServer, BridgeRegistry, MCP config writer, CC channel). The cc-flavored agents register under `entity://agent/cc_<name>` (PR #141 + #149 — AgentTypeRegistry deleted; flavor is name-prefix, kind_module wiring lives on the Template per SPEC v2 §5.14).
- `ezagent_plugin_curl_agent` — HTTP-API agents (curl-flavored, `entity://agent/curl_<name>`)
- `ezagent_plugin_echo` — test/reference stub plugin (`entity://agent/echo_<name>`)
- `ezagent_plugin_feishu` — Lark integration (FeishuReceive Behavior on User Kind per SPEC v2 §5.8; no `feishu://` scheme; outbound now goes through ExternalMirror Domain — see invariant 15)
- `ezagent_plugin_liveview` — admin web UI LiveViews

**Rules**:
- `plugin_*` MAY depend on `core` and any `domain_*`.
- Plugins EXTEND `core` registries (BehaviorRegistry / SpawnRegistry / TemplateRegistry / RoutingRegistry) at `Application.start/2`. They do NOT write new core or domain primitives.
- Plugins do NOT introduce new top-level URI schemes (SPEC v2 §5.8 / invariant 11).

## Boundary rules summary

| From → To | core | domain | plugin |
|---|---|---|---|
| **core** | ✓ (intra) | ✗ | ✗ |
| **domain** | ✓ | ✓ (siblings, no cycles) | ✗ |
| **plugin** | ✓ | ✓ | ✓ (siblings rare) |

When in doubt: "could two unrelated plugin authors ship in parallel without merge conflict?" If no, the abstraction is in the wrong tier or the boundary is wrong.
