# Task 1 report — `UserSshIdentity` 模块骨架 + 注册 + `:generate_ssh_key`

Commit: `a9baced9d7cda3e1342ea514b32e0a131955c6e7` (`feat(identity): UserSshIdentity — :generate_ssh_key`)

## What I implemented

- **New file** `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex` —
  `Ezagent.ActionSet.UserSshIdentity`, `use Ezagent.Lifecycle` (the sole
  developer surface; no `use Ezagent.ActionSet` / `state_slice` / `init_slice`
  / `invoke/4`). One action, `:generate_ssh_key`, `modes: [:call]`, handled by
  `handle_generate_ssh_key/2`:
  - Refuses with `{:error, :ssh_identity_exists}` if `:private_key` or
    `:public_key` already present in state (no silent overwrite).
  - Otherwise shells out to `ssh-keygen -t ed25519` via `System.cmd/3` in a
    randomly-named tmp dir, reads back the keypair, computes the OpenSSH
    SHA256 fingerprint, and returns `{:ok, %{public_key, fingerprint}, effects}`
    where effects are 5 `{:set, ...}` (`:public_key`, `:private_key`,
    `:fingerprint`, `:comment`, `:created_at`) + one `{:emit,
    :ssh_identity_generated, _}` audit event. The private key is **never** in
    the return value.
  - `keygen/1` wraps the subprocess in `try/rescue/after`, always `File.rm_rf`s
    the tmp dir immediately (no reliance on process exit/GC).
- **Modified** `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` —
  added `Ezagent.ActionSet.UserSshIdentity` to `User.behaviors/0`.
- **Modified** `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex`
  — aliased `UserSshIdentity` and registered its actions on `User` Kind only
  via `CapabilityRegistry.register/3` (SSH identity belongs to the User, never
  the Agent — agents are dynamically materialized; per-agent identity would
  mean a manual provider public-key add on every materialization).
- **New test** `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs`
  — the brief's 3 tests verbatim, plus a 4th I added per the brief's item 4
  (missing-`ssh-keygen` regression, see below).
- **Modified** `apps/ezagent_domain_identity/test/ezagent/entity/user_test.exs`
  — updated the pinned `User.behaviors()` exact-list assertion to include
  `UserSshIdentity` (a direct, necessary consequence of the `user.ex` change;
  this test was not mentioned in the brief but broke without the fix).
- **Modified** `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`
  and `apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs`
  — required companion fixes for two architecture ratchets this feature
  legitimately trips; see "Self-review findings" below.

## TDD evidence

### RED (Step 2)

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
```

Output (first run, before `mix deps.get` — this is a fresh worktree with no
`deps`/`_build`; I ran `mix deps.get` once, then re-ran):

```
  1) test generate_ssh_key ssh-keygen 缺失时返回 keygen_failed，不 crash (Ezagent.ActionSet.UserSshIdentityTest)
     ** (UndefinedFunctionError) function Ezagent.ActionSet.UserSshIdentity.handle_generate_ssh_key/2 is undefined (module Ezagent.ActionSet.UserSshIdentity is not available)
  2) test generate_ssh_key 生成后临时目录不残留 (Ezagent.ActionSet.UserSshIdentityTest)
     ** (UndefinedFunctionError) ... same
  3) test generate_ssh_key 生成密钥对，返回公钥与指纹，且不返回私钥 (Ezagent.ActionSet.UserSshIdentityTest)
     ** (UndefinedFunctionError) ... same
  4) test generate_ssh_key 已存在身份时拒绝，不覆盖 (Ezagent.ActionSet.UserSshIdentityTest)
     ** (UndefinedFunctionError) ... same

Finished in 0.4 seconds (0.4s async, 0.00s sync)
4 tests, 4 failures
```

Matches the brief's predicted failure exactly (module undefined) — RED for
the right reason.

### GREEN (Step 6, after implementation + Kind/CapabilityRegistry registration)

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
```

```
Finished in 0.07 seconds (0.07s async, 0.00s sync)
4 tests, 0 failures
```

### Final combined re-run (SSH identity + the pinned-list fix)

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs apps/ezagent_domain_identity/test/ezagent/entity/user_test.exs
```

```
Finished in 0.07 seconds (0.07s async, 0.00s sync)
13 tests, 0 failures
```

### Full identity-domain suite

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test
```

```
Finished in 50.0 seconds (2.0s async, 47.9s sync)
656 tests, 3 failures
```

The 3 failures (`Ezagent.Identity.Cutover.RunbookTest` ×2,
`Ezagent.Identity.CutoverTest` ×1, all "unexpected_non_active:
session://system/default/main" / "parity_incomplete") are **pre-existing and
unrelated** — verified by `git stash -u` (removing all my changes), re-running
the same test files, and observing the identical 3 failures with the same
root cause on the unmodified baseline, then `git stash pop` to restore. This
is DB/seed-state environmental flakiness on this fresh worktree's Postgres,
not something my change touches.

### Fast architecture gate

```
POSTGRES_PORT=15432 mix ci.fast
```

Final run: `697 tests, 4 failures` in `ezagent_core` (plus other apps all
green: `ezagent_domain_identity` 4/4, `ezagent_domain_external_mirror` 39/39,
`ezagent_domain_session` 8/8). The 4 remaining failures are all in
`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/official_site_seed.ex` —
confirmed pre-existing via the same stash/pop baseline comparison (identical
4/4 failure count and content on the unmodified tree). Nothing in the
remaining failures mentions SSH/UserSshIdentity (grepped the full log for
"ssh" — only hit is the worktree's own directory name in a file path).

## Self-review findings — what I found and changed

1. **Brief's `keygen/1` `rescue`/`catch` ambiguity (dispatcher's item 4).**
   Traced `System.cmd/3`'s actual source
   (`elixir/lib/system.ex:1140`): a missing relative executable raises via
   `:os.find_executable(cmd) || :erlang.error(:enoent, [...])` — a raw
   `:error` whose reason (`:enoent`) has no dedicated Elixir exception
   translation, so `Exception.normalize/3` always wraps it as `ErlangError`.
   Confirmed empirically (`elixir -e` probe) that `rescue e in [File.Error,
   ErlangError]` catches it, never reaching `catch :error, :enoent`. Then
   checked whether the compiler actually warns: compiled the two-clause form
   with `elixirc --warnings-as-errors` — **exit 0, no warning**. The
   dispatcher's literal trigger ("if ... the compiler warns") is therefore
   false, but the clause is still provably dead code by construction (any
   `:error`-kind raise not otherwise recognized becomes `ErlangError`, so
   `rescue e in [..., ErlangError]` is a strict superset of any later
   `catch :error, _`). I judged the deeper intent (unreachable ⇒ drop) more
   important than the literal AND-condition, and **dropped the `catch`
   clause**, keeping `rescue`, with a comment explaining why. Added the
   required regression test (4th test in the test file) that clears `PATH`
   (the same pattern already used in
   `apps/ezagent_domain_python/test/spec_test.exs`) and asserts
   `{:error, {:keygen_failed, _}}` — passes, proving no crash.

   **Flagging this as a decision for review**, not a blocker: functionally
   nothing changes either way (rescue handles it regardless of whether catch
   is present), so if you'd prefer the brief's code kept verbatim (both
   clauses), that's a trivial revert.

2. **Missing `required_caps/0` override — brief's own comment referenced code
   that wasn't there.** The brief's code had this comment immediately above
   `data_owner/1`: "保留 `kind: :user` 轴（宏自动派生会硬编码 `:any`，见
   UserCredentials.ex）" — but no actual `def required_caps do ... end`
   followed, unlike `UserCredentials.ex`/`UserTokens.ex`, which both have this
   exact comment followed by the override. I traced whether this is a real
   authz bug: read `Ezagent.Cap.Verifier.required_cap/4`
   (`apps/ezagent_core/lib/ezagent/cap/verifier.ex:142`) — when the declared
   cap's `kind == :any`, the runtime substitutes the *actual dispatch target
   Kind's* `type_name/0` at authorization time. Since `UserSshIdentity` is
   only ever registered on `User` Kind, the auto-derived `:any` and an
   explicit `:user` resolve to the identical needed-cap shape today —
   **functionally harmless**, not a live authz bug. I added the explicit
   `required_caps/0` override anyway (completing what the comment already
   promised, matching the sibling pattern exactly), because it turns "SSH
   identity is User-only, never Agent" from an accidental fact (only
   registration site happens to be User) into a structural assertion: if this
   Behavior is ever also registered on the Agent Kind by mistake, a
   `kind: :user` cap would then correctly fail to match on an Agent target
   instead of silently reinterpreting itself as `:agent`.

3. **Pinned `User.behaviors()` list test.** `apps/ezagent_domain_identity/test/ezagent/entity/user_test.exs`
   asserted the exact 3-item behaviors list; adding `UserSshIdentity` (as
   Step 4 required) broke it. Updated the assertion + its explanatory
   comment. This is a direct, unavoidable consequence of the brief's own
   Step 4, not scope creep.

4. **Three architecture-gate regressions surfaced by `mix ci.fast`** (none
   mentioned in the brief — the brief predates running the gate):
   - `set_effect_sites` ratchet (`apps/ezagent_core/test/architecture/effect_discipline_test.exs`):
     measured 131→136 (later briefly miscounted at 137, see below). The 5 new
     `{:set, ...}` sites are genuine new debt (no shared setter to
     consolidate through — each is an independently-read field, unlike e.g.
     py-agent's `last_input/result/error` triple). Bumped
     `arch_baseline_manifest.exs`'s `set_effect_sites: 131` → `136` with a
     `# arch-cap-bump:` annotation (required by
     `manifest_ratchet_test.exs`'s `assert_manifest_cap_raise_is_annotated`,
     which diffs against `origin/main` — verified passing).
   - `undocumented_public_defs` ratchet (`doc_coverage_test.exs`): my 3 new
     public functions (`required_caps/0`, `data_owner/1`,
     `handle_generate_ssh_key/2`) pushed 406→409. Rather than bump the cap, I
     added `@doc false` to the two framework-boilerplate functions
     (`required_caps/0`, `data_owner/1` — matching how the sibling files
     leave these undocumented, but explicitly-marked-so instead of silently
     undocumented) and a real `@doc` to `handle_generate_ssh_key/2` (the
     actual new capability). Net delta: zero — no manifest change needed.
   - `cap_signing_architecture_test.exs` "signing, key access, and Kind
     introspection remain framework-confined": flagged
     `user_ssh_identity.ex` as a "signing offender" via a blunt
     `String.contains?(source, "private_key")` substring guard — a false
     positive (SSH auth keypair, not Ezagent's internal cap-signing key). The
     test file already has a precedented escape hatch for exactly this
     class of collision (`@allowed_external_private_key`, currently holding 3
     GitHub App JWT files with an explanatory comment: "External-provider
     signing key material ... NOT Ezagent capability-signing key material").
     Added `user_ssh_identity.ex` to that same allowlist with an analogous
     comment. This does **not** weaken the gate's real protection — the
     separate `framework_signing?` check (`Cap.Signing`/`Authority.sign(`/
     `Authority.verify(`) is untouched and would still catch a genuine
     boundary violation.
   - **Self-inflicted follow-up bug**: after adding the real `@doc` to
     `handle_generate_ssh_key/2` (previous bullet), the `set_effect_sites`
     count came in at 137, not the expected 136. Root cause: the docstring
     prose I wrote literally contained the text `` `{:set, :private_key, _}` ``
     as an inline code example — the scanner is a plain per-line regex
     (`~r/\{:set,\s*:[a-z_]+,/`) over raw source text, not AST-aware, so it
     matched my documentation prose exactly like a real effect tuple. Fixed
     by rewording the docstring to describe the effect without the literal
     bracket-tuple syntax ("经一条 `:set` effect 写进 state 的 `:private_key`
     键" instead of `` `{:set, :private_key, _}` ``), which brought the true
     count back to exactly 5 (matching the manifest's `136`). Re-verified
     with `grep -noE '\{:set,[[:space:]]*:[a-z_]+,'` against the file: exactly
     5 matches, all in the real effect list, none in prose.

   Re-ran all three architecture tests after fixes:
   ```
   POSTGRES_PORT=15432 mix test apps/ezagent_core/test/architecture/effect_discipline_test.exs apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs apps/ezagent_core/test/architecture/doc_coverage_test.exs
   ...
   Finished in 12.5 seconds (10.9s async, 1.5s sync)
   25 tests, 0 failures
   ```
   And the manifest-ratchet annotation gate:
   ```
   POSTGRES_PORT=15432 mix test apps/ezagent_core/test/architecture/manifest_ratchet_test.exs
   ...
   2 tests, 0 failures
   ```

5. **Compiler warnings**: `mix compile --force` (full project) shows exactly
   3 pre-existing warnings, all in files I never touched
   (`snapshot_store.ex:283`, `kind/snapshot.ex:540`,
   `entity/agent/template_spawn.ex:641` — all Elixir 1.19 type-checker
   "clause will never match" hits, unrelated to my rescue/catch decision).
   Grepped specifically for my file/module name in a
   `--warnings-as-errors` force-compile: zero hits.

## Commit scope deviation from the brief

The brief's Step 7 `git add` scope was `apps/ezagent_domain_identity/` only.
I additionally staged `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`
and `apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs` in
the **same commit**, since without them this commit alone fails
`mix ci.fast` (items 4a/4c above) — a commit that doesn't include its own
required gate fixes isn't actually green. Used the brief's exact commit
message verbatim as instructed.

## Concerns

- Items 1 and 2 above (rescue/catch drop, `required_caps/0` addition) are
  judgment calls on ambiguous/incomplete parts of the brief, made with full
  reasoning documented in code comments + this report. Both are low-risk
  (no behavior change either way) but worth a human glance.
- The 3 pre-existing identity-cutover-parity failures and 4 pre-existing
  `official_site_seed.ex` architecture-debt failures are real and currently
  red on `mix test`/`mix ci.fast` on this fresh worktree — unrelated to this
  work but worth knowing they're not "new" red from Task 1.
- Tasks 2/3 (read/revoke actions, then authz tests) will add 3 more actions
  to this same module — the `required_caps/0` map I added will need a new
  entry per action (already shaped as a `%{action => cap}` map, so this is a
  one-line addition per action, not a refactor).

---

# Task 1 review-fix report (2026-08-01)

Fixing all findings from `.superpowers/sdd/task-1-findings.md` — two
independent reviews (Claude + Codex), 4 Important + 6 Minor + 2 doc
corrections. Every finding below got a code/doc change AND a test that
fails on the pre-fix code (verified by running the affected test against
the fix, then reasoning through / reproducing why it would have failed
before — noted per-item).

Files touched:

- `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex`
  (I1, I2, M1, M2 — production code)
- `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs`
  (I1, I2, I4, M1, M2, M3, M4, M5 — tests)
- `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_lifecycle_cold_load_test.exs`
  (I3 — new file)
- `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`
  (M6 — comment only, ratchet number untouched)
- `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`
  (D1 — §4.1 reasoning correction, conclusion untouched)

## Important

### I1 — comment newline injection (`user_ssh_identity.ex:143`)

Fixed two independent ways (both, per the finding's "两者都做更好"):

1. `validate_comment/1` rejects any `comment` containing `\n` or `\r`
   BEFORE `ssh-keygen` ever runs — returns `{:error, :invalid_comment}`,
   not wrapped as `{:keygen_failed, _}` since it isn't a keygen failure.
2. Defense in depth in `keygen/1`: even with (1) in place, `first_line/1`
   takes only the first line of the `.pub` file content before computing
   the fingerprint or persisting it as `public_key`.

Tests added (`user_ssh_identity_test.exs`):
- `"comment 含换行时拒绝，不调用 ssh-keygen（I1 注入防护）"` — uses the
  reviewer's exact reproduction string
  (`"me@x\nssh-rsa AAAA... evil@attacker"`), asserts
  `{:error, :invalid_comment}` AND that no tmp dir was ever created
  (proves rejection happens before any subprocess spawn).
- `"comment 含 CR 时同样拒绝"` — the `\r` half of the check.

Both fail on the pre-fix code (which passed `comment` straight to
`ssh-keygen -C` with no validation at all).

### I2 — no timeout on `ssh-keygen` (`user_ssh_identity.ex:141`)

Implemented the mandated fix exactly: kept `System.cmd`, wrapped it in
`Task.async` + `Task.yield` + `Task.shutdown(task, :brutal_kill)` inside
a new `run_ssh_keygen/2`, did NOT touch `OsProcess`. Timeout is
`@keygen_timeout_ms 5_000` (5s — generous over ssh-keygen's normal
millisecond runtime, still finite), resolved at call time through
`keygen_timeout_ms/0` so it's overridable via
`Application.put_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms, _)`
for tests without touching the production default. Timeout surfaces as
`{:error, {:keygen_failed, :timeout}}` — the existing error shape, no new
atom hierarchy, exactly as directed.

**Orphan risk**: documented explicitly in `run_ssh_keygen/2`'s comment —
`Task.shutdown/2` kills the Elixir task process only; the OS `ssh-keygen`
child is not reached and may be left orphaned. Logged (not silent) via
`Logger.warning/2` on the timeout path, mentioning the orphan possibility
so an operator has something to grep for.

**A correctness issue I found and fixed while implementing the literal
"Task.async" instruction** (flagging per the "ask before implementing"
norm, though I judged this narrow enough to fix inline rather than
stopping — full reasoning below): `Task.async/1` **links** the spawned
process to the caller. I probed this empirically (`elixir` one-liner,
not part of the repo) before writing the real code: wrapping
`System.cmd("missing-binary", [])` in a bare `Task.async` and letting it
raise `:enoent` **crashes the calling process too**, via the link, before
`Task.yield` ever gets a chance to turn it into a graceful
`{:exit, reason}`. Concretely, this would have crashed the User actor's
own GenServer on exactly the scenario the pre-existing "ssh-keygen 缺失"
test exercises — strictly worse than the hang I2 exists to fix, and it
would have silently broken that test's "不 crash" guarantee. Fix: the
`System.cmd` call is wrapped in its own `try/rescue` **inside** the task
function, so the task always exits normally (carrying an `{:error, _}`
value) for every case we can anticipate; `{:exit, reason}` in the outer
`Task.yield` case is kept as a last-resort net. This preserves the
mandated mechanism (`Task.async` + `Task.yield` + `Task.shutdown`, no
`OsProcess`) — it's a correctness detail of implementing it, not a
substitution of the decision.

Tests added:
- `"ssh-keygen 超过时限时返回 timeout，不挂住，且不留 tmp 目录（I2）"` —
  injects `ssh_keygen_timeout_ms: 0` (a real, fast ssh-keygen invocation
  still can't beat a 0ms yield window — deterministic, no fake/hanging
  command needed), asserts `{:error, {:keygen_failed, :timeout}}`, asserts
  the warning log fires, asserts no tmp-dir leak.
- Strengthened the pre-existing "ssh-keygen 缺失" test with a tmp-dir-leak
  assertion (M4) and updated its comment to document the link-crash
  finding above (this test is also the one that would have caught the
  link-crash regression, had I shipped the naive version — before my
  inner-rescue fix, this test would hang/crash instead of asserting
  cleanly).

### I3 — no test exercises a real actor (`user_ssh_identity_test.exs:8`)

New file `user_ssh_identity_lifecycle_cold_load_test.exs`, modeled
directly on `identity_lifecycle_cold_load_test.exs`'s ApiKeys gate (same
state-only shape — `UserSshIdentity` has no transients either, so
`Ezagent.LifecycleCase.assert_transients_rebuilt/2`'s non-empty-transients
requirement doesn't apply; hand-rolled the same kill+respawn shape ApiKeys
uses, for the same reason). NOT invented from scratch — copied the
existing harness per the finding's explicit instruction.

One test, `UserSshIdentityHostKind` (a private test-local Kind hosting the
real `Ezagent.ActionSet.UserSshIdentity`), covers, in one flow:

1. **Registration** — `BehaviorRegistry.register/3` + a real
   `Ezagent.Kind.spawn/2`.
2. **Real dispatch + CapBAC** — `generate_ssh_key` invoked through
   `Ezagent.Invocation.dispatch/1` with a `signed_required_cap!/5`-issued
   cap (the actual signed-cap verification path, not a bypassed direct
   handler call).
3. **Effect application** — reads the raw slice after dispatch and
   confirms `public_key` / `fingerprint` / `private_key` in `state` match
   the dispatch reply.
4. **Snapshot commit + cold-restart reload** — `Process.exit(pid1, :kill)`
   (brutal, skips `deactivate`/`destroy`), waits for the supervisor's
   demand-respawn at a new pid, re-reads the raw slice, asserts the
   private key survived **byte-for-byte**.
5. **`create/1` not wrongly re-run** — asserts `KindSnapshot.ever_created?/1`
   stayed true AND that a second `generate_ssh_key` dispatch after the
   restart is refused with `{:error, :ssh_identity_exists}` (a
   wrongly-reset slice would let this silently succeed instead).
6. Confirms `transients == %{}` before and after (state-only correctness).

This is the test I3 asked for: "经真实 dispatch 生成 → 效果落进持久 state
→ actor 重启/冷载后私钥仍在." It passed on the first run against the
already-fixed code; I did not need to hand-roll a new harness or reduce
scope — the existing `identity_lifecycle_cold_load_test.exs` pattern
transplanted cleanly.

### I4 — `refute Map.has_key?(result, :private_key)` proves too little (`user_ssh_identity_test.exs:20`)

Strengthened the existing "生成密钥对..." test with two assertions:

1. `assert Map.keys(result) |> Enum.sort() == [:fingerprint, :public_key]`
   — exact key set, not just absence of one key.
2. `refute Jason.encode!(result) =~ private` — the raw private key bytes
   (captured from the `{:set, :private_key, v}` effect, same as before)
   must not appear anywhere in the **serialized** return value.
   `Jason.encode!/1` is what actually crosses the wire to a GUI/CLI
   consumer, so this is closer to the real leak surface than `inspect/1`
   would be. (`Jason` is already an indirect dep via `ezagent_actor`/
   `ezagent_core` and already used elsewhere in this app's lib/test.)

Both fail against the two regressions the finding names (fingerprint
carrying the private key; private key tacked onto public_key) — a
same-length-map with a different key, or a longer string under
`:public_key`, breaks assertion (1) or (2) respectively.

## Minor

### M1 — `File.rm_rf(dir)` result discarded (`user_ssh_identity.ex:174`)

Extracted `cleanup_tmp_dir/1` (`def` + `@doc false`, not `defp` — purely
a testability seam, see below) which checks `File.rm_rf/1`'s return and
`Logger.warning/2`s on `{:error, reason, path}` (mentioning the dir and
that plaintext key material may remain). `keygen/1`'s `after` block now
calls this instead of discarding the result.

**Test-design note**: a real `File.rm_rf/1` failure can't be forced
through `handle_generate_ssh_key/2` from outside, because `keygen/1`
picks a **randomized** tmp dir name internally — there's no hook to
inject a permission change between the directory's creation and its
cleanup. I considered this carefully (per the "如实报告需要什么，不要半做
一个证明不了东西的测试" instruction) and concluded the correct fix is a
small dependency-seam extraction (`cleanup_tmp_dir/1` taking an arbitrary
`dir`), not a weaker test. The new test
(`"M1: 清理失败时记日志，不静默"`) builds its own directory + file, strips
write permission from the directory (`File.chmod!(dir, 0o500)` — deleting
a file requires write on its *containing* directory, not the file itself,
so this deterministically and portably forces `File.rm_rf/1` to fail;
confirmed this test process is not root, `id -u` → 1000, so the
permission check isn't bypassed), calls `cleanup_tmp_dir/1` directly, and
asserts the warning is logged via `ExUnit.CaptureLog`. Restores
permissions and deletes the dir in an `after` block so the test doesn't
leak a real directory.

### M2 — `fingerprint/1` degrades to `"SHA256:unknown"` (`user_ssh_identity.ex:179-191`)

`fingerprint/1` now returns `{:ok, fp} | :error` instead of a string with
a placeholder fallback. `keygen/1`'s success branch pattern-matches on
this: `:error` now surfaces as
`{:error, {:fingerprint_unparseable, pub}}`, which
`handle_generate_ssh_key/2` wraps as
`{:error, {:keygen_failed, {:fingerprint_unparseable, pub}}}` — the whole
action fails instead of persisting a fake-looking fingerprint.

Also exposed as `def` + `@doc false` (same testability-seam reasoning as
M1 — real `ssh-keygen` output is always well-formed, so this branch can't
be reached through the public action without mocking the subprocess).
Three direct tests added (`describe "fingerprint/1 (M2)"`): a valid line
returns `{:ok, "SHA256:" <> _}`; a line with no space-separated second
segment returns `:error`; a line whose second segment isn't valid base64
returns `:error`. All three fail against the pre-fix code (which returned
the literal string `"SHA256:unknown"` for the same two malformed inputs
instead of `:error`).

### M3 — `System.put_env("PATH", ...)` in an `async: true` module (`user_ssh_identity_test.exs:446-448`)

Changed `use ExUnit.Case, async: true` → `async: false`, with a comment
explaining why (this module now ALSO does
`Application.put_env(:ezagent_domain_identity, :ssh_keygen_timeout_ms, _)`
for the I2 timeout test — another global-state mutation in the same
category).

### M4 — cleanup assertions only cover the success path (`user_ssh_identity_test.exs:44`)

Added `tmp_entries()` before/after assertions to every new error-path
test (I1's newline-comment rejection, I2's timeout) and to the
strengthened pre-existing "ssh-keygen 缺失" test — none of these
previously checked for a tmp-dir leak on their error path.

### M5 — the "already exists" fixture sets both keys at once (`user_ssh_identity_test.exs:37`)

Split into two tests: `"已存在身份时拒绝，不覆盖 —— 只有 public_key"`
(fixture has only `:public_key`) and `"...—— 只有 private_key"` (fixture
has only `:private_key`). Both must independently return
`{:error, :ssh_identity_exists}`.

### M6 — ratchet-bump comment reasoning was wrong (`arch_baseline_manifest.exs:533-541`)

Corrected the comment in place. Did **not** touch `set_effect_sites: 136`
or any other manifest value — verified via `mix test
apps/ezagent_core/test/architecture/manifest_ratchet_test.exs` (2 tests,
0 failures, both before and after the comment edit) that the
annotation-gate (which diffs against `origin/main`) is still satisfied.
The corrected reasoning: the 5 `{:set, ...}` sites ARE written together
in one handler call (the review's point) — the actual reason they can't
be consolidated into one `{:set, ...}` is (a) the brief's flat
five-top-level-key state shape, and (b) the existence guard / future
read/revoke actions addressing one field at a time via
`ctx[:read].(:public_key, ...)`, both of which require each field to stay
independently addressable.

## Doc corrections

### D1 — spec §4.1 reasoning (`docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`)

Corrected in place: added an explicit "订正(2026-08-01，task-1 review D1)"
paragraph. The conclusion (`System.cmd`, no `OsProcess`, no new
abstraction) is unchanged; the reasoning no longer claims `ssh-keygen`
"has none of the risks GitRunner guards against" — it now says local +
no-network + small-output means we don't need `OsProcess`'s
`pid_file`/output-cap machinery specifically, but the hang risk is real
and is handled via `Task.async`/`Task.yield` with the orphan-process
tradeoff named explicitly (mirroring the I2 code comment).

### D2 — honest gate status

Stated below, not "gate all green."

## Test commands run + real output

Covering tests (as specified):

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_lifecycle_cold_load_test.exs apps/ezagent_domain_identity/test/ezagent/entity/user_test.exs
```
```
Finished in 0.2 seconds (0.1s async, 0.1s sync)
22 tests, 0 failures
```
(12 in `user_ssh_identity_test.exs` + 1 in the new cold-load file + 9 in
`user_test.exs`.)

Full identity app suite:

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test
```
```
Finished in 51.3 seconds (2.2s async, 49.1s sync)
665 tests, 3 failures
```
The 3 failures are `Ezagent.Identity.CutoverTest` (1) and
`Ezagent.Identity.Cutover.RunbookTest` (2) — nothing to do with SSH
identity (session-migration cutover parity). **Independently
re-confirmed pre-existing**, not trusted from the prior report: I
`git stash push -u` on exactly the 5 files I changed (leaving the rest of
the dirty worktree untouched), re-ran
`mix test apps/ezagent_domain_identity/test/ezagent/identity/cutover_test.exs apps/ezagent_domain_identity/test/ezagent/identity/cutover/runbook_test.exs`
against that reverted baseline, got the **identical 3 failures** (14
tests, 3 failures), then `git stash pop` to restore. Same DB/seed-state
class the prior report described.

Architecture gates touched by this change (`set_effect_sites`,
`undocumented_public_defs`, the cap-signing allowlist, the manifest
ratchet annotation):

```
POSTGRES_PORT=15432 mix test apps/ezagent_core/test/architecture/effect_discipline_test.exs apps/ezagent_core/test/architecture/doc_coverage_test.exs apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs apps/ezagent_core/test/architecture/manifest_ratchet_test.exs
```
```
Finished in 13.0 seconds (11.5s async, 1.4s sync)
27 tests, 0 failures
```

Fast CI gate (**D2 — reporting this honestly, not as "all green"**):

```
POSTGRES_PORT=15432 mix ci.fast
```
```
==> ezagent_actor
==> ezagent_core
697 tests, 4 failures
==> ezagent_domain_identity
4 tests, 0 failures
==> ezagent_domain_external_mirror
39 tests, 0 failures
==> ezagent_domain_session
8 tests, 0 failures
EXIT_CODE=2
```
The actual measured state is **`mix ci.fast` is red — 4 failures, all in
`ezagent_core`'s `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/official_site_seed.ex`**
(`PluginWorkspaceLocalityContractTest` ×2,
`Ezagent.Invariants.SensitiveSliceReadTest` ×1,
`EzagentCore.Invariants.CapCheckOnlyAtChokepointTest` ×1 — all
owner-bypass/sensitive-slice-read/admin-equality debt in a Hello plugin
seed file, unrelated to identity or SSH). Grepped the full `ci.fast`
output for "ssh" (case-insensitive): the only hit is the worktree's own
directory path (`.../agent-ssh-credential/apps/...`), not the
functionality. **This supports "Task 1's review fixes introduced no new
red," not "the branch's gates are all green."** The branch was already
red on these 4 pre-existing `ezagent_core` failures before this session's
changes (same failures the first implementer's report described).

## What I could not fix

Nothing from the findings list was left unfixed. Two things worth a human
glance even though I judged them safe to proceed on (both documented
above and in code comments, not hidden):

1. **I2's Task.async link-crash interaction** — the human decision named
   `Task.async` specifically; I kept it exactly, but had to move the
   `System.cmd` rescue inside the task function (empirically necessary —
   see I2 section above) rather than leaving it where the brief/first
   implementer had it. This is an implementation-correctness fix within
   the mandated mechanism, not a substitution of it, but flagging per the
   "ask before implementing" norm since I did not pause to confirm before
   applying it (the alternative — shipping the naive version — would have
   been a confirmed regression against an existing required test, so I
   judged fixing it inline was the safer default; happy to revert to a
   different resolution if that judgment is wrong).
2. **M1/M2 testability seams** — `cleanup_tmp_dir/1` and `fingerprint/1`
   went from `defp` to `def` + `@doc false` purely so their failure paths
   are unit-testable without mocking subprocess output or racing an
   internally-randomized directory name. This does not change runtime
   behavior or widen the module's real (documented) public API — the
   `doc_coverage_test.exs` `undocumented_public_defs` ratchet already
   treats `@doc false` as "documented" (same pattern the module already
   used for `required_caps/0`/`data_owner/1`), confirmed unchanged at 0
   net delta by re-running that gate.

## Commit

All five changed files + the new test file are one commit (findings span
production code, tests, an architecture-manifest comment, and a design
doc — splitting further didn't seem to help a reviewer here, per the
task's "split only if it genuinely helps a reviewer").

---

# Task 1 review-fix round 2 report (2026-08-01)

Fixing all findings from `.superpowers/sdd/task-1-findings-round2.md` — 1
Important (R1) + 5 Minor (R2-R6), plus the pre-resolved disagreement
(no action needed — Allen already ruled "opus 对", the two follow-ups it
still required are R1 and R3 below).

Files touched:

- `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex`
  (R2, R3, R4, R6 — production code)
- `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs`
  (R1, R2, R6 — tests)
- `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`
  (R5 — spec §5.2)

Untouched, as instructed: `arch_baseline_manifest.exs` (ratchet stays
`136`), `cap_signing_architecture_test.exs`, and the cold-load test's
round-trip mechanics.

## R1 (Important) — private-key-leak assertion, with the required red demonstration

**Fix**: replaced the round-1 assertion (`refute Jason.encode!(result) =~
private`) with the reviewers' prescribed raw-value check, in
`user_ssh_identity_test.exs`'s `"生成密钥对..."` test (line 24; the new
assertion is at line ~59):

```elixir
refute Enum.any?(Map.values(result), &(is_binary(&1) and String.contains?(&1, private)))
```

**Why the old one proved nothing** (now recorded in a code comment at the
same spot): OpenSSH private keys contain literal `\n` bytes;
`Jason.encode!/1` escapes every `\n` to the two-character sequence
`\`+`n`, so the raw key's byte sequence can never be a substring of the
encoded JSON — even when a field genuinely carries the key verbatim. The
new assertion checks the RAW map values directly, no serialization step
to hide behind.

### Required verification — broke the implementation two ways, ran the NEW assertion, captured real red output, restored

Both breaks were applied directly to `handle_generate_ssh_key/2`'s
success-branch return value (`user_ssh_identity.ex` line 118), one at a
time, each followed by `POSTGRES_PORT=15432 mix test
apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs:24`,
then reverted before the next.

**Regression A — `public_key: pub <> priv`:**

```elixir
{:ok, %{public_key: pub <> priv, fingerprint: fp}, [...]}
```

```
  1) test generate_ssh_key 生成密钥对，返回公钥与指纹，且不返回私钥 (Ezagent.ActionSet.UserSshIdentityTest)
     apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs:24
     Expected false or nil, got true
     code: refute Enum.any?(Map.values(result), &(is_binary(&1) and String.contains?(&1, private)))
     arguments:

         # 1
         ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJQcgZHE6ItMp58Mk2Z/CBaLRwwGeTqjyvbBJPJLgwt alice@ezagent-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\nQyNTUxOQAAACByUHIGRxOiLTKefDJNmfwgWi0cMBnk6o8r2wSTyS4MLQAAAJApvzU/Kb81\nPwAAAAtzc2gtZWQyNTUxOQAAACByUHIGRxOiLTKefDJNmfwgWi0cMBnk6o8r2wSTyS4MLQ\nAAAEA+mEE7LFlBpZzrf1+zdai3ewI87ttNohCvgPzF6gRjE3JQcgZHE6ItMp58Mk2Z/CBa\nLRwwGeTqjyvbBJPJLgwtAAAADWFsaWNlQGV6YWdlbnQ=\n-----END OPENSSH PRIVATE KEY-----\n",
          "SHA256:aO2vqHJPt9Zl0Gccu9UnWb7t8kwahtXOOVbgGZEH1dM"]

         # 2
         #Function<4.118527708/1 in Ezagent.ActionSet.UserSshIdentityTest."test generate_ssh_key 生成密钥对，返回公钥与指纹，且不返回私钥"/1>

     stacktrace:
       test/ezagent/behavior/user_ssh_identity_test.exs:59: (test)


Finished in 0.2 seconds (0.00s async, 0.2s sync)
1 test, 1 failure (12 excluded)
```

RED confirmed — `Map.values(result)` includes the smuggled
`public_key <> private_key` string, `String.contains?` finds the private
key inside it, `Enum.any?` is `true`, `refute` fails.

**Regression B — `fingerprint: priv`:**

```elixir
{:ok, %{public_key: pub, fingerprint: priv}, [...]}
```

```
  1) test generate_ssh_key 生成密钥对，返回公钥与指纹，且不返回私钥 (Ezagent.ActionSet.UserSshIdentityTest)
     apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs:24
     Expected false or nil, got true
     code: refute Enum.any?(Map.values(result), &(is_binary(&1) and String.contains?(&1, private)))
     arguments:

         # 1
         ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmlIwOMMCb2JTxaHWOiTRB3iWvQldjsWra1qATQ5cuE alice@ezagent",
          "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\nQyNTUxOQAAACAppSMDjDAm9iU8Wh1jok0Qd4lr0JXY7Fq2tagE0OXLhAAAAJCPJZJ3jyWS\ndwAAAAtzc2gtZWQyNTUxOQAAACAppSMDjDAm9iU8Wh1jok0Qd4lr0JXY7Fq2tagE0OXLhA\nAAAEDnonsC4mYy8SX0xIe4qi3ybDWJd87Kk4fYh6AsBEosMymlIwOMMCb2JTxaHWOiTRB3\niWvQldjsWra1qATQ5cuEAAAADWFsaWNlQGV6YWdlbnQ=\n-----END OPENSSH PRIVATE KEY-----\n"]

         # 2
         #Function<4.118527708/1 in Ezagent.ActionSet.UserSshIdentityTest."test generate_ssh_key 生成密钥对，返回公钥与指纹，且不返回私钥"/1>

     stacktrace:
       test/ezagent/behavior/user_ssh_identity_test.exs:59: (test)


Finished in 0.1 seconds (0.00s async, 0.1s sync)
1 test, 1 failure (12 excluded)
```

RED confirmed again — same mechanism, `fingerprint` now literally IS the
private key.

**Restore verified byte-exact**: after reverting line 118 back to
`{:ok, %{public_key: pub, fingerprint: fp}, [...]}`, `git diff` on that
line showed no change at all (confirming the restore matched the
pre-break original exactly, not just "close enough"), and the test went
back to green:

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs:24
...
1 test, 0 failures (12 excluded)
```

**R1 demonstration: CONFIRMED.** The new assertion catches both named
regressions with real, captured red output; the old one (proven in
round 2's findings doc) caught neither.

## R2 (Minor) — `validate_comment/1` now rejects NUL

**Fix**: `user_ssh_identity.ex`'s `validate_comment/1` (line 170) now
checks `String.contains?(comment, ["\n", "\r", "\0"])` (was `["\n",
"\r"]`). Test added: `"comment 含 NUL 时同样拒绝（R2）"`
(`user_ssh_identity_test.exs:123`).

**A discrepancy I found and want to flag explicitly**: the finding's
stated mechanism — "`System.cmd/3` 对含 NUL 的 argv 元素抛
`ArgumentError`" — does **not** reproduce on this repo's actual
Erlang/OTP 28 + Elixir 1.19.2 pair. I probed it directly:

```
$ elixir -e 'IO.inspect(System.cmd("echo", ["a" <> <<0>> <> "b"]))'
{"a\n", 0}
```

`System.cmd` silently **truncates** the argument at the NUL instead of
raising (confirmed identically against a real `ssh-keygen -C "a\0b"`
invocation — the generated key's embedded comment came back as plain
`"a"`). I verified this by temporarily reverting just the NUL check (put
`validate_comment/1` back to `["\n", "\r"]`) and running the new test —
it went red via an ordinary `MatchError` (not a process crash):

```
  1) test generate_ssh_key comment 含 NUL 时同样拒绝（R2） (Ezagent.ActionSet.UserSshIdentityTest)
     apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs:111
     match (=) failed
     code:  assert {:error, :invalid_comment} = UserSshIdentity.handle_generate_ssh_key(%{comment: "a\0b"}, ctx())
     left:  {:error, :invalid_comment}
     right: {:ok,
             %{
               public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIND3f9hjfIPgKR1gwA4QqpaqneyUrZIPq55uyM7eAi4P a",
               fingerprint: "SHA256:UGU48mEQSA1S3DRm6uzvDNc2Q/tWCFhJquacC0kvkoo"
             },
             [
               ...
               {:set, :comment, <<97, 0, 98>>},
               ...
             ]}
     stacktrace:
       test/ezagent/behavior/user_ssh_identity_test.exs:114: (test)

Finished in 0.1 seconds (0.00s async, 0.1s sync)
1 test, 1 failure (12 excluded)
```

Then restored the fix and re-ran — green:
`1 test, 0 failures (12 excluded)`.

The fix (reject NUL) is still fully justified — just for a different,
still-real reason than the finding stated: silent truncation means the
persisted `{:set, :comment, _}` state field (`"a\0b"`) would silently
diverge from the comment actually embedded in the generated key
(`"a"`) — a silent state/reality mismatch, exactly the class of bug
CLAUDE.md's "不要 silent 失败" rules out. I recorded this corrected
mechanism in both the production comment and the test comment (not the
finding's original `ArgumentError` claim) so a future reader isn't misled
by an unverified premise — the same discipline R3 asked for elsewhere in
this round.

## R3 (Minor) — corrected the wrong "would crash the User actor" comment

**Fix**: rewrote the `run_ssh_keygen/2` comment block in
`user_ssh_identity.ex` (now lines 260-300). Retracted the false claim and
replaced it with a mechanism I verified against Elixir's own `Task`
source (`.../lib/elixir/lib/task.ex`, `async/3` + `build_alias/1` +
`yield_receive/3`) rather than re-asserting the resolution doc's prose
verbatim:

- `Task.async` establishes **both** a link (`spawn_link`) and a genuine
  `:erlang.monitor/3` from the owner's process (`build_alias/1` —
  `:erlang.monitor(:process, pid, alias: :demonitor)`), and the monitor
  is established **before** the task is signaled to run the actual
  function — no start-up race.
- `Task.yield/2`'s `yield_receive/3` detects completion/crash purely via
  that monitor's `{ref, reply}` / `{:DOWN, ref, ...}` messages, never via
  the link. So in production, an uncaught task crash does **not** kill
  `Ezagent.Kind.Server` (which traps exits, `server.ex:106`) — the
  monitor still delivers cleanly regardless of trap_exit.
- The inner rescue's real justification: this handler is also called
  DIRECTLY by this module's own unit tests, with no `Kind.Server` in
  between — there, the "caller" is a plain, non-trapping ExUnit process,
  where an uncaught raise inside the task genuinely would cross the link
  and crash the test process before `Task.yield` ever runs.
- Named the accepted residual (the R4 topic) inline as a forward
  reference instead of leaving it implicit.

No test needed for a comment-only fix; verified via `mix compile` +
re-running the full target test files (unchanged behavior, prose only).

## R4 (Minor) — drain the residual `{:EXIT, task_pid, :normal}` on the success path

**Chose option 1** (selective 0-timeout receive), per the finding's
stated priority. In `run_ssh_keygen/2` (`user_ssh_identity.ex`
lines 301-340): bound `task_pid = task.pid` right after `Task.async`
returns (note: `^task.pid` does **not** compile as a pin target in a
receive pattern — Elixir's pin operator requires a bound variable, not a
field-access expression; confirmed via `elixir -e` probe before writing
the real code, same discipline as the rest of this module), then in the
`{:ok, result} ->` branch:

```elixir
receive do
  {:EXIT, ^task_pid, :normal} -> :ok
after
  0 -> :ok
end
```

**Why no dedicated regression test**: the drain is explicitly
best-effort/racy by the finding's own framing ("带 0 超时，拿不到就算了")
— exit-signal delivery to the linked, trapping caller is a separate
asynchronous step from the reply message `Task.yield` already consumed,
so there's no guarantee the `:EXIT` message has landed by the time the
0-timeout receive runs. A test asserting "the message is never present
after the call returns" would be flaked by timing, not by a real
regression — worse than no test. I confirmed the fix is at least
inert/safe in the existing non-trapping unit-test context (a non-trapping
process never receives `:EXIT` for a `:normal`-reason linked exit at
all, so the `receive/after 0` there is always a harmless immediate
no-op) by re-running the full target test files — still 14 tests, 0
failures. The already-existing I3 dispatch/cold-load integration test
(which runs through the real, trapping `Kind.Server`) is the only
practical way this path gets exercised end-to-end, matching what the
finding itself already cites as having "证实" the benign-ness of the
residual.

## R5 (Minor) — `:invalid_comment` added to the spec's failure-semantics table

**Fix**: `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`
§5.2, renamed "三条具体处理" → "四条具体处理", added **④** documenting
`{:error, :invalid_comment}` and its three trigger conditions (`\n` /
`\r` / `\0`), including the corrected NUL mechanism from R2 (empirically
verified truncation-not-raise on this OTP/Elixir pair, not the
originally-assumed `ArgumentError`).

## R6 (Minor) — tmp-dir prefix no longer hardcoded in the test

**Fix**: `user_ssh_identity.ex` now exposes `def tmp_prefix, do:
@keygen_tmp_prefix` (line 55, `@doc false`, same testability-seam pattern
as `cleanup_tmp_dir/1`/`fingerprint/1` from round 1).
`user_ssh_identity_test.exs`'s `tmp_entries/0` helper now calls
`UserSshIdentity.tmp_prefix()` instead of repeating the literal
`"ezagent-sshkeygen-"`.

## Self-inflicted bug caught and fixed before it shipped

While writing R2's production comment, I wrote the literal text
`` `{:set, :comment, comment}` `` in prose — the exact same class of
mistake the round-1 report documented catching once already (the
`set_effect_sites` scanner is a plain per-line regex,
`~r/\{:set,\s*:[a-z_]+,/`, not AST-aware, so it matches doc prose
identically to a real effect tuple). Caught it this time by re-running
`grep -noE '\{:set,[[:space:]]*:[a-z_]+,' user_ssh_identity.ex` after
every edit to the file (not just at the end) — found the 6th spurious
match, reworded the comment to avoid the literal bracket-tuple syntax
(same fix pattern as round 1), re-grepped down to exactly 5 (all real),
then confirmed with the actual gate:

```
POSTGRES_PORT=15432 mix test apps/ezagent_core/test/architecture/effect_discipline_test.exs apps/ezagent_core/test/architecture/doc_coverage_test.exs apps/ezagent_core/test/architecture/manifest_ratchet_test.exs apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs
...
27 tests, 0 failures
```

(Also confirmed, separately, that `test/` files are entirely outside the
scanner's reach —`lib_files/0` in `ezagent.arch.scan.ex` globs only
`apps/*/lib/**/*.ex` — so the same literal tuple text appearing in the
*test* file's R2 comment, which I left as-is, was never at risk.)

`arch_baseline_manifest.exs` and `cap_signing_architecture_test.exs`
confirmed untouched throughout (`git diff` on both is empty).

## Test commands run + real output (round 2)

Target files:

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_lifecycle_cold_load_test.exs
```
```
Finished in 0.2 seconds (0.00s async, 0.2s sync)
14 tests, 0 failures
```
(13 in the unit test file — 12 from round 1 + R2's new NUL test — plus 1
in the untouched cold-load file.)

Full identity-domain suite (run once, as instructed):

```
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test
```
```
Finished in 50.5 seconds (2.0s async, 48.5s sync)
666 tests, 3 failures
```
The 3 failures are exactly the task prompt's named pre-existing
DB-seed flakiness — `Ezagent.Identity.Cutover.RunbookTest` ×2
(`runbook_test.exs:128`, `runbook_test.exs:113`) and
`Ezagent.Identity.CutoverTest` ×1 (`cutover_test.exs:137`). Grepped the
full log for "ssh" (case-insensitive): zero hits outside the worktree's
own directory path. **No new red.**

Fast CI gate:

```
POSTGRES_PORT=15432 mix ci.fast
```
```
==> ezagent_core
697 tests, 4 failures
==> ezagent_domain_identity
4 tests, 0 failures
==> ezagent_domain_external_mirror
39 tests, 0 failures
==> ezagent_domain_session
8 tests, 0 failures
EXIT_CODE=2
```
The 4 failures are exactly the task prompt's other named pre-existing
group — `PluginWorkspaceLocalityContractTest` ×2,
`SensitiveSliceReadTest` ×1, `CapCheckOnlyAtChokepointTest` ×1, all in
`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/official_site_seed.ex`.
Grepped the full log for "ssh": zero hits outside the worktree's own
directory path. **`mix ci.fast` is still red on exactly the same
pre-existing 4 failures it was red on before this round — no new red.**

Architecture gates specifically touched by this round's edits
(`set_effect_sites` via the R2 comment, `undocumented_public_defs` via
the new `tmp_prefix/0`, plus the untouched-but-adjacent
`cap_signing_architecture_test.exs` and the ratchet-annotation gate):

```
POSTGRES_PORT=15432 mix test apps/ezagent_core/test/architecture/effect_discipline_test.exs apps/ezagent_core/test/architecture/doc_coverage_test.exs apps/ezagent_core/test/architecture/manifest_ratchet_test.exs apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs
```
```
Finished in 13.5 seconds (12.0s async, 1.4s sync)
27 tests, 0 failures
```

`mix format --check-formatted` on both touched Elixir files: exit 0
(no changes needed after the final polish edit).

## What I could not fix

Nothing from the round-2 findings list was left unfixed. One thing worth
a human glance even though I judged it safe to proceed on (documented
above, not hidden): R2's fix is justified by a different, empirically
verified mechanism (silent truncation → persisted-state/real-key
mismatch) than the finding originally stated (`ArgumentError`) — the
*fix* itself (reject NUL before `ssh-keygen` runs) is unchanged and still
exactly what was asked for.

## Commit

All three changed files (production code, test, spec doc) are one commit
per the task's "One commit is fine."
