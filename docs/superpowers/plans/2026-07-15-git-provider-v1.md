# Git Provider V1 Program Roadmap

> **For agentic workers:** This is a sequencing roadmap, not an executable implementation plan. Execute only the linked prerequisite plan until its GO/NO-GO decision is approved.

**Goal:** Deliver the W29 first real change-request loop without weakening credential isolation, then productize provider-neutral Git access.

**Architecture:** Work is split into five independently approved plans. Plan A establishes the secret and process-isolation boundary and selects the W29 transport. Plans B–E are written only after their consumed interfaces exist; this prevents aspirational module names and stale repository assumptions from becoming implementation instructions.

**Current executable plan:** `docs/superpowers/plans/2026-07-15-git-provider-v1-a-security-prerequisites.md`

## Program invariants

- GitHub remains a plugin; Git provider-neutral types and dispatch live in a domain.
- No GitHub token, SSH private key, credential path, descriptor, socket, or credential-bearing environment reaches an agent.
- All agent/provisioner operations enter through Router dispatch before effects.
- Resources use the registered `resource://<workspace>/<type>/<id>` shape.
- Use the current signed `Cap.issue(authorization, grantee_uri, capability)` and `verify_for/2` semantics.
- Use Req for provider HTTP and `Ezagent.Runtime.OsProcess` for subprocess lifecycle.
- Do not touch AgentRuntime ARB, EntityCaps A/B/D, `caps_json`, no-tail enforcement, or cc-PTY bridge join/#1405.
- Do not deploy or merge without lead authorization.
- Keep the W29 honesty label: loose-coupled, not final mount; #1360 Layer B pending.

## Plan A — Security prerequisites and W29 transport decision

**Status:** evidence complete; architecture/security review pending.

**Outcome:** approved secret-use interface, SSH parser decision, demonstrated broker isolation or explicit SSH NO-GO, and a tested choice between generic SSH transport and public-checkout + GitHub API commit transport.

**Decision:** public anonymous checkout plus GitHub Git Data API is GO for
downstream planning. Secret backend, SSH parser, and SSH broker isolation are
NO-GO. Exact evidence and interfaces are in
`docs/superpowers/specs/2026-07-16-git-provider-v1-a-decisions.md`.

**Stop condition:** Plan B may be written after review approves the decision
spec. Production GitHub OAuth/API work remains blocked on an approved encrypted
token backend; SSH/private checkout remains blocked.

## Plan B — Git Domain spine

**Status:** eligible to write after Plan A architecture/security review.

**Scope:** exact Resource Kinds/Lifecycle, provider-neutral structs/errors, Behavior actions, Router/CapabilityRegistry registration, adapter plugin declaration/boot rollback, persistence, current signed Cap issuance/self-store/verify/revoke, and unauthorized-no-effect invariants.

**Exit:** two fake adapters pass the contract; an authorized in-memory task action dispatches through the exact `GitTaskAccess` Resource; unauthorized dispatch produces zero mutation.

## Plan C — Transport and workspace provisioning

**Status:** gated by Plan B; public anonymous checkout only.

**Scope:** implement only the transport approved by Plan A, durable provision state, deterministic per-generation worktree, lease/CAS/reaper/start token, and a provider-neutral pre-start prerequisite port owned outside `plugin_cc`.

**Exit:** one Git-enabled recipe gets a verified `project_cwd` before cc-headless startup; duplicate claims and crash recovery start one sidecar; no `plugin_cc -> domain_git` dependency.

## Plan D — GitHub plugin

**Status:** gated by Plans B–C and an approved encrypted token backend.

**Scope:** OAuth authorize/callback with state/PKCE/session binding/replay protection, opaque token secret reference, refresh/revoke/disconnect, Req adapter, repository access, GitHub API transport if selected, pull request and head-CI reads.

**Exit:** a test user produces a real PR with green PR-head CI through production-facing paths. Merge is not performed by the agent.

## Plan E — Product UX, Kanban projection, and canary acceptance

**Status:** gated by Plan D; SSH identity UI excluded while SSH prerequisites are NO-GO.

**Scope:** SSH identity import/generation UI if SSH transport was approved, GitHub connection UI, provider-neutral fact relay, Kanban detailed artifact projection while preserving its four-state core, agent-browser evidence, and dev-together return.

**Exit:** reviewable evidence package; lead-authorized review/merge may advance the card to done. Without authorization, stop at review-ready.

## W29 shortest-path policy

- Prefer the smallest strategy Plan A proves safe.
- For a public repository, anonymous checkout plus GitHub API commit/branch/PR is an allowed candidate.
- It must be labeled GitHub-specific and does not count as final provider-neutral SSH transport.
- Private-repository checkout remains blocked until authenticated checkout is proven safe.
- A manually dropped token/private key, raw RPC/eval, live DB mutation, wildcard cap, or agent-readable temp key is never an acceptable demo shortcut.

## Review and planning order

1. Execute and review Plan A.
2. Update the design with its approved decisions.
3. Write and review Plan B; then execute it.
4. Repeat write-review-execute for C, D, and E.
5. Run `MIX_ENV=test MIX_TEST_PARTITION=$USER mix ci.local` before final handoff when code exists.
