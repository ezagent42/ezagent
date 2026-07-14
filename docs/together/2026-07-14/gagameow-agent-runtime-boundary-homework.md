# gagameow 今日作业 · AgentRuntime 边界与 demo agent 凭证

日期：2026-07-14

负责人：黄佳佳（`gagameow` / `gaga`）

日计划：`docs/together/2026-07-14/plan.md`

设计：`docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md`

实施计划：`docs/superpowers/plans/2026-07-14-agent-runtime-boundary.md`

## 1. 作业目标

本作业服务 W29 统一 demo 的第三条使能结构：收敛 agent 控制面边界，使
Session 面不再直接负责 agent 的物化、复活、就绪、停止、销毁和凭证/config
应用。

作业分成两个独立交付轨：

1. **代码轨：AgentRuntime 边界 SPEC + `agent_runtime_boundary` 静态 gate。**
   在 `spec/agent-runtime-boundary` 分支完成，形成独立 PR。
2. **运维轨：demo agent 凭证下发 + 脱敏实证。**不进入代码 PR，不提交凭证、
   凭证哈希、环境变量或敏感路径。

两轨独立验收。代码轨通过不代表凭证轨完成；凭证文件存在也不代表 agent
已经可以从正式产品入口调用。

## 2. 已批准的架构方案

采用 **domain-agent 窄 Facade + command-shaped API**：

- `AgentRuntime` 是 `ezagent_domain_agent` 所有的控制面边界概念，不是在 core
  新建的通用模块或进程。
- core 的 `Ezagent.LocalRuntime` 继续保持 URI-only、Kind/flavor-agnostic。
- Session 只声明会话成员、路由、投递和退出意图，通过 domain-agent 的公开
  Facade 请求 agent 控制操作。
- domain-agent 负责 agent 的 materialize、ensure-live、readiness、restart、
  retire/destroy 和 credential/config application 的编排边界。
- flavor plugin 继续负责 cc/codex/py 等执行机制，不新增 Command Bus、Port
  behaviour 或 adapter registry。
- 只有未来出现至少两种独立 runtime controller，且现有
  Invocation/Lifecycle 无法承载时，才重新评估 Port/Adapter。

## 3. 代码轨作业清单

### 3.1 现状与边界 SPEC

- [ ] 定义五层词汇：definition plane、agent control plane、execution adapter、
  session conversation plane、core Kind locality plane。
- [ ] 写清 `domain_session → domain_agent → core` 的所有权和依赖方向。
- [ ] 列出 Session 域中所有 agent 生命周期直接触点，并逐项分类：
  - agent 物化；
  - cold agent 复活；
  - executor/sidecar 启停；
  - agent destroy/retire；
  - sandbox/config/credential/readiness 控制；
  - 合法的 membership、routing、dispatch、非激活式读取。
- [ ] 形成允许/禁止矩阵，不能把所有 Session→Agent 引用一刀切禁止。
- [ ] 明确既有 `Ezagent.Domain.Agent` 从 Session app 迁到 Agent app 的方向。
- [ ] 明确本轮不在 core 新建 `Ezagent.AgentRuntime`。
- [ ] 明确实现分期和 debt ratchet 到零的路径。

### 3.2 `agent_runtime_boundary` gate

- [ ] 扫描 `apps/ezagent_domain_session/lib/**/*.ex`，自动覆盖未来新增文件。
- [ ] 使用 AST 识别模块调用和 alias，不用 grep/纯文本总数充当最终 gate。
- [ ] 检查生命周期 API 族，而非禁止全部 Registry/Lifecycle 使用。
- [ ] 使用精确 allowlist：路径、调用类型、源码锚点、理由。
- [ ] 校验 allowlist stale entry，旧违规消失后必须删除对应条目。
- [ ] 种入全限定调用违规 fixture，证明 gate 会失败。
- [ ] 种入 alias 调用违规 fixture，证明不能靠 alias 绕过。
- [ ] 保留合法 Session destroy、SessionTemplate spawn、membership lookup 的
  negative fixtures，证明 gate 不会 blanket-ban。

### 3.3 评审与机器闸

- [ ] SPEC 先做 Codex 对抗评审，覆盖架构方向、分层、边界、漏报、误报和
  可绕过性。
- [ ] 对抗评审结论达到 `SOUND` 后再交 lead。
- [ ] 跑 gate 专项测试。
- [ ] 跑 core architecture + invariants。
- [ ] 跑 `mix ezagent.arch.scan`、`mix ezagent.check_invariants`。
- [x] 最终跑 `mix precommit`。
- [ ] PR head CI 绿，并 rebase 到当前 `origin/main`。

## 4. 运维轨作业清单

### 4.1 盘点

- [ ] 从已认证 World 管理面获取当前 demo agents 清单；仓库里的名字不是部署
  现场权威清单。
- [ ] 过滤 credential-bearing flavors。
- [ ] 通过 cap-gated credential status 查看 `missing`、`expired`、
  `authenticated`，不读取凭证正文。
- [ ] 至少核对 `test-zyli-cc-1`，并记录是否还有其他缺凭证 agent。

### 4.2 下发

首选路径：进入目标 agent 的正式 Terminal，在该 agent 自己的 config home 中
执行 `claude /login`。

仅在 demo/operator 已有合法 credential source 时，才使用受支持的辅助任务：

```bash
mix ezagent.demo.seed_cc_sandbox \
  --name <agent-name> \
  --sandbox-dir <detail-reported-config-dir> \
  --credentials-file <operator-owned-source>
```

约束：

- `config_dir` 必须来自当前 agent detail，禁止根据旧日志猜 `/data/...` 路径。
- 默认不使用 `--force`；覆盖前必须先查明现有文件状态和 lead 授权。
- `mix ezagent.credential.adopt` 只建立未来 materialization 的默认来源，不是
  修复既有 target agent 的直接手段。
- 禁止 raw RPC、任意 eval、直接 DB setter 或绕过产品/CLI 的临时脚本。

### 4.3 脱敏验收

- [ ] 下发前状态为 `missing` 或 `expired`。
- [ ] 下发后 credential status 为 `authenticated`。
- [ ] 从正式产品入口调用目标 agent，得到真实回复 transcript。
- [ ] 重启目标 agent 后再次调用成功，证明凭证持久。
- [ ] 证据只包含 agent URI、flavor、状态、检查时间和脱敏 transcript。
- [ ] 证据不包含凭证正文、hash、token、env dump、shell trace 或敏感路径。

## 5. Definition of Done

### 代码轨

1. **Goal-derived：**SPEC 和 gate 覆盖完整 agent 生命周期所有权，而不是方便
   扫描的几个字符串。
2. **Verifiable：**每条边界有源码 inventory 或 fixture；gate 有正反例；完整
   gate 与 CI 通过。
3. **User-facing：**SPEC 说明边界如何避免 Session 阻塞、误复活、误销毁 agent，
   并保护正式调用链。
4. **Closed set：**所有列出的违规点都被迁移、精确 allowlist 或 lead 明确延期；
   开发者不得自行删除 DoD 项。

### 运维轨

1. 部署现场的 credential-bearing demo agents 已完整盘点。
2. 缺凭证 agent 已通过正式路径下发或明确列出阻塞。
3. `test-zyli-cc-1` 从缺凭证状态转为可正式调用，或提供可核验阻塞证据。
4. 已证明重启后仍可调用。
5. 全部证据脱敏，无秘密进入 Git。

## 6. 明确不做

- 不在本轮完成 AgentRuntime 全量迁移。
- 不在 core 新建泛化 `Ezagent.AgentRuntime`。
- 不引入新的 Command Bus、Port behaviour 或 adapter registry。
- 不把 `test-zyli-cc-1` 的凭证缺失重新解释为 933 次 crash-loop 根因。
- 不承担 hello E2E、hello↔kanban 融合或 #1360 Layer B 实现。
- 不把 live credential provisioning 混入 `spec/agent-runtime-boundary` PR。

## 7. 并行策略

适合并行的只读/独立工作：

- 生命周期触点 inventory 与分类；
- gate AST matcher/fixture 研究；
- SPEC 分层与所有权对抗评审；
- 部署态 credential inventory 与证据模板。

必须由单一实现者串行负责的共享面：

- gate scanner、allowlist 和 gate 测试；
- 既有 `Ezagent.Domain.Agent` 的迁移与公开 API 命名；
- 同一目标 agent 的凭证写入和重启验证。

## 8. PR #1375 / #1379 基线裁定

本作业采用“**语义立即吸纳，代码不直接叠分支**”策略：

- PR #1375 定义 agent 的 Manage cap 携带 PTY 看、写、重启，并把 PTY read
  policy 收敛到 `Ezagent.Domain.Pty.Access`。它是创建者从正式 Terminal 执行
  `claude /login` 的硬前置。
- PR #1379 把 `users.caps_json` writer 接回 `Ezagent.Cap.issue/3`，补齐
  ISSUE→STORE→VERIFY chokepoint。它是后续 Agent Facade authority 设计的安全
  基线，但不是 ARB-0/ARB-1 scanner 的编译依赖。
- 两个 PR 都从 `main` 独立分叉、互不为祖先，当前也都仍需 review。因此本任务
  不 cherry-pick、不 merge PR head，也不从其中任一 PR branch 起分支。

### 两个 PR 合入前可执行

- 更新 SPEC 中的 PTY ownership 与 Cap.issue 约束；
- 建立不依赖最终行号的生命周期 API inventory；
- 用 TDD 建 AST scanner 的正反 fixture；
- 准备 credential 脱敏验收模板。

### 必须等待 #1375

- 冻结涉及 `session_creator/materializer.ex` 的最终行号/源码锚点；
- 执行创建者 Terminal → `claude /login` 的正式凭证验收；
- 验证未授权用户不能读取登录过程；
- 验证创建者能看、写、重启自己的 agent PTY。

### 必须等待 #1379

- 实施任何会 issue/store capability 的 Facade 切片；
- 冻结 Facade authority/provenance 的最终接口；
- 对新增 cap writer 做最终 invariant 评审。

两个 PR 合入后，本分支先 rebase 到最新 `origin/main`，重跑 inventory 和全部
gate，再进入正式 return。

## 9. 执行状态

### 已完成

- [x] ARB-0 生命周期 inventory：34 行闭合表；primary search 76 = 28 个
  executable expressions + 48 个 prose/history hits；混合 target wrapper 按调用
  边分类。
- [x] ARB-1 scanner fixture 骨架：qualified、alias、parent alias、声明顺序、
  module/function/block、sibling `case/cond/fn` clause 词法作用域均有 fixture。
- [x] 合法反例：Session destroy、SessionTemplate ensure-live、member dispatch、
  Kind lookup 不会被 blanket-ban。
- [x] credential 脱敏验收模板已准备。
- [x] PR #1375（`ca65f5266`）与 #1379（`6ee6e8af1`）均已合入；工作分支已
  rebase 到最新 `origin/main`，没有直接吸纳未审查 head。
- [x] Task 3 exact repository gate：动态扫描全部 Session production source，
  使用 24 项 exact allowlist，逐项 stale/duplicate/schema 检查，并覆盖已知绕过。

实现提交：

- `f161a75b3` — 初版 inventory 与批准文档；
- `2b3be5120` — 补 aliased executor call 与混合 wrapper 调用边；
- `9382d19bd` — 统一 inventory 记账；
- `2996c4f68` — Task 2 AST scanner + 词法 alias fixtures；
- `f9bcd30d4` — Task 3 exact allowlist、repository gate 与绕过回归测试。

### 下一步与阻塞

- [x] Task 4：ownership、allowlist bypass、false positive 独立攻防复核完成，
  verdict `SOUND`；grouped alias、import、option-bearing grouped alias 绕过均已关闭；
- Task 5：汇总最终 gates 与 return evidence；
- creator Terminal live acceptance：只读 canary 检查已证明 #1375 部署在
  `ezagent:22d966b04`，公网 health 200。`test-zyli-cc-1` 已启动 Claude 并加入
  agent bridge，说明 credential-bearing runtime 存在，但停在未识别交互对话框；
  尚未完成正常产品调用和 restart persistence，且本轮未获线上写操作授权；
- capability-issuing Facade slice：#1379 chokepoint 已就绪，在 Task 4 gate review
  后仍不得直接进入 authority-persisting 实现。PR #1381 证明该 chokepoint 只枚举
  静态可解析调用，不能证明运行时所有 cap 都来自 `Ezagent.Cap.issue/3`。#1382
  已将 structural enforcement 锁定为 Ed25519 signed artifact；本 slice 等待其
  P1–P6 实现及迁移状态，不吸纳 #1381 的 ETS fingerprint 草案；
- Task 5 post-rebase 验证：focused 23/23、`arch.scan`、`doc.scan`、
  `check_invariants` 通过。确认 4 条 `probe-*` workspace 仅是本机共享 test DB
  的无价值旧测试残留后，已精确事务删除并复核残留为 0；workspace visibility
  invariant 10/10 通过，最终 `SHELL=/bin/bash mix precommit` exit 0。该清理未访问
  或修改 canary/线上数据。

## 10. 新增任务：Caps 真相源与 fail-closed 治理

### 10.1 审计结论

canary 实测发现新建 agent 的 creator Manage cap 已进入在线 Identity slice，
但 `LiveAuth` 仍从 `users.caps_json` 读取权限，导致 World 页面与 Terminal 的授权
判断不一致。局部修复已将 LiveAuth 收敛到
`Ezagent.Identity.read_entity_caps/1`；该 reader 负责 live slice → durable snapshot
回退，并在读取边界执行 receiver-aware `Ezagent.Cap.verified_set/2`。

全局审计同时登记以下后续问题：

| ID | 优先级 | 问题 | 风险/验收方向 | 状态 |
|---|---:|---|---|---|
| CAP-SOT-0 | P0 | LiveAuth 使用旧 `users.caps_json` | 热态先从 receiver-aware verified reader 取当前权限；`EntityCaps` facade 落地后迁到统一 facade，覆盖 cold User/Agent | 热态修复及 post-rebase 验证完成，待 facade 迁移 |
| CAP-SOT-1 | P0 | User/Agent 有两个物理 durable store，调用方容易选错 | 遵循 #1394 lead-locked 方案：User=`caps_json`、Agent=snapshot，统一经 `Ezagent.EntityCaps` facade；不做物理 SSOT 大迁移 | 已被 entity-caps scoped D 接管，待合入 |
| CAP-SOT-2 | P0 | grant/revoke 与 User `caps_json`/live slice 未形成统一持久化语义 | 通过 `EntityCaps.grant/revoke/persist` 保证 revoke 后 cold restart 不复活，并补 grant→revoke→stop→restart 回归 | 已被 entity-caps scoped A/D 接管，待合入 |
| AUTH-FAIL-1 | P0 | `HomeLive` 对异常或过期 identity cookie 回退 admin URI | malformed/stale cookie 必须 fail closed，清 session 或跳转登录，绝不获得 admin principal | 待独立修复 |
| CAP-READ-1 | P1 | `member_cap.ex` 的 snapshot cap 幂等读取未 verify | 改用 verified reader 或把该读取封装为非授权用途，并用 gate 防止被授权路径复用 | 待处理 |
| CAP-DISPLAY-1 | P2 | World 用户列表 `cap_count` 读取旧 `users.caps_json` | 展示与真实 verified caps 一致；不得影响授权语义 | 待处理 |
| CAP-BOUNDARY-1 | P1 | email inbound 构造固定 ephemeral self-cap，未走 issue/verified-set | 明确为受控边界例外并加 invariant，或迁移到正式 issuance reader | 待裁定 |
| CAP-PROVENANCE-1 | P0 | Phase-4 已签发 Ed25519 artifact，但仍处于 dual-read | #1399 已合入；完成 no-tail 重签、审计 unsigned=0 后才允许 `require_signature:true` | 机制已合入，迁移/enforce 未完成 |

补充约束：`origin/main` 的 #1399 已使新 `Cap.issue/3` 产出 receiver-bound Ed25519
签名，并使 `verify/1` 校验签名；但默认仍为 `require_signature:false`。unsigned
legacy Caps 会走 telemetry 标记的兼容读取，因此当前只能表述为“签名机制已落地、
生产仍在 dual-read 迁移期”，不能表述为“全链只接受密码学验证的 Caps”。真实
canary 数据审计显示旧 EventLog backfill 仅能处理 196 个 Caps 中的 6 个，no-tail
必须走正常 `Cap.issue/3` 重新授权/重签，而不是盲签或继续修补该 backfill。

### 10.2 处理顺序与拆分

1. **先 rebase 并重审 CAP-SOT-0（当前分支，已完成）：**保留 canary 差异回归，
   并按 #1399 的 receiver-bound signature 重新验证；在 `EntityCaps` 尚未落地时
   不得把 `read_entity_caps/1` 宣称为 User/Agent 最终统一 SSOT facade。
2. **跟随 entity-caps scoped A/D 关闭 CAP-SOT-1 + CAP-SOT-2：**不另造第三套
   reader。D 统一 `load/persist/grant/revoke` API，A 提供 grant/revoke durable retry；
   合入后将 LiveAuth 迁到 facade，并补 online/cold/restart 矩阵。
3. **并行独立处理 AUTH-FAIL-1（独立安全修复 PR）：**不依赖 Caps durable
   truth 设计，可直接按 fail-closed 原则 TDD；优先级与 CAP-SOT-1/2 同为 P0。
4. **随后处理 CAP-READ-1 + CAP-DISPLAY-1：**先封住非 verified reader 的复用
   风险，再统一 UI 读模型；不得以展示修复替代授权修复。
5. **单独裁定 CAP-BOUNDARY-1：**确认 email inbound 的 authority provenance 后再
   决定 gate exception 或正式迁移，不与前述 PR 混改。
6. **CAP-PROVENANCE-1 执行 no-tail 升级：**#1399 机制不再等待；按 #1400/#1401
   handoff 逐类验证正常 re-derive 是否签名，对 stored User Caps 经 `Cap.issue/3`
   重签并重写，最终 audit unsigned authorizer caps = 0 后才翻
   `require_signature:true`。

每个 P0 任务的共同 Definition of Done：

- 授权决策只消费 verified caps reader，不直接消费 `users.caps_json`；
- 覆盖 online、cold、grant、revoke、restart 五类状态转换；
- malformed/stale identity 输入 fail closed；
- focused tests、capability invariants、`arch.scan`、`check_invariants` 和
  `mix precommit` 均通过；若基线污染阻塞，必须提供纯 main 对照证据，不得标完成。

### 10.3 当前日任务汇总

#### 已完成

- ARB-0 inventory、ARB-1 scanner fixtures、Task 3 exact gate 和 Task 4 独立攻防
  复核（`SOUND`）。
- PR #1375/#1379 合入后的 rebase 与语义复核。
- 已 rebase 到包含 #1399/#1400/#1401 的最新 `origin/main`（`be23fcf97`），PR
  #1402 创建时分支 ahead 17、behind 0；LiveAuth 回归已按 receiver-bound Ed25519
  签名重审。
- canary 上复现 LiveAuth/Terminal capability 差异并定位到双读取源。
- CAP-SOT-0 热态代码与 User/Agent 回归测试已实现；focused capability gates、
  `arch.scan`、`check_invariants`、`git diff --check` 已通过。
- Caps 全局读取/冷启动/fail-open 审计完成，本节新增任务已登记并排序。
- #1399 Ed25519 signing 已在 `origin/main`；已确认当前是 receiver-bound signed
  issue + dual-read verify，而不是 enforce 模式。
- 本地共享 test DB 的 4 条 `probe-*` 旧 workspace 已精确事务清理；visibility
  invariant 10/10、最终 `SHELL=/bin/bash mix precommit` 均通过（exit 0）。

#### 未完成

- CAP-SOT-0 热态修复已随 PR #1402 提交；`EntityCaps` facade 合入后还需迁移
  LiveAuth 并补 cold User、grant/revoke/restart 完整矩阵。
- Task 5 return 已形成，尚待 PR #1402 protected CI URL/状态回填。
- creator Terminal 的正常产品调用、credential authenticated 状态和 restart
  persistence 验收尚未完成。
- CAP-SOT-1/2 等待 entity-caps scoped A/D；AUTH-FAIL-1、CAP-READ-1、
  CAP-DISPLAY-1、CAP-BOUNDARY-1 均未实施。
- CAP-PROVENANCE-1 的签名机制已完成，但 no-tail 重签、真实数据审计
  unsigned=0、`require_signature:true` enforce flip 均未完成。
