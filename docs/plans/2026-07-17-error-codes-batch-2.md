# 通用可配置错误机制 — 第二批错误码（补充注册）

> 2026-07-17 · ruihua（designer）· 基于全仓库 `{:error, ...}` 返回扫描
> 第一批 7 条已注册（`docs/plans/2026-07-17-error-codes-batch-1.md`）。
> 第二批覆盖 dispatch 层 + session + sandbox 中**用户可感知**的错误。
> 纯内部框架错误（snapshot 版本、behavior_set 内部等）归入 §尾部「仅 Layer 3 兜底」——注册但不设计 Layer 1/2 交互。

---

## 概览

### 用户可感知（本批次主体，17 条）

| # | code | category | trigger | 来源 |
|---|------|----------|---------|------|
| 8 | `agent_not_found` | lifecycle | `{:error, :no_such_actor}` | `invocation.ex:218,327,365` |
| 9 | `agent_startup_failed` | lifecycle | `{:error, :failed}` | `invocation.ex:211,236` |
| 10 | `agent_activate_timeout` | lifecycle | `{:error, :activate_timeout}` | `invocation.ex:257` |
| 11 | `unsupported_mode` | lifecycle | `{:error, :unsupported_mode}` | `invocation.ex:118` |
| 12 | `unknown_action` | validation | `{:error, {:unknown_action, _}}` | `runtime.ex:723,784` |
| 13 | `handler_exception` | lifecycle | `{:error, {:behavior_exception, _, _}}` | `runtime.ex:879` |
| 14 | `invalid_args_schema` | validation | `{:error, {:invalid_args, _}}` | `interface_validator.ex:61` |
| 15 | `passive_actor_cannot_join` | permission | `{:error, {:passive_actor_cannot_join, _}}` | `session.ex:813` |
| 16 | `member_not_joined` | validation | `{:error, :member_not_joined}` | `session.ex:926` |
| 17 | `role_requires_user_uri` | validation | `{:error, :assign_role_requires_user_uri}` | `session.ex:920` |
| 18 | `human_role_not_declared` | validation | `{:error, {:human_role_not_declared, _}}` | `session.ex:948` |
| 19 | `invalid_role_name` | validation | `{:error, :invalid_role_name}` | `session.ex:915` |
| 20 | `invalid_consent_command` | validation | `{:error, :invalid_consent_command}` | `session.ex:1022` |
| 21 | `sandbox_destroyed` | lifecycle | `{:error, :destroyed}` | `sandbox.ex:306,382` |
| 22 | `config_dir_not_materialized` | lifecycle | `{:error, {:config_dir_not_materialized, _}}` | `sandbox.ex:785` |
| 23 | `message_store_write_failed` | lifecycle | `{:error, {:message_store_write_failed, _}}` | `session.ex:707` |
| 24 | `stale_incarnation` | lifecycle | `{:error, :stale_incarnation}` | `invocation.ex:419,534` |

### 仅 Layer 3 兜底（纯内部框架错误，6 条）

| # | code | trigger | 说明 |
|---|------|---------|------|
| I1 | `handler_return_invalid` | `{:error, {:bad_handler_return, _, _, _}}` | handler 返回格式不符合 `{:ok,...}/{:error,...}` 约定 |
| I2 | `missing_handler` | `{:error, {:missing_handler, _, _}}` | `handle_<action>/2` 未导出 |
| I3 | `not_a_behavior` | `{:error, {:not_a_behavior, _}}` | 模块不是新式 behavior |
| I4 | `snapshot_version_mismatch` | `{:error, {:snapshot_version_too_old, _, _}}` 或 `{:snapshot_version_too_new, _, _}` | snapshot 版本不兼容 |
| I5 | `identity_read_unavailable` | `{:error, :identity_read_unavailable}` | caller identity slice 读取瞬时失败 |
| I6 | `buffer_full` | `{:error, :buffer_full}` | PendingDelivery 缓冲区满 |

---

## 用户可感知错误码（逐条定义）

### 8. agent_not_found

```elixir
%{
  code: "agent_not_found",
  trigger: {:error, :no_such_actor},
  category: :lifecycle,
  message: %{
    what: "Agent 不存在或已被移除",
    impact: "无法处理你的请求",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `invocation.ex` — dispatch 时 target Kind 无 snapshot + 无 live 进程（line 218, 327, 365）；或 dead target race（line 415, 422, 425）。

---

### 9. agent_startup_failed

```elixir
%{
  code: "agent_startup_failed",
  trigger: {:error, :failed},
  category: :lifecycle,
  message: %{
    what: "Agent 启动失败",
    impact: "无法处理你的请求，请联系 workspace founder 检查 Agent 配置",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `invocation.ex:211` — ReadyGate 状态为 `:failed`（agent 激活过程出错）。

---

### 10. agent_activate_timeout

```elixir
%{
  code: "agent_activate_timeout",
  trigger: {:error, :activate_timeout},
  category: :lifecycle,
  message: %{
    what: "Agent 启动超时",
    impact: "Agent 初始化时间过长，请稍后重试。如持续出现，请联系 workspace founder",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `invocation.ex:257` — `ReadyGate.await` 超时，agent 冷启动未在预期时间内完成。

**与 #2（agent_not_ready）的关系：** `agent_not_ready` = agent 正在启动中（暂时）；`agent_activate_timeout` = 启动超时（可能需要干预）。两条独立注册，渲染时可以给不同建议。

---

### 11. unsupported_mode

```elixir
%{
  code: "unsupported_mode",
  trigger: {:error, :unsupported_mode},
  category: :lifecycle,
  message: %{
    what: "不支持的操作模式",
    impact: "此操作尚未实现，无法完成你的请求",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `invocation.ex:118` — `:subscribe` / `:introspect` 模式尚未实现。

**说明：** 普通用户不太可能遇到此错误（`:subscribe` / `:introspect` 非用户直接调用的模式）。注册主要为 Layer 3 兜底——如果因 bug 暴露给用户，消息有意义。

---

### 12. unknown_action

```elixir
%{
  code: "unknown_action",
  trigger: {:error, {:unknown_action, _}},
  category: :validation,
  message: %{
    what: "不支持的操作",
    impact: "无法完成你的请求",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `kind/runtime.ex:723,784` / `kind/behavior_set.ex:269` — action 不在 Behavior 声明的 actions 列表中。

**说明：** 此错误通常是调用方 bug（请求了一个不存在的 action），非用户操作触发。注册主要为 Layer 3 兜底。

---

### 13. handler_exception

```elixir
%{
  code: "handler_exception",
  trigger: {:error, {:behavior_exception, _, _}},
  category: :lifecycle,
  message: %{
    what: "Agent 执行时遇到内部错误",
    impact: "无法完成你的请求。此问题已自动登记，团队会跟进处理",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `kind/runtime.ex:879` — handler 执行中抛出异常（catch kind + reason）。

**说明：** 用户无法自修。`fix_owner = nil` 意味着直接走 Layer 3——系统自动登记 issue，用户看到「已登记」。

---

### 14. invalid_args_schema

```elixir
%{
  code: "invalid_args_schema",
  trigger: {:error, {:invalid_args, _}},
  category: :validation,
  message: %{
    what: "输入内容不符合要求",
    impact: "请修改后重试",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `interface_validator.ex:61` — args schema 校验失败。

**与 #5（invalid_args）的关系：** #5 匹配 handler 返回的 `{:bad_args, _, _}`（action 内部校验失败）；#14 匹配 validator 返回的 `{:invalid_args, _}`（框架层 schema 校验失败）。触发路径不同，**两条都需要注册**。这是 Q1（bad_args vs invalid_args 不一致）的答案：两个都注册，因为它们来自不同的代码路径。

---

### 15. passive_actor_cannot_join

```elixir
%{
  code: "passive_actor_cannot_join",
  trigger: {:error, {:passive_actor_cannot_join, _}},
  category: :permission,
  message: %{
    what: "此成员无法加入会话",
    impact: "数据类型的成员（如知识库、看板）不能作为参与者加入会话",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:813` — RF-6 gate：passive data actor 尝试 join。

---

### 16. member_not_joined

```elixir
%{
  code: "member_not_joined",
  trigger: {:error, :member_not_joined},
  category: :validation,
  message: %{
    what: "目标成员尚未加入此会话",
    impact: "请先邀请该成员加入会话后再执行此操作",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:926` — `assign_role` 的目标成员不在 members map 中。

---

### 17. role_requires_user_uri

```elixir
%{
  code: "role_requires_user_uri",
  trigger: {:error, :assign_role_requires_user_uri},
  category: :validation,
  message: %{
    what: "角色只能分配给用户",
    impact: "请选择一位用户来担任此角色",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:920,923` — `assign_role` 的目标不是 user URI。

---

### 18. human_role_not_declared

```elixir
%{
  code: "human_role_not_declared",
  trigger: {:error, {:human_role_not_declared, _}},
  category: :validation,
  message: %{
    what: "未声明的角色",
    impact: "此角色尚未在会话中注册",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `session.ex:948` — role_name 未在 installation 中声明为 `:human` 角色。

---

### 19. invalid_role_name

```elixir
%{
  code: "invalid_role_name",
  trigger: {:error, :invalid_role_name},
  category: :validation,
  message: %{
    what: "无效的角色名称",
    impact: "请检查角色名称是否正确",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:915` — `assign_role` 调用时未提供 `role_name`。

---

### 20. invalid_consent_command

```elixir
%{
  code: "invalid_consent_command",
  trigger: {:error, :invalid_consent_command},
  category: :validation,
  message: %{
    what: "无效的同意指令",
    impact: "请检查操作是否正确",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:1022` — `composition_consent` 收到无效指令。

---

### 21. sandbox_destroyed

```elixir
%{
  code: "sandbox_destroyed",
  trigger: {:error, :destroyed},
  category: :lifecycle,
  message: %{
    what: "Agent 已被销毁",
    impact: "无法执行任何操作，请联系 workspace founder 创建新的 Agent",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `sandbox.ex:306,382` — sandbox 已销毁后尝试操作。

---

### 22. config_dir_not_materialized

```elixir
%{
  code: "config_dir_not_materialized",
  trigger: {:error, {:config_dir_not_materialized, _}},
  category: :lifecycle,
  message: %{
    what: "Agent 配置尚未就绪",
    impact: "请稍后重试。如持续出现，请联系 workspace founder",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `sandbox.ex:785` — config 目录尚未 materialize。

---

### 23. message_store_write_failed

```elixir
%{
  code: "message_store_write_failed",
  trigger: {:error, {:message_store_write_failed, _}},
  category: :lifecycle,
  message: %{
    what: "消息存储失败",
    impact: "你的消息可能未被保存，请重试",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:707` — MessageStore.write 在 `:send` 期间失败。

---

### 24. stale_incarnation

```elixir
%{
  code: "stale_incarnation",
  trigger: {:error, :stale_incarnation},
  category: :lifecycle,
  message: %{
    what: "Agent 状态已变更",
    impact: "Agent 在此期间被重建，请重试你的操作",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `invocation.ex:419,534` — cast 交付目标 incarnation 已变。

---

## 仅 Layer 3 兜底（内部框架错误）

以下 6 条为纯内部框架错误——用户几乎不可能遇到，即使遇到也无法采取任何行动。注册它们的目的：**当这些错误意外暴露给用户时，系统自动登记 issue 而非显示裸 atom**。

| # | code | trigger | 用户看到的消息（Layer 3 统一模板） |
|---|------|---------|-----------------------------------|
| I1 | `handler_return_invalid` | `{:error, {:bad_handler_return, _, _, _}}` | "Agent 执行时遇到内部错误。此问题已自动登记（登记号 #N），团队会跟进处理" |
| I2 | `missing_handler` | `{:error, {:missing_handler, _, _}}` | 同上 |
| I3 | `not_a_behavior` | `{:error, {:not_a_behavior, _}}` | 同上 |
| I4 | `snapshot_version_mismatch` | `{:error, {:snapshot_version_too_old, _, _}}` 或 `{:snapshot_version_too_new, _, _}` | 同上 |
| I5 | `identity_read_unavailable` | `{:error, :identity_read_unavailable}` | 同上 |
| I6 | `buffer_full` | `{:error, :buffer_full}` | 同上 |

> 对于仅 Layer 3 的错误码：`fix_path = nil`，`fix_owner = nil`。渲染时跳过 Layer 1/2 判断，直接走系统自动登记 issue。

---

## 两批合计

| 批次 | 条数 | 覆盖范围 |
|:--:|:--:|------|
| 第一批 | 7 | credential + permission + lifecycle + validation + resource（核心用户可感知） |
| 第二批（用户可感知） | 17 | dispatch 层 + session + sandbox（扩展用户可感知） |
| 第二批（仅 Layer 3） | 6 | 内部框架错误（兜底登记） |
| **合计** | **30** | |

---

## 实施顺序

| 优先级 | 错误码 | 理由 |
|:--:|------|------|
| **P0** | #8 `agent_not_found` + #9 `agent_startup_failed` + #10 `agent_activate_timeout` + #13 `handler_exception` | dispatch 层最常见用户可感知错误，覆盖 agent 消失/坏掉/超时/崩溃四个场景 |
| **P1** | #15–#20（session 6 条） | session join/role 错误，用户操作触发，频率中等 |
| **P2** | #21 `sandbox_destroyed` + #22 `config_dir_not_materialized` + #23 `message_store_write_failed` + #24 `stale_incarnation` | 频率较低但用户可能遇到 |
| **P3** | #11 `unsupported_mode` + #12 `unknown_action` + #14 `invalid_args_schema` | 用户几乎不会直接触发，主要为 Layer 3 兜底 |
| **P4** | I1–I6（仅 Layer 3 兜底） | 纯框架内部错误。只需注册 trigger + 统一兜底消息，无需设计 Layer 1/2 交互 |
