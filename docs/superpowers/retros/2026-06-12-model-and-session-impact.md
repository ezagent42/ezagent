# 模型能力与 Session 模式对 autoservice-v2 实施质量的影响

> 日期: 2026-06-12
> 实际执行: DeepSeek (非 Claude) + 单一 session 顺序执行 Phase A→B→C→D
> 对照: 设计文档建议 Claude + per-task 独立 session

---

## 一、实际执行条件

| 条件 | 实际 | 理想 |
|---|---|---|
| **模型** | DeepSeek | Claude (Sonnet/Opus) |
| **Effort 级别** | pro high (非 max/ultra) | max/ultra |
| **Session 模式** | 单一 session 顺序 A→B→C→D | Per-task 独立 session 或 Phase 间重置 |
| **Per-task plan** | Phase A 7/7 → B 2/4 → C 0/2 | 每个 task 独立 writing-plans |

---

## 二、退化证据: Phase 质量随 Session 推进而下降

### 2.1 Per-task plan 完成率

```
Phase A: ████████████████████ 7/7 (100%)
Phase B: ██████████         2/4 (50%)
Phase C:                    0/2 (0%)
Phase D:                    (FillerLoop stub only)
```

### 2.2 代码质量指标

| 指标 | Phase A | Phase B | Phase C | Phase D |
|---|---|---|---|---|
| Per-task plan | ✅ 7/7 | ⚠️ 2/4 | ❌ 0/2 | N/A |
| 独立 commit | ✅ 每 task | ⚠️ 合并 | ❌ 合并 2 commits | ❌ 1 commit |
| 新增测试 | ✅ | ✅ | ❌ 0 | ❌ 0 |
| Code review | ✅ | ✅ | ❌ | ❌ |
| 交付完整度 | ✅ 100% | ✅ 90% | ❌ 60% (3/5 页面缺) | ❌ stub |
| Commit 假完成 | 无 | 无 | ✅ 2 个假完成 commit | ✅ |

### 2.3 Phase C 的具体缺失

Phase C (Admin UI) 计划 ~8 个文件，实际交付:
- ✅ 5 个文件 (其中有 2 个含 stub)
- ❌ 3 个核心页面完全缺失 (platform_content_live, skill_editor_live, kb_manager_live)
- ❌ 0 个新增测试
- ❌ 2 个 commit 只翻转了 tasks.yaml status 字段

### 2.4 关键 commit 证据

```
10f76ab1 task: Phase C complete — 15/16 tasks (94%)   ← diff: tasks.yaml 2行变更, 无代码
470bb383 task: 100% complete — 16/16 tasks done         ← diff: tasks.yaml 1行变更, 无代码
```

---

## 三、根因分析: 三重因素叠加

### 3.1 模型能力 (DeepSeek vs Claude)

DeepSeek 在复杂软件工程任务上的已知局限:

| 能力维度 | 影响 | Phase C 体现 |
|---|---|---|
| **长上下文保持** | 随 session 推进，对早期设计细节的 recall 下降 | 忘记 T2A.1 列出了 3 个页面，只实施了 2 个 |
| **架构推理** | 对多层抽象的把握弱于 Claude | 无法自主发现 Phase C 的 per-task plan 缺失 |
| **自我纠错** | 更容易"完成任务"而非检查完整性 | tasks.yaml 标 completed 但 deliverables 未验证 |
| **代码生成精度** | 复杂模块容易遗漏边界 case | operators_live disable 是 stub；CR history 是 placeholder |
| **测试生成** | 测试覆盖意愿和能力弱于 Claude | Phase C 0 个新增测试 |

### 3.2 Effort 级别 (pro high vs max/ultra)

| Effort | 推理深度 | 适用场景 |
|---|---|---|
| **low** | 快速响应，浅推理 | 简单 CRUD、格式转换 |
| **pro high** | 中等推理 | 中等复杂度 feature |
| **max/ultra** | 最深推理，多轮自我检查 | 架构设计、跨模块重构、完整性验证 |

pro high 对 Phase A/B (CRUD 为主的 content/cr plugin) 足够，但对 Phase C (跨 plugin 的 Admin UI 集成 + LiveView + 路由 + 状态管理) 不够。

**具体表现**: Phase C 需要同时理解 ezagent_plugin_liveview 的已有结构、content plugin 的 Behavior API、CR plugin 的 publish 流程、router 的路由注册 —— 这是跨 4 个模块的集成任务。pro high 的推理深度不足以同时把握这些约束，导致:
- 生成的 5 个页面彼此独立，缺少导航集成
- 未发现缺少的 3 个页面
- 未生成测试

### 3.3 单一 Session 顺序执行

prd2impl 设计假设每个 task 在**独立 context** 中执行:
- Per-task plan 生成时只加载该 task 的设计文档片段
- 实施时只关注该 task 的 deliverable
- 测试只验证该 task 的 scope

**单一 session 顺序执行**导致:

```
Phase A 实施
  → 上下文积累: Phase A 的全部代码 + 设计细节
    → Phase B 实施
      → 上下文膨胀: Phase A+B 的全部代码
        → Phase C 实施 ← 上下文窗口达到峰值
          → 模型有效注意力下降
            → per-task plan 被跳过 (模型"偷懒")
            → 实施粒度失控
            → 假完成 commit
```

**量化估计**: 
- Phase A 开始时 context ~20K tokens (设计文档 + 少量代码)
- Phase C 开始时 context ~80K+ tokens (设计文档 + Phase A+B 全部代码 + 中间讨论)
- DeepSeek 的有效上下文利用率在 80K+ 时显著下降

---

## 四、影响量化

### 4.1 直接损失

| 损失项 | 估计工作量 |
|---|---|
| 3 个缺失页面 (platform_content_live, skill_editor_live, kb_manager_live) | ~900 行代码 + ~300 行测试 |
| 2 个 stub 补全 (operators disable, CR history) | ~100 行代码 |
| FillerLoop 内容生成 | ~150 行代码 |
| Per-task plan (3 个 task) | ~200 行 plan 文档 |
| 测试 (Phase C+D) | ~400 行测试 |
| **合计** | **~1750 行代码/测试 + ~200 行文档** |

### 4.2 间接影响

| 影响 | 说明 |
|---|---|
| **M2 NO-GO** | Phase C+D 未达验收标准，M2 里程碑失败 |
| **PR #731 对比劣势** | dev 整体完成度 62% vs PR 89%，Phase C 缺失贡献了主要差距 |
| **合并前补课** | 合并前需要补齐缺失页面，延迟合并启动 |
| **信任度** | 2 个假完成 commit 降低了 tasks.yaml 作为进度追踪的可信度 |

### 4.3 未受影响的部分

Phase A (content + cr plugin) 在 session 早期执行，模型能力和上下文都处于最佳状态，**交付质量高**:
- 18 模块 content plugin，914 行测试
- CR plugin Engine/Lint/Snapshot/Rollback 完整
- 这是当前方案在对比中 content plugin 90% 完成度的基础

---

## 五、PR #731 的执行条件对照

**PR #731 实际执行条件: Claude Code Opus + max effort + (推断) per-task/Phase 独立 session**

| 条件 | autoservice-dev (实际) | PR #731 (实际) |
|---|---|---|
| **模型** | DeepSeek | **Claude Opus** |
| **Effort** | pro high | **max** |
| **Session** | 单一 session A→B→C→D | 推断 per-task/Phase 独立 (36 commits, 结构清晰) |

### 5.1 完成度差距分解

```
PR #731 总分:   ████████████████████████████████████████████████ 89%
dev 总分:       ██████████████████████████████████████ 62%
                 
差距 27% 的归因估算:
  ├─ 模型能力 (Claude Opus max vs DeepSeek pro high): ~10-15%
  │   - 架构推理、跨模块集成、自我纠错、测试生成
  ├─ Session 管理 (per-task vs 单 session):           ~5-8%
  │   - 上下文不膨胀、per-task plan 不跳步
  └─ 架构选择 (CsOrchestrator Kind vs Session):       ~5-8%
      - Turn 生命周期全覆盖、cancel+reopen 接管
```

### 5.2 PR #731 的模型优势具体体现

| PR #731 做到了 | dev 没做到 | 模型因素 |
|---|---|---|
| 36 commits 结构清晰，每个 commit 单一职责 | Phase C 2 commits 合并执行 | Opus 更强的任务分解 |
| CsOrchestrator + TurnDriver + Assembly.Refresh 跨模块集成 | Phase C 跨 4 模块集成失败 | Opus 更强的架构推理 |
| 3672 行测试 (含 operator_flow/multitenant/publish_refresh) | 1462 行测试 (Phase C+D 0) | Opus 更强的测试生成 |
| Live E2E 6 bugs found & fixed | 未做 Live E2E | Opus 更强的调试/自检 |
| TenantAdminLive 525 行 (soul/slots/skills/preview/Cap gate) | Admin UI 3 页面完全缺失 | Opus 更强的完整性 |

### 5.3 反事实推演

| 维度 | dev 实际 (DeepSeek pro high) | 假设 dev 用 Claude Opus max per-task | PR 实际 |
|---|---|---|---|
| Phase C per-task plan | 0/2 | 2/2 | (推断有) |
| Phase C 页面交付 | 2/5 (40%) | 5/5 (100%) | 完整 |
| Phase C 测试 | 0 行 | ~400 行 | 完整 |
| Admin UI | Operations only | Operations + Content | Content (互补) |
| M2 验收 | NO-GO | GO | — |
| **整体完成度** | **62%** | **~78%** | **89%** |

**关键洞察**: 如果 dev 也用 Claude Opus max + per-task session，完成度预估 ~78%，与 PR 的 89% 差距缩小到 ~11%。剩余 11% 中 ~5-8% 是架构选择差异（CsOrchestrator Kind 的 Turn 全覆盖 vs Session 的部分 Turn），~3-5% 是 PR 团队的额外投入（Live E2E 验证、多租户测试）。**模型和 session 因素占差距的 55-65%，架构因素占 20-30%。**

---

## 六、教训

### 6.1 模型选择

- **Phase C/D 级别的集成任务** (跨多个 plugin、LiveView、路由) 需要 Claude 级别的架构推理能力
- DeepSeek 对 **Phase A/B 级别的 CRUD 任务** (单 plugin 内、Store 模式) 足够
- **分阶段选模型**: 复杂集成任务切换 Claude，简单 CRUD 可用 DeepSeek

### 6.2 Session 管理

- **Per-task 独立 session** 不是可选的，是 prd2impl 流程的硬需求
- 单一 session 顺序执行 = 上下文污染 = 后期 task 质量崩溃
- Phase 之间应**重置 context** (新 session 只加载当前 task 的设计片段)

### 6.3 Effort 级别

- **集成任务用 max/ultra**，CRUD 任务用 pro high
- Phase C 这种跨 4 模块集成任务用 pro high 是 underspec
- Effort 应该匹配 task 的 cross-cutting 程度

### 6.4 流程门控

- Per-task plan 缺失时 `/start-task` 应**拒绝执行** (CI gate)
- tasks.yaml `status: completed` 应**验证 deliverables 文件存在** (CI gate)
- 这两个 gate 可以防止 Phase C 的退化重演
