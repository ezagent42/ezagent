# AutoService V2 实施回顾 — 问题、缺口、教训

> 日期: 2026-06-12 | 合并前整理
> 来源: v2-issues.md + debug records + M2 retro + Phase C gap analysis
>
> 原始文件:
> - `docs/v2-issues.md` — 设计实现缺口 & 技术上下文
> - `docs/debugging/2026-06-12-autoservice-session-debug.md` — 调试记录
> - `docs/debugging/2026-06-12-phase-c-admin-ui-gaps.md` — Phase C 流程退化分析
> - `docs/plans/2026-06-12-m2-retro.md` — M2 回顾 (NO-GO)
> - `docs/plans/2026-06-11-gap-analysis.yaml` — prd2impl gap 分析

---

## 一、prd2impl 执行流程退化

### 1.1 Phase 对比

| 流程步骤 | Phase A (8 tasks) | Phase B (4 tasks) | Phase C (2 tasks) |
|---|---|---|---|
| Per-task plan 文件 | ✅ 7/7 | ⚠️ 2/4 | ❌ **0/2** |
| Per-task 独立实施 | ✅ | ⚠️ 合并 | ❌ 合并为 2 commits |
| 测试验证 (mix test) | ✅ | ✅ | ❌ 无新增 |
| Code review | ✅ | ✅ | ❌ 无 |
| Commit 标记完整度 | ✅ T0A.x | ⚠️ T1A.x | ❌ T2A.2 标记但内容不完整 |

**关键发现**: Phase C 是唯一完全没有 per-task plan 的 phase。

### 1.2 退化链

```
/start-task T2A.1 → writing-plans 被跳过
  → 无 per-task plan 作为 checklist
    → 实施粒度失控 (T2A.1 列出 3 页面, 实际做了 2 个)
      → 无 plan 中的 verification gate
        → 无新增测试
          → 无 code review
            → tasks.yaml 手工翻 completed
              → 3 个核心页面无声缺失
```

### 1.3 关键 commit 证据

```
10f76ab1 task: Phase C complete — 15/16 tasks (94%)   ← diff 只改 tasks.yaml (2行)
470bb383 task: 100% complete — 16/16 tasks done         ← diff 只改 tasks.yaml (1行)
```

这两个 commit 只翻转了 YAML status 字段，没有代码变更。

### 1.4 M2 GO/NO-GO

**NO-GO** — M2 未达验收标准:

| Gate | 预期 | 实际 |
|---|---|---|
| admin 可创建租户 | tenant_onboard_live 可用 | ✅ |
| tenant 可编辑 soul/skill/KB | soul_slot_editor/skill_editor/kb_manager 可用 | ❌ 3 个页面全部缺失 |
| CR publish 可用 | Publish/Cancel | ⚠️ 可用但 CR 历史是 placeholder |
| operator 管理 | 增删改查 | ⚠️ 增/查可用, Disable 是 stub |

---

## 二、待实现缺口

### 2.1 缺失页面 (Phase C 未交付)

| 页面 | 所属 task | 设计参考 |
|---|---|---|
| `platform_content_live.ex` | T2A.1 | §8.5 — master admin 平台 soul/skill/KB 模板编辑 |
| `skill_editor_live.ex` | T2A.2 | §8.3 — 4 层 tab 切换, 文件列表, 代码编辑器 |
| `kb_manager_live.ex` | T2A.2 | §8.4 — 搜索框, URL 抓取, 文件上传, escalation keywords |

### 2.2 已有但含 stub

| 页面 | Stub |
|---|---|
| `operators_live.ex` | Disable 按钮 → flash "Disable not yet implemented in this version." |
| `cr_dashboard_live.ex` | CR 历史 → placeholder "CR history will be shown here when available." |

### 2.3 功能缺口

| Gap | 严重度 | 说明 |
|---|---|---|
| **Customer 不走 Turn 生命周期** | ⭐⭐⭐ | `customer_live.ex` 直接 `chat.send`，跳过 Turn 状态机 |
| **FillerLoop 无人调用** | ⭐⭐⭐ | `filler_loop.ex` 完整但为孤儿代码 |
| **Soul slot 编辑器** | ⭐⭐ | 后端 SoulStore/SoulRenderer 已就绪，缺 UI |
| **Skill 编辑器** | ⭐⭐ | 后端 SkillStore/SkillLoader 已就绪，缺 UI |
| **KB 管理器** | ⭐⭐ | 后端 KbStore/KbRebuilder 已就绪，缺 UI |
| **Platform 内容编辑器** | ⭐ | V2 spec §8.5 规划未实现 |
| **Loom customer SPA** | ⭐ | 决策 D1 推迟到单独分支 |

---

## 三、调试问题记录

### 3.1 Feishu WsClient 日志爆炸

**现象**: `mix phx.server` 85 分钟 5889 行 warning，全是 `:credentials_unfilled; retry in 5000ms`

**根因**: `ws_client.ex` 硬编码 `@restart_backoff_ms 5_000`，永久性配置错误每 5s 重试无限循环

**修复** (`4067c39d`): 永久错误不重试 + 指数退避 5s→300s cap

### 3.2 Admin 页面崩溃

**现象**: `/admin/autoservice?as=admin&workspace=system` → GenServer timeout

**根因**: cmd.exe 把 URL 中的 `&` 解释为命令分隔符，`workspace=system` 被丢弃。实际登录非 system admin，被 `:require_admin` gate bounce

**修复** (`2edf339a`): 改用 `?as=entity://system/user/admin`

### 3.3 Tailwind CSS 颜色/暗色模式

| 问题 | 根因 | 修复 |
|---|---|---|
| 输入框/气泡颜色失效 | Tailwind v4 `source(none)` 不生成 `gray-*` | 41 处 `gray-*` → `zinc-*` |
| Dark mode 对比度 | `@source` 缺 autoservice plugin 目录 | 加 `@source` + `dark:` 变体 |

### 3.4 Customer 收不到 AI 回复

**现象**: 发送消息后无回应

**根因**: 只订阅 `CustomerFeed.topic`，缺少 `Chat.session_events_topic`。且 `_ensure_joined` 没 re-join fast agent

**修复**: 双订阅 + re-join fast/slow agent

### 3.5 消息双条

**根因**: `chat_message` 和 `customer_delivery` 对同一消息都触发，无去重

**修复**: 按消息 ID 去重 (`Enum.any?(messages, &(&1.id == msg.id))`)

### 3.6 Operator 列表为空

**根因**: session URI 格式 `session://<ws>/cs/<name>`，filter 写死 `session://cs/` 前缀 → 永远不匹配

**修复**: `String.contains?("/cs/")` 匹配 path segment

---

## 四、关键技术约束

### 4.1 Tailwind v4 CSS

- `source(none)` 不扫描文件，新增 `@source` 目录必须同步到 `app.css`
- 颜色用 `zinc-*`（非 `gray-*`）
- 所有颜色类必须配 `dark:` 变体

### 4.2 PubSub 双通道

Customer LV 必须同时订阅两个 topic:
```elixir
Phoenix.PubSub.subscribe(PubSub, CustomerFeed.topic(session_uri))
Phoenix.PubSub.subscribe(PubSub, Chat.session_events_topic(session_uri))
```

### 4.3 `_ensure_joined` 必须 re-join agent

Server 重启后 session rehydrate，join 关系丢失。必须 re-join fast agent + slow agent。

### 4.4 代码位置

- UI 层: `ezagent_plugin_liveview`
- 业务层: `ezagent_plugin_autoservice`
- `ezagent_plugin_autoservice` 中**不存在** `customer_live.ex` / `operator_live.ex` (已删除旧副本)

### 4.5 URI 格式

```elixir
session://<workspace>/cs/<name>   # ws 在前, /cs/ 在后
entity://<ws>/user/<name>
entity://<ws>/agent/curl_fast-<name>
entity://<ws>/agent/cc_slow-<name>
```

### 4.6 跨 VM 种子

Seed 脚本在单独 BEAM 运行。Kind 进程 seed VM 退出后死亡，Server VM 通过 KindSnapshot + Workspace Loader 重新实例化。

---

## 五、Lessons Learned

### 5.1 不要为测试场景加防护代码

两次尝试给 CustomerLive 加 admin 拦截逻辑均被拒绝。**错误模式**: "admin 误入 customer 页面 → 加 guard 拒绝非 customer"。guard 隐藏真问题，在症状处打补丁。

### 5.2 删除旧文件

重构迁移后务必删除旧文件。LiveView 模块迁移后旧文件未删，两套代码并存一个月。

### 5.3 Per-task plan 是硬 gate

Phase C 缺失 per-task plan → 实施粒度失控 → 3 页面无声缺失。**prd2impl 流程必须保证每个 task 都有 per-task plan**，CI 应检查 `status: completed` 的 task 是否有 `source_plan_path`。

### 5.4 Tasks.yaml 状态不能手工翻

`10f76ab1` 和 `470bb383` 只改 YAML status 字段。**status: completed 必须有对应的 deliverable 验证**。CI gate: 检查 deliverables 文件全部存在。

---

## 六、流程改进建议 (提交 prd2impl 框架)

以下问题记录在 `docs/notes/prd2impl-usage-issues-2026-06-11.md` 和 `docs/notes/prd2impl-feature-requests-2026-06-11.md`:

**使用问题 (10 项)**:
1. 入口选择困惑 (Entry A vs B)
2. skill-0 提取丢失关键内容 (1500+ 行文档提取精度不足)
3. Pipeline 不自动链式触发
4. 设计变更后需手动重跑全流程
5. gap-scan 与 ingest 的 gap 重复
6. contract-check 在 greenfield 项目无意义但无提示
7. superpowers 插件依赖不可达
8. writing-plans 逐个生成效率低
9. 分支管理未纳入 pipeline
10. 缺少"检查设计文档完整性"的 step

**Feature Requests (8 项)**:
1. autorun 支持 per-task plan 生成 (`--with-plans`)
2. ingest 提取完整性检查
3. 源文档变更自动检测
4. Pipeline 链式触发提示
5. gap-scan 与 ingest 的 gap 合并而非覆盖
6. writing-plans 批量模式
7. greenfield 项目跳过 contract-check
8. skill-0 role-detector 增强
