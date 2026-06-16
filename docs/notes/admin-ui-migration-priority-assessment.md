# AutoService Admin UI → ezagent Migration — Priority Assessment

> 2026-06-16 | Worktree: ui-impl-session2
>
> **Vision**: 两个 admin 入口 — 可视化管理页编辑 + Admin Session 会话式管理。Dream 后放。

---

## Priority Classification

| Level | Criteria |
|-------|----------|
| **P0 — Required** | 租户日常管理的核心闭环，缺了无法投入使用 |
| **P1 — Important** | 显著提升效率/可见性，发布前应完成 |
| **P2 — Platform** | 平台级管理 + 会话式 Admin Session |
| **P3 — Future** | 自动化/增强，后放 |

---

## Tenant 侧 — 可视化管理 (Entry 1)

### P0 — Required（核心闭环）

| # | 功能 | 说明 | 当前状态 | AI 辅助 |
|---|------|------|:--:|------|
| T1 | **Tenant 创建（壳）** | Master 创建 Tenant ID + Brand Name | ✅ 已完成 | — |
| T2 | **TenantDashboard + Init 引导** | 初始化状态检测 + 可选 Init banner + 总览 KPI | ✅ 已完成 | — |
| T3 | **InitWizard（3步）** | 品牌信息→Soul生成→Slot预填→Publish | ✅ 已完成 | — |
| T4 | **Soul 编辑器** | Source 编辑 + Diff(sandbox vs release) + Preview + 层级显示 | ✅ 已完成 | AI Diff 建议 |
| T5 | **Slot 编辑器** | 表单式 key-value + YAML 切换 | ✅ 已完成 | — |
| T6 | **Skill 管理器** | 4层(L0-L3)卡片网格 + 搜索 + 编辑/删除 | ✅ 已完成 | — |
| T7 | **KB 管理器** | Sources/Search/URL Fetch/File Upload/Glossary 5-Tab | ✅ 已完成 | — |
| T8 | **CR 仪表盘 + Tracked Changes** | Active CR 状态 + sandbox_diff 统计 + 变更路径列表 + Publish/Cancel | ✅ 已完成 | — |
| T9 | **Operators 管理** | 添加/禁用操作员 | ✅ 已完成 | — |

### P1 — Important（效率增强）

| # | 功能 | 说明 | 当前状态 | AI 辅助 |
|---|------|------|:--:|------|
| T10 | **FastPrompt 编辑器** | fast_ack_prompt.md 独立编辑页 | ✅ 已完成 | AI 建议 prompt 模板 |
| T11 | **Sandbox Preview** | 完整 Claude.md 合成预览 | ✅ 已完成 | — |
| T12 | **Version Timeline** | 发布版本历史 + 回滚 | ✅ 已完成 | — |
| T13 | **AI Assist 面板** | 内联 NL→Diff 建议 + accept/reject。嵌入 Soul/Skill 编辑器作为辅助 tab，NOT 独立页面 | ❌ 未开始 | 🔥 核心 AI 能力 |
| T14 | **Soul Inbox** | 待处理 CR 提案，按 target_kind 分组 Accept/Reject | ❌ 未开始 | AI 批量审核建议 |
| T15 | **Soul Test Console** | Dry-run: 客户消息输入 → sandbox vs release 对比输出 | ❌ 未开始 | AI 生成测试消息 |

### P2 — 会话式管理 (Entry 2)

| # | 功能 | 说明 | 当前状态 | 依赖 |
|---|------|------|:--:|------|
| T16 | **AdminSessionLive** | 对话式管理页面，Admin Agent 以卡片展示组件 | ❌ 未开始 | P0 组件独立化 |
| T17 | **AdminAgent Behavior** | Admin Agent 的 Kind+Behavior，dispatch 路由 | ❌ 未开始 | Session 基础设施 |
| T18 | **组件 Card 化** | SoulEditor/SkillManager/KbManager 等支持 live_isolated 嵌入卡片 | ⚠️ 已设计，待验证 | 现有组件 |

### P3 — Future（自动化 + 远期）

| # | 功能 | 说明 | 当前状态 |
|---|------|------|:--:|
| T19 | **Response Settings** | PV2 prompt ack/progress/filler 三段式覆盖 | ❌ 未开始 |
| T20 | **Soul Regen** | 一键重新生成 Soul | ❌ 未开始 |
| T21 | **Dream/Proposal** | 后台 LLM 分析对话→发现缺口→生成提案 | ❌ 未开始（后放） |
| T22 | **Gap Analysis** | NL 输入→AI 分析4层资源→推荐 | ❌ 未开始（后放） |
| T23 | **Billing** | 账单 | ❌ 未开始（非核心） |

---

## Master 侧 — 平台管理

### P1 — Important

| # | 功能 | 说明 | 当前状态 |
|---|------|------|:--:|
| M1 | **MasterDashboard** | 租户列表总览 | ✅ 已有 |
| M2 | **TenantOnboard** | 创建租户壳（精简后） | ✅ 已完成 |

### P2 — Platform

| # | 功能 | 说明 | 后端 | 前端 |
|---|------|------|:--:|:--:|
| M3 | **Platform Soul** (L1) | 平台级 Soul 编辑 per-role | PlatformSoulStore ✅ | ❌ |
| M4 | **Industry Soul** (L2) | 行业级 Soul 编辑 per-industry+role | PlatformSoulStore ✅ | ❌ |
| M5 | **Soul Templates** (L3) | 模板编辑 per-role+sid | PlatformSoulStore ✅ | ❌ |
| M6 | **Platform Skills** (L0/L1/L2) | 平台级 Skill 管理 | PlatformSkillStore ✅ | ❌ |

### P3 — Future

| # | 功能 | 说明 |
|---|------|------|
| M7 | **Priority YAML** | 4层优先级 override 规则 |
| M8 | **Master Operators** | 平台级操作员管理 |
| M9 | **Master Dream** | 平台级 Dream |

---

## 优先级总览

```
P0 (Required)  ██████████ 9 items  — 租户日常管理闭环
P1 (Important) ██████     6 items  — AI Assist + TestConsole + Inbox + FastPrompt
P2 (Platform)  ████████   8 items  — Platform Soul/Skills + Admin Session Entry 2
P3 (Future)    ██████     7 items  — Dream/GapAnalysis/Response/Billing 后放

Total: 30 items (matching old AutoService 30-page scope)
```

---

## P0 闭环验证 Checklist

租户从创建到日常管理的完整流程：

- [x] Master 创建租户壳 (Tenant ID + Brand Name)
- [x] 进入 TenantDashboard → 看到 init 引导 + 完整 Dashboard
- [x] 运行 InitWizard: 品牌信息 → Soul 生成 → Slot 预填 → Publish
- [x] 进入 SoulEditor → 编辑 Soul → 查看 Diff → 保存 → CR 自动追踪
- [x] 进入 SlotEditor → 编辑 Slot 值 → 保存
- [x] 进入 SkillManager → 查看4层 Skill → 编辑/删除
- [x] 进入 KbManager → URL 抓取 / 手动添加 / Glossary
- [x] 进入 CrDashboard → 查看 Tracked Changes → Publish
- [x] 进入 VersionTimeline → 查看发布历史

---

## 决策点（待 Review）

1. **AI Assist 面板 (T13)**: 降级为 P1 还是提升为 P0？理由：可视化管理需要 AI 辅助定位编辑，但基础 CRUD 可先不用 AI

2. **Soul Inbox (T14) vs Soul Test Console (T15)**: 哪个更优先？Inbox 是审核工作流，TestConsole 是发布前验证

3. **Admin Session (T16-T18)**: 会话式管理何时启动？建议等 P0 组件全部独立化后再做

4. **Platform Soul/Skills (M3-M6)**: 后端已有 PlatformSoulStore/PlatformSkillStore，前端是否赶 P1 还是放 P2？

5. **Response Settings (T19)**: 是否提升？Prompt 覆盖在生产中很重要但非阻断性
