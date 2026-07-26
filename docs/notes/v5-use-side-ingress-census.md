# V5 use-side ingress census (initial) — Kind.Server mailbox enumeration

**Phase:** V5 pid-closure, use-side — ENUMERATION (report-only).
**Deliverable:** empirical list of every message shape observed reaching the
`Ezagent.Kind.Server` GenServer callbacks, feeding the later mailbox-sealing
phase. **No enforcement, no behavior change** — the instrumentation
(`Ezagent.Kind.IngressCensus.observe/2` at the top of every ingress callback
clause in `apps/ezagent_actor/lib/ezagent/kind/server.ex`) is observe-and-log
ONLY via `:telemetry.execute([:ezagent, :kind, :ingress_census], %{count: 1},
%{callback:, class:, shape:})`.

## How this census was produced

Two `EZAGENT_INGRESS_CENSUS=1` runs (env-gated hooks in
`apps/ezagent_actor/test/test_helper.exs` and
`apps/ezagent_core/test/test_helper.exs`; default suite runs are
byte-identical — no collector, no handler, no dump):

- `EZAGENT_INGRESS_CENSUS=1 mix test apps/ezagent_actor/test`
  → `_build/census/ezagent_actor_ingress_census.txt` — **204 tests, 0
  failures, dump = `[]`**. The actor app's own suite never spawns a full
  `Kind.Server` (its ports are wired at core boot), so it observes nothing.
- `EZAGENT_INGRESS_CENSUS=1 mix test` over a bounded actor-touching core
  subset (`test/ezagent/kind`, `test/ezagent/behavior`,
  `kind_terminate_honest`, `invocation_lazy_spawn`, `invocation_death_race`,
  `router_test`, `slice_change_test`, `lifecycle_hosts`, `lifecycle`,
  `lifecycle_destroy_honest`, `integration/routing_cap`,
  `integration/snapshot_restart`)
  → `_build/census/ezagent_core_ingress_census.txt` — **259 tests, 0
  failures**, 35 distinct `{callback, class, shape}` tuples.

> **This is an INITIAL census from the actor suites — coverage evidence, not
> a completeness proof.** A full-umbrella soak (all domain/plugin suites under
> the env var) is a follow-up. Notably unobserved so far: `:snapshot_tick`,
> `:ready_gate` self-signals, `:monitor_down`, `:exit`, `:task_reply`, and
> several `handle_call` verbs (`:ezagent_runtime_view`,
> `:ezagent_recredential_generation`, `:ezagent_verify_cap_artifact`,
> `:ezagent_validate_cap_artifact`, `:ezagent_revoke_all_to`) — their clauses
> are instrumented; the bounded subset simply never routed them.

## `:sys` — PERMANENT static-ban-only tier (out of census scope)

`:sys.get_state/2`, `:sys.replace_state/2`, `:sys.get_status/1` and friends
are served inside the `:gen_server`/`proc_lib` shim and **never reach these
callbacks** — they cannot appear in any census by design. `:sys` is a
PERMANENT static-ban-only tier, enforced statically by
`Ezagent.ActorBoundaryScanner` (`@sys_banned`), not by runtime census.

## Observed census (35 distinct tuples, 4 distinct classes)

Classes observed: `:lifecycle`, `:kind_message_verb`, `:run_deferred`,
`:would_drop`. (Defined-but-unobserved classes: `:snapshot_tick`,
`:ready_gate`, `:monitor_down`, `:exit`, `:task_reply`.)

| callback | class | sanctioned? | example shape | source |
|---|---|---|---|---|
| `init` | `:lifecycle` | yes | `{Ezagent.Entity.Agent, 2}` (kind module + args-size) | core subset |
| `init` | `:lifecycle` | yes | `{Ezagent.Entity.User, 2}`, `{Ezagent.Entity.System, 2}` | core subset |
| `init` | `:lifecycle` | yes | 10 test-fixture kinds (`Ezagent.Test.TestKind`, `Ezagent.TestSupport.PostInitKind`, `LifecycleFixtureKind`, `HonestTerminateKind`, …) | core subset |
| `handle_continue` | `:lifecycle` | yes | `:announce_ready` | core subset |
| `handle_continue` | `:lifecycle` | yes | `{:ezagent_post_init, 2}` | core subset |
| `handle_call` | `:kind_message_verb` | yes | `:ezagent_kind_module` (bare atom) | core subset |
| `handle_call` | `:kind_message_verb` | yes | `:ezagent_launch_context_relay` (bare atom) | core subset |
| `handle_call` | `:kind_message_verb` | yes | `{:ezagent_dispatch, 2}` | core subset |
| `handle_call` | `:kind_message_verb` | yes | `{:ezagent_get_slice, 2}` | core subset |
| `handle_call` | `:kind_message_verb` | yes | `{:ezagent_mount, 3}` / `{:ezagent_detach, 2}` | core subset |
| `handle_call` | `:kind_message_verb` | yes | `{:ezagent_lifecycle_destroy, 2}` | core subset |
| `handle_call` | `:kind_message_verb` | yes | `{:ezagent_resolve_action_subject, 2}` | core subset |
| `handle_cast` | `:kind_message_verb` | yes | `{:ezagent_dispatch, 2}` | core subset |
| `handle_info` | `:kind_message_verb` | yes | `{:ezagent_recover_settlements, 1}` (Turn settlement-recovery self-signal, `behavior/turn.ex:93`) | core subset |
| `handle_info` | `:run_deferred` | yes | `{:ezagent_run_deferred, 2}` (DeferredDispatch self-message, `kind/deferred_dispatch.ex:56`) | core subset |
| `handle_info` | `:would_drop` | **no** | `{:pty_phase, 4}` — REAL producer: PTY phase broadcast `{:pty_phase, agent_uri, phase, meta}` via PubSub (`apps/ezagent_domain_pty/lib/ezagent_domain_pty/phase_broadcast.ex:48-52`), fanned into subscribed Kind mailboxes (Sandbox behavior) | core subset |
| `handle_info` | `:would_drop` | **no** | `{:lifecycle_signal_notify, 2}` / `{:lifecycle_signal_dispatch, 2}` — TEST-FIXTURE raw `send(pid, …)` (`test/ezagent/lifecycle_test.exs:345,402` → `test/support/lifecycle_fixture.ex` `handle_signal`) | core subset |
| `handle_info` | `:would_drop` | **no** | `{:some_signal, 2}` — TEST-FIXTURE raw `send(pid, …)` (`test/ezagent/kind/instance_set_denial_test.exs:415`) | core subset |
| `terminate` | `:lifecycle` | yes | `:normal`, `:shutdown`, `{:other_tuple, 2}` (non-atom-head reason) | core subset |

Actor-suite dump (`ezagent_actor_ingress_census.txt`): empty (`[]`) — see
above; no `Kind.Server` is booted in that suite.

## Reading the `:would_drop` rows

The future seal must NOT drop these on the strength of this table:

- `{:pty_phase, 4}` is a **legitimate cross-domain signal** (PTY → Sandbox
  behavior via PubSub topic). It is unrecognized only because the classifier's
  sanctioned set currently covers framework verbs + OTP shapes, not
  domain-level PubSub fan-out. The full-umbrella soak will surface the rest of
  this family (`{:slice_changed, _}`, `{:publisher_alive, _}`,
  `{:publisher_event, _}`, `{:ezagent_ce_reconcile, …}`, …) — the starter
  inventory below predicts them; the bounded subset did not exercise those
  producers.
- The other three are test-support signals that exercise the catch-all →
  `handle_signal` forwarding path deliberately.

## Static producer inventory (grep-verified)

Raw message producers that can land in a `Kind.Server` mailbox
(`handle_info` catch-all → `handle_kind_message`/`handle_signal`), confirming
and correcting the starter list:

- **Activation/ready self-signals** — CONFIRMED, paths corrected (they live in
  domain apps, not core): `send(self(), :ezagent_ce_reconcile)` at
  `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex:197`
  (signal atom defined at :89); `send(self(), {:ezagent_recover_settlements})`
  at `apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex:93` — the
  latter OBSERVED in this census as `{:ezagent_recover_settlements, 1}`.
- **Detached-task results** — CONFIRMED, path corrected: the producer is
  `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex`
  (not the entity file): `Task.Supervisor.start_child` under
  `Ezagent.ExternalMirror.SubscribeTaskSup` at :470-491 reports back via
  `send(worker_pid, {:ezagent_worker_subscribe_result, result})` (:488); the
  initial subscribe is self-kicked by `send(self(),
  :ezagent_worker_initial_subscribe)` (:279) and retries via
  `Process.send_after(self(), {:ezagent_worker_resubscribe_retry, attempt+1}, …)`
  (:442-444). These are plain sends, NOT `{ref, result}` `Task.async` replies.
- **Publisher replay/fan-out** — CONFIRMED at
  `apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex:469`
  and `:619`: `send(subscriber_pid, {:publisher_event, ev})` (starter said
  :467 — actual :469/:619).
- **SliceChange** — CONFIRMED:
  `apps/ezagent_actor/lib/ezagent/slice_change.ex:166-169` broadcasts
  `{:slice_changed, broadcast_event}` via `Phoenix.PubSub` (starter said :164
  — actual :166-169); subscribers receive it as a mailbox message.
- **Publisher lifecycle** — CONFIRMED:
  `apps/ezagent_core/lib/ezagent/publisher_lifecycle.ex:144-148`
  `broadcast_alive/1` → PubSub `{:publisher_alive, publisher_uri}`.
- **PTY phase broadcast** — CONFIRMED and OBSERVED (`{:pty_phase, 4}` above):
  `apps/ezagent_domain_pty/lib/ezagent_domain_pty/phase_broadcast.ex:48-52` →
  PubSub `{:pty_phase, agent_uri, phase, meta}`.
- **EM reconcile self-signal** — `send(self(), {:ezagent_em_reconcile,
  bindings})` at `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:249`.
- **Monitor `:DOWN`** — `Process.monitor/1` of member/subscriber pids:
  `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:565`
  (member liveness; handled at :1169), publisher subscriber monitor (see
  `session_impl.ex:361` comment). `{:DOWN, ref, :process, pid, reason}` →
  class `:monitor_down` (not yet observed in census).
- **Timers** — `Process.send_after/3`: `:snapshot_tick` re-arm
  (`kind/server.ex` `schedule_periodic_snapshot` + tick clause),
  `{:ezagent_worker_resubscribe_retry, _}` (above).
- **`Task.async` replies** — NOT FOUND: no `Task.async/1` in any
  `apps/*/lib` (only `Task.start`/`Task.Supervisor.start_child`, which report
  by explicit `send`). `{ref, result}` + companion `:DOWN` (`:task_reply`
  class) is therefore expected to be rare/absent; a crashed linked
  `Task.start` instead arrives as `{:EXIT, pid, reason}` (Kinds
  `Process.flag(:trap_exit, true)`).
- **Linked-resource `:EXIT`** — `trap_exit` is set in `init/1`
  (`kind/server.ex`), so any linked process death (DB connection in sandbox
  tests, linked tasks) arrives as `{:EXIT, pid, reason}` → class `:exit`
  (not yet observed in census).

### TCP/SSL/gen_event/Broadway/Oban

- **Broadway / Oban: NONE.** No `:broadway` or `:oban` in any
  `apps/*/mix.exs` or in `mix.lock`. Confirmed.
- **`:gen_tcp` / `:gen_event`: NONE** in `apps/*/lib`. No Behavior (or any
  lib code) owns a raw TCP socket or a `:gen_event` manager.
- **`:ssl`: client-options only.** Three sites, all as HTTP(S) *client*
  options (`Req`/`:httpc` verify config), none owning a socket:
  `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/credential_refresh.ex:153`,
  `apps/ezagent_plugin_email/lib/ezagent/email/inbox/cf_worker.ex:85`,
  `apps/ezagent_web/lib/ezagent/mail/ezagent_chat_adapter.ex:36,41`.
- **Ports/PTY:** `apps/ezagent_domain_pty` owns OS processes via erlexec
  ports (`lib/ezagent_domain_pty/server.ex`, `lib/ezagent/domain/pty.ex`) —
  port messages go to the PTY domain server, NOT to `Kind.Server`; its only
  Kind-ward traffic is the PubSub `{:pty_phase, …}` broadcast above.

## Follow-ups

1. Full-umbrella soak (`EZAGENT_INGRESS_CENSUS=1 mix test` at the root) to
   complete coverage — expected to add `:monitor_down`, `:exit`,
   `:snapshot_tick`, `:ready_gate`, and the PubSub fan-out family.
2. Extend the sanctioned classifier for the domain-signal family
   (`:pty_phase`, `:slice_changed`, `:publisher_alive`, `:publisher_event`,
   `:ezagent_ce_reconcile`, …) once the soak shows their real shapes — only
   then is the `:would_drop` list a seal candidate list.
