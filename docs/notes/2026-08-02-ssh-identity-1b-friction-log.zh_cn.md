# SSH 身份 1b 研发摩擦记录

**日期：** 2026-08-02
**范围：** 任务 1b（把 User SSH 身份物化进 agent），5 个 SDD task
**姊妹篇：** `docs/notes/2026-08-02-ssh-identity-1a-friction-log.zh_cn.md`（1a 那轮）

记录框架 / 规约 / 新旧代码 / 方法论上的摩擦，供后续总结改进。**不是 bug 清单** —— 已修的缺陷在 `.superpowers/sdd/progress.md` 里。

---

## 一、架构 gate 的摩擦

### 1.1 多道文本 gate，豁免规则互不一致

本轮撞上三道基于**文本扫描**的 gate，行为各不相同：

| gate | 机制 | 豁免 `@doc`/`@moduledoc`？ | 有 allowlist？ |
|---|---|---|---|
| `cap_authority_confinement_test.exs` | 字面子串 `"private_key"` 等 | 否（整文件扫） | **有**（4 个 CapBAC 文件） |
| `uri_query` scan 的 `uri_string_key` | 行级：含 `URI.to_string` 且同行有 `%{`/`Map.`/`cap`/`routing`… | **是** | **无**（零容忍） |
| `authorize_chokepoint_ratchet` 的 `:cap_obtaining_entitycaps_load` | 朴素正则 | **否** | 有 |

**实际代价**：
- 有人在 **moduledoc 里写 `EntityCaps.load/1` 这几个字**（纯文档措辞）就触发了第三道
- `private_key` 这个**参数名**在 core 里触发第一道 —— 而它指的是 SSH 私钥，跟 gate 要防的 CapBAC 签名密钥完全无关
- `"granted #{inspect(cap.action)} on #{URI.to_string(user)}"` 这条**日志字符串**触发第二道，只因为 `cap.action` 里有 `cap` 三个字母

**建议**：这三道 gate 的豁免规则应当统一 —— 至少让"文档与注释"在所有文本 gate 里一致地被豁免。现状是每加一个新模块都要靠 `ci.fast` 撞一遍才知道踩了哪道。

### 1.2 tier 边界导致同一概念两种命名

`cap_authority_confinement_test.exs` 的 `@core_lib` 只扫 `apps/ezagent_core/lib`。于是：

- `Ezagent.Credential.GitIdentityRuntime`（**core**）被迫把参数叫 `key_pem`
- `Ezagent.Identity.AgentGitIdentity`（**domain**）可以正常用 `private_key`（也确实该用 —— 那是 1a action 返回值的字段名）

**同一个东西在相邻两层有两个名字，理由纯粹是 gate 的扫描范围。** 改名本身是对的处置（别加宽 grep），但这个约束**没有任何地方成文** —— 我们是靠 ledger 手工把这条带给下一个实现者的。

**建议**：要么给该 gate 加一条"外部凭据（非 CapBAC 签名材料）"的显式豁免机制，要么把这条约束写进 `ezagent-developer` SKILL。

### 1.3 ratchet 的正确用法在本轮被验证了三次

三处 allowlist/ratchet 改动（`cap_signing_architecture_test.exs`、`authorize_chokepoint_ratchet_test.exs`、`cap_self_store_paradigm_lock_test.exs`），**每一处都是"登记新站点的精确计数"，没有放宽任何断言逻辑**。

这与 memory `reference-arch-gate-enforcement-patterns` 的排序一致（编译期边界 > ratchet 冻结现状 > AST 污点 > 诚实降级）。**值得作为正面案例保留** —— 三个不同的实现者独立做出了同样正确的选择，说明这条原则已经传达到位。

---

## 二、既有代码 / 契约的摩擦

### 2.1 `Task.async` 是 link 的 —— 同一个坑在 1a 和 1b 各踩一次

1a 的 `keygen/1` 最终把 `rescue` 放进 `Task.async` 的函数**内部**，因为 `System.cmd` 抛异常会先把调用者带走。

1b 的 `ssh-keyscan` 包装**原样重犯**：`rescue e in ErlangError` 写在 `Task.async` **外面**，是不可达死代码；`ssh-keyscan` 未安装时任务以裸 EXIT 崩掉，而不是给出设计好的错误。

**这不是实现者的问题** —— 我的 brief 就是这么写的。**建议**：`ezagent-developer` SKILL 的 debug-recipes 加一条「`Task.async` + `System.cmd` 的 rescue 必须放在 task 函数内部」。

### 2.2 `rescue` 不接 exit，而 `Invocation.dispatch` 故意 re-raise

`invocation.ex:488-490` 对 `:timeout` EXIT 与 handler crash EXIT **故意 re-raise**（注释写明"masking it would hide a genuinely stuck handler"）。

任何声称"never raises"的调用方**必须同时写 `rescue` 与 `catch :exit`**。本轮 Task 3 漏了 `catch`，被终审抓到。1a 的 M2（`@keygen_timeout_ms` 与 dispatch 默认 deadline 的耦合）是同一个根因的另一面。

仓库里已有正确模板：`execution_seam/cap_backed.ex:183-187` 的 `dispatch_catching_exit/1`、`invocation.ex:400-408`。**建议**：把这条写进 SKILL —— 它已经在本项目造成过两次缺陷。

### 2.3 `SpawnRegistry` 对 `user` 类型 URI 无条件 spawn

`application.ex:838-867` 对 `{:ok, "user"}` 无条件 `Kind.spawn(User, ...)`，而 `User.initial_caps_for_spawn/1` 对未知 URI 返回空集而不报错。

后果：**任何拿着一个打错的 user URI 的运维工具都会凭空拉起一个 phantom User Kind**，并且看起来一切正常。本轮的 grant task 因此会对一个不存在的 user 铸出真 cap 并报告成功。

正确原语是 `Ezagent.LocalRuntime.ensure_live/1`（对 never-created URI 返回 `{:error, :not_created}`）。**建议**：审一遍还有多少运维路径用了 `ensure_started` 而该用 `ensure_live`。

### 2.4 `Ezagent.URI.segment!/1` 只拒空串和 `/`

于是 agent 名可以含 `$`、`(`、`)`、`;`。任何把 URI 段拼进 shell 字符串的地方都要自己引号 —— 本轮 `GIT_SSH_COMMAND` 就是**全仓唯一一处拼 shell 字符串而非 argv 列表**的地方，没有任何既有约定保护它。

（更现实的触发不是恶意名字，而是 `EZAGENT_HOME` 里有个空格 —— 本机是 WSL，`/mnt/c/Users/John Doe/` 完全可能。）

---

## 三、测试环境的摩擦

- **Postgres 端口**：本机 15432，`config/test.exs:63` 默认 55432。不设 `POSTGRES_PORT=15432` 会以**连接超时**失败，不是明确的端口错。（1a 已记录，本轮每个 dispatch 都要重复叮嘱一次）
- **`build_pty_params_for_env(_, cwd, _, :test)` 在 test env 直接短路** —— cc PTY 的 spawn seam 在测试里**根本不可达**。这让 Task 5 的接线一度零覆盖而不自知（删掉整段功能，全套 cc 测试仍绿）。绕行办法：`CcAgent.build_claude_cmd/3` 可以直接调，既有先例 `cc_custom_backend_test.exs:427`
- **`mix ci.local` 会卡在 tailwind 下载**（代理环境），两个不同的实现者各撞一次
- **全量并发跑（~3500 测试）下三条测试因 Postgrex 连接池耗尽而 flaky**，单跑 100% 通过

---

## 四、方法论观察

### 4.1 三段式红演示的产出，第二次被验证

要求「改坏 → 贴真实红色输出 → `git diff` 空证明逐字节还原 → 贴绿」，配合一句「**改坏之后如果仍然绿，那是真实发现，报告，不要硬凑**」。

**五个 task，每一个的实现者都靠这一步抓出了我（计划作者）的一处错**：

| Task | 抓到的 |
|---|---|
| 1 | 一条**恒真**的断言（比较两个具名函数捕获，永远不相等） |
| 2 | 我的红演示指令不精确（字面照做全绿） |
| 3 | 一个**不存在的 API**（`Ezagent.Identity.revoke_cap/2`）；以及"错误不合并"这条不变式**零测试覆盖** |
| 4 | 我写反的 `ssh-keyscan` 退出码前提；我数少了违规站点（说 2 处实为 4 处） |
| 5 | 我给的退路**不满足它自己的验收标准**（关闭态断言对"整段删除"零鉴别力） |

### 4.2 两道独立复审，每一轮都各自找到对方漏的

| Task | codex 独有 | opus 独有 |
|---|---|---|
| 1 | "钉住接线未钉住结果" | M2–M4 三条 |
| 2 | 陈旧 key 残留 | **写入顺序把私钥搁浅**（真跑 `:eisdir` 复现） |
| 3 | exit 不被捕获 | **多 cap 时静默取任意一条**；并**推翻了我判的一个 Critical** |

**没有一轮是"其中一道足够了"。** 但也要记：opus 那轮推翻我的 Critical，靠的是**去查上游契约**（1a 的 `valid_private_key?` 守卫），而我只查了本地代码 —— 这是 codex 与我共同的盲区。

### 4.3 per-task 复审看不到跨 task 累积的 gate 红

`uri_query` scan 的新红**跨 Task 3 与 Task 4 共 4 处**，两轮 per-task 复审都没抓到 —— 因为每轮的 review 包只含本 task 的 diff。最后是 **Task 5 的实现者跑全量时撞上的**。

**建议**：SDD 流程里每个 task 结束时（而不只是分支结束时）跑一次 `mix ci.fast`。本轮成本约 1–2 分钟，远低于让它漏到终审。

### 4.4 最贵的缺陷是设计缺陷，不是代码缺陷

本轮改动最大的一条不是任何代码 bug，而是**设计文档 §1.3 的一句论证是假的**：

> "每次 spawn 写 → 撤销在下次重启生效"

—— cap 撤销后走的是"不写"这条路，而原设计里**没有任何东西删掉盘上的 key**。三条独立发现（codex 的 known_hosts 残留、opus 的写入顺序、我顺着查出的 `{:ok, :none}` 分支）汇到一起才看清全貌，最终新增了 §6.1 清理规则表。

**同类还有两条**：§1.2 关于"共用 authority 函数会导致 `cp_r` 泄漏"的论证在当前代码下不可达（真正的理由是别的）；§8 的"非 admin 调用被拒"描述了一个**没有参数可查、也没有先例**的检查。

**观察**：三条都是**论证错了但结论对了**。设计文档里"为什么"那部分比"做什么"更容易写错，且更不容易被测试抓到 —— 它只会误导下一个读者。
