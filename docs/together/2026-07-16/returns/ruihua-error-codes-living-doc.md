> **Task:** 错误码注册表 — 合并为 Living Document
> **Branch:** `docs/workspace-self-service-product-plan`
> **PR:** https://github.com/ezagent42/ezagent/pull/1436
> **Dev:** ruihua（designer）
> **returned_at:** 2026-07-17 18:00 +0800
> **deadline:** 2026-07-17
> **deadline_status:** on_time

## 做了什么

基于全仓库 `{:error, ...}` 返回扫描（200+ 处），将第一批（7 条）和第二批（23 条）合并为 **单一 Living Document**：

**文件：** `docs/plans/2026-07-17-error-codes-batch-1.md`（待重命名 + 移动目录）

**内容：**
- 用户可感知错误码：24 条（含逐条定义、精确 trigger pattern、来源文件和行号）
- 仅 Layer 3 兜底：6 条（内部框架错误——注册只为防止裸 atom 暴露给用户）
- 实施顺序：P0 → P6
- 追加指南：新功能上线时按此模板追加

## Living Document 设计

**为什么不拆成多份文档：**
- 错误码注册表是**单一事实源**——研发找「这个错误应该展示什么消息」，只查一个地方
- 新功能上线时追加一条记录即可，不需要判断「该加到 batch-1 还是 batch-2」
- 与 SOP 的关系：SOP 告诉你怎么注册；注册表是注册结果

**追加流程：** 功能负责人按 SOP §3 收集错误 case → 在本文档末尾追加新条目 → 更新实施顺序表。

## 待 lead 裁定

| # | 决策项 | 说明 |
|---|--------|------|
| **D4** | **本文档的最终目录和文件名** | 当前放在 `docs/plans/2026-07-17-error-codes-batch-1.md`（临时位置）。建议选项：<br>A: `docs/plans/error-code-registry.md`（living doc 不应带日期前缀）<br>B: `docs/guide/error-code-registry.md`（作为开发指南的一部分）<br>C: 与错误码模块同目录（如 `apps/ezagent_*/lib/.../ERROR_CODES.md`）<br>D: 其他——由 lead 根据仓库惯例决定 |
| **D1** | 错误码注册表放在哪个 app？ | （此前已列出，等裁定） |
| **D3** | 渲染链路前端改造范围？ | （此前已列出，等裁定） |

## Merge request

上述改动已 push 到 PR #1436 分支。D4 裁定后我将重命名 + 移动文件。
