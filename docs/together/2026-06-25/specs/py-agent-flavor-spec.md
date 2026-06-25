# py-agent — general script-driven Python agent flavor

> **Status**: rev3 — 2026-06-25. Author: Claude (self-driven per Allen Feishu
> 2026-06-25). rev1 → review(stale tree) → rev2 → review(round 2, current main
> c4de8a62) → rev3. rev3 resolves round-2's load-bearing findings: **py's value
> REQUIRES building a per-agent script file-channel — it cannot be sidestepped
> with priv-dir delivery** (that would ship "np with a different script", zero
> new capability). All line numbers re-derived from c4de8a62. Plan-ready
> pending a light round-3 sanity check.

## 0. Scope and foundation

### 0.1 py-agent **is**

A **general agent flavor** (`"py"`) whose per-message logic is an **operator-
supplied python script**, executed in a per-agent `Ezagent.Domain.Python`
subprocess. The script is supplied **at create time** by the operator and
installed into the agent's per-agent `config_dir`; `Behavior.PyAgent` runs it.

**End-state (Allen 2026-06-25): `py` is THE python flavor; `np` and `echo`
become py-ROLES.** A py-role = the `py` flavor + a specific script + caps.
`np` = py-role with `np_compute_server.py`; `echo` = py-role with `echo.py`.
Role-over-flavor fully applied: one flavor, one runtime, agents distinguished
by their (operator-authored) script. A role's safety travels with its
**script** — np stays exactly as safe (its hardened whitelist script is
unchanged), merely delivered as a py-role.

### 0.2 The script file-channel is P1's CORE deliverable (round-2 HIGH-A/B)

The value above REQUIRES a mechanism to get an **operator-supplied** script to
the agent. Current main does NOT have it:
- `Role.Compose.materialize/2` → `sandbox_content: %{skills, plugins, prompt}`
  ONLY — no script/arbitrary-file field (`role/compose.ex:34-43,73-77`).
- `RoleStep` threads behaviors + `passive` + `role` + caps, no file content
  (`agent_create/role_step.ex:127-131`). **RF-5b (file-flavor role + content→
  config_dir install) is deferred** (`role_step.ex:36,62,84`).
- np's script ships from the **compiled plugin priv dir**
  (`template/np_agent.ex:284-286` `:code.priv_dir(:ezagent_plugin_np)`) —
  build-time, NOT operator-supplied.

⇒ A "priv-dir like np" P1 would deliver only "np with `echo.py`" — no new
capability, and it contradicts §0.1's operator-authored promise. **So P1 owns
the script file-channel.** Two layers, landed in order:

- **P1 — create-time channel (the minimum that makes py *py*)**: the create
  path accepts an operator-supplied script (a `script` field in the `py.agent`
  template config / create params), writes it into the agent's per-agent
  `config_dir`, and `Template.PyAgent.instantiate/3` points Domain.Python at
  that path. This is the RF-5b *shape* scoped to one flavor's create route —
  not the full role-cascade RF-5b, just "operator script → this agent's
  config_dir at create." Cap-gated by create (§5).
- **P2/P4 — role-carried script (the end-state channel)**: extend
  `sandbox_content` with a `script`/file field so a ROLE carries its script
  (this IS the general RF-5b content→config_dir install). Needed when echo/np
  become *roles* (not just operator-created agents). Until then a "py-role" =
  role name + caps + a create-time script; the role-distinguished-only-by-
  script end-state (§0.1) is **gated on this P2/P4 channel** (round-2 HIGH-B —
  OQ-1 is RF-5b-gated, not free).

### 0.3 py-agent **is NOT**

- Not a new runtime (consumes Domain.Python). Not a hot-reload runtime (script
  change ⇒ re-spawn / new agent). Not an end-user code surface (operator-
  authored only, §5).
- Migration order: echo retires first (P2, trivial, de-risks the pattern), np
  re-homes as a py-role later (P4 fast-follow; keeps working until then;
  whitelist script moves verbatim). Both end as py-roles.

## 1. The script contract (the wire) — matches current Domain.Python exactly

The user script uses the shipped `ezagent_python` lib: register handlers with
`@method`, call `run()` (verified `priv/python/ezagent_python.py:64,219`).
py-agent dispatches one method, `"receive"`; `configure`/`reset` stay BEAM-side
(np's are pure `{:set,_}` effects that never call python — `np_agent.ex:177-191`
— so no python-side configure/reset needed):

```python
# echo.py
from ezagent_python import method, run

@method("receive")
def receive(params):                 # {"text", "from", "session"}
    return {"text": params["text"]}  # reply payload, or None to stay silent

run()
```

`Behavior.PyAgent`'s `:receive` calls `Domain.Python.call(handle, "receive",
params, timeout_ms)` — the real arity-4 method-named API (`python.ex:211-212`)
— and on a non-nil reply dispatches `chat.send` to the originating session
(np's `{:dispatch,%Cmd{}}` shape). Script raises ⇒ captured to `last_error`
(durable) + logged; the BEAM Kind does not crash.

## 2. Architecture

### 2.1 Extract shared Domain.Python agent lifecycle (round-2 MED-1 — DRY)

np's subprocess lifecycle is currently **private** to NpAgent: `activate/2`
self-heal (`np_agent.ex:390-414`), `subscribe_to_phase_topic/1` +
`handle_signal/2` (`np_agent.ex:425-518`), `start_python/2` +
`ensure_subprocess_alive/2` (`template/np_agent.ex:180-260`). py "reusing" it
= copying ~150 lines unless extracted. **P1 extracts** a shared
`Ezagent.Domain.Python.AgentLifecycle` (a `use`-able module or helper) owning:
spawn-from-config, ensure-alive, phase-subscribe, phase-signal→badge. np and py
both consume it. (np refactor onto it is part of P1's extraction or the P4
np-migration — decide in the plan; smaller blast radius is P4.)

### 2.2 Behavior.PyAgent — sibling of np, own method + cap axis

- **Reused (via §2.1 shared module)**: subprocess spawn/ensure-alive +
  the phase-subscription transient + `handle_signal`→badge (KEPT — the topic
  tracks the *python subprocess*, which py has; np has no PTY either).
- **State (persistent)**: `python_handle`, `script_path` (under config_dir),
  `timeout_ms`, `cwd`, `last_input/result/error`, `python_phase`.
- **Own contract**: the single `"receive"` method (vs np's `pick_method`
  LaTeX heuristic); its own `:py_agent` cap axis (`required_caps/0`).
- **Kind (Q3)**: own-Kind `Entity.PyAgent` + `Template.PyAgent`, mirroring np
  (per-agent subprocess + supervisor is a Kind concern). The `native`+behavior-
  via-role route is the RF-aligned future, viable once the P2/P4 role-script
  channel lands; not P1.

### 2.3 Create route — MUST be specified, do NOT "mirror np" (round-2 HIGH-C)

The generic direct-spawn route (`agent_create.ex` `do_create_agent/_` :467 →
`Kind.spawn` :513) **never calls `Template.instantiate/3`** (where
`start_python` runs) and `direct_spawn_config_args(_,_)→%{}` (:605) **drops
cwd** for non-curl flavors. So np-via-UI/CLI comes up with no subprocess (only
the e2e calling `NpTemplate.instantiate/3` directly works,
`comprehensive_4agent_e2e_test.exs:268`). py must NOT inherit this.

**P1 gives py its own `do_create_agent("py", ...)` clause** (the echo/cc
template-route pattern, `agent_create.ex:364` `register_and_invoke_template`)
that: writes the operator script into the agent's `config_dir` (§0.2 P1
channel), calls `Template.PyAgent.instantiate/3` (starts the subprocess
pointing at `script_path`), threads `cwd`=config_dir. The plan must name this
route explicitly and add a create-path test that asserts the subprocess is
live after create (closing the np gap, not copying it).

### 2.4 Flavor decl (mirror np `application.ex`)

`agent_flavors/0`→`"py"`→`{Entity.PyAgent, Template.PyAgent}`; `behaviors/0`→
`{Entity.PyAgent, :receive|:reset|:configure}`→`Behavior.PyAgent`;
`template_classes/0`→`py.agent` (config: `script` source + `timeout_ms`);
`config_surface/0`→`:flavor`; `children/0`→per-Kind `DynamicSupervisor`.

## 3. echo retirement — honest surface + reachable gate (round-2 MED-2/3, LOW-1)

Real surface on c4de8a62 (`git grep -il 'echo\.agent\|Behavior.Echo\|
Entity.Echo\|EchoAgent\|ezagent_plugin_echo' apps/` — NARROWED pattern, drops
bare `"echo"` which matches the unrelated `domain_python/test/support/
echo_server.py` fixture + prose). Load-bearing, NON-mechanical spots (lines
re-derived from c4de8a62):

- **Hardcoded core/domain**: `agent_create.ex:138` flavor whitelist
  `~w(cc echo curl np codex)`; `:173-175` `validate_cwd_for_flavor("echo")`;
  `:364` `do_create_agent("echo")` (template route, non-credentialled —
  `:381` "echo is NOT a file-flavor"); `agent_module_resolver.ex:119`
  `kind_module_from_kind_type("echo")`.
- **World**: `world/identity_data.ex:13` `@fallback_flavors ~w(cc echo curl)`,
  `:130`, `:301` + `Identities.tsx`/`PtyTerminal.tsx`.
- **Gate scope path**: `ezagent.check_invariants.ex:~262` greps
  `apps/ezagent_plugin_echo/lib` for `:stub_grant` under `2>/dev/null` — on
  deletion this **silently stops scanning that dir** (stderr swallowed, gate
  still passes); NOT a red gate (round-2 LOW-1 corrects rev2). Update for
  hygiene + to avoid a silent stale scope.
- **Core teaching examples**: `behavior.ex:22`, `capability.ex:9-10`,
  `plugin.ex:22-27` use `Ezagent.Behavior.Echo`/`EzagentPluginEcho` as THE
  worked example — re-home to py or leave dangling refs in core docs.
- **Core invariant tests** assert against echo as the reference plugin
  (`cap_check_only_at_chokepoint_test`, `plugin_hot_install_test`,
  `receiver_kind_pattern_test`, `capability_test`).

**Parity gate (enumerated FROM echo):** `git grep -il 'echo\.agent\|
Behavior.Echo\|Entity.Echo\|EchoAgent\|ezagent_plugin_echo' apps/` == 0
(the narrowed pattern is reachable — the bare-`"echo"` fixture/prose hits are
excluded by construction), AND `mix ezagent.check_invariants` green (scope path
updated), AND the 3 core teaching examples re-homed to py, AND
`ezagent_plugin_echo` deleted. Re-baseline the file count from this narrowed
pattern in the plan.

## 4. Plan shape

- **P1** — the file-channel + the flavor: (a) create-time operator-script →
  config_dir channel (§0.2 P1) + py's own `do_create_agent("py")` route (§2.3);
  (b) extract `Domain.Python.AgentLifecycle` (§2.1); (c) `Behavior.PyAgent`,
  `Entity.PyAgent`, `Template.PyAgent`, flavor `"py"`, `:py_agent` cap axis;
  script **immutable post-create** (configure touches timeout/cwd only). TDD:
  create a py-agent with an operator script → subprocess LIVE after create
  (closes the np gap) → `:receive` replies; cold-restart re-spawns + re-loads;
  configure cannot mutate the script.
- **P2** — echo→py: echo as an operator-script py-agent (or, if the role-script
  channel lands, a py-role); migrate the full §3 surface; re-home teaching
  examples; update check_invariants scope; delete `ezagent_plugin_echo`; parity
  gate == 0.
- **P3** — world E2E: a py-agent with a custom script replies in a world
  session; the world seed's former echo agent is now a py-agent.
- **P4 (fast-follow)** — role-carried script channel (extend `sandbox_content`,
  the general RF-5b content install) THEN np re-homes as a py-role (whitelist
  script verbatim); delete `ezagent_plugin_np` with its own parity gate. np
  keeps working until then.

## 5. Security — posture A (Allen-decided)

Operator-only general python; OS-sandbox deferred. Enforcement verified on
current main:
- **Authorship = create-cap.** `RoleStep.mint_and_grant_caps` runs under caller
  authority (`{:held_by, caller}`, `role_step.ex:26-29,200`); CapMint is
  fail-closed (`cap_mint.ex:55-58,107-113`). A non-operator cannot mint the
  role's caps ⇒ cannot create a py-agent.
- **Script set only at create, immutable via configure** (round-2 MED-2
  confirmed sound): under the P1 config_dir channel the script is written once
  at create; `configure`/`reset` are BEAM-side `{:set,_}` effects that never
  touch the script. **NEW vectors P2/P4 must analyze**: once the script is
  per-agent data (config_dir) or role-carried (sandbox_content), **clone/fork,
  template-edit, and `Kind.mount` become script-injection paths** — each must
  re-assert the create-time authorship cap before accepting a script. The plan
  MUST gate these (round-2 raised this; rev2 missed it).
- **Rationale for no new OS sandbox**: operators already command `cc` agents
  running arbitrary code with node access — an operator-authored python script
  is not a new privilege for an actor with node-level trust. OS sandboxing
  (seccomp/namespaces/low-priv user) is required ONLY to admit untrusted
  (non-operator) authors — not a current need; the single condition that
  reopens this.

## 6. Open questions — resolved

1. **np also a py-role?** Yes (Allen). Safety travels with the script. Gated on
   the P2/P4 role-script channel (round-2 HIGH-B) — sequenced P4, np works until
   then.
2. **Security posture?** A (operator-only; OS-sandbox deferred).
3. **own-Kind vs native+behavior?** own-Kind (`Entity.PyAgent`) for P1; native+
   behavior-via-role is the future once the role-script channel lands.
4. **echo-role name vs gate?** Gate keys on flavor/Kind/plugin refs (narrowed
   pattern §3), not the word; a retained role name is allowlisted.
5. **(round-2) P1 = priv-dir or file-channel?** File-channel (§0.2). Priv-dir
   would be "np with a different script" — not py. P1 builds the create-time
   config_dir script channel.
