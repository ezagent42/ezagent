# Phase 4 Completion — Spec 03: CC PTY Plugin (`ezagent_plugin_cc`)

**Status:** DRAFT for Allen review. NO CODE YET.
**Closes:** Decision #56 split (cc_pty vs cc_channel) — lands the `cc_pty` half.
**Depends on:** Spec 01 (Template Class) — `cc-pty.session` Template Class needs the `Ezagent.Kind.Template` behaviour landed first. **Will not implement until #01 merges.**
**Companion to:** Decisions #22 (Process trait removal — PTY lives as Behavior, not Kind), #26 (`erlexec`/`:ex_pty` 归位 Behavior 内部), #29 (PTY libs moved out of `ezagent_core` into plugins), #56 (cc_pty ≠ cc_channel; both coexist).
**Reading time:** ~12 minutes. Largest spec because cc_pty has the most decision points.
**Honest framing:** parts of this are genuinely hard. Read §11 ("what worries me") *first* if you want the un-pretty take.

---

## 1. Problem statement

Ezagent today has zero ability to spawn `claude` itself. The `v1_prototype` (`apps/ezagent_plugin_cc_bridge_v1_prototype/`) is an **external-attach** model:

1. Operator runs `bash scripts/cc-bridge-attach.sh` in a terminal.
2. Claude is launched by that script, wrapped in `script -q /dev/null` (PTY shim).
3. Claude reads `~/.ezagent/bridge.mcp.json` (written by `Ezagent.Bridge.V1Prototype.McpConfigWriter`), spawns the Python MCP bridge as a subprocess.
4. The Python bridge POSTs `/api/cc-bridge/announce` → `Ezagent.CcBridgeAnnounceController` spawns an `Ezagent.Entity.Agent` Kind at the URI in `EZAGENT_AGENT_URI`.
5. From then on: claude→bridge→HTTP→Ezagent→PubSub→LV; Ezagent→PubSub→SSE→bridge→stdout-JSON-RPC→claude.

This works for the demo. It does **not** make Ezagent "production usable":

- Ezagent doesn't *own* the claude lifecycle. Operator pulls the trigger; if claude crashes, the operator restarts.
- Workspace declares `members: [agent://cc-builder]` but the URI lights up only when an operator happens to be running the attach script. The "auto-recreate on boot" promise of Decision #64 is broken: an agent that requires a human-driven external script is not "loaded from persistence."
- No supervision tree, no observability, no per-instance config (cwd / model / args) — all of which are operator concerns the Workspace UI should answer.

**What cc_pty delivers:** declare a cc-pty agent in a Workspace → Ezagent's plugin supervisor spawns the `claude` binary as a managed child process via PTY → claude attaches back through the same MCP channel pattern v1_prototype proved → if claude crashes, the supervisor restarts it. The operator never types a bash command. The `agent://architect` URI is alive whenever Ezagent is.

This is also the **first non-chat plugin** that exercises Phase 4's plugin-isolation north star end-to-end. If `cc_pty` can be written without touching `ezagent_core` or `esr_plugin_chat`, the north star is proved. If it can't, we have homework before Phase 5.

**What this spec is NOT:** it's not the cc_channel plugin (Phase 5+). cc_channel is "bridge to externally-spawned claude" — the v1_prototype's lineage. cc_pty is "Ezagent spawns claude as a child." They coexist (Decision #56). v1_prototype is not deprecated by this PR; operators picking the external-attach UX keep it.

---

## 2. Plugin shape

**New umbrella app:** `apps/ezagent_plugin_cc/`

```
apps/ezagent_plugin_cc/
├── mix.exs                                    # deps: ezagent_core, esr_plugin_chat, :erlexec
├── lib/
│   ├── ezagent_plugin_cc/
│   │   ├── application.ex                     # Application.start — register stuff
│   │   ├── process_supervisor.ex              # DynamicSupervisor for per-instance Servers
│   │   └── default_workspace.ex               # OPTIONAL seed: a demo Workspace using cc-pty
│   ├── esr/
│   │   ├── behavior/
│   │   │   └── cc_pty.ex                      # Ezagent.Behavior.CcPty — owns PTY slice + spawn/write/resize
│   │   └── template/
│   │       └── cc_pty_session.ex              # Ezagent.Template.CcPtySession (Class for #01)
│   └── ezagent_plugin_cc.ex                   # convenience aliases
└── test/
    ├── esr/behavior/cc_pty_test.exs           # unit (mock claude binary = echo script)
    ├── esr/template/cc_pty_session_test.exs
    └── integration/cc_pty_lifecycle_test.exs  # spawn → write → read round-trip
```

**Dependency order in umbrella:** `cc_pty` depends on `esr_plugin_chat` (because it instantiates Agent Kinds via the same SpawnRegistry binding chat already owns — see §3 decision below). Chat must start first so `Ezagent.SpawnRegistry.register("agent", _)` has executed.

Application boot order becomes:
1. `ezagent_core` — registries, repo, supervisors
2. `ezagent_web` — endpoint
3. `esr_plugin_chat` — registers `agent`/`session`/`user` schemes, registers Template Class for `session.generic` (per spec #01), spawns admin User + default Session, runs `Workspace.Loader.load_all/0`
4. **`ezagent_plugin_cc`** — registers Template Class for `cc-pty.session`, registers a *second* spawn fn for `agent://` URIs whose query string carries `?managed_by=cc-pty` (see §3 below), boots its `ProcessSupervisor`. **Does NOT call `Loader.load_all/0`** — that's chat plugin's responsibility per spec #01 deferral discussion. Instead cc_pty walks already-loaded Workspaces and triggers any cc-pty Template Class instantiations.
5. `ezagent_web_liveview` — UI layer

**Worry signal:** step 4's "re-walk after loader" is the "second-pass Loader" gate from spec #01 Q4. If we settle on (a) "log + skip now," cc_pty's templates simply won't instantiate when first declared in a Workspace that loaded before cc_pty registered its Template Class. **See decision Q1.**

---

## 3. The biggest decision: reuse Agent Kind vs. new Kind

This is the architectural commit that ripples through everything else. Options:

### Option 1 — Reuse `Ezagent.Entity.Agent`

**Shape:** A cc-pty agent is just an `Ezagent.Entity.Agent` with a different SpawnRegistry binding. URI: `agent://architect`. The chat router can't tell the difference between an externally-attached claude and a cc-pty-spawned claude — both are Agents that emit `:reply_received` and consume `:receive`.

**Implementation:** cc_pty plugin does NOT register an `agent://` spawn fn (that would collide with chat's). Instead, cc_pty's Template Class `instantiate/3`:
1. Calls `Ezagent.SpawnRegistry.spawn(agent_uri)` — chat's spawn fn lights up an Agent Kind (empty Identity slice).
2. Then immediately starts a sidecar `EzagentPluginCc.ProcessServer` (a GenServer in cc_pty's DynamicSupervisor) bound to that agent's URI. The ProcessServer holds the erlexec port, captures stdout, writes stdin.
3. ProcessServer **monitors** the Agent pid (`Process.monitor`). If Agent dies, ProcessServer kills its claude and exits. If claude dies, ProcessServer broadcasts `:claude_crashed` and the cc-pty supervisor restarts it (one-for-one within ProcessServer's restart policy); the Agent Kind survives.

**Plus:**
- Zero new Kind, zero new behaviors in chat. Chat router unchanged.
- UI consistency: `agent://architect` everywhere; LV admin sees the same shape.
- v1_prototype + cc_pty produce indistinguishable Agents on the router side — proves the abstraction.
- **Plugin isolation preserved:** cc_pty depends on chat (already true), chat does not depend on cc_pty.

**Minus:**
- Two-process pair (Agent Kind + ProcessServer) for each cc-pty agent. Lifecycle coupling is via `Process.monitor`, not supervision — that's a subtle pattern (good with OTP, but easy to get the restart semantics wrong on first read).
- PTY-specific state (cwd, model, exit_code, restart_count) lives in ProcessServer, not in the Agent Kind's slice. The LV "process status" view has to *also* query ProcessServer, not just `Ezagent.KindRegistry.lookup(agent_uri)`.

### Option 2 — New `Ezagent.Entity.CcPty` Kind

**Shape:** dedicated Kind with its own URI scheme `cc-pty://architect`. Implements `Ezagent.Behavior.CcPty` (PTY slice) and re-implements `Ezagent.Behavior.Chat` for `:receive` / `:reply_received` so it can speak chat. Workspace `members` list contains `cc-pty://architect` directly.

**Plus:**
- One process owns PTY + chat traffic. Cleaner lifecycle, no monitor dance.
- LV can render cc-pty agents distinctly (process status icon next to the agent in the member list).
- Schema-level clarity: a `cc-pty://` URI is unambiguously "this is a managed claude process."

**Minus:**
- Chat router (`Ezagent.Behavior.Chat`, `MentionRouting`, etc.) all currently match on `agent://`. Either (a) chat router becomes scheme-agnostic, or (b) cc_pty has to register its Kind to receive Chat actions via `BehaviorRegistry.register(Ezagent.Entity.CcPty, :receive, Ezagent.Behavior.Chat)` — which works, but means chat's matcher patterns (mention `@cc-builder` → `agent://cc-builder`) also need an option to resolve `@architect` → `cc-pty://architect`. **This is a chat-plugin change driven by cc_pty** — a north-star violation.
- v1_prototype-attached claude (`agent://cc-builder`) and cc_pty-spawned claude (`cc-pty://architect`) are different URIs. Reply traffic flows through different paths. Cognitive overhead for operators.
- More code (new Kind module, registration plumbing in chat to accept the new scheme).

### Recommendation

**Option 1 (reuse Agent Kind).** Rationale:

1. **Plugin isolation north star.** Option 2 forces chat-plugin changes to accept a new scheme. Option 1 forces zero changes outside cc_pty.
2. **v1_prototype parity.** Reply traffic flows through the same path the v1 demo proves works. We're not betting Phase 4 completion on a fresh wire format.
3. **The two-process pair is OTP-idiomatic.** Erlang has 40 years of Port + monitor patterns; we're not inventing.
4. The LV "process status" annoyance is real but cosmetic — solved by a `ProcessSupervisor.status_for(agent_uri)` lookup, which is one ETS read.

**Decision needed: Q2 below.** If Allen prefers Option 2 for the URI clarity, the spec body expands by ~150 LOC (new Kind + chat registration). Confirm before implementation.

---

## 4. PTY library choice

The candidates:

| Library    | Status                                  | Pros                                                                                                     | Cons                                                                                                   |
| ---------- | --------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `:erlexec` | Old, battle-tested, hex.pm `~> 2.0`     | PTY supported via `:pty` option; monitor/link semantics; old esr uses it (`runtime/lib/esr/entity/pty_process.ex`) at production-ish scale; macOS + Linux verified | C-NIF port driver; spawn semantics are esoteric (`:exec.run/2` with `:pty, :monitor`); requires `:erlexec` Application start |
| `:ex_pty`  | Newer, native PTY, hex.pm `~> 0.5`      | Pure Elixir API, cleaner monad-like response shape                                                       | Smaller community; less production mileage in this team; one less data point for "we've done this before" |

### Recommendation

**`:erlexec`.** Rationale:

1. **Old esr's `runtime/lib/esr/entity/pty_process.ex` is 400+ LOC of `:erlexec`-based PTY code we already wrote and shipped to production-ish dev DB.** We know its failure modes, its `TERM=xterm-256color` quirks, its `Device Attributes query blocks at boot` gotcha (line 282-289). Picking `:ex_pty` means re-learning those at production-impact time.
2. **`os_pid` monitoring is rock-solid.** `:exec.run/2` with `{:monitor, true}` delivers `{'EXIT', port, _}` cleanly to the owner GenServer — exactly the contract `ProcessServer` wants.
3. **Phase 4 invariant tests need a fake `claude` binary** (an `echo` script — see §10). `:erlexec` runs any executable on PATH; no difference vs `:ex_pty` there.

**What we lose vs `:ex_pty`:** marginally cleaner Elixir-native API. **Worth less than the production wisdom we inherit.**

**Decision needed: Q3 below** to confirm.

**`mix.exs` dep:** `{:erlexec, "~> 2.0"}`. Must be added to `extra_applications` in `cc_pty`'s `application/0` so the `:erlexec` Application starts before `ProcessSupervisor`.

---

## 5. The other critical decision: how does cc_pty talk to claude?

Two paths, both technically feasible:

### Path A — MCP-over-stdio (RECOMMENDED)

Ezagent spawns `claude --dangerously-load-development-channels server:esr-cc-pty --mcp-config <path>` via PTY. The mcp.json points claude at an **Ezagent-internal MCP server** that speaks JSON-RPC on stdio. This server isn't a separate Python process — it's an Elixir GenServer wired into a stdio-handler port (because the MCP config writer hands claude `command: "elixir"` or `command: "<built escript>"` that talks JSON-RPC). When claude calls the `reply` tool, the Elixir side translates that into the same `forward_reply_to_agent` path v1_prototype uses.

**Concretely:** cc_pty writes a per-instance mcp.json (one per cc-pty agent, NOT a single shared file like v1) pointing at an escript or `mix run` invocation that runs `EzagentPluginCc.McpStdioServer.main/0`. That server reads stdio JSON-RPC, dispatches `tools/call reply` → `Ezagent.Bridge.V1Prototype.Server.forward_reply_to_agent/4` (yes, reusing the existing module — see §6 coexistence).

**Plus:**
- Reply traffic flows through the **same wire format** v1_prototype proves out. We don't ship a second comms path.
- claude's TUI output (banner, "thinking" spinner, raw text) is *separate* from reply traffic. We can choose to ignore or render it; it doesn't pollute the chat router.
- Adding the channel server to Ezagent's own code (vs spawning Python) closes a deploy-complexity hole (no `uv run python3` requirement in production).

**Minus:**
- Building a stdio MCP server in Elixir. The shape is well-defined (JSON-RPC 2.0 with `initialize`, `tools/list`, `tools/call`, `notifications/claude/channel`) and v1's Python is 322 lines — Elixir version probably ~250. Not trivial, but bounded.
- Each cc-pty agent spawns TWO OS processes: the claude binary (in our PTY) *and* the MCP stdio server (in claude's MCP-subprocess slot). That's an extra fork-exec per agent. Bearable.

### Path B — raw TUI parse, no MCP

Skip MCP. Spawn `claude` with no channel flags, capture its TUI output stream, parse ANSI escape codes to extract user-facing text, send keystrokes via PTY to feed prompts.

**Plus:**
- One fewer process per agent.
- No MCP-protocol code at all.

**Minus:**
- **Parsing claude's TUI is genuinely hard.** Spinner overwrites itself with `\r`; markdown rendering uses ANSI color sequences; tool-call boxes are drawn with Unicode box-drawing chars. We'd be reverse-engineering claude's terminal output stream as a wire protocol — and Anthropic can change it any release with zero notice.
- No way to receive structured tool-call data (only what claude prints to the screen).
- Loses every reason v1_prototype chose MCP in the first place.

### Recommendation

**Path A (MCP-over-stdio).** Path B is a research project; Path A is engineering.

**Sub-decision (Q4):** does cc_pty's MCP stdio server **reuse** `Ezagent.Bridge.V1Prototype.Server` for the `forward_reply_to_agent` plumbing, or does cc_pty get its own copy?

- **Reuse:** keeps v1 + cc_pty using the same Server state for bridge↔agent binding. Risk: muddies the "v1_prototype is a separate replaceable plugin" boundary.
- **Own copy:** cc_pty has `EzagentPluginCc.AgentBindings` GenServer (~100 LOC). Independent lifecycle from v1. Clean. Pays a duplication cost.

**My recommendation: own copy.** v1_prototype's name advertises its disposability; cc_pty should not depend on a soon-to-be-deleted module. Yes, ~80 LOC of duplication. Worth it.

---

## 6. Process lifecycle (cc_pty side)

Once decisions A/Q3/Q4 above are committed: per-instance process tree for one cc-pty agent at URI `agent://architect`:

```
EzagentPluginCc.ProcessSupervisor (DynamicSupervisor, one_for_one)
  └─ EzagentPluginCc.ProcessServer (GenServer, transient restart, max_restarts: 3 in 60s)
       │ Owns:
       │   - erlexec_port (the claude PTY process)
       │   - mcp_config_path (per-instance .mcp.json absolute path)
       │   - agent_uri (binding key)
       │   - state: %{cwd, model, env, restart_count, last_exit, started_at}
       │
       │ Monitors: Ezagent.KindRegistry.lookup(agent_uri).pid  # the Agent Kind
       │
       │ Spawns at init/1:
       │   1. Write per-instance mcp.json pointing at our stdio MCP server
       │   2. :exec.run([claude_path, "--dangerously-load-development-channels", ...],
       │                [:pty, :monitor, {:env, env}, {:cd, cwd}])
       │   3. Subscribe to PubSub `esr:cc_pty:to_claude:#{agent_uri}` for outbound
       │
       │ On {:stdout, port, data}: capture, decide per §7 (display vs discard)
       │ On {'EXIT', port, exit_code}: emit telemetry, return {:stop, :claude_crashed}
       │ On {:DOWN, ref, :process, agent_pid, _}: kill claude, exit normally
       │ On {:to_claude, content, meta}: write_stdin to port
```

**Restart policy:** `restart: :transient` + `max_restarts: 3` in 60s window. After exhaustion, supervisor stops the child permanently → operator sees "process: crashed permanently" in LV and must manually restart from the UI (button → `ProcessSupervisor.restart_child/1`). Backoff is implicit via DynamicSupervisor's intensity throttle — we do not add custom exponential backoff in v1. **Decision Q5: confirm 3-in-60s is the right window, or stricter (3-in-300s)?**

**Crash detection telemetry:**
- `[:ezagent, :cc_pty, :spawn, :start]` — emitted on `init/1` success with `%{cwd, model, agent_uri}`
- `[:ezagent, :cc_pty, :spawn, :crash]` — emitted on `{'EXIT', port, code}` with `%{exit_code, runtime_ms, restart_count}`
- `[:ezagent, :cc_pty, :spawn, :restart_exhausted]` — when DynamicSupervisor gives up

LV admin subscribes to these for the process-status badge.

---

## 7. What to do with claude's PTY stdout

A genuine sub-problem. Claude's TUI output is a stream of:
1. ANSI escape sequences (cursor moves, color, screen clear)
2. The startup banner ("Claude Code v1.x", trust dialog, dev-channel warnings)
3. The chat prompt area (user input echo)
4. The assistant's rendered response (markdown → ANSI-colored text)
5. Tool-call "boxes" (Unicode box-drawing)
6. Spinner / "thinking…" indicators (constantly rewritten via `\r`)

**Reply traffic comes via MCP**, not via TUI parsing. So the TUI output is **strictly for operator-facing observability** — not for chat router consumption.

Three options:

| Option                         | What we do with TUI stdout                                              | Operator UX                                                                                       |
| ------------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| (a) **Discard**                | Read & drop. Maybe log first/last 1KB to a per-instance ringbuffer.     | Operator sees only reply-tool output in chat. Process is opaque ("is it actually running?")        |
| (b) **Pipe to PubSub**         | Each stdout chunk → `Phoenix.PubSub.broadcast("cc-pty:#{uri}:stdout", chunk)`. LV "console" tab renders with xterm.js (old esr's pattern). | Operator can pop a side-panel showing claude's actual TUI. Useful for debugging. Adds xterm.js dep. |
| (c) **Strip ANSI + log lines** | Run output through `Ezagent.Cli.AnsiStrip` (~30 LOC), log each plain line at `:debug`. | Operator inspects logs to see what claude saw. Lightweight, no UI work.                            |

### Recommendation

**(c) for v1, (b) for a follow-on PR.** Rationale:

- (c) gets us observability now with zero UI work. The plain log lines suffice for "did claude actually boot, did it answer."
- (b) is the genuinely nice version but xterm.js + a /attach-style LV is real frontend work (old esr's `EzagentWeb.PtySocket` is 200+ LOC). It's worth doing, but not before the cc_pty wiring itself is proven.
- (a) leaves operators flying blind. Don't.

**Decision Q6: confirm (c)-now-then-(b)-later, or do we want (b) in this PR?**

---

## 8. Template Class integration (depends on spec #01)

**`Ezagent.Template.CcPtySession`** — implements `@behaviour Ezagent.Kind.Template` (the contract from spec #01).

```
template_name/0 :: "cc-pty.session"

template_data shape:
  %{
    "agent_uri"  => String.t(),        # required — e.g. "agent://architect"
    "cwd"        => String.t(),        # required — absolute path; must exist
    "model"      => "opus" | "sonnet", # required (claude --model flag)
    "args"       => [String.t()] | nil,# optional extra argv to claude
    "env"        => %{String.t() => String.t()} | nil  # optional extra env (proxy etc.)
  }

validate/1 checks:
  - agent_uri is a valid URI with scheme "agent"
  - cwd is absolute, exists, is a directory
  - model in ~w(opus sonnet haiku)
  - args is a list of strings if present
  - env keys & values are strings if present
  - reject unknown top-level keys (strict — same posture as spec #01 GenericSession)

instantiate/3:
  1. Parse agent_uri.
  2. Ezagent.SpawnRegistry.spawn(agent_uri)  # chat plugin's "agent" handler
  3. EzagentPluginCc.ProcessSupervisor.start_for(agent_uri, %{cwd, model, args, env})
     — idempotent: if already running, return existing pid
  4. Return {:ok, [agent_uri]}  # the Agent URI is what the Workspace tracks
```

The two-step instantiate (spawn Agent Kind, then spawn ProcessServer) lets the Agent Kind survive ProcessServer restarts — its chat slice + Identity slice stay live across claude crashes.

**Registration:** `EzagentPluginCc.Application.start/2` calls `Ezagent.TemplateRegistry.register(Ezagent.Template.CcPtySession)`.

**Workspace declaration** (from operator's perspective — see §9 UX):
```json
{
  "session_templates": {
    "architect-on-ezagent": {
      "class": "cc-pty.session",
      "agent_uri": "agent://architect",
      "cwd": "/Users/h2oslabs/Workspace/ezagent",
      "model": "opus",
      "env": {"HTTPS_PROXY": "http://127.0.0.1:7890"}
    }
  },
  "members": ["agent://architect", "user://admin"]
}
```

Note: `agent://architect` appears in *both* `members` and the template. The Loader will `SpawnRegistry.spawn` it via the member path AND the template will `SpawnRegistry.spawn` it again — both calls hit chat's idempotent spawn fn, so the Agent Kind is born once. The template then layers the ProcessServer on top. This duplication is **OK by design** (spec #01 §9 worry #3 acknowledged it); cc_pty makes it concrete.

---

## 9. UX walkthrough

**Operator declares a cc-pty agent and watches claude auto-launch:**

1. Operator runs `mix ezagent.workspace.add_template ng-dev "architect-on-ezagent" --class cc-pty.session --data '{"agent_uri":"agent://architect","cwd":"/Users/h2oslabs/Workspace/ezagent","model":"opus"}'`.
2. `Ezagent.Workspace.add_template/3` calls `Ezagent.TemplateRegistry.lookup("cc-pty.session")` → `{:ok, Ezagent.Template.CcPtySession}` → `validate/1` → `:ok`. Persists.
3. Operator runs `mix ezagent.workspace.add_member ng-dev agent://architect` (members list).
4. Operator restarts Ezagent. On boot:
   - Chat plugin starts, registers `agent` scheme, spawns admin User + session://main.
   - Chat plugin calls `Loader.load_all/0`. For workspace `ng-dev`: `:instantiate` returns `[{:member, agent://architect}, {:template, "architect-on-ezagent", %{...}}]`.
   - Loader walks members → `SpawnRegistry.spawn(agent://architect)` → chat's fn spawns the Agent Kind. Idempotent.
   - cc_pty plugin starts (after chat). Walks already-loaded workspaces (via `Workspace.Store.list_all`) looking for `cc-pty.session` template entries. Finds `architect-on-ezagent`. Calls `CcPtySession.instantiate/3` → spawns ProcessServer → `:exec.run(...)` boots claude with PTY.
   - claude boots, reads its mcp.json, spawns Ezagent's stdio MCP server, sends `initialize` → Ezagent's MCP server posts to `EzagentPluginCc.AgentBindings.bind(agent_uri, server_pid)` → binding is live.
5. Operator opens `/admin` LiveView. Workspace `ng-dev` shows:
   - Members: `agent://architect` ✓ alive, `user://admin` ✓ alive
   - Templates: `architect-on-ezagent` (class: cc-pty.session) ✓ process running, pid 12345, started 13s ago, restarts: 0
6. Operator types `@architect what's in current directory` in the chat panel. MentionRouting fires → `chat/send` lands on Agent → Agent dispatches via PubSub → Ezagent's stdio MCP server emits `notifications/claude/channel` → claude sees it as a `<channel>` tag → claude responds via the `reply` tool → MCP server posts to `AgentBindings.forward_reply` → Agent → chat router → operator sees the response in LV.

**Failure UX:** claude crashes (e.g. operator kills its PID externally). ProcessSupervisor restarts it within 60s (max 3 times). LV shows a yellow "process restarted (count: 1)" badge with a timeline (telemetry-driven). If the 3rd restart is exhausted, the badge turns red: "process: crashed permanently. [Restart]". Restart button invokes `ProcessSupervisor.restart_child/1`.

---

## 10. Dev-author experience

A plugin author writing a new PTY-backed plugin (e.g., `esr_plugin_codex_pty`) after cc_pty ships:

1. Pattern from `ezagent_plugin_cc`: a Template Class implementing `Ezagent.Kind.Template`.
2. `instantiate/3` body is the recipe — spawn the Agent URI via SpawnRegistry, then spawn the per-instance ProcessServer.
3. Their own DynamicSupervisor + ProcessServer. Their own erlexec invocation. Their own stdio MCP server if needed.
4. Register Template Class in their `Application.start/2`. One line.

**They never modify `ezagent_core`, `esr_plugin_chat`, or `ezagent_plugin_cc`.** The contract surface is `Ezagent.Kind.Template` + `Ezagent.SpawnRegistry` + `Ezagent.TemplateRegistry`. That's it.

**This is the north star validation.** If cc_pty can be written without touching anything else, codex-pty's author writes their plugin without touching anything else.

---

## 11. What worries me (read this BEFORE the decision questions)

1. **Stdio MCP server in Elixir.** I have not personally written one of these. v1's Python is 322 lines, mostly JSON-RPC framing + SSE plumbing. The Elixir version is bounded but unfamiliar. **Risk: 50% it ships clean, 50% it eats a follow-on bugfix PR.** Mitigation: prototype the stdio MCP server as a 1-day spike BEFORE merging the rest of cc_pty. If the spike works, ship; if it doesn't, fall back to "cc_pty spawns the Python bridge as its MCP subprocess" (same wire shape, more processes per agent, kept as a fallback option Q7).
2. **`:erlexec` PTY mode + claude TUI's boot dance.** Old esr learned this the hard way (line 282-289 of `pty_process.ex` — claude blocks on Device Attributes query). We will hit at least one of those issues again. They're solvable (we have the old code as reference), but expect 1-2 days of "why doesn't it boot" debugging at first integration.
3. **Two-process pair (Agent Kind + ProcessServer) lifecycle is OTP-correct but unintuitive.** Code reviewers WILL ask "why isn't the ProcessServer a child of the Agent Kind?" Answer: because Agent's slice survives ProcessServer restarts and we want claude restartable without the chat state going away. This is a docstring battle, not a design battle.
4. **mcp.json per instance.** v1 writes one shared `.mcp.json` to `~/.ezagent/bridge.mcp.json`. cc_pty needs N — one per agent. Path: `~/.ezagent/cc-pty/<agent-uri-slug>.mcp.json`. Cleanup on Workspace.remove_template: someone must delete the file. Easy to leak. **Add a cleanup hook in CcPtySession on a future `:deinstantiate/2` callback** (which spec #01 doesn't define yet — see Q7 of spec #01 re: removal semantics).
5. **Security.** claude runs as Ezagent's user with PTY access. It can `rm -rf $HOME`. The `--permission-mode auto` + tool-call permission gating in cc-bridge-attach.sh is what protects us today. cc_pty must set the same flags. Environment variable scrubbing (PATH, HOME, USER) is left alone — same posture as old esr. **No sandboxing in v1.** Operator who declares a cc-pty agent in their Workspace owns the trust decision; same as running claude manually.
6. **What if claude binary is not on PATH?** `:exec.run` returns `{:error, :enoent}`. ProcessServer's init fails; DynamicSupervisor escalates; cc_pty's supervisor's `:rest_for_one` strategy will… wait, currently spec says `one_for_one`. **Confirm one_for_one — failures are isolated per agent.** Yes, that's right; one bad cc-pty config doesn't take down others.
7. **What about Windows?** `:erlexec` on Windows is unsupported. cc_pty is macOS + Linux only. **State this in mix.exs `@moduledoc` and in the README.** Probably fine — Ezagent's deployment target is server Linux.

---

## 12. Decision questions for Allen (ranked by impact)

| #  | Question                                                                                                                                                                                                                                                                                                                                                  | Default if unanswered                                                                                                                              |
| -- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Q1 | **Agent Kind reuse vs new Kind** (§3). Confirm Option 1 (reuse `Ezagent.Entity.Agent`, two-process pair via `Process.monitor`)?                                                                                                                                                                                                                                | Option 1. New Kind is a north-star violation (forces chat-plugin changes).                                                                          |
| Q2 | **MCP-over-stdio vs raw-TUI-parse** (§5). Confirm Path A (MCP)?                                                                                                                                                                                                                                                                                            | Path A. Path B is a research project.                                                                                                              |
| Q3 | **PTY library** (§4). Confirm `:erlexec`?                                                                                                                                                                                                                                                                                                                  | `:erlexec`. Old-esr production wisdom inheritable.                                                                                                  |
| Q4 | **Reuse v1's `Ezagent.Bridge.V1Prototype.Server` for cc_pty's agent bindings, or own copy** (§5 sub-decision)?                                                                                                                                                                                                                                                | Own copy (`EzagentPluginCc.AgentBindings`). ~80 LOC duplication worth the boundary.                                                                  |
| Q5 | **Restart intensity** (§6). 3 restarts in 60s, then operator-driven? Or stricter (3 in 300s)?                                                                                                                                                                                                                                                              | 3 in 60s. Aggressive enough to recover transient crashes; quick failure surface for real bugs.                                                       |
| Q6 | **TUI output handling** (§7). Path (c) discard+log this PR, (b) PubSub→xterm.js next PR?                                                                                                                                                                                                                                                                   | (c) now, (b) later.                                                                                                                                |
| Q7 | **MCP server: native Elixir vs spawn-the-Python-bridge** (§11 worry #1 fallback). Build native Elixir stdio MCP server, OR (cheaper) have cc_pty spawn `esr_mcp_bridge_v1_prototype.py` as claude's MCP subprocess (i.e., literally hand cc_pty's per-instance mcp.json pointing at the same Python script v1 already uses)?                                | Build native Elixir. The Python path is a coward's fallback — works, but locks Ezagent's deploy story to having `uv` available everywhere.              |
| Q8 | **cc_pty in plugin dep order** (§2). Strict `cc_pty AFTER chat` (umbrella dep)? Or do we want a "late-binding plugin starts" mechanism in a future Phase 5?                                                                                                                                                                                                | Strict dep on chat (umbrella dep). Late-binding mechanism is Phase 5+ work tied to spec #01 Q4.                                                     |
| Q9 | **Mix task surface.** New `mix ezagent.cc_pty.status` (list all cc-pty agents + their process status + last crash)? Or rely on LV admin solely?                                                                                                                                                                                                                | Add the mix task. CLI status is operator-friendly and trivial (~30 LOC).                                                                            |

---

## 13. Migration / backward compat

| Scenario                                                                                                              | Behavior                                                                                                                                                                                                                                                                |
| --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Existing v1_prototype users (operator runs `cc-bridge-attach.sh`)                                                     | **Unchanged.** v1_prototype keeps working; `Ezagent.Bridge.V1Prototype.Server` keeps its HTTP routes. cc_pty does NOT delete or modify v1.                                                                                                                                  |
| Workspace today has `members: [agent://cc-builder]` (v1-attached agent) AND a new `cc-pty.session` template for `agent://architect` | Both Agents coexist. cc-builder is brought up only when the operator runs the bridge script (today's UX, unchanged). architect is brought up by Ezagent on boot. The router treats them identically.                                                                       |
| Operator currently uses `cc-bridge-attach.sh` for everything — wants to migrate to cc_pty                              | Per-agent migration: declare the same agent URI via cc-pty.session template, stop running the bridge script. v1_prototype announce HTTP routes still exist; operator can drop the migration mid-stream and revert.                                                       |
| Phase 5 introduces `ezagent_plugin_cc` (the "external-attach v2")                                                  | cc_channel deprecates v1_prototype; cc_pty is unaffected (it's the "Ezagent-spawns-claude" path, orthogonal). The Decision #56 split holds: cc_pty stays for managed-process, cc_channel for external-attach. Both can coexist.                                              |

---

## 14. Test strategy

| Test                                                                          | Location                                                                                | Asserts                                                                                                                                                                                            |
| ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Ezagent.Template.CcPtySession` validate                                          | `apps/ezagent_plugin_cc/test/esr/template/cc_pty_session_test.exs`                       | Rejects bad URIs, missing cwd, nonexistent cwd, invalid model, unknown top-level keys                                                                                                                |
| `Ezagent.Template.CcPtySession` instantiate (with mock binary)                    | same file                                                                               | With `claude_binary_path: "<repo>/test/support/fake_claude.sh"` (a 5-line shell script that prints a fixed `initialize` response then sleeps): asserts Agent Kind + ProcessServer both alive, mock binary OS pid live |
| `ProcessServer` crash → restart                                               | `apps/ezagent_plugin_cc/test/esr/process_server_test.exs`                                | Mock binary exits with code 1; assert ProcessServer restarts within DynamicSupervisor intensity; restart_count telemetry fires                                                                       |
| `ProcessServer` restart exhaustion                                            | same                                                                                    | Mock binary always exits 1; after 3 restarts in 60s, supervisor stops it; LV telemetry shows `:restart_exhausted`                                                                                     |
| `ProcessServer` stdin write                                                   | same                                                                                    | Spawn mock binary that echoes stdin to a file; write via ProcessServer; assert file contents                                                                                                         |
| Stdio MCP server unit                                                         | `apps/ezagent_plugin_cc/test/ezagent_plugin_cc/mcp_stdio_server_test.exs`                | `initialize` response shape; `tools/list` shape; `tools/call reply` dispatches to AgentBindings; `notifications/claude/channel` emitted on PubSub event                                              |
| End-to-end integration (mock claude binary) ★                                  | `apps/ezagent_plugin_cc/test/integration/cc_pty_lifecycle_test.exs`                      | Declare a Workspace with cc-pty.session template (mock binary) → Loader runs → ProcessServer alive → simulate MCP `reply` from mock binary → assert message lands in session://main with sender = agent URI |
| **Phase 4 invariant test EXTENSION** ★★                                      | `apps/ezagent_core/test/integration/plugin_isolation_workspace_test.exs` (extend, again)    | Inline a `FakeCcPtyTemplate` Class (modeled after the spec #01 ProbeTemplate); declare in a Workspace; verify after teardown+`Loader.load_all/0` the spawned URIs are alive — **all from cc_pty plugin, zero references in ezagent_core or esr_plugin_chat to `EzagentPluginCc`.** |

★ The mock-binary end-to-end IS the production-flow validation per memory `feedback_e2e_faces_production`. Don't substitute the supervisor with a stub.

★★ This is the architectural gate per memory `feedback_completion_requires_invariant_test`. If cc_pty can be added to the Phase 4 invariant test without changing the test's assertion code (beyond adding a new template fixture), the north star is preserved. If the test needs to special-case cc_pty, the design has leaked plugin specifics into core.

---

## 15. LOC estimate

| File                                                                                          | New / Δ | LOC      |
| --------------------------------------------------------------------------------------------- | ------- | -------- |
| `apps/ezagent_plugin_cc/mix.exs`                                                              | New     | ~40      |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/application.ex`                                 | New     | ~80      |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/process_supervisor.ex`                          | New     | ~60      |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/process_server.ex`                              | New     | ~280     |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/mcp_stdio_server.ex` (Q7-Elixir)                | New     | ~250     |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/agent_bindings.ex` (Q4-own-copy)                | New     | ~100     |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/mcp_config_writer.ex` (per-instance)            | New     | ~70      |
| `apps/ezagent_plugin_cc/lib/esr/template/cc_pty_session.ex`                                   | New     | ~120     |
| `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/ansi_strip.ex` (Q6-(c))                         | New     | ~30      |
| `apps/ezagent_plugin_cc/lib/mix/tasks/esr.cc_pty.status.ex` (Q9)                              | New     | ~50      |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspace_detail_live.ex` (process status badges) | Δ       | +60      |
| **Subtotal impl**                                                                             |         | **~1140**|
| Tests (per §14)                                                                               | New + Δ | ~520     |
| Mock claude binary script (`test/support/fake_claude.sh`)                                     | New     | ~30      |
| **Total**                                                                                     |         | **~1690**|

**This breaks the Decision #72 1100-LOC per-PR red line.** Mitigation: split into two PRs.

- **PR-A (~700 LOC):** `mix.exs`, application, process_supervisor, process_server, agent_bindings, mcp_config_writer, cc_pty_session Template Class. Uses Q7-fallback (spawn the v1 Python bridge as claude's MCP subprocess) so MCP code is zero in this PR. Tests + mock binary + invariant extension included. Ships a working cc_pty using the Python bridge.
- **PR-B (~440 LOC):** Native Elixir `MCPStdioServer` + ANSI strip + mix status task + LV badges. Removes the Python bridge dep from PR-A. Tests for the MCP server.

**This split is itself a decision point — Q10 below.**

| #   | Question                                                                                                                                                                                                                       | Default                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Q10 | Two-PR split: ship cc_pty in PR-A with Python-bridge MCP (working, but deploy-heavy), then replace with native Elixir MCP server in PR-B?                                                                                       | Yes. Reduces PR-A risk; PR-B is a clean refactor with tests. |

---

## 16. Honest self-assessment: well-understood vs. needs-prototype

**Well-understood (low risk, ship with confidence):**

- Plugin shape, mix.exs, Application boot wiring (we have spec #01 to model off; same structure)
- Template Class implementation (validate/instantiate trivial once spec #01 lands)
- DynamicSupervisor + ProcessServer skeleton (`use GenServer` boilerplate)
- Agent URI reuse strategy (Option 1, §3) — chat's spawn fn is already idempotent
- `:erlexec` invocation for a simple `echo`-style binary (we have old-esr code as reference)
- LV process-status badge (telemetry + Phoenix.LiveView — standard)
- Test suite shape (mock binary pattern proven by old-esr at `runtime/test/esr/entity/pty_process_test.exs`)

**Needs prototyping after spec approval (medium risk):**

- `:erlexec` + claude's TUI boot dance. Old-esr's `TERM=xterm-256color`, `COLUMNS=120`, etc., env was empirically derived. We'll re-discover these. Budget: 1-2 days of "claude doesn't print its banner" debugging.
- Per-instance mcp.json writing + cleanup. Conceptually simple, but the "where do these files live" question (per Q11 implicit) wants a 1-hour spike.
- `Process.monitor` lifecycle between Agent Kind and ProcessServer. OTP-idiomatic but one of those things where the first three implementations have a bug. Budget: 1 day of "test passes locally, fails in CI under load."

**Genuinely hard, prototype FIRST (high risk):**

- Native Elixir stdio MCP server (Q7). Building a JSON-RPC stdio server from scratch in Elixir, with the specific MCP extensions claude expects (capabilities.experimental['claude/channel'], notifications/claude/channel), is **the single most uncertain piece of this spec.** Strongly recommend: a 1-day spike that gets `claude --mcp-config <points-at-elixir-script>` to successfully `initialize` and respond to `tools/list`, BEFORE PR-B is written. If the spike fails, ship cc_pty permanently on the Python-bridge fallback (Q7 fallback path). The downside of that fallback (deploy needs `uv`) is real but survivable.

**Items I do NOT think are hard but might surprise us:**

- Reading claude's reply text out of the MCP `tools/call reply` payload (it's just JSON — but claude's reply text may include channel tags / file references that v1's bridge already handles)
- Telemetry plumbing (standard `:telemetry.execute`)
- The `validate/1` checks (basic guards)

---

**END SPEC.** Awaiting Allen's answers to Q1–Q10 before implementation begins.

If Allen approves and Q10 = yes (two-PR split), the next deliverable is the **PR-A plan** (separate document, following spec #01's PLAN convention) — not code. The PR-A plan resolves any open question marks from the decision table and lays out the implementation sequence, with the 1-day MCP-server spike as a discrete checkpoint between PR-A and PR-B.
