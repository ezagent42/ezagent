# autoservice-dev admin UI — re-route 说明 (反馈给 Allen)

> 2026-06-17 | autoservice-dev 团队
> 回应 PR #812 / #813 / #814 的发现和建议

---

## 一句话

autoservice-dev 的 admin UI 确实绕过了 dispatch/CapBAC。我们认可 FatNine 在 #813 的评估，正在按 `fix/content-and-mechanical` 方向修复。**所有修复在 plugin 层完成，不需要改动 core/domain 模型。唯一的 core 依赖是 turn-adapter 的 system principal 注册（`catalog.ex` +7 行）。**

---

## 前因: 为什么会绕过

### 设计背景

autoservice 管理的数据（soul/slots/skills/KB/CR）存储在文件系统：
```
~/.ezagent/default/tenants/<tid>/sandbox/
├── souls/customer.md
├── slots/customer.yaml
├── skills/<role>/<name>/SKILL.md
├── kb/kb.db
└── config/fast_ack_prompt.md
```

原设计 spec（`2026-06-10-autoservice-v2-design.md` §3.2.1）允许 admin 直接操作文件：
> "租户创建时从 skeleton 复制基线到运行时路径; 后续 tenant admin 编辑直接写运行时路径"

同时提供了 `ContentAdmin` dispatch Behavior 作为 dispatchable wrapper（7 个 action），供 MCP/CLI/外部 Agent 使用。

### 实际实施

admin UI 全部走直接 `File.write`，从未调用 `ContentAdmin` dispatch：

```
ContentAdmin dispatch actions:  7 个（设计就有的）
Admin UI 调用 ContentAdmin:     0 次
Admin UI 直接 File.write:      85 处
Admin UI dispatch 调用:         0 次
```

另外 `can_write? = admin_uri != nil` 去掉了前端 cap 检查。

### 后果

- **无 CapBAC**: 任何登录用户可以编辑任意租户内容（`can_write?` 只看是否登录，不看是否有权限）
- **无 telemetry**: 写操作不生成审计事件
- **CLI 不可用**: `mix ezagent` 无法复用 admin UI 的写逻辑

---

## 修复方案

### 方向

将 admin UI 的写路径从直接 `File.write` 改为走 `ContentAdmin` dispatch：

```
之前: admin LV handle_event → File.write(path, content)
之后: admin LV handle_event → Invocation.dispatch(workspace://tid?action=content_admin.write_soul, ...)
                                → ContentAdmin.handle_write_soul(args, ctx)
                                  → File.write(path, content)
                                    ↑
                              CapBAC step 5.5 自动在这里执行
```

### 实施状态

`fix/content-and-mechanical` 分支已完成 Phase 0+1：

| 步骤 | 内容 | 文件 | 状态 |
|------|------|------|:--:|
| Phase 0 | ContentAdmin 新增 9 个 write action | `content_admin.ex` | ✅ |
| Phase 1 | admin role cap 修复 (`:content` → `:workspace`) | `roles.ex` | ✅ |
| Phase 1 | admin LV 瘦身（去掉重复的 File.write 逻辑） | `fast_agent_live.ex` 等 5 个文件 | ✅ |
| Phase 2 | SlowAgentLive 改为 dispatch 调用 | `slow_agent_live.ex` | 🔄 待做 |
| Phase 3 | 去掉 `can_write? = admin_uri != nil` | TenantAdminLive 等 | 🔄 待做 |

### 改动范围

```
全部改动在 plugin 层:
  apps/ezagent_plugin_content/   ← ContentAdmin 扩展
  apps/ezagent_plugin_autoservice/ ← roles.ex cap 修复
  apps/ezagent_plugin_liveview/  ← admin LV 瘦身
  
  apps/ezagent_core/         ← 0 个文件（无改动）
  apps/ezagent_domain_*/     ← 0 个文件（无改动）
```

---

## 对 core/domain 的支持需求

### 唯一需要 core 配合的点: turn-adapter system principal

**是什么**: `system://turn-adapter` 是一个系统身份，持有 `cap(:session, Chat, :any)`，用于代表没有 Turn cap 的 customer/agent 发起 Turn 操作（open/compose/settle）。

**为什么需要**: Customer 发消息时需要触发 `turn.open`，但 customer 不持有 Turn cap。agent 回复时需要触发 `turn.compose`，同样没有 cap。需要一个有界系统身份代为 dispatch。这是 CapBAC 架构下的硬需求（Decision #4: 每条 dispatch 必须有 cap）。

**为什么不能从 autoservice plugin 内部解决**: system principal 必须在 `catalog.ex`（core §4.1）注册，因为它是 CapBAC 的 "已知身份集合"。plugin 不能往 catalog 动态添加 —— 这是 core 的 closed enum。

**当前状态**: autoservice-dev 已在 `catalog.ex` 添加 `turn-adapter`（+7 行）。

**两个选择**:

| 方案 | 改动 | 优缺点 |
|------|:--:|------|
| **A: 纳入 catalog §4.1** | core `catalog.ex` +7 行 | 简单，有界 principal（只作用于 Session Kind 的 Chat wildcard），符合 closed enum |
| **B: 走 #814 `{:rule, name, configurer}` 动态授予** | 等 #814 落地后，turn lifecycle 改为规则驱动，不再需要常驻 principal | 不需要 core 改动，但依赖 #814 的成熟度 |

**团队建议**: 短期走方案 A（已在 autoservice-dev 中）。方案 B 作为 #814 落地后的优化替换，届时可以从 catalog 移除 turn-adapter。

---

## 我们对 #812/#814 的理解

| PR | 内容 | 对 autoservice 的影响 |
|-----|------|------|
| **#812** | CapBAC 原则："no unowned permissions" — 每个 cap 的 `granted_by` 必须是真实 entity | 无直接影响。turn-adapter 不 mint cap（只持有 cap），不违反此原则 |
| **#814** | 统一 grant 关口 `Ezagent.Identity.Grant` | 无直接影响。autoservice 不执行 grant/revoke 操作 |
| **#813** | autoservice-dev 评估 — 发现绕过 dispatch/CapBAC | 正在按建议修复（见上方方案） |

---

## 时间线

```
Jun 15  autoservice-dev rebase 到 main (a39c4e66)
Jun 15-16  admin UI v2 实施（119 commits）
Jun 17  #812 merged (no unowned permissions)
Jun 17  #813 opened (FatNine 评估)
Jun 17  #814 merged (unified grant chokepoint)
Jun 17  fix/content-and-mechanical 创建 — re-route Phase 0+1
Jun 17  now — 等待 Allen review 方向，继续 Phase 2+3
```

---

## 待确认事项

1. **catalog 接纳**: Allen 是否同意将 `turn-adapter` 纳入 `catalog.ex` §4.1（方案 A），还是倾向等 #814 动态授予（方案 B）？
2. **re-route 方向**: `fix/content-and-mechanical` 的 ContentAdmin 扩展方向是否正确？
3. **时序**: autoservice-dev 是否应该先 rebase 到最新 main（包含 #812/#814），再做 re-route？

---

> 文档维护: autoservice-dev 团队 | 最后更新: 2026-06-17
