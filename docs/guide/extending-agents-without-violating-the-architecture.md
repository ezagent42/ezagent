# Extending agents without violating the architecture

> **Moved into the `ezagent-developer` skill — that is now the canonical home**
> (so every dev who loads the skill gets this guidance inline). This file is a
> thin pointer to avoid a second source of truth.

For adding a new **agent type**, or a new **render / feed / transport** capability,
read:

- **`.claude/skills/ezagent-developer/SKILL.md`** §"Extending agents without
  violating the architecture" — the pre-flight checklist (4 STOP checks) + the two
  principles inline.
- **`.claude/skills/ezagent-developer/references/extending-agents.md`** — the two
  worked examples (`Entity.Salesperson` → role × flavor; render-card → mechanism vs
  producer split) + the concrete levers (which docs/skills to load, the
  SPEC → codex adversarial-review → implement gate).
- Two matching refusals in `.claude/skills/ezagent-developer/references/anti-patterns.md`.

The two red lines in one line each:

1. **A new agent type is a `role × flavor`** on the unified `Ezagent.Entity.Agent`
   (register a recipe via `roles/0`, role-foundation #54) — **never its own
   `Entity.*` Kind** (the anti-pattern retired in P4b).
2. **Platform mechanism must be separable from business logic** — a generic
   render/feed/transport is producer-agnostic; business agents *consume* it, they
   don't bake it in behind a persona-named cap (cf. #1035 transport-only).

Chinese summary: [`extending-agents-without-violating-the-architecture.zh_cn.md`](extending-agents-without-violating-the-architecture.zh_cn.md).
Related: `docs/together/contributing/README.md` 台账 P0–P3.
