# Sidecar OS-process erlexec unification — Implementation Plan (REVISED post-review)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`). Load skills `ezagent-developer`, `elixir-phoenix-helper`, `erlexec-elixir` in every task subagent.

**Goal:** Replace the 4 sidecars' native `Port.open({:spawn_executable})` with an erlexec-based runtime primitive that reaps the whole process subtree (no orphans), unify pid-file + boot reaping in the runtime layer, and add an AST arch gate forbidding raw `Port.open` spawns.

**Architecture:** New runtime-tier modules in `ezagent_core`: `Ezagent.Runtime.OsProcess` (functional erlexec primitive — `run_link` + `{group,0}`+`kill_group`, the sanctioned spawn exit), `Ezagent.Runtime.LineBuffer` (capped newline framing), `Ezagent.Runtime.OrphanReaper` (shared boot reaper). The 4 sidecars keep their own GenServers and call `OsProcess` directly (NO `use`-behaviour — B2 dropped). PTY/Python domains untouched. See SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md`.

**Tech Stack:** Elixir/OTP, erlexec 2.3.0, ExUnit. Umbrella: `apps/ezagent_core`, `apps/ezagent_plugin_{cc,codex,feishu}`.

## Global Constraints

- erlexec spawns ALWAYS pair `{:group, 0}` + `:kill_group` (SPEC §2 safety invariant); spawn via **`:exec.run_link`** (NOT `run`), NO `:monitor`. Only `Ezagent.Runtime.OsProcess` calls `:exec.run_link` for sidecars.
- **Caller contract** (every sidecar): `Process.flag(:trap_exit, true)` in `init/1` UNCONDITIONALLY (even codex test_mode) BEFORE spawn; handle `{:EXIT, exec_pid, reason}` for **ALL** reasons (`:normal` clean-exit | `{:exit_status, n}` | `:port_closed`) + a defensive `{:EXIT, _other, _}` clause + `{:stdout, os_pid, bytes}` (+ `{:stderr, os_pid, bytes}` when `:separate`); `terminate/2` → `OsProcess.stop(exec_pid)` + `cleanup_pid_file`.
- `:exec.stop/send` take the **Erlang `exec_pid`** (matches `Domain.Pty`/`Domain.Python`).
- env entries → `{charlist, charlist}`; `{:cd, charlist}`. cmd as a **list** (execve, no shell).
- Orphan tests use **exact captured os_pid + `ps -p`**, NEVER `pkill`.
- Preserve each sidecar's stderr disposition (SPEC §4): cc SDK + feishu `:separate`; codex two `:merge`.
- `LineBuffer` keeps the existing byte caps (cc 1 MiB, feishu 64 KiB); split on `~r/\r?\n/`.
- Do NOT modify `Domain.Pty.Server`, `Domain.Python.Server`, `Cc.OrphanReaper` (PTY), np `OrphanReaper`, or feishu `load_credentials/0` (A-owned — move verbatim).
- `uv run` not `python`; `pnpm` not `npm`. Format only touched files. CI = `mix precommit` + `mix ezagent.check_invariants` green on PR head, rebased on `main`.

---

### Task 1: `Ezagent.Runtime.OsProcess` + `LineBuffer` + erlexec dep (orphan fix core)

**Files:**
- Modify: `apps/ezagent_core/mix.exs` (`{:erlexec, "~> 2.3"}` dep + `:erlexec` in `extra_applications`)
- Create: `apps/ezagent_core/lib/ezagent/runtime/os_process.ex`, `.../line_buffer.ex`
- Test: `apps/ezagent_core/test/ezagent/runtime/os_process_test.exs`, `.../line_buffer_test.exs`

**Interfaces:**
- Produces: `OsProcess.spawn(cmd, opts) :: {:ok, %{exec_pid: pid, os_pid: pos_integer}} | {:error, term}`; `OsProcess.send(exec_pid, iodata) :: :ok | {:error,_}`; `OsProcess.stop(exec_pid|nil) :: :ok`; `OsProcess.cleanup_pid_file(plugin, key) :: :ok`. `LineBuffer.new(max_line_bytes) :: t`; `LineBuffer.feed(t, binary) :: {t, [String.t]}`.

- [ ] **Step 1: erlexec dep** — add dep + `:erlexec` to `extra_applications`; `mix deps.get`; in `iex -S mix` confirm `:exec.start()` returns `{:ok,_}` / `{:error,{:already_started,_}}`.
- [ ] **Step 2: LineBuffer failing test** — chunks reassemble into complete lines; partial tail held; `\r\n` stripped; a line exceeding the cap is flushed (not buffered forever).

```elixir
test "caps an over-long line instead of growing forever" do
  lb = Ezagent.Runtime.LineBuffer.new(8)
  {_lb, lines} = Ezagent.Runtime.LineBuffer.feed(lb, "AAAAAAAAAAAAAAAAAA")  # 18 bytes, no \n
  assert lines == ["AAAAAAAA"]  # flushed at cap (exact policy: emit the capped prefix)
end
```

- [ ] **Step 3: implement LineBuffer** — defstruct `buf: "", max: …`; `feed/2` splits on `~r/\r?\n/`, emits complete lines, holds tail; if tail ≥ max, emit the capped prefix and keep the remainder. `max` is a **generous safety ceiling sized above the realistic max event (≥1 MiB)**, NOT the old `{:line, N}` (feishu had no cap — `{:line,N}` was delivery chunk size); a too-small cap is a real feishu regression. Run → PASS.
- [ ] **Step 4: OsProcess subtree-reap failing test** (`@tag :slow`)

```elixir
@tag :slow
test "stop/1 reaps the whole subtree — grandchild os_pid dies, not just the direct child" do
  {:ok, %{exec_pid: ep, os_pid: parent}} =
    Ezagent.Runtime.OsProcess.spawn(["/bin/sh","-c","sleep 300 & echo GRANDCHILD=$!; wait"],
      cd: System.tmp_dir!())
  grandchild =
    receive do
      {:stdout, ^parent, b} ->
        [_, g] = Regex.run(~r/GRANDCHILD=(\d+)/, IO.iodata_to_binary(b)); String.to_integer(g)
    after 5_000 -> flunk("no grandchild pid") end
  assert os_alive?(parent) and os_alive?(grandchild)
  :ok = Ezagent.Runtime.OsProcess.stop(ep)
  assert eventually_dead?(grandchild, 10_000), "grandchild #{grandchild} orphaned"
end
```

- [ ] **Step 5: OsProcess owner-death failing test** (`@tag :slow`) — spawn from a throwaway linked process, `Process.exit(that_pid, :kill)`, poll the captured os_pid dead within 10 s (proves `run_link` reaps on brutal owner kill). Use a tiny helper GenServer/Task that spawns and reports os_pid.
- [ ] **Step 6: implement OsProcess** — `ensure_started/0`; opts `[:stdin, :stdout, {:group,0}, :kill_group, {:cd,_}, {:env,_}]` + stderr (`:merge`→`{:stderr,:stdout}`, `:separate`→`:stderr`); `:exec.run_link` (NO `:monitor`); on ok optional `PidFile.write`. `send/2`→`:exec.send`; `stop/1`→`:exec.stop(exec_pid)` try/catch; `cleanup_pid_file/2`→`PidFile.remove`. Run Steps 4-5 (`mix test --include slow`) → PASS. **This is the orphan-fix proof.**
- [ ] **Step 6b: clean-exit (status-0) test** — spawn `["/bin/sh","-c","exit 0"]`; assert the owner receives `{:EXIT, exec_pid, :normal}` (NOT a numeric status — `:monitor` is dropped so status-0 collapses to `:normal`). Documents the reason taxonomy `:normal | {:exit_status, n} | :port_closed` the migrations must all handle.
- [ ] **Step 7: pid-file write test** — `spawn(…, pid_file: {"t", uri})` writes; `cleanup_pid_file` removes. Assert.
- [ ] **Step 8: Commit** — `feat(runtime): erlexec OS-process primitive (run_link + group-kill subtree reaping)`

### Task 2: PidFile URI-body + shared `Ezagent.Runtime.OrphanReaper`

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/runtime/pid_file.ex`
- Create: `apps/ezagent_core/lib/ezagent/runtime/orphan_reaper.ex`
- Test: `.../pid_file_uri_body_test.exs`, `.../orphan_reaper_test.exs`

**Interfaces:**
- Consumes: `PidFile.enumerate/1`, `PidFile.process_start_seconds/1`, `:exec.stop` (adopt-then-stop a foreign os_pid).
- Produces: `OrphanReaper.reap(plugin :: String.t()) :: :ok` (imperative sweep, called from each plugin's `Application.after_boot/0` — NOT a supervision child_spec; matches the existing `Cc.OrphanReaper`/np `reap()` precedent + the reap-before-`load_all` ordering); `PidFile.write(plugin, key, os_pid)` now writes a 3rd `URI.to_string` line; `enumerate/1` reads it (fallback to filename reverse-parse for legacy 2-line files; a missing body-URI on a non-`entity` subdir is a recoverable skip, NOT a garbage-delete).

- [ ] **Step 1: PidFile URI-body failing test** — write a `system://feishu/ws` key → `enumerate` returns that exact `%URI{}`; a legacy 2-line `entity://…` file still round-trips via filename fallback. Rename the `agent_uri` param to `key`.
- [ ] **Step 2: implement PidFile change** — `write/3` body = `"#{os_pid}\n#{start}\n#{URI.to_string(key)}\n"`; `parse/1` reads line 3 as the URI when present, else `agent_uri_from_filename/1`. Run → PASS. (Existing `[pid_str, start_str | _]` destructure already tolerates the extra line — verify legacy reaper tests still green: `mix test apps/ezagent_plugin_cc/test/orphan_reaper_test.exs`.)
- [ ] **Step 3: OrphanReaper failing test** — synthetic pid file pointing at a live `sleep` os_pid (matching start-time) → `OrphanReaper.reap("t")` kills it + deletes file; a start-time-mismatched (recycled) entry → file deleted WITHOUT signalling the live pid.
- [ ] **Step 4: implement OrphanReaper** — a plain module with `reap(plugin) :: :ok` (NOT a GenServer/child_spec — call it from `after_boot/0`): one `PidFile.enumerate(plugin)` sweep: per entry, recheck `process_start_seconds` vs stored; match → adopt the os_pid via `:exec.manage`/`:exec.stop` + `PidFile.remove`; mismatch/dead → `PidFile.remove` only. Run → PASS.
- [ ] **Step 5: Commit** — `feat(runtime): shared OrphanReaper + pid-file URI-body (non-entity keys)`

### Task 3: migrate `EzagentPluginCc.SdkSidecar` (JSON-line; prove protocol + orphan)

**Files:**
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/application.ex` (call `Ezagent.Runtime.OrphanReaper.reap("cc-sdk")` in `after_boot/0`, beside the existing `Cc.OrphanReaper` reap)
- Test: `apps/ezagent_plugin_cc/test/sdk_sidecar_erlexec_test.exs`

**Interfaces:** Preserve public API `start/2`, `lookup/1`, `alive?/1`, `stop/1`, `query/3`, `recent_output/1`, `start_link/1`, `sdk_runner/1`.

- [ ] **Step 1: JSON round-trip failing test** — start `SdkSidecar` against a deterministic stub worker (tiny `sh`/`uv run` script echoing a JSON reply for one `query` frame); assert `query/3` → `{:ok, %{content: …}}`. (DoD "JSON-line works under erlexec" proof — don't oversell as full-SDK e2e.)
- [ ] **Step 2: migrate** — `init`: `Process.flag(:trap_exit, true)` then `OsProcess.spawn([runner | runner_args ++ [script]], cd: cwd, env: env, stderr: :separate, pid_file: {"cc-sdk", agent_uri})`; store `exec_pid`/`os_pid`/`%LineBuffer{}`. Move `{_port,{:data,{:eol,line}}}` body into `handle_info({:stdout, os_pid, bytes}, …)` → `LineBuffer.feed` → `handle_line` (id-correlation verbatim). `{:stderr, os_pid, b}` → log+drop. `{:EXIT, exec_pid, reason}` → reply pending `{:error,{:sdk_sidecar_exit,reason}}` + `{:stop,…}`. `send_frame` → `OsProcess.send(exec_pid, json)`. `terminate` → `OsProcess.stop` + `cleanup_pid_file`. Run Step 1 → PASS.
- [ ] **Step 3: orphan proof** — spawn, capture worker os_pid, `stop/1`, poll dead. And `single_spawn_entry_test` still green (`DynamicSupervisor.start_child` unchanged): `mix test apps/ezagent_core/test/invariants/single_spawn_entry_test.exs`.
- [ ] **Step 4: Commit** — `refactor(cc): SdkSidecar → OsProcess (erlexec, no orphans)`

### Task 4: migrate `EzagentPluginCodex.AppServer` + `BridgeSidecar` (raw framing)

**Files:**
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/app_server.ex`, `.../bridge_sidecar.ex`
- Modify: codex `application.ex` (`after_boot/0`: `OrphanReaper.reap("codex-appserver")` + `OrphanReaper.reap("codex-bridge")`)
- Test: `apps/ezagent_plugin_codex/test/codex_sidecar_erlexec_test.exs`

**Interfaces:** Preserve `start/2`, `lookup/1`, `alive?/1`, `stop/1`, `recent_output/1`, `bridge_runner/1`, `codex_executable/1`, the `test_mode` short-circuit.

- [ ] **Step 1: test_mode failing test** — `alive?/1` after `start/2` in `:test` (no real codex), proving the no-spawn short-circuit still holds.
- [ ] **Step 2: migrate AppServer** — `init`: trap_exit; in test_mode skip spawn; else mkdir+rm socket, `OsProcess.spawn([codex,"app-server","--listen","unix://#{socket}"], cd:, env:, stderr: :merge, pid_file: {"codex-appserver", agent_uri})`. `{:stdout, _, data}` → `handle_chunk` (trim_output). `{:EXIT, exec_pid, reason}` → `{:stop,…}`. `terminate` → stop + cleanup. Run.
- [ ] **Step 3: migrate BridgeSidecar** — same shape, `stderr: :merge`, `pid_file: {"codex-bridge", agent_uri}`, runner cmd + env (token mint preserved); `recent_output` unchanged. Keep `BridgeSidecarTest.bridge_runner/1` green: `mix test apps/ezagent_plugin_codex/test/bridge_adapter_test.exs`.
- [ ] **Step 4: orphan proof** — `@tag :slow`; if codex binary absent, prove via a stub command argv; capture os_pid, stop, poll dead.
- [ ] **Step 5: Commit** — `refactor(codex): AppServer + BridgeSidecar → OsProcess (erlexec)`

### Task 5: migrate `EzagentPluginFeishu.WsClient` (deferred spawn + restart)

**Files:**
- Modify: `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex`
- Modify: feishu `application.ex` (`after_boot/0`: `OrphanReaper.reap("feishu-ws")`)
- Test: `apps/ezagent_plugin_feishu/test/ws_client_erlexec_test.exs`

**Interfaces:** Preserve `start_link/1`, `status/0`, `EZAGENT_FEISHU_WS=0` idle path, `load_credentials/0` (A-owned — verbatim), `EventDecoder` dispatch.

- [ ] **Step 1: failing grandchild orphan proof** (`@tag :slow`) — feishu is NOT started at test boot (`maybe_ws_client_spec` returns nil in `:test`), so the test owns the lifecycle: `start_supervised!(WsClient)` (needs `node` in PATH, else skip like the existing integration test) with bogus creds so the deferred `:open_sidecar` spawns the node sidecar; have a test stub (or `main.js` test hook) fork a worker grandchild that prints its pid; capture the **grandchild** os_pid; `Process.exit(ws_client_pid, :kill)`; poll the grandchild dead within 10 s (proves `kill_group` subtree reap, not the node self-exit). Keep existing `sidecar_orphan_reap_test` green.
- [ ] **Step 2: migrate** — `init`: trap_exit; keep enabled?/node?/sidecar-exists guards; `handle_info(:open_sidecar, …)` calls `load_credentials/0` **verbatim**, then `OsProcess.spawn([node_bin, sidecar_path], cd:, env: env_for_sidecar(...), stderr: :separate, pid_file: {"feishu-ws", Ezagent.URI.system("feishu","ws")})`; store exec_pid/os_pid/LineBuffer. `{:stdout,_,b}` → `LineBuffer.feed` → `handle_json_line` verbatim. `{:EXIT, exec_pid, _}` → `handle_exit` → `Process.send_after(self(), :open_sidecar, 5_000)` (restart). `terminate` → stop + cleanup. Run Step 1 → PASS.
- [ ] **Step 3: wire reaper** — `OrphanReaper.reap("feishu-ws")` in feishu `after_boot/0`; assert booting the app runs the sweep without crashing (and reaps a planted stale `feishu-ws` pid file).
- [ ] **Step 4: Commit** — `refactor(feishu): WsClient → OsProcess + feishu-ws reaper (erlexec)`

### Task 6: arch gate `raw_port_spawn_executable` (AST-based)

**Files:**
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex` (counter in `do_measure/0` + AST helper)
- Modify: `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` (`raw_port_spawn_executable: 0`)
- Create: `apps/ezagent_core/test/architecture/raw_port_spawn_test.exs`

- [ ] **Step 1: failing gate test** — `import EzagentCore.ArchitectureCase; test "no raw Port.open spawn_executable", do: assert_zero(:raw_port_spawn_executable)`. Run → fails (counter not in `measure/0`).
- [ ] **Step 2: add AST counter** — new `raw_port_spawn_executable_count/0`: for each `lib_files()`, `Code.string_to_quoted` + `Macro.prewalk` matching a `Port.open` call `{{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, [first_arg | _]}` whose **`first_arg` is the bare 2-tuple** — `match?({:spawn_executable, _}, first_arg) or match?({:{}, _, [:spawn_executable | _]}, first_arg)`. EMPIRICALLY VERIFIED: `Port.open({:spawn_executable, x}, [])` quotes `first_arg` as `{:spawn_executable, {:x,[],Elixir}}` (2-tuple literal), while `{:fd, 0, 1}` quotes as `{:{}, _, [:fd,0,1]}` (must NOT match). The earlier `{:{}, _, [:spawn_executable|_]}`-only pattern matches NOTHING real → false-green. Honour `# arch-allow:` via `arch_allowed_lines/1`. Add `raw_port_spawn_executable: 0` to manifest with a comment. Run gate → PASS. `mix ezagent.arch.scan` shows `PASS raw_port_spawn_executable: count=0 cap=0`.
- [ ] **Step 3: regression proof** — temporarily add a **multi-line 2-tuple** `Port.open(\n  {:spawn_executable, x}, [])` to a scratch lib file; run the gate → FAILS (proves the AST path catches the form line-grep would miss). Also confirm `Port.open({:fd, 0, 1}, [])` is NOT counted (no false-positive). Revert. `manifest_ratchet_test` green.
- [ ] **Step 4: Commit** — `feat(arch): AST gate forbidding raw Port.open spawn_executable (cap 0)`

### Task 7: full-suite green + return

**Files:** Create `docs/together/2026-06-25/returns/allenwoods-B-sidecar-erlexec.md`

- [ ] **Step 1:** `mix format` (touched only); `mix test` (full, incl. `--include slow`); `mix ezagent.check_invariants`; `mix ezagent.arch.scan`; **positively** `mix test apps/ezagent_domain_pty` (DoD #4). All green.
- [ ] **Step 2:** push `feat/sidecar-erlexec-b`, open PR, confirm CI (`precommit + check_invariants`) green on PR head, rebased on `main`. Confirm the CI entrypoint actually runs `mix test`.
- [ ] **Step 3:** write the dev-together return: four-property DoD reconciliation + orphan-proof evidence (captured pids) + the C two-file conflict note + the `load_credentials/0` A-ownership flag. Hand PR# + return to the lead. **Do NOT self-merge to main.**

---

## Self-review notes
- Spec coverage: Task 1 = OsProcess/LineBuffer (§3.1-3.3); Task 2 = pid-file/reaper (§3.4); 3-5 = migrations (§4); 6 = AST gate (§5); 7 = DoD §6 + conflict §7. All four DoD properties have a concrete CI-run test (subtree + owner-kill + grandchild orphan proofs; gate; positive PTY test).
- Type consistency: `OsProcess.spawn/2` → `%{exec_pid, os_pid}` used identically in Tasks 3-5; `{:EXIT, exec_pid, reason}` is the single child-exit shape; `OsProcess.send(exec_pid, _)` the single stdin path.
- No `use`-behaviour (B2 dropped); each sidecar's trap_exit + terminate contract is in Global Constraints.
