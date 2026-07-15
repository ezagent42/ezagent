# W29 demo — dev-loop provisioning: architecture constraints (for gaga)

**Context.** gaga's #1416 (`docs/together/2026-07-15/returns/demo-e2e-dispatch.md`) advanced the W29 demo path — real login, cc-headless-deepseek role materialization + task dispatch, and **confirmed CapBAC enforces in the live demo** (kanban write-config/create-card precisely denied). The remaining "agent actually writes code + opens a real PR + it flows through CI/review/merge + kanban card flows" leg is blocked on **4 provisioning gaps**. This note is the **architecture constraints** for filling them (not a full spec) — lead-reviewed 2026-07-15. gaga owns the implementation (AgentRuntime domain).

## Gap 3 (+ gap 1's GitHub half) — GitHub as a PLUGIN, never inside the agent
- GitHub is an **external integration → a plugin (Receiver Kind / Behavior)**, per the north-star `plugin external integration = Receiver Kind`. It does NOT live in the agent runtime.
- **The GitHub token never enters the agent process.** The plugin holds/brokers tokens; the agent **requests** GitHub operations (clone-auth, push, open-PR, read CI/review/merge) via a **capability-gated call** to the plugin. Push/PR are then CapBAC-gated (an agent needs a `github.push` / `github.pr.create` cap — enforced, as #1416 proved the gate works).
- **Per-user token.** The plugin resolves the **acting entity's own** GitHub credential (OAuth token from a credential store) and acts *as that user* — not a shared platform token. This is what closes gap 1's GitHub-credential half: the agent inherits the *right* to ask, the plugin supplies the user's token.
- Mirror the existing external-adapter plugin shape (the OpenAI/Anthropic-compatible adapter work) rather than inventing a new mechanism.

## Gap 1 — credential inheritance: separate the two credential TYPES
- **LLM creds** (deepseek etc., so the agent can *think*) inherit via the established **per-agent `config_dir`** materialization (see the credential-isolation line: per-agent config_dir contract, credential-status view, the socialware-materialized-agent-inherits-installer-login fix).
- **Authority-checked, no co-tenant leak.** An agent inherits **its owner's** creds only — never a co-tenant's. (Co-tenant credential spend via an unchecked join was a real prior hole — `session.join` needs the member-authority check.) The inheritance entry MUST verify the acting authority.
- **Do NOT bake GitHub creds into the cc-headless config.** "Can call an LLM" and "can push code" are different authorities — keep GitHub on the plugin path above, don't fuse them into one config blob.

## Gap 2 — repo clone / task worktree / `project_cwd`: provision BEFORE the sidecar
- **The ordering bug gaga hit (`:sdk_sidecar_not_started` because `project_cwd` didn't exist) is the #1 trap:** the working directory must be **cloned/created before the agent's sidecar boots**. Provisioning is a *prerequisite step* in the agent's materialization lifecycle, not a post-boot afterthought.
- **Per-task worktree isolation.** Each dev task gets its own git worktree / cwd — concurrent agents must NOT share a cwd (parallel-worktree corruption is a known trap; no shared `git stash`).
- **Lifecycle.** Create on task-claim → clean on task-done. Worktrees/clones accumulate and must be reaped (we've had to prune stale-worktree buildup before).
- **Parametrize the repo + base branch** from the kanban task card / socialware config — never hard-code which repo or base.

## Gap 4 — demo owner's kanban capability: precise, governed, signed
- **Least privilege.** Grant the *precise* operating caps (`kanban.card.create` / `.move` / `.assign`, board-scoped), NOT `admin` / wildcard (`#154` no-unowned/over-broad caps).
- **Via socialware governance, through `Cap.issue`.** The owner's kanban caps come from the **socialware install granting the owner its operating caps** (governance), issued through `Cap.issue` (signed). **Do NOT direct-write `caps_json`** — that trips the #1409 write-side arch gate now, and would be an unsigned cap that fails the no-tail audit / enforce later.

## Cross-cutting (hold all four to these)
- **Everything the agent does is CapBAC-gated** (push, PR, kanban ops) — #1416 proved the gate is live; lean on it, don't route around it.
- **No cheating for a green demo** (the standing rule gaga already follows): no raw RPC / eval / live-DB edits / temp priv-esc / platform-cred drop. The E2E must face production.
- **Honest labeling:** hello↔kanban stays loose-coupled until #1360 Layer B; don't present loose-coupling as final mount.
