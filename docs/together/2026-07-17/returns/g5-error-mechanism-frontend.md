# G5 错误机制前端切片 · return

> **Task:** 实现 G5 通用可配置错误机制的前端部分
> **Branch:** `feat/g5-error-mechanism-frontend`
> **Base:** `origin/main`
> **PR:** https://github.com/ezagent42/ezagent/pull/1450
> **returned_at:** 2026-07-17 +0800

## 验收来源与边界

验收来源是 SOP `docs/plans/2026-07-17-error-mechanism-sop.md`。本分支从 `origin/main` 新建，
仅包含 `apps/ezagent_plugin_world/assets` 下的前端改动，不触碰 backend dispatch / action /
数据库迁移。

后端 G5 实现见 PR #1447；本 PR 作为独立前端切片，保证后端后续切换到结构化错误码时，
前端接口无需改动。

## 本轮完成

1. **错误码注册表** (`src/lib/errorCodes.ts`)
   - 定义 7 个 beta 错误码：`agent_credential_missing`、`action_unauthorized`、
     `cross_workspace_denied`、`agent_not_ready`、`invalid_args`、
     `member_not_registered`、`quota_exhausted`。
   - 每个错误码包含 `category`、`what`、`impact`、`fixPath`、`fixOwner`。
   - 保留 `UNKNOWN_ERROR` 作为 Layer 3 兜底。

2. **错误匹配器** (`src/lib/errorMatcher.ts`)
   - 解析 `last_dispatch_status` 的 `"error:<reason>"` 格式。
   - 提供临时 backend atom 到注册码的映射（如 `no_api_key` → `agent_credential_missing`），
     使前端在后端尚未输出结构化 code 时即可工作。
   - 未识别原因回落到 `unknown`。

3. **分层渲染器** (`src/lib/errorRenderer.ts`)
   - Layer 1：当前用户可修复时给出 `primaryAction`（前往修复链接）。
   - Layer 2：用户不可修复但存在 `fixOwner` 时给出 `secondaryAction`
     （`error.notify_admin`）。
   - Layer 3：无修复路径/负责人时显示自动登记说明。
   - 按 `category` 输出视觉 tone：`danger` / `warning` / `info`。

4. **错误卡片组件** (`src/components/ErrorMessageCard.tsx`)
   - 使用 Tailwind 设计 token，支持暗色模式。
   - 暴露 `data-error-code` 与 `data-error-layer` 便于 E2E 断言。
   - 支持 dismiss、navigate、action 回调。

5. **接入 World 主入口** (`src/main.tsx`)
   - 从 `initialState.last_dispatch_status` 初始化错误卡片状态。
   - 在消息列表顶部渲染 `ErrorMessageCard`。

6. **单元测试**
   - `errorMatcher.test.ts`：覆盖 null/undefined、直接匹配、backend atom 映射、未知原因。
   - `errorRenderer.test.ts`：覆盖 Layer 1/2/3 分支和 `categoryTone`。

## 暂缓项

| 项 | 说明 |
|---|---|
| 后端结构化错误码 | 等待 backend 将 `last_dispatch_status` 升级为带 `code` 的 structured payload；前端接口已预留。 |
| `error.notify_admin` 真实 dispatch | 当前卡片触发 action 回调；具体 pushEvent 与 backend persistence 不在本切片。 |
| 浏览器 E2E | 本机 Playwright Chromium 下载环境阻塞，未新增 Playwright 用例；Tier-1 现有 harness 不受影响。 |
| 多语言 | 中文文案写死；后续如需 i18n 再从注册表抽离。 |

## 浏览器证据

本地 Vite dev server 渲染的四层错误卡片演示：

![G5 错误卡片演示](../evidence/g5-error-mechanism-frontend/error-cards-demo.png)

从左到右依次展示：

1. **Layer 1 · 管理员可修复**：danger tone，主按钮「前往修复」跳转到 `/identities/agents`。
2. **Layer 2 · 普通成员提醒 founder**：同一条错误，非管理员不暴露修复链接，仅显示「提醒可修复人」。
3. **Layer 3 · 未知错误自动登记**：info tone，显示兜底说明「此问题已自动登记，系统管理员会处理。」
4. **Warning tone · 额度不足**：amber tone，用于 `quota_exhausted` 等资源类错误。

## 验证结果

在 worktree `/home/lenovo/workspace/ezagent/ezagent-wt-g5` 中完成验证。

| 验证项 | 命令 | 结果 |
|---|---|---|
| TypeScript | `npx tsc --noEmit` | PASS |
| ESLint | `npx eslint src --max-warnings 0` | PASS，0 warnings |
| Vitest | `npx vitest run src` | PASS，23 tests |
| diff 检查 | `git diff --check` | PASS |

## 交付说明

请在 PR #1450 审阅前端切片。本 PR 可与后端 G5 并行 review，也可等 #1447 合并后再合，
没有 merge-order 依赖。
