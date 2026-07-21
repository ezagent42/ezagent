# Hello 官网 greeter-relay crash — root-cause analysis

**Date:** 2026-07-22
**Symptom:** a member `:send` to the `system/hello/web` greeter succeeds
(`{:ok, %{stored: true}}`), but the greeter's reply relay crashes with
`Ezagent.ActionSet.Agent.Receive.handle_receive/2 → {:unknown_action, :hello_sync_result}`.
**Status:** REPRODUCED deterministically on current `origin/main` (e0d07be17).
Diagnosis only — no fix shipped (per the coordinator's request).

---

## 0. TL;DR

The crash is **NOT** a mounting gap and **NOT** a mis-routing to `Agent.Receive`.
The `hello.front-desk` agent is correctly built as a `"hello"`-flavor agent with
`HelloOrchestrator` mounted in its per-instance behavior set — per-instance
resolution of `:hello_sync_result` works.

The crash is a **regression introduced by PR #1457
(`feat(cap): enforce per-Kind signing authority`, commit `596bd3a1d`)** — the
cap-signing strict re-architecture. That PR made the `:sync_result` self-dispatch
mint a **target-signed capability** via `Ezagent.Cap.issue_for_action/3` and
hard-match it:

```elixir
# apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:300
{:ok, signed_cap} =
  Ezagent.Cap.issue_for_action({:admin, admin}, self_uri, target)
```

For a **self-target** issuance (the agent signing a cap that targets itself),
`Cap.issue_for_action` → `Ezagent.Cap.action_context/3` takes the
`pid == self()` branch, which resolves the action's subject **only through the
GLOBAL `BehaviorRegistry`** (`registered_subject/2`). `:hello_sync_result` is a
**flavor-only, per-instance** action — hello registers `HelloOrchestrator` via
the `"hello"` flavor's `instance_behaviors` (captured in `:kind_base`), but it
does **NOT** globally register `{Entity.Agent, :hello_sync_result}`. So
`registered_subject` returns `:error` → `action_context` returns
`{:error, {:unknown_action, :hello_sync_result}}` → the `{:ok, signed_cap} = …`
**badmatch** crashes `handle_receive/2`.

**Why only hello and not py / cc-headless:** py globally registers its flavor
sync-result behavior (`behaviors/0` → `{Entity.Agent, :py_sync_result} →
PyAgentBehavior`; this exact pair is the canonical example in
`behavior_registry.ex:12`). Hello registers `HelloOrchestrator` **per-instance
only**. That single registration asymmetry is why the same code path succeeds
for py and crashes for hello.

> **NOTE — the task's premise is overturned.** The bug report framed this as a
> MIS-ROUTING / mounting gap (`:hello_sync_result` dispatched to `Agent.Receive`
> instead of `HelloOrchestrator`). It is neither: `HelloOrchestrator` IS mounted
> and per-instance resolution DOES work. The crash is a **cap-signing self-target
> resolver asymmetry** in the effect-build step, upstream of dispatch. Read §4.

---

## 1. Reproduction (deterministic, isolated)

Test: `apps/ezagent_plugin_hello/test/integration/hello_greeter_relay_repro_test.exs`
(added in this worktree). It provisions a hello app with `App.ensure_app/2`
(same path `FusionSeed.run` / `OfficialSiteSeed.ensure` take), then drives the
**genuine runtime `:receive`** to the front-desk via the real per-recipient
delivery primitive `Ezagent.ActionSet.Session.Delivery.dispatch_receive_call/3`
(which does `Ezagent.Router.dispatch` of `:receive` — the runtime builds ctx and
processes the effect, unlike the existing `hello_orchestrator_delivery_test.exs`
which stops at `deliver_agent_receive` and never fires the re-dispatch).

Observed output (verbatim, trimmed):

```
[1] BehaviorRegistry.lookup(Entity.Agent, :hello_sync_result) => :error

[2] front-desk :kind_base captured behaviors:
    [..., Ezagent.ActionSet.HelloOrchestrator]
    HelloOrchestrator present? => true

[3] BehaviorSet.resolve_action(Entity.Agent, :hello_sync_result, slice_state)
      => {:ok, Ezagent.ActionSet.HelloOrchestrator}
    effective_set => [..., Ezagent.ActionSet.HelloOrchestrator, KindBase, Manage]

[4] captured log during real :receive delivery:
  [error] Behavior Ezagent.ActionSet.Agent.Receive.handle_receive/2 crashed:
          :error {:badmatch, {:error, {:unknown_action, :hello_sync_result}}}
  [error] Kind.Server: fire-and-forget cast dispatch FAILED …
          reason={:behavior_exception, :error,
                  {:badmatch, {:error, {:unknown_action, :hello_sync_result}}}}
```

The `[1]/[2]/[3]` reads prove the mounting is correct **and** that per-instance
resolution succeeds; `[4]` proves the runtime path still crashes — so the crash
is upstream of dispatch resolution, in the effect-build step.

**Exact crash frame** (captured with a temporary `__STACKTRACE__` log, since
reverted):

```
receive.ex:300  Ezagent.ActionSet.Agent.Receive.sync_result_effect/4   <-- {:ok, signed_cap} = …
receive.ex:245  Ezagent.ActionSet.Agent.Receive.do_handle_receive/2
runtime.ex:598  Ezagent.Kind.Runtime.invoke_handler_with_post/7
runtime.ex:183  Ezagent.Kind.Runtime.do_handle_dispatch/4
cap/authority.ex:123  Ezagent.Cap.Authority.with_current/2
kind/server.ex:696    Ezagent.Kind.Server.handle_cast/2
```

The badmatch is at **`receive.ex:300`** — the cap-issuance line, running while
the front-desk holds the current authority compartment (`with_current`), i.e.
the self-target path.

---

## 2. The exact crash chain (real module/function names)

1. **Member send** → `Ezagent.ActionSet.Session.handle_send/2` → routing rule
   `{always} → ["front-desk"]` (from `App.hello_definition_attrs/1`,
   `routing_rules`) → per-recipient delivery
   `Ezagent.ActionSet.Session.Delivery.dispatch_receive_call/3`.
2. **Delivery** dispatches `:receive` to the front-desk agent →
   `Ezagent.ActionSet.Agent.Receive.handle_receive/2` (member-cap authorized,
   not self-message).
3. `Ezagent.ActionSet.Agent.Delivery.deliver_agent_receive/2` resolves the
   `"hello"` flavor's in-process adapter (`EzagentPluginHello.BridgeAdapter`,
   `:in_process_sync`) and returns `{:sync, "hello", {:ok, %{session_uri, sender,
   text}}}`.
4. `handle_receive` → `do_handle_receive` matches `{:sync, flavor, sync_result}`
   and builds the re-dispatch effect via **`sync_result_effect/4`**.
5. `sync_result_action("hello") → :hello_sync_result`;
   `target = self_uri?action=hello_sync_result`.
6. **`{:ok, signed_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, self_uri,
   target)`** (`receive.ex:300`).
   * `issue_for_action` → `action_context(pid, instance, :hello_sync_result)`
     with `pid == self()` (front-desk is the current authority target).
   * Self-target branch (`cap.ex:98-108`) →
     `registered_subject(:agent, :hello_sync_result)` scans
     `BehaviorRegistry.list_all()` for `{Entity.Agent, :hello_sync_result}` →
     **not found** → `:error` → `action_context` returns
     `{:error, {:unknown_action, :hello_sync_result}}`.
7. `{:ok, signed_cap} = {:error, …}` → **`{:badmatch, …}`** → `handle_receive/2`
   crashes. The `:receive` is a fire-and-forget cast, so the reply never lands
   (the visitor's message is stored but never answered).

The re-dispatch itself (step after the cap) is never reached — resolution of
`:hello_sync_result` at dispatch time would have succeeded per-instance (proven
in §1 `[3]`). The failure is entirely in **cap issuance**.

---

## 3. Why a custom `:hello_sync_result` action exists — sound, or a workaround?

**Rationale (from `hello_orchestrator.ex` moduledoc + `receive.ex` comments):**

* `:receive` on `Entity.Agent` is owned by the **flavor-blind** `Agent.Receive`
  (the AgentBridge seam) and cannot be overridden by a role behavior.
* The supported way for an **in-process flavor** to run custom Elixir on chat is
  the `:in_process_sync` class: the adapter returns the message inputs, and
  `Agent.Receive` **re-dispatches** them to the flavor behavior's sync-result
  action, which persists/acts and replies.
* The action is uniquely named `:hello_sync_result` (not the default
  `:sync_result`) because **`:sync_result` is claimed GLOBALLY by
  `Behavior.CurlAgent` on `Entity.Agent`** — using the default would resolve to
  curl (not in hello's set) and be denied. So the unique name dodges a genuine
  global naming collision.

**Verdict:** The unique-action pattern is **sound for the collision it solves**,
and it deliberately **mirrors py (`:py_sync_result`) and cc-headless
(`:cc_headless_sync_result`)**. It is not the cause of the crash.

**But** hello diverges from py/cc-headless in one way that matters: py registers
`PyAgentBehavior` **globally** (`behaviors/0`) *and* per-instance; hello
registers `HelloOrchestrator` **per-instance only**. Under the pre-#1457 design
this divergence was invisible (the self-dispatch minted a provenance-only cap
inline, never resolving through the global registry). Under #1457's signed-cap
issuance it becomes fatal. So `:hello_sync_result` is a legitimate seam that has
been left half-wired relative to its py sibling.

---

## 4. The precise root cause (the wiring gap)

Two asymmetries compound:

**A. Registration asymmetry (hello-specific).**
`:hello_sync_result` is mounted **per-instance** (flavor `instance_behaviors` +
recipe fold → captured in `:kind_base`), never **globally** in `BehaviorRegistry`.
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:209`
  `behaviors/0` registers only `{Entity.Session, :hello_render}` — nothing for
  `{Entity.Agent, :hello_sync_result}`.
- Contrast py: `apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:93`
  `behaviors/0` → `{Entity.Agent, action} → PyAgentBehavior` for every
  `PyAgentBehavior.actions()` (incl. `:py_sync_result`).

**B. Resolver asymmetry (framework-level, the deeper issue).**
`Ezagent.Cap.action_context/3` resolves the target action **differently** for
self-target vs cross-process:
- `pid == self()` (self-target, `cap.ex:98`): via `registered_subject/2` =
  **GLOBAL `BehaviorRegistry` only**.
- `pid != self()` (cross-process, `cap.ex:110`): via
  `GenServer.call(pid, :ezagent_runtime_view)` → `BehaviorSet.resolve_action/3`
  = **per-instance effective_set** (reads the live slice_state).

The `:sync_result` re-dispatch is a **pure self-dispatch** (caller = target =
`self_uri`), so it always takes branch (A→self), where a per-instance-only action
is invisible. py "works" only because it *also* registers globally — masking the
resolver asymmetry. Hello exposes it.

**Regression provenance:** `git log -L` on `sync_result_effect` shows the
`{:ok, signed_cap} = Ezagent.Cap.issue_for_action(...)` line was introduced by
**#1457 `feat(cap): enforce per-Kind signing authority`** (`596bd3a1d`). The
prior version built a self-minted, provenance-only `%Ezagent.Capability{…
granted_by: self_uri}` inline — no `issue_for_action`, no global-registry
resolution, no crash. Fail-before (pre-#1457) / crash-after (#1457) is a genuine
regression, not new hello behavior.

---

## 5. Team-routing verdict (product owner's core architectural question)

Does the greeter reply flow through the generic **world routing / sender-rule
relay** or a **custom HelloOrchestrator orchestration**? Answer, grounded in code:

| Hop | Mechanism | Standard or custom |
|---|---|---|
| member → front-desk (delivery) | routing rule `{always} → ["front-desk"]` (`app.ex` `routing_rules`) | **STANDARD** world routing |
| front-desk `:receive` → run Elixir | `Agent.Receive` re-dispatch to flavor `:sync_result` (`:in_process_sync`) | framework seam (same for py/cc-headless/curl) |
| front-desk → builder/concierge | `EzagentPluginHello.Router.route` → direct `Ezagent.Invocation.dispatch` of `:rebuild` / `:answer` | **CUSTOM** orchestration |

* Inbound delivery already uses the **standard** routing rule — there are **no
  `{:from, uri}` sender-rules** in the hello definition (the only rule is
  `{always} → front-desk`). The sender-based logic is confined to the loop-guard
  in `Router.should_route?/2`.
* The front-desk → worker hop is **genuine custom policy**: intent × identity
  (`Router.decide/3` — non-owner ⇒ concierge with no LLM call; owner ⇒
  `Generator.classify_intent`). **No static sender-rule can express** an
  owner-check + LLM intent classification, so the custom orchestration is
  justified on its own terms.

**Would routing this through the standard team/relay mechanism eliminate
`:hello_sync_result` and the crash? NO.** `:hello_sync_result` exists because
`Agent.Receive` is flavor-blind and *must* re-dispatch to run flavor Elixir; a
`{:from, uri}` sender-rule relay is a different concern (fan-out to receivers)
and does not remove that seam. The crash lives in **cap issuance for the
self-dispatch**, independent of how downstream routing is expressed.

What *would* remove the seam entirely is the runtime's own documented
KNOWN-LIMITATION **"option 1" — per-flavor `:receive` selection** (let the
`"hello"` flavor own `{Entity.Agent, :receive}` and run `Router.route` inline in
one dispatch, no re-dispatch, no self-cap). That is a registry/dispatch redesign
(`BehaviorRegistry.lookup/2` resolves `{Kind, action}` to a single global
behavior today), not a hello change — a larger, separate effort.

---

## 6. Recommended fix (for the coordinator + product owner to direct)

Two options, not mutually exclusive:

**Option 1 — minimal py-parity (unblocks the 官网 now).**
Globally register hello's sync-result action, mirroring py: add
`{Ezagent.Entity.Agent, :hello_sync_result, Ezagent.ActionSet.HelloOrchestrator}`
to `EzagentPluginHello.Application.behaviors/0`. `registered_subject/2` then finds
it; the signed self-cap issues; the per-instance dispatch (already proven to
resolve) runs `handle_hello_sync_result` → `Router.route`. Low blast radius; it
makes hello consistent with the established py pattern. Verify it does not
disturb RF-1 per-instance denial (py already relies on the same global+per-
instance combination, and the `instance_set_gate` still denies non-hello agents).

**Option 2 — principled framework fix (removes the asymmetry, protects future
flavors).** Make `Ezagent.Cap.action_context/3`'s **self-target** branch resolve
the action the same way the cross-process branch does — through the live
instance's `BehaviorSet.resolve_action/3` / effective_set (available from the
current authority compartment / runtime view) — instead of the global-only
`registered_subject/2`. This eliminates the class of bug: any flavor-only,
per-instance `:sync_result` action self-dispatches correctly without needing a
global registration (py's global registration would no longer be load-bearing).

**Option 1 is EMPIRICALLY VERIFIED** (in this throwaway worktree; reverted): with
`{Entity.Agent, :hello_sync_result, HelloOrchestrator}` added to `behaviors/0`,
the repro's `[1]` flips to `{:ok, HelloOrchestrator}` and the `[4]` log goes
**clean** — no badmatch, no `unknown_action`, no failed dispatch. The relay
completes end-to-end: the only remaining log is
`hello.Generator: concierge answer failed: {:no_api_key, "deepseek"}`, i.e. the
reply successfully routed to the concierge's `:answer` and only stopped at the
downstream LLM call because the test runs keyless (it would succeed with a real
`DEEPSEEK_API_KEY`). So there is **no second crash** lurking at `issue_reply_cap`
(receive.ex:303), the `Cap.Verifier.authorize` step, or `Router.route`.

**Recommendation:** ship **Option 1** to restore the 官网 immediately (it is the
documented py pattern, the smallest safe change, and now verified to complete the
relay), and track **Option 2** as the correct framework hardening so the next
in-process flavor doesn't rediscover this. (Option 2's feasibility hinges on
obtaining the target's slice_state without a self-`GenServer.call` — which is the
very reason the self-target branch uses the global registry today; treat it as
hardening to design, not a trivial swap.) Flag the runtime's KNOWN-LIMITATION
"option 1" (per-flavor `:receive`) as the eventual architectural simplification
that retires the sync-result seam altogether — a separate, larger decision.

---

## Appendix — key file:line references

* Crash line: `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:300`
  (`{:ok, signed_cap} = Ezagent.Cap.issue_for_action(...)`).
* Self-target resolver: `apps/ezagent_core/lib/ezagent/cap.ex:98-108`
  (`action_context/3 when pid == self()` → `registered_subject/2`, global only);
  cross-process at `cap.ex:110-117` (per-instance `resolve_action`).
* Per-instance resolution (works): `apps/ezagent_core/lib/ezagent/kind/behavior_set.ex:262`
  (`resolve_action`), `:187` (`effective_set`).
* Flavor mount (hello): `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:71`
  (`agent_flavors` → `instance_behaviors: base ++ [HelloOrchestrator]`);
  `hello_definition_attrs/1` roles `front-desk … flavor: "hello"`.
* py global registration (works): `apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:93`;
  cited canonically in `apps/ezagent_core/lib/ezagent/behavior_registry.ex:12`.
* Regression source: PR #1457 `feat(cap): enforce per-Kind signing authority`
  (`596bd3a1d`).
* Repro: `apps/ezagent_plugin_hello/test/integration/hello_greeter_relay_repro_test.exs`.
