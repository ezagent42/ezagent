# Return: Agent Console Overview convergence

> **Task:** agent-console-overview-convergence
> **Branch:** `fix/agent-console-completeness-0630`
> **PR:** https://github.com/ezagent42/ezagent/pull/1112
> **Dev:** dai.ming (human) + Claude (agent, SDD loop)
> **returned_at:** 2026-07-01 18:30 +0800
> **deadline:** 2026-07-01 20:00 +0800
> **deadline_status:** on_time

## 背景

领导 review 反馈（PR #1112）："@戴明 做一个 prototype，实现一个；不要做 n 个 prototype，最后实现 0 个。" 原 PR 含 28 个静态 HTML demo，方向发散。本次任务收敛到 Overview 落地页一个真正可运行的实现。

## 改动

### 1. 后端：`admin_data.ex`

为 overview 状态新增：
- `available_sessions`: workspace 内最多 3 个 session（URI-ordered，非 time-ordered），含 `{uri, name}`
- `session_template_names`: 可用 session 模板列表，含 F3 回归守卫 `class_directly_creatable?/1`

命名用 `available_sessions` 回避"最近"承诺；`session_name/1` 用 `Ezagent.URI.name!/1` 获取产品化名称。

### 2. 前端：`Overview.tsx`

完整重写为三板块（旧 KPI 卡片升级为产品语言标签）：
- 推荐下一步：继续 session / 创建 Agent / 浏览 Sessions / 新建 Session
- 关键状态：5 个 KPI
- 可继续的 Sessions：session 列表 + `/sessions?session=` 深链接

### 3. 测试：`admin_data_test.exs`（4 tests, 0 failures）

- payload 形状（kpis + available_sessions + session_template_names）
- JSON 安全
- nil workspace guard rail
- non-workspace URI guard rail

### 4. 清理

删除 28 个未选中 prototype HTML 文件，更新 completeness doc 链接。

## 验证

| 检查项 | 结果 |
|---|---|
| AdminData 测试 (4 tests) | PASS (MIX_ENV=dev) |
| TypeScript 编译 | 干净 |
| Asset 构建 | 成功 |
| 浏览器截图（Playwright） | 三板块正常渲染 |

截图证据：
- Before: `docs/together/2026-07-01/screenshots/overview-before-enhancement.png`
- After: `docs/together/2026-07-01/screenshots/overview-after-enhancement.png`

## 已知限制

`mix precommit` 被预有 bug 阻断（`ezagent_core/test/support/no_surface_read_dispatch_probes.ex:58`，正则字面量在模块属性中不兼容 Elixir 1.18/OTP 28）。在本次改动前即存在，与本次无关。

## 方法摩擦

1. **evidence-loop 成本**：截图证据需要运行中的 session 进程，但 `list_sessions` 查的是 KindRegistry（运行进程）而非数据库。为截图.spawn session → 进程销毁 → 证据丢失，来回数次。教训：landing page 的证据策略应在 plan 阶段确定，必要时带 seed task。
2. **多 agent 验证一致性**：多个 review agent 在不同时间点读取同一 PNG 文件，缓存/路径歧义放大了确认成本。教训：证据 commit 后应在 return 里明确声明"图片在 commit <sha>，截图时间 <time>"，减少复验回合。
