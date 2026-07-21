# Handoff → gaga: #1445 Git Provider V1 — must-fixes before merge (2026-07-21)

**Lead's adversarial review verdict: NEEDS-WORK — but the security architecture earned a clean bill.** All 4 security surfaces verified sound (several beyond your reviewers' claims): CapBAC signed-receiver (all 7 GitTaskAccess actions route through the `Cap.Verifier.authorize/5` chokepoint at runtime 5.5 — real signed+receiver-bound verify, not bare match), credential no-leak (EffectBoundary fences all 17 boundary crossings; secrets cross as `{:write_only_handoff, ref}`, never cleartext; AES-256-GCM correct), CAS fencing + atomic Agent ownership (genuine generational fencing via `FOR UPDATE` + rotating `start_claim_token`), OAuth authorization-code flow. **794 tests / 0 failures reproduced locally** (DomainGit 155/0, GitHub plugin 60/0, ProviderConnection 331/0, task_workspace CAS 142/0, arch.scan green, compile --warnings-as-errors clean).

Neither blocker below is a hole in your logic — both are collisions with **gates that landed on `main` after your branch was cut** (you're 2 behind).

## MUST-FIX 1 — anti-bypass ratchet gate trips (CI-red, reproduced)
`AuthorizeChokepointRatchetTest` (#1500, now on main) probe `:bare_match_authorization_authorizes` flags **`apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex:299`** — `Authorization.authorizing_cap(` — not in its allowlist. Offenders = exactly this one site. GitHub runs PR CI on the head-merged-into-base commit, so `gate (deterministic)` is already FAILURE.
- **Fix (also resolves the #195 interaction in one change):** DROP the redundant in-handler `authorizing_cap` re-scan, but **KEEP `caller == policy.grantee_uri`**. Rationale: runtime step 5.5 already crypto-verifies the cap bound to the *presenter*; the ONE thing your in-handler adds beyond 5.5 is binding to the *policy's grantee* — keep that, drop the rest. (Do NOT keep the `authorizing_cap` re-scan — it's a bare-match that both the ratchet and #195 want gone; the triple-check was satisfiable by a forged presence-only cap anyway, safe only because 5.5 gated first.)

## MUST-FIX 2 — gitleaks trips (CI-red, trivial)
Gitleaks (#1502, new gate) reports 4 findings — **all documentation placeholders/sentinels, zero real secrets**: `apps/ezagent_plugin_github/.../github-plugin-config.md:76` (`"abc123def456..."`), and plan/spec docs (`"gho-D0-SENTINEL"`).
- **Fix:** redact the placeholders (use obviously-fake forms) OR allowlist the doc paths in `.gitleaks.toml`.

## MUST-FIX 3 — rebase
Rebase onto current `origin/main` (2 behind; `merge-tree` is file-clean, the conflicts are the two gates above scanning at runtime). After rebase + fixes 1&2, re-run `gate` locally via the FAST arch subset (see PR #1504's new alias if merged, else `mix test apps/ezagent_core/test/invariants` etc.) — do NOT rely on a timed-out full precommit.

## SHOULD-FIX (fold in — credential MEDIUM)
`GitHubCredentialBackend.encryption_key/0` silently falls back to an ephemeral module-load key when `GITHUB_TOKEN_ENCRYPTION_KEY` is **unset OR malformed** (bad base64 / wrong length), while `oauth_client_secret` raises. Your own config guide says "treat as a permanent secret" — but a typo'd prod key would silently lose ALL stored credentials on the next boot. **Make it fail-loud for a configured-but-invalid key.**

## Non-blocking / acknowledged
- `consume_lease/1` is a no-op and `dispatch_operation` never calls `lease_for_operation`, so `token/0` returns `""` — **V1 can't do authenticated Git ops end-to-end yet** (the credential→adapter wire is deferred integration, consistent with your honest V1 boundary). Fine to defer; the socialware/skill integration lands that.
- EffectBoundary scrubs raise/throw/exit but not a driver's *returned* `{:error, {_, secret}}` — the no-leak guarantee relies on drivers returning closed error atoms (yours do). Keep it that way.

Fix 1+2+3 (+ ideally the SHOULD-FIX) → `gate`+`gitleaks` green → ping lead. Merge-path: it's your PR, but the ratchet change re-touches CapBAC, so route the fixed diff past the review gate (lead or codex) before merge. Coordinator (OAuth App creds for canary) + the socialware integration are being handled separately.
