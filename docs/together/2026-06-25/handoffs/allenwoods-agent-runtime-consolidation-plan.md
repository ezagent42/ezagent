# 规划 — agent 运行时后端整合（allenwoods，clarify-first 前相）

> 回应 @林懿伦 2026-06-25 的 3 个问题 + 总方向。总方向（你定）：**确保所有 agent 的配置接口都收拢到 `domain.agent` 提供的统一入口和注册器**。
> 状态：本文是 clarify-first 的规划（先厘清再动手）；正式开工在当前 docs 落地 + gaga 现状 handoff 之后。

## 0. 先检查的 GitHub PR 状态（相关）
- **#918**（FatNine, OPEN）echo→Entity.Agent + soul：本任务的直接相关项（echo 的 config 接入），落后 main、与 #957 LocalRuntime 冲突，需 rebase + LocalRuntime 决策。
- **#952**（gaga, 已合）= 两份文档：Protocol API 命名/拆分评估 + codex-remote/cc-headless sidecar 生命周期方案。
- 其余 OPEN PR 与本任务无直接耦合（jjkysy #963/#964 dev 工具、FatNine #823/#819/#813 admin-ui、zhaomaota97 #822 loom）。

## 1. 一个关键厘清：「agent 后端(sidecar, api)」其实是**三个不同问题**，别混
| 子问题 | 是什么 | 归属本任务？ |
|---|---|---|
| **A. 配置接口统一 → domain.agent** | 所有 flavor（cc/codex/curl/echo）的 config 接口收拢到 `domain.agent` 的统一入口 + 注册器（registrar） | ✅ **本任务核心**（你的总方向） |
| **B. sidecar 生命周期治理** | 外部 `Port.open` sidecar 退出/重启/崩溃后残留 OS 进程的治理（孤儿回收） | ⚠️ **进程管理问题，和配置统一是两码事**；gaga 在 #952 已有方案（#97）。建议**独立 track**，除非你要把它并进来 |
| **C. LocalRuntime 运行时 chokepoint** | hello/protocol_api/world 还直接调 SpawnRegistry/KindRegistry，未走 LocalRuntime（#99）| ✅ 顺带做（liveness/spawn 收口，与 A 同向） |

## 2. 回答你的 3 个问题

**Q1：echo 的 domain.agent 接入在计划里吗？** → **在，且是 A 的一部分。** echo 目前是独立 Kind、没有 config（这正是 #958 echo 配不了的原因）。#918 让 echo 骑 `Entity.Agent` → 获得 Identity + ConfigEvolve。本任务把 echo 的 config 接口和 cc/codex/curl 一样收拢到 `domain.agent` 的统一入口+注册器。**所有 flavor 的 config 走同一个 domain.agent 入口/registrar，就是 A 的验收。**

**Q2：「cc-headless sidecar」是 cc-headless 独立问题，还是所有 sidecar（含 executor）？究竟是什么问题？**
→ 据 gaga #952：**不是 cc-headless 独立的，是三个外部 `Port.open` sidecar 共有的生命周期问题**：`EzagentPluginCodex.AppServer`、`EzagentPluginCodex.BridgeSidecar`、`EzagentPluginCc.SdkSidecar`。问题=它们退出时只 `Port.close`，杀不掉 `uv→python` / `codex wrapper→vendor binary` 进程树 → 测试/重启/崩溃后残留孤儿进程。
→ **executor（erlexec / 普通 cc PTY）不在问题里——它恰恰是治理得好的「参考样板」**（`:exec.stop` + pid-file + boot-time reaper），#952 明确「不改普通 cc PTY」。
→ **这是进程管理（B），不是配置统一（A）。** 建议：B 作为独立 track（gaga 的 #952 方案 = #97），本任务专注 A+C；如果你要"agent 后端整合"把 B 也含进来，我就把 B 显式纳入并扩大范围——**请你定 A+C 还是 A+B+C。**

**Q3：protocol_api 整合，gaga 昨天的文档是什么？**
→ gaga #952 的《Protocol API 命名与拆分评估》结论：**不拆成 3 个 plugin、不改名 restful-api；保留单 plugin，定位为「LLM Protocol API」（入站 OpenAI/Anthropic wire-protocol 兼容层）**；短期保留 code slug `protocol_api`，UI/文档显示名改 LLM Protocol API，**按 endpoint 拆模块、不按供应商拆 plugin**。它被建模为 **Feishu inbound 的同类物**（HTTP → conversation_id→session → dispatch → 协议形态回复）。
→ 对本任务：**命名/拆分是 #96（你拍板），不在本任务**；本任务只把 protocol_api **起 agent/session 的 spawn/lookup 收口到 LocalRuntime/domain.agent**（C 的一部分）。

## 3. 建议的任务结构（A+C，B 待你定）
1. **前相**：gaga 的后端现状 handoff + 本规划 → 锁定 domain.agent 统一入口/registrar 的形状 + LocalRuntime 是否加带-behaviors spawn arity（#918/#99 共用）。
2. **A-1**：定义/收口 domain.agent 的统一 config 入口 + registrar；把 cc/codex/curl 的 config 接口接上。
3. **A-2**：echo 接入（吸收/协调 #918）—— echo config 走同一入口。
4. **C**：hello/protocol_api/world 的 spawn/lookup → LocalRuntime；arch cap 下调。
5. **验收（四性质 DoD）**：所有 flavor 的 config 都经 domain.agent 统一入口/registrar（parity：4 个 flavor 全覆盖）+ 回归测试 + 全量 mix test 绿 + CI 绿。

## 4. 已拍板（@林懿伦 2026-06-25）
1. **范围 = A+B+C**（配置统一 + sidecar + 运行时收口）。
2. **B 的做法 = 把 3 个 sidecar 从 `Port.open` 迁到 erlexec（根治），不另建 pid-file/reaper。**
   - 根因：原生 `Port.close` 只杀直接子进程，杀不到 `uv→python`/`codex→vendor` 孙子 → 孤儿；而 PTY 路径用 erlexec（`:exec.run`/`:exec.stop` + 进程组 + BEAM 崩溃自 reap）从不留孤儿。三个 sidecar 用 Port 纯属历史不一致，无技术理由。
   - 迁移对象：`EzagentPluginCc.SdkSidecar`（`sdk_sidecar.ex:214`）、`EzagentPluginCodex.AppServer`（`app_server.ex:111`）、`EzagentPluginCodex.BridgeSidecar`（`bridge_sidecar.ex:130`）。**不改普通 cc PTY（已是 erlexec 样板）。**
   - 全用 erlexec 后 gaga #952 的独立 reaper 方案基本不需要（erlexec 自带 BEAM-death reaping）。
   - 风险：每个 sidecar 的 IO 要从 Port 消息改写成 erlexec `{:stdout,...}` + `:exec.send` stdin；先拿一个（SdkSidecar）验证 JSON-line 跑通再推广。
3. **LocalRuntime 加带-behaviors 的 spawn arity = 加**。具体：现在 `ensure_started(%URI{}=uri)` 只按默认起；新增 `ensure_started(uri, init_args)`（init_args 含 behaviors）透传给被 gate 的 spawn，让 echo（#918）走 LocalRuntime 又能带自己的 behaviors（避免直接 `Kind.spawn` 违反 #957 隔离）。#918/#99 共用。
4. **FatNine 今日休息**，不在本任务。

## 5. 落地顺序（A+B+C）
1. **PR-1（beachhead）**：LocalRuntime 加带-behaviors 的 spawn arity（小、core、解锁 #918/#99）。
2. **PR-2（C）**：hello/protocol_api/world 的 spawn/lookup → LocalRuntime；arch cap 下调。
3. **PR-3（A）**：domain.agent 统一 config 入口 + registrar；cc/codex/curl 接上；echo（吸收/协调 #918）接上 —— 4 flavor parity。
4. **PR-4（B）**：3 个 sidecar Port.open→erlexec（先 SdkSidecar 验证）。
5. 每个 PR 走四性质 DoD + CI 绿 + rebase。
