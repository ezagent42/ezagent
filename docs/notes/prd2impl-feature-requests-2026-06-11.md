# prd2impl Feature Requests

> 日期: 2026-06-11
> 来源: AutoService v2 项目使用经验 + 10 项 issues 记录
> 目标: 提升大规模设计文档的自动化程度

---

## 1. autorun 支持 per-task plan 生成

**现状**: autorun 直接加载 tasks.yaml，批量 dispatch 所有 task。不会在执行前生成详细 plan。

**需求**: autorun 增加 `--with-plans` 模式，每执行一个 task 前自动调用 `writing-plans` 生成该 task 的详细 plan。

```
/autorun green --with-plans
  → T0A.1: writing-plans → 生成 plan → subagent-driven-development 执行 → 审查
  → T0A.2: writing-plans → 生成 plan (基于 T0A.1 输出) → 执行 → 审查
  → ...
```

**理由**: 避免提前生成全部 plan 的"错误扩散"问题；每个 plan 基于最新代码库状态；设计修正只影响剩余 task。

**实现**: autorun Step 3 的 dispatch loop 中，在 invoke skill-8/skill-5 之前，先对 task 调 `writing-plans`，将产出路径回写到 `tasks.yaml` 的 `source_plan_path`，再进入 plan-passthrough 执行。

---

## 2. ingest 提取完整性检查

**现状**: `/ingest-docs` 对 1500+ 行设计文档的提取精度不够。第一次丢失了 10 项关键内容（modules 少 1 个、file_changes 少 10 个、审查修正记录全部丢失）。

**需求**: skill-0 增加"提取完整性检查"步骤，对比源文档章节数和 YAML 条目数，差异超过阈值时警告。

```
skill-0 建议新增 Step:
  - 统计源文档: 章节数 X, file_changes 提及数 Y, modules 提及数 Z
  - 统计 YAML: gaps N, file_changes M, modules K
  - 如 Y/X < 70% 或 M/Y < 70%: 警告 "提取可能不完整,建议人工审查"
```

---

## 3. 源文档变更自动检测

**现状**: 设计文档被修改后，旧的 YAML 仍然存在，需要手动删除并重新 `/ingest-docs`。

**需求**: 在 YAML 中记录源文档的 git hash。下次任何 skill 读取 YAML 时，对比源文档当前 hash，不一致时提示用户重新摄取。

```yaml
source_hash:
  design.md: "sha256:abc123"
  plan.md: "sha256:def456"
```

---

## 4. Pipeline 链式触发提示

**现状**: 每个 skill 完成后不提示下一步，用户需要自己知道 pipeline 流程。

**需求**: 每个 skill 完成后输出明确的下一步建议:

```
✅ /ingest-docs complete
Next: run /gap-scan to verify codebase coverage
     run /task-gen to generate tasks from YAMLs

✅ /task-gen complete
Next: run /plan-schedule to create batches and milestones
     or /next-task to start working immediately
```

---

## 5. gap-scan 与 ingest 的 gap 合并而非覆盖

**现状**: `/gap-scan` 生成同名 `gap-analysis.yaml` 覆盖 `/ingest-docs` 的输出。两者粒度不同，应互补。

**需求**: gap-scan 读入已有 gap-analysis.yaml，只追加代码库验证结果（existing_code、coverage_pct），不覆盖 ingest 提取的 gap 定义。

```
gap-scan 逻辑:
  if gap-analysis.yaml exists:
    for each existing gap:
      scan codebase → add coverage evidence
      append new gaps only if found in codebase but not in existing
  else:
    full scan
```

---

## 6. writing-plans 批量模式

**现状**: writing-plans 一次只能处理一个 task。16 个 task 需要手动逐个调用。

**需求**: writing-plans 支持批量模式——传入 tasks.yaml，为所有 task 生成 plan，输出到 `docs/superpowers/plans/{date}-{task_id}.md`。

可配合 #1 使用：autorun 用批量模式预生成，但执行时基于当前 HEAD 验证 plan 是否仍然有效。

---

## 7. greenfield 项目跳过 contract-check

**现状**: 全新项目（代码库 0%）运行 contract-check 输出 "0 changes, 0 affected"，无意义但也不报错。

**需求**: 检测到 greenfield（0 个 contract 文件、0% coverage_pct），自动跳过并提示 "greenfield project, contract-check skipped"。

---

## 8. skill-0 role-detector 增强

**现状**: `--tag` 参数需要用户手动指定每个文件的 role。初次使用不清楚 tag 语法。

**需求**: 增强自动检测——扫描文档的 H1 标题和 TOC，匹配已知模式:
- "架构设计" / "Architecture Design" → design-spec
- "实施计划" / "Implementation Plan" → plan  
- "gap analysis" → gap
- "PRD" / "需求文档" → prd

提示用户确认而非要求手动传 `--tag`。

---

## 优先级建议

| # | 功能 | 优先级 | 复杂度 |
|---|---|---|---|
| 1 | autorun with plans | **高** | 中 |
| 3 | 源文档变更检测 | **高** | 低 |
| 4 | Pipeline 链式提示 | 中 | 低 |
| 2 | 提取完整性检查 | 中 | 中 |
| 5 | gap 合并 | 中 | 低 |
| 6 | writing-plans 批量 | 低 | 中 |
| 7 | greenfield 跳过 | 低 | 低 |
| 8 | role-detector 增强 | 低 | 中 |
