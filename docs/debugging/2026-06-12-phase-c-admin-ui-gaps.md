# Phase C Admin UI 缺口调查 — 2026-06-12

## 结论

**Phase C 任务未漏跑，是 prd2impl 执行流程在 Phase C 出现了多重退化。**
具体：per-task plan 缺失 → 实施粒度失控 → 验证跳过 → tasks.yaml 过早标 completed。

## 执行流程偏差分析

### prd2impl 标准流程 (Phase 2 Task Execution)

按 prd2impl 设计，每个 task 应走：

```
/start-task <ID>
  → superpowers:writing-plans → 生成 per-task plan (docs/superpowers/plans/<DATE>-<ID>-*.md)
  → superpowers:test-driven-development → 红/绿/重构节奏
  → superpowers:requesting-code-review → 独立 code review
  → 更新 tasks.yaml status: completed
```

### 实际执行对比

| 流程步骤 | Phase A (T0A.1-T0A.8) | Phase B (T1A.1-T1A.4) | Phase C (T2A.1-T2A.2) |
|---|---|---|---|
| Per-task plan 文件 | ✅ 7/7 tasks 有 | ⚠️ 2/4 tasks 有 (T1A.1, T1A.3) | ❌ 0/2 tasks 有 |
| Per-task 实施 | ✅ 每个 task 一个 commit | ⚠️ 合并执行 | ❌ 合并执行为 2 个 commit |
| 测试验证 | ✅ mix test 绿 | ✅ mix test 绿 | ❌ 无新增测试 |
| Code review | ✅ (推断) | ✅ (推断) | ❌ 无 |
| Commit 标记完整度 | ✅ T0A.x 编号 | ⚠️ T1A.x 编号 | ❌ T2A.2 编号出现在 commit 但内容不完整 |

**Phase C 是唯一完全没有 per-task plan 文件的 phase。**

### Per-task plan 文件存在情况

```
docs/superpowers/plans/
  2026-06-11-T0A.1-content-plugin-skeleton.md   ✅
  2026-06-11-T0A.2-soul-crud.md                 ✅
  2026-06-11-T0A.3-skill-crud.md                ✅
  2026-06-11-T0A.4-kb-crud.md                   ✅
  2026-06-11-T0A.5-tenant-management.md         ✅
  2026-06-11-T0A.6-cr-engine.md                 ✅
  2026-06-11-T0A.7-autoservice-refactor.md      ✅
  2026-06-11-T1A.1-assembly.md                  ✅
  2026-06-11-T1A.3-operator-feed.md             ✅
  2026-06-11-T2A.1-*.md                         ❌ 不存在
  2026-06-11-T2A.2-*.md                         ❌ 不存在
```

### 退化链条

```
1. /start-task T2A.1 未调 writing-plans
     ↓ (跳过了 per-task plan 生成)
2. 实施时无 per-task plan 作为 checklist
     ↓ (T2A.1 描述列出 3 页面, 实施时只做了 2 个, 无法对照)
3. 无 plan 中的 verification 步骤做 gate
     ↓ (未新增任何测试)
4. 无 code review 检查 deliverables
     ↓ (reviewer 无 plan 可对照, 只能肉眼扫代码)
5. tasks.yaml status 手工翻为 completed
     ↓
6. platform_content_live / skill_editor_live / kb_manager_live 无声缺失
```

## 具体缺失与 stub

### 缺失页面 (3)

| 页面 | 所属 task | 设计参考 |
|---|---|---|
| `platform_content_live.ex` | T2A.1 | §8.5 — master admin 平台 soul/skill/KB 模板编辑 |
| `skill_editor_live.ex` | T2A.2 | §8.3 — 4 层 tab 切换, 文件列表, 代码编辑器 |
| `kb_manager_live.ex` | T2A.2 | §8.4 — 搜索框, URL 抓取, 文件上传, escalation keywords |

### 已有但含 stub (2)

| 页面 | Stub 内容 |
|---|---|
| `operators_live.ex` | Disable 按钮 → flash "Disable not yet implemented in this version." |
| `cr_dashboard_live.ex` | CR 历史 → 占位文字 "CR history will be shown here when available." |

### 关键 commit 轨迹

```
ae354231 feat(autoservice): T2A.2 — CR Dashboard LiveView
1574f63a feat(autoservice): T2A.2 — Operators LiveView
10f76ab1 task: Phase C complete — 15/16 tasks (94%)   ← diff 只改了 tasks.yaml (2 行)
470bb383 task: 100% complete — 16/16 tasks done         ← diff 只改了 tasks.yaml (1 行)
```

`10f76ab1` 和 `470bb383` 的 diff 只改 `tasks.yaml` 的 status 字段，没有代码变更。

## 执行计划的压缩

执行计划 `2026-06-11-execution-plan.md` 把 Phase A (22 新文件) 分配了 **6 个 batch**，
Phase B (~10 改动) 分配了 **4 个 batch**，但 Phase C+D (10 新文件) 只分配了 **2 个 batch**
(batch-11 + batch-12)。Phase C 单个 batch 的 tasks 数量看起来少 (2 tasks)，
但每个 task 折叠了 3-5 个独立页面，实际工作量被严重低估。

```
batch-1..6:  Phase A — 22 文件, 6 batches, 9 tasks
batch-7..10: Phase B — ~10 改动, 4 batches, 4 tasks
batch-11:    Phase C+D — T2A.1 (3 页面) + T2A.3 (1 文件), 1 batch
batch-12:    Phase C+D — T2A.2 (5 页面), 1 batch
```

## 影响

- 3 个核心 admin 页面 (platform, skill, kb) 缺失
- 2 个已有页面含 stub (disable, CR history)
- Tenant admin 无法通过 UI 编辑 soul/skill/KB
- "admin 通过 agent 对话管理租户" 的愿景需要 MCP 工具兜底

## 修复步骤

### 短期 (补全缺失页面)

1. 为 T2A.1/T2A.2 的每个缺失页生成 per-task plan
2. 逐个实施：platform_content_live → skill_editor_live → kb_manager_live
3. 为已有 stub (operators disable, CR history) 补充实现

### 流程改进

1. **禁止无-plan task 执行**: `/start-task` 在无 per-task plan 时拒绝执行,
   强制先调 writing-plans
2. **tasks.yaml deliverables gate**: CI 检查 `status: completed` 的 task 的
   `deliverables` 路径全部存在
3. **Phase C tasks 拆分**: T2A.1 → T2A.1a/1b/1c (每个页面对应一个 task),
   T2A.2 → T2A.2a/2b/2c/2d/2e
4. **Verification criteria 具体化**: 从 "tenant admin 可完整管理" 改为
   "skill_editor_live.ex 文件存在 + 路由注册 + 4 层 tab 切换通过 agent-browser E2E"
