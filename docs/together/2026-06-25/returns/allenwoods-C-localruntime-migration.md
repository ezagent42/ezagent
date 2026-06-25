> **Task:** C — LocalRuntime 收口（#99）
> **Branch:** `feat/localruntime-migration-c`
> **PR:** https://github.com/ezagent42/ezagent/pull/977
> **Dev:** allenwoods (agent)
> **returned_at:** 2026-06-25 12:08 +0800
> **deadline:** 2026-06-25 23:59 +0800
> **deadline_status:** on_time
> **head SHA:** e33eccdb · **rebase-base (current main):** 8a6dfa7d
> **CI:** precommit + check_invariants — **SUCCESS** on head `e33eccdb` (https://github.com/ezagent42/ezagent/actions/runs/28146232977) · advisories pass

## What's done

hello/protocol_api/world 的 6 处直调 `SpawnRegistry`/`KindRegistry`（7 个调用点）全部改走 owner-gated `Ezagent.LocalRuntime`：

| 文件:行 | before | after |
|---|---|---|
| hello_session.ex:41 | `KindRegistry.lookup == :error` | `not LocalRuntime.kind_alive?/1` |
| conversation_registry.ex:53,90 | `SpawnRegistry.spawn/1` | `LocalRuntime.ensure_started/1` |
| openai_chat_plug.ex:109 | `KindRegistry.lookup`(轮询) | `LocalRuntime.kind_alive?/1`（case→cond） |
| openai_chat_plug.ex:195 | `SpawnRegistry.spawn/1` | `LocalRuntime.ensure_started/1` |
| workspace_plugin_data.ex:122,164 | `KindRegistry.lookup` 读 pid | `LocalRuntime.kind_alive?/1` |

- LocalRuntime 维持 **URI-only / 无新 arity**（behaviors 归 A）。单节点 owner-gate 为 no-op → 行为不变。
- 范围外（已确认不碰）：openai `ensure_live`、world `KindRegistry.list_all`、scanner 里 stale 的 `mcp_server` sanctioned 条目。
- 连带（被 gate 强制，纳入本 PR）：删 contract-test 的 7 条 `@allowlist`（剩 5 条 cc/codex 债）；scanner `@spawn_registry_sanctioned_files` 删 conv_reg+openai（`local_runtime.ex` 保留为 on-chokepoint delegate）。

## DoD reconciliation

| # | DoD line（handoff） | status | proof / open decision |
|---|---|---|---|
| 1 | hello/protocol_api/world 不再直接调 SpawnRegistry/KindRegistry（走 LocalRuntime） | met | 4 源文件 diff；`plugin_workspace_locality_contract_test.exs` 由 7 条 allowlist → 0（绿，无需 allowlist） |
| 2 | arch 扫描 call_sites/off_chokepoint 计数下降并下调 cap | met（部分按构造） | `mix ezagent.arch.scan` 绿：`call_sites 30→27`、`modules 26→24` 真降并下调 cap；**`off_chokepoint` 维持 16**——见下「带证据说明」 |
| 3 | 单节点行为不变：全量 mix test 绿；protocol_api 起 agent、hello/world liveness 有测试覆盖 | met（见 §note） | 新增 `workspace_liveness_test`（world live:true list+detail）、`conversation_registry_test`（stateless+durable resolve 起 live session）；既有 `hello_session_test` fresh? 绿。全量本地 `mix test`：除 3 个 **cc `:requires_exec` E2E**（本机装了 uv 才会跑，bridge 子进程 flake，**不碰 cc 代码**、CI 因无 uv 自动 skip）外全绿 |
| 4 | CI 绿 + rebase | met | 已 rebase 到 `8a6dfa7d`（当前 main，clean，docs-only 推进无重叠）；PR head `e33eccdb` 的 `precommit + check_invariants` **SUCCESS**（run 28146232977） |

**四性质对账：** 目标派生（6 处 → owner-gated 单一入口）；可验证带证明（contract gate allowlisted→绿 + arch.scan 27/24/16 + 两条新 test）；在用户面（world workspace liveness 显示 / protocol_api 起 session / hello app freshness，单节点行为不变）；闭集（ensure_live / list_all / mcp_server-stale / A 的 behaviors 边界 显式划外）。

## off_chokepoint 为何不降（带证据，非 deferred）

`conversation_registry.ex` + `openai_chat_plug.ex` 此前被列入 scanner `@spawn_registry_sanctioned_files`（算 **on-chokepoint**），从不计入 `off_chokepoint`。把它们移出 SpawnRegistry + 移出白名单是「一进一出」，其它*未授权* spawner 数量未变 → 仍 **16**。架构收益真实存在（sanctioned 白名单收紧、`local_runtime.ex` 仍是唯一 on-chokepoint delegate），但该 counter 量的是「白名单*外*的违规者」，量不到白名单本身收紧——收益体现在 `call_sites`/`modules` 两条真降。lead 若希望它也体现，需要给 off_chokepoint 换一个「含白名单大小」的度量（独立改 scanner 语义，建议另起 issue）。

## Method friction

- **多 agent 同目录冲突（高优）**：开工中途，并行的子任务 B（`feat/sidecar-erlexec-b`）在**同一个主 worktree** 里 `git checkout` 切走了分支，把我的未提交改动卷到了 B 的分支上（reflog 实锤）。已用「path-limited stash 把我的 6 文件从 B 树撤出（不碰 B 的 todo.md/specs）→ 新建隔离 worktree（`.worktrees/localruntime-migration-c`，off 当前 origin/main）→ 干净重做」恢复，B 的树未受影响。**建议：dev-together 的并行 dev 应强制各自独立 worktree，lead 在 plan/handoff 里就把 worktree 分配写死，别让两个 agent 共用主 worktree。**
- **stale `_build` 误导**：`mix ezagent.arch.scan`（:dev）与 test（:test）用**分开的 `_build`**；branch-switch 残留的 stale `_build/dev` 给过一次假读数（off_chokepoint 17 假红）。建议 handoff 提醒「ratchet 前先 `MIX_ENV=dev mix compile`」。
- **本机 uv 让 cc E2E 误跑**：cc 的 `:requires_exec` E2E 用 `@missing_tooling`（uv/python3 在不在 PATH）做 skip 门；本机装了 uv 就会跑，但 bridge 子进程在本地 flake。与本任务无关，CI（runner 无 uv）自动 skip。

## Adversarial review (codex-rescue style, static)

**Verdict: SHIP.** All 7 categories PASS (behavior-equivalence of every swap; no scope leak / dangling alias; contract gate exact; scanner `local_runtime.ex` retained + valid list syntax; manifest arithmetic sound + off_chokepoint=16 justified; both new tests genuinely exercise the migrated lines). Two NITs, both **non-actionable**:
- `openai_chat_plug.ex:198` `{:error, :already_started}` arm is dead — **pre-existing** (`spawn/1` collapses already-running → `{:ok, pid}`); `ensure_started` preserves it exactly. Not introduced here; fixing it = out-of-scope behavior change.
- new tests use stdlib `URI.new!("workspace://…")` not `Ezagent.URI.new!` — reviewer confirms structurally equal here + matches the established green idiom in sibling world tests. No defect.

Code head reviewed + CI-verified: `e33eccdb` (this return doc is a docs-only follow-up commit on top).

## Merge request

- 单 PR（#977），单 commit（`e33eccdb`），已 rebase 到当前 main（`8a6dfa7d`）。
- 与 B 的 `arch_baseline_manifest.exs` 冲突点：**目前未触发**（B 尚未合，origin/main 该文件未变）。若 B 先合并改了 manifest/scanner，我 rebase 后重新 ratchet（call_sites/modules 两条按新实际值；off_chokepoint 仍 16）。
- 请 lead 在 PR head CI 绿后纳入 dev-together 合并；**未自合 main**。
