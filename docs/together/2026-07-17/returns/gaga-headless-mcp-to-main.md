# Return: 任务 A —— #1323 headless-MCP 落 main

> **returned_at:** 2026-07-17 17:30 (+0800) · **deadline:** handoff 未设 · **deadline_status:** on_time
> **From:** gaga · **To:** jjkysy (lead) · **Handoff:** `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §3
> **Branch:** `fix/1323-headless-mcp-to-main`（7 commits，off main @ 66734aae5）
> **e2e 证据:** `docs/e2e/2026-07-17/headless-mcp-kanban/`（README 含完整时间线 + invocations 表证据）

## DoD 逐行对账

| Handoff DoD | 状态 | 证据 |
|---|---|---|
| 真 UI e2e：装 kanban sw → @assistant 加节点 → 板上见节点（截图+transcript，非 stub） | ⚠️ **达成但有两处如实标注** | 9 张截图 + agent transcript + invocations 时间线。① dispatch 不经 esr-bridge 而经 **CLI 身份**（recipe #1425 明文"no MCP kanban tools, use CLI"；esr-bridge 只有 reply 一个 tool，且 `Channel.verify_transport_class` 按设计拒 `:in_process_sync` 的 WS join —— handoff DoD 措辞与 recipe 的矛盾，非实施选择）。② "turn 内全自动写入"被发现 4（in-turn 自身份 caps 读死锁）卡住：turn 内 dispatch **授权已证**（round-3 `get_tree`×2 + `add_node` 全 granted），完整写入以**同身份 turn 外**执行证明（`{:ok, %{id:"n2"}}`，板画布见「登录表单」）——已透明标注 |
| 回归测试锁 "config_dir 有 .mcp.json → worker options 出现该 server" | ✅ | 三层锁：python unittest 6 case（`resolve_mcp_config` route B）+ `SdkSidecarEnvTest`（env 契约）+ `CcHeadlessAgentTest`（params threading） |
| 桥脚本路径断言：不含 worktree/repo 绝对路径 | ✅ | `McpConfigWriterTest`：写出的每个 script path 必须派生自 `Application.app_dir` 且 `refute =~ /apps/ezagent_plugin_cc/` |
| gates：arch/doc/uri_query/check_invariants/format/test/plugin_check | ✅* | 全绿；*两个 main 已知基线原样：`uri_query.scan` 1 violation（`skill_reconcile.ex:142`）+ `skill_distribution_prod_shape_test`（本地 seed/runtime mismatch）——均在 clean main 复现，#1445 verification 有记录 |
| CI 绿 on PR head + rebase main | ⏳ | 分支已 push；PR 见下，等 CI |

## 交付内容（超出 #1323 原 diff 的部分全部有 live 证据驱动）

1. `2cad2670f` — **#1323 读侧原样落地**（Allen route B + python tests，保留 #1434 plugins 块，co-author 保留）
2. `af1dbc860` — **CLI 身份 env 接进 headless cmd_env**（复用 `SpawnPlan.maybe_put_cli_identity_env/3`，#1323 commit message "cmd_env seam" 的当代形态；kanban e2e 的真正 enabler）
3. `700b7104a` — 三层回归锁 + 桥路径断言（DoD 2/3）
4. `b088c79de` — **sidecar 自建 cwd**（fresh host crash-loop，live 发现）
5. `539a1c8f5` — **permission_mode 默认 bypassPermissions**（PTY parity；default 模式下 headless 无人应答 prompt，skill 完全无法执行——transcript 实锤）

## 别人 lane 的发现（不修，只报）

- **kanban lane（jjkysy）**：① fresh 安装 assistant 零板钥匙且无补发面（`BoardProvision.create_board/5` 无生产 caller；e2e 用 sanctioned `mix ezagent agent grant_cap` 补发）——任务 B/⑩ 供给面家族；② per-node admin 门实际要求 **`kind: :any`** cap（skill 文档"admin-wildcard"该写清）；③ seed 版 `kanban-cli.sh` 硬编码 `/home/yaosh` cookie 路径 + `mise`
- **平台/Allen**：④ dev 环境 `socialware_manifest_boot_scan` 仅 prod（config.exs:29），本地 dev 栈装不出 kanban；⑤ `mix ezagent.bootstrap`/`home.init` 在 task 环境 ETS 未起即用 `Ezagent.URI.new!` 崩

## Open decisions（等 Allen）

1. **headless × esr-bridge**：`:in_process_sync` flavor 要不要 WS join 通道（reply 工具对等）？现按设计被 `transport_class_mismatch` 拒；本任务未给 headless 物化 esr-bridge。
2. **turn 内 CLI 自身份 caps 读**：`:identity_read_unavailable`（e2e README 发现 4，invocations 有 4.18s×3 证据；Kind 空闲时同命令 100% 成功）。「cli+skill 范式」×「阻塞式 in_process_sync」结构冲突。
3. **headless turn 120s 超时丢结果**：`SdkSidecar @default_timeout 120_000`，长 turn 结果丢失无 DLQ（发现 3）。

## Method friction（供 review 的 method-deltas）

- handoff DoD 引用的"经 esr-bridge dispatch"与 #1425 recipe 已经矛盾——handoff 写作时点早于对 recipe 的重读；建议 handoff 模板的 DoD 行强制引用 SoT 文件行号。
- 本地 dev 栈跑 socialware e2e 的完整环境适配步骤已沉淀在 e2e README（manifest scan gate / PAT pepper / 分布式节点 / world SPA build），可提炼进 `docs/guide/`。
