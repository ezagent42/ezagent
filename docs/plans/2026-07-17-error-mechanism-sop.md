# 通用可配置错误机制 — SOP

> 2026-07-17 · ruihua（designer）· v1 draft
> 受众：研发 agent + 产品/设计 agent。研发看 §2-§4（技术实施），产品/设计看 §5（消息撰写规范）。
> 目标：新功能上线时，功能负责人按本文档即可补充错误码注册表，无需重新设计错误处理流程。
>
> 关联：G5 产品计划（`docs/plans/2026-07-16-workspace-self-service-product-plan.md` §3）

---

## §1 现有基础

本 SOP 不是从零设计——以下机制已存在于仓库中，可直接复用或扩展：

| 已有机制 | 位置 | 可以怎么用 |
|---------|------|-----------|
| `{:error, reason}` 返回约定 | 所有 `handle_<action>/2` 严格遵循 | 错误码注册不需要改 action 返回格式——捕获 `{:error, reason}` 即可匹配 |
| `dispatch_error` 类型 | `apps/ezagent_core/lib/ezagent/router.ex:57-68` | 已有 `:unauthorized` / `:cross_workspace_denied` / `:not_ready` 等框架层错误，可直接纳入错误码表 |
| 错误消息映射函数 | `user_data.ex:106` 的 `error_message/1`；`identity_data.ex` 的 `create_error_message/1`；`agent_actions.ex` 的 `action_error_message/1` + `config_error_message/1`；`conversation_actions.ex` 的 `session_create_error_message/1` | 目前一个领域一个映射函数，各自处理。SOP 目标：**统一为一个注册表**，按错误码匹配而非按领域散落 |
| `Ezagent.Notifications` | `apps/ezagent_core/lib/ezagent/notifications.ex` — PubSub 广播 `{:notification, user_uri, map}` | Layer 2（通知 admin）可直接复用此通道 |
| `CredentialStatus` 返回格式 | `apps/ezagent_domain_agent/lib/ezagent/agent/credential_status.ex` — 返回结构化 map（`%{status: atom, detail: ...}`） | 结构化错误消息的**参考格式**——map 而非裸 atom |
| 站内通知渲染 | `world_live.ex` — `handle_info({:notification, ...})` 推送到前端 | Layer 2 admin 通知可走同一条渲染链路 |

---

## §2 错误码 Schema

每条错误码在注册表中为一条记录：

```elixir
%{
  # —— 匹配 ——
  code: "agent_credential_missing",       # 唯一标识（snake_case string）
  trigger: {:error, {:no_api_key, _}},    # 匹配条件：atom / tuple pattern（支持 _ 通配）

  # —— 分类 ——
  category: :credential,                  # :credential | :permission | :lifecycle | :validation | :resource | :unknown

  # —— 结构化消息（中文） ——
  message: %{
    what: "Agent 未配置凭证",              # 发生了什么（陈述事实，不含"请/建议"）
    impact: "无法调用 AI 模型，你的消息暂时无法得到回复",
    fix_path: :agent_keys_page,           # 修复页面标识 → 由前端路由解析为 URL
    fix_owner: :workspace_founder,        # 谁可以修 → 由系统解析为具体人名
  }
}
```

### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|:--:|------|
| `code` | string | ✅ | 唯一标识，snake_case。命名：`{category}_{具体场景}` |
| `trigger` | atom or tuple | ✅ | 匹配 `{:error, reason}` 中的 reason。支持 `_` 匹配任意值 |
| `category` | atom | ✅ | 见下方 category 枚举 |
| `message.what` | string | ✅ | 发生了什么（§5 撰写规范） |
| `message.impact` | string | ✅ | 对用户有什么影响（§5 撰写规范） |
| `message.fix_path` | atom or nil | 可选 | 修复页面的路由标识。nil = 无修复路径（直接走 Layer 2 或 3） |
| `message.fix_owner` | atom or nil | 可选 | 谁可以修的角色标识。nil = 无明确修复人（走 Layer 3 兜底） |

### Category 枚举

| category | 含义 | 示例 |
|----------|------|------|
| `:credential` | 凭证相关 | agent 缺凭证、凭证过期 |
| `:permission` | 权限相关 | unauthorized、跨 workspace 拒绝 |
| `:lifecycle` | 生命周期 | agent 未就绪、已销毁 |
| `:validation` | 参数校验 | 无效参数、名称不符合规则 |
| `:resource` | 资源配额 | 配额耗尽、存储不足 |
| `:unknown` | 未分类 | 兜底——未注册错误码自动归入此类 |

---

## §3 注册流程（研发）

新功能上线时，功能负责人按以下步骤补充错误码注册表。

### Step 1 — 收集错误 case

从新功能代码中梳理可能失败的点：

- **从 `{:error, reason}` 返回中提取。** 每个 `handle_<action>/2` 的 error 分支，记录 reason 的 atom / tuple
- **检查 dispatch_error 类型。** `router.ex` 中 `dispatch_error()` 类型列出的框架层错误（`:unauthorized` / `:cross_workspace_denied` / `:not_ready` / `:no_such_actor` / `:unsupported_mode`），如果之前未注册，补充注册
- **输出：待注册的错误码列表**（code + trigger + category）

### Step 2 — 注册错误码

在错误码注册模块中添加一条记录（按 §2 Schema）：

1. 确定 `code`（snake_case，唯一）
2. 确定 `trigger`（精确匹配 atom 或用 `_` 通配 tuple 中的动态字段）
3. 选 `category`
4. 按 §5 规范撰写 `message.what` + `message.impact`
5. 如果有修复页面 → 填 `fix_path`（同时确认路由映射中存在该标识）
6. 如果有明确修复角色 → 填 `fix_owner`（同时确认 `fix_owner` 解析逻辑能处理该角色）

### Step 3 — 写消息文案

见 §5（产品/设计 agent 同看此节）。

### Step 4 — 测试链路

每注册一条错误码后验证：

1. **触发匹配：** 触发该错误 → 确认系统匹配到正确的错误码（而非 fallback 到 Layer 3）
2. **消息渲染：** 前端正确显示 what / impact / 行动入口
3. **权限感知（Layer 1 vs 2）：** 有修复权限的用户看到修复链接；无权限用户看到「找谁修」+ 提醒按钮
4. **Layer 2 通知：** 点击发送提醒 → admin 收到站内通知（含 workspace / agent / 错误描述 / 发起人 / 修复链接）
5. **Layer 3 兜底：** 删除该错误码注册 → 确认回退到系统自动登记 issue，用户无操作

---

## §4 渲染链路（研发）

### 整体流程

```
action 返回 {:error, reason}
        │
        ▼
ErrorMatcher.match(reason)
        │
        ├─ 命中已注册错误码 ──→ 进入 Layer 1/2 渲染
        └─ 未命中 ──→ Layer 3 兜底（系统自动登记 issue）
        │
        ▼
ErrorRenderer.render(code, current_user)
        │
        ├─ current_user 有 fix_path 对应权限 → Layer 1 消息（含修复链接）
        ├─ current_user 无权限 + fix_owner 有值 → Layer 2 消息（含「找谁修」+ 提醒按钮）
        └─ fix_owner = nil → Layer 3 兜底
        │
        ▼
前端渲染结构化消息卡片
```

### 需要新建/修改的模块

| 模块 | 职责 | 位置建议 |
|------|------|---------|
| `ErrorCode` | 错误码注册表（数据定义） | `apps/ezagent_domain_agent/lib/ezagent/agent/error_codes.ex` |
| `ErrorMatcher` | `{:error, reason}` → 错误码匹配 | 同上模块或独立 |
| `ErrorRenderer` | 根据当前用户权限生成消息卡片（Layer 1/2/3 分支） | 同上 |
| 修改 `world_live.ex` | dispatch 结果处理：`last_dispatch_status` 为 error 时走 `ErrorRenderer` 而非裸 atom 展示 | 现有文件 |
| 前端消息卡片组件 | 渲染结构化错误消息（what / impact / 行动入口） | 前端 React 组件 |

---

## §5 消息文案撰写规范（产品/设计）

### 字段撰写规则

| 字段 | 要求 | ✅ 例 | ❌ 反例 |
|------|------|-------|--------|
| **what** | 一句陈述，描述事实。不含「请」「建议」「可能」 | 「Agent 未配置凭证」 | 「请前往设置页面配置 API Key」 |
| **impact** | 一句说明影响。不道歉、不夸张 | 「无法调用 AI 模型，你的消息暂时无法得到回复」 | 「抱歉，我无法处理你的请求」 |
| **fix_path** | 研发用的路由标识（atom），非面向用户 | `:agent_keys_page` | 硬编码 URL 如 `/settings/keys` |
| **fix_owner** | 研发用的角色标识（atom），系统解析为具体人名 | `:workspace_founder` | 硬编码人名如「陈瑞华」 |

### 语气原则

- **不道歉。** 不写「抱歉」「对不起」「请原谅」
- **不猜测。** 不写「可能是…」「请检查…」「建议你…」
- **可行动。** 每条消息让用户知道：（a）发生了什么（b）影响是什么（c）下一步做什么 or 找谁
- **中文优先。** beta 范围先写中文；英文为后续国际化预留字段

### 示例（按 category）

| category | what | impact |
|----------|------|--------|
| credential | Agent 未配置凭证 | 无法调用 AI 模型，你的消息暂时无法得到回复 |
| permission | 你没有权限执行此操作 | 如需访问，请联系 workspace founder |
| lifecycle | Agent 尚未就绪 | 暂时无法处理你的请求，请稍后再试 |
| validation | 输入内容不符合规则 | 无法完成操作，请修改后重试 |
| resource | Workspace 的 API 调用配额已用完 | Agent 暂时无法回复消息 |
| unknown | Agent 执行时遇到错误 | 无法完成你的请求 |

---

## §6 beta 阶段第一批错误码（从现有代码提取）

以下是从仓库已有 `{:error, reason}` 返回中提取的第一批待注册 case，功能负责人不需要自行发现：

| # | code | trigger | 来源文件 | category |
|---|------|---------|---------|----------|
| 1 | `agent_credential_missing` | `{:error, {:no_api_key, _}}` | `curl_agent.ex:250` | credential |
| 2 | `agent_not_ready` | `:not_ready` | `router.ex:60` | lifecycle |
| 3 | `action_unauthorized` | `:unauthorized` | `router.ex:58` / 各 behavior | permission |
| 4 | `cross_workspace_denied` | `:cross_workspace_denied` | `router.ex:59` | permission |
| 5 | `invalid_args` | `{:error, {:bad_args, _, _}}` | `api_keys.ex` / `user_credentials.ex` | validation |
| 6 | `member_not_registered` | `{:error, {:member_not_registered, _}}` | `session.ex:855` | validation |
| 7 | `quota_exhausted` | （待实现——当前无配额机制） | — | resource |

> **beta 最小路径建议：** 先注册 #1（agent_credential_missing）+ #3（action_unauthorized）两条。这两条覆盖了最常见的失败场景（凭证 + 权限），且 trigger 直接匹配现有 `{:error, reason}` 返回。跑通全链路（匹配 → 渲染 → Layer 1/2/3）后再逐步注册其余。

---

## §7 验证方式

### 单条错误码验证（功能负责人自测）

| # | 验证项 | 操作 | 预期 |
|---|--------|------|------|
| 1 | 匹配 | 触发该错误 | 系统匹配到正确错误码，不走 Layer 3 兜底 |
| 2 | Layer 1 消息 | 以有权限用户身份触发 | 消息卡片显示 what + impact + 修复链接（可点击跳转） |
| 3 | Layer 2 消息 | 以无权限用户身份触发 | 消息卡片显示 what + impact + 谁可以修 + 「发送提醒」按钮 |
| 4 | Layer 2 通知 | 点击「发送提醒」 | admin 收到站内通知（含 workspace / agent / 错误描述 / 发起人 / 修复链接） |
| 5 | Layer 3 兜底 | 删除该错误码注册 → 再次触发 | 消息卡片显示「此问题已自动登记（登记号 #N）」+ 系统自动登记 issue |
| 6 | 修复后恢复 | admin 修复完成后 | 发起提醒的用户收到回执；agent 状态更新 |

### 全链路验证（CI / E2E）

当错误码注册数量 ≥ 5 条时，将上述验证项中的 #1-#5 加入 CI E2E 测试（对应 G10）。

---

## §8 待 lead 裁定

以下 3 项在文档撰写时无法决策，需 Allen 裁定后锁定：

| # | 决策项 | 选项 | 影响 |
|---|--------|------|------|
| **D1** | **错误码注册表放在哪个 app 下？** | A: `ezagent_domain_agent`（靠近 agent 概念）<br>B: `ezagent_core`（作为通用 infrastructure，所有 domain 共用） | 决定了 `ErrorCode` / `ErrorMatcher` / `ErrorRenderer` 三个模块的 namespace 和依赖方向 |
| **D2** | **beta 第一批注册几条？** | A: 2 条最小路径（#1 agent_credential_missing + #3 action_unauthorized），跑通全链路后再加<br>B: §6 列出的全部 7 条（含 quota_exhausted 需先实现配额机制） | 决定了 beta 阶段的实施范围：A = 先验证机制可行性，B = 一次性覆盖常见 case |
| **D3** | **渲染链路改造范围？** | A: 只改后端 `world_live.ex` 的 dispatch 结果处理 + 现有前端消息组件扩展<br>B: 需要新建前端消息卡片组件（结构化渲染 what/impact/action，非纯文本） | 决定了前端工作量：A = 最小改动，B = 新组件开发 |

---

## §9 关联文档

- G5 产品计划（三层错误处理 blueprint + 12 条 AC）：`docs/plans/2026-07-16-workspace-self-service-product-plan.md` §3
- G5 产品计划中的 G5 待办（SOP 文档 + 错误用例收集）：同上 §3 G5 待办
- G10 E2E 锁定：同上 §5 G10
