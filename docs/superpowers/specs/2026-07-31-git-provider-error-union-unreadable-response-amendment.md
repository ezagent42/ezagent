# Git Provider error-union amendment — unreadable provider responses

**Status:** approved for implementation 2026-07-31 (gaga)

**Amends:** the 2026-07-16 V1-A decisions (§6 Error union) and the 2026-07-16
V1-B domain spine (§10 Error model), both of which state that
`Ezagent.DomainGit.Error.t()` is the exact/frozen Plan A union

**Narrow forward amendment:** this document supersedes the earlier statement
that the Plan A union is closed at its original members. It adds exactly one
member, `:provider_response_unrecognized`, and records why. The union remains
frozen in the sense that matters — `plan_a_contract_test` still asserts it
member-for-member, so the next addition is equally deliberate.

**Does not change:** provider neutrality, the five frozen adapter callbacks or
their arity, the `{:ok, _} | {:error, Error.t()}` result shape, capability
semantics, URI/receiver authority, the `Ezagent.ActionSet.GitTaskAccess` policy,
or any stored data. `EzagentPluginGitWorkflow.Blocker`'s existing codes keep
their classifications.

---

## 1. Why this amendment exists

`:provider_unavailable` carried two facts that need different answers.

A provider that is genuinely down — a 5xx, a connection timeout, a dispatch
timeout — should be re-asked. `Blocker` classifies `:provider_unavailable`
retryable, and for that case it is right.

A provider that answered **2xx** with a body the adapter cannot normalize —
an unknown enum value, a missing or renamed field, a body shape that does not
match — will answer identically to the identical request. Re-asking buys
nothing.

`Blocker`'s own rule already separates these: its comment classifies by
"deterministic given the same run inputs → terminal, needs an operator" versus
"transient → bounded retry". The second case above is deterministic and was
being retried.

The consequence was not a hang. `RunFailure.fail/4` leaves a retryable run's
status alone and returns `{:retry, _}`; the observation loop's deadline
eventually produces the terminal `:observation_incomplete`. The consequence was
**misdiagnosis**: a provider schema change presented to an operator as a
timeout, after burning the whole deadline. That is the opposite of the signal
the event deserves, and provider schema drift is precisely what the read-path
hardening in PR #1653 exists to catch.

The distinction cannot be recovered downstream. Both cases reach
`Blocker.from_error/1` as the same atom; the information is destroyed at the
adapter boundary. Splitting at the source is the only place it can be done.

## 2. Why a new member rather than a reclassification

Reclassifying `:provider_unavailable` as terminal would break the retry that a
real outage legitimately needs. The problem is not that one code sits in the
wrong bucket — that case has a precedent, and `RunFailure`'s moduledoc records
its resolution ("the misplacement was in the classification, not in the
protocol"). The problem here is that one code holds two buckets' worth of
meaning. So: split, not move.

No existing member covers it. `:invalid_ref` and `:invalid_file_change` describe
request inputs; `:installation_scope_mismatch` is a narrower credential-scope
answer; `:provider_rate_limited` and `:checks_unavailable` are transient.

## 3. What was added

```elixir
:provider_response_unrecognized
```

The provider completed a successful **2xx** interaction whose response carried
something this code cannot normalize. Terminal.

One member, not three. "Unknown value", "missing field" and "wrong body shape"
all lead to the same next action — stop, do not trust partial facts, have
someone check whether the API changed — so splitting them further would add
vocabulary without changing policy.

Degrading onto a concrete value remains correct wherever the domain type
declares a member meaning "a value we have no mapping for": `Check.conclusion`
has `:other`, so an unrecognized conclusion STRING is still reported honestly
rather than refused. `Check.status`, `Review.state` and `ChangeRequest.state`
have no such member, so for those any specific answer would be an invention.

## 4. What `:provider_unavailable` now means, stated honestly

The residual bucket: the provider did not give a usable answer at all — a
transport failure, or an HTTP status this client does not specifically
classify. Retryable.

It is deliberately NOT documented as "no response", because that is not all it
holds. It also catches **deterministic 4xx**: the GitHub adapter's
`map_read_error` / `map_checks_error` / `map_git_data_error` map a 422 onto it,
and `GitHubClient`'s unclassified-status fallback sweeps up 400-class statuses
alongside 5xx. Those are deterministic and their retryable classification is
inaccurate.

That is **not fixed here**, and not folded into the new member either. A 422
means "the provider understood the request and rejected it as invalid", which is
a different fact from "the response could not be read"; mapping it onto
`:provider_response_unrecognized` would be a second inaccuracy rather than a
fix. It needs a per-operation answer — a 422 on a read and a 422 on a git-data
write do not mean the same thing — and `plan_e_fault_injection_test` currently
freezes 422 as retryable alongside 503. Tracked as a follow-up.

## 5. Consequences accepted

A malformed 2xx could in principle be a one-off proxy glitch, and terminal
classification gives up automatic recovery from that. Accepted: the adapter
cannot distinguish a glitch from a schema change, and of the two possible
wrong answers, "stop and tell someone" costs an operator one look while
"retry silently to the deadline" costs the run its whole budget and reports the
wrong cause.

## 6. Where this is enforced

| Gate | Catches |
|---|---|
| `plan_a_contract_test` "exact frozen union" | a member added or removed without saying so |
| `blocker_test` "the vocabulary is total" | a domain member with no `Blocker` mapping |
| `blocker_test` "the vocabulary is exactly …" | a `Blocker` code added or removed |
| `blocker_test` "unreadable is terminal while unavailable is retryable" | the two being collapsed back into one |
| `observation_test` "CASes to blocked instead of being retried" | the state-machine consequence |
| `adapter_contract_test` + `FakeGitAdapterA` | an adapter that cannot return the member |

`blocker_test`'s totality gate was repaired as part of this change. It had
enumerated the union as a **literal copy** while its comment called itself "the
test that catches a future domain_git addition" — a copy cannot do that, and
measurement confirmed the new member sailed past it. It now reads the typespec
via `Code.Typespec.fetch_types/1`. (The copy's stated reason — "`t()` is a TYPE,
there is nothing to read at runtime" — was untrue; typespecs live in the BEAM
chunk.)

## 7. Forgejo adopts it here, not later

An earlier draft of this section said Forgejo was absent from main and would
adopt the new member when PR #1643 rebased. **#1643 merged on 2026-07-30**, so
by the time this change landed Forgejo was already in the tree carrying the same
conflation — modelled on the GitHub adapter, 19 production sites. Leaving it
would have shipped one tree in which the identical schema-drift event stops
immediately for GitHub and retries to the observation deadline for Forgejo.

So it is migrated here: **14 runtime sites** (10 in `normalize.ex`, 4 in
`forgejo_adapter.ex`) plus the three `@spec` declarations in `normalize.ex`,
and the 11 `normalize_test` assertions that had frozen the old answer.

**Two sites deliberately keep `:provider_unavailable`:**

- the `@max_items` clause of `all_pages/5` — the 2,000-item pagination cap.
  Deterministic, but nothing was unreadable: the instance was still answering
  and OUR limit was reached. Calling that a provider schema problem points an
  operator at the wrong system. Now covered by a test, which it was not before.
- `map_error/3`'s fallback — the transport/status residue, the same role as the
  GitHub client's unclassified-status fallback, and retryable for the same
  reason.

The general rule this leaves: a provider plugin's parse refusals are
`:provider_response_unrecognized`; its own limits and its transport residue stay
`:provider_unavailable`. A third provider should be read against that line
rather than against either adapter's line count.
