# 通用可配置错误机制 — 错误码注册表（Living Doc）

> 2026-07-17 · ruihua（designer）· **Living Document** — 新功能上线时功能负责人按 SOP 在此文档追加。
> 每条错误码的 trigger 均从源码中精确提取，含文件路径和行号。
> 格式遵循 `docs/plans/2026-07-17-error-mechanism-sop.md` §2 Schema。
> **本文件合并了第一批（7 条）+ 第二批（17 条用户可感知 + 6 条内部兜底），共 30 条。**

---

## 目录

- [用户可感知错误码](#用户可感知错误码)（24 条 — Layer 1/2/3 完整交互）
- [仅 Layer 3 兜底](#仅-layer-3-兜底)（6 条 — 内部框架错误，系统自动登记）

---

## 用户可感知错误码

### 总览

| # | code | category | trigger | 来源 |
|---|------|----------|---------|------|
| 1 | `agent_credential_missing` | credential | `{:error, {:no_api_key, _}}` | `curl_agent.ex:250` |
| 2 | `agent_not_ready` | lifecycle | `{:error, :not_ready}` | `invocation.ex:208,249` |
| 3 | `action_unauthorized` | permission | `{:error, :unauthorized}` | `runtime.ex:365,403` |
| 4 | `cross_workspace_denied` | permission | `{:error, :cross_workspace_denied}` | `runtime.ex:665` |
| 5 | `invalid_args` | validation | `{:error, {:bad_args, _, _}}` | `api_keys.ex:166` 等多处 |
| 6 | `member_not_registered` | validation | `{:error, {:member_not_registered, _}}` | `session.ex:855` |
| 7 | `quota_exhausted` | resource | `{:error, :quota_exhausted}` | 待实现 |
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

---

### 逐条定义

#### 1. agent_credential_missing

```elixir
%{
  code: "agent_credential_missing",
  trigger: {:error, {:no_api_key, _}},
  category: :credential,
  message: %{
    what: "Agent 未配置凭证",
    impact: "无法调用 AI 模型，你的消息暂时无法得到回复",
    fix_path: :workspace_agent_settings,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex:250` — agent 收到 `{:no_api_key}` 后向用户回复错误的位置
```elixir
{:error, {:no_api_key, provider}} ->
  reply_text = "no API key for provider `#{provider}` — please add one at ..."
```

---

#### 2. agent_not_ready

```elixir
%{
  code: "agent_not_ready",
  trigger: {:error, :not_ready},
  category: :lifecycle,
  message: %{
    what: "Agent 正在启动中",
    impact: "请稍等片刻后重试。如持续出现，请联系 workspace founder",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `apps/ezagent_core/lib/ezagent/invocation.ex:208,249`
**说明：** 暂时性状态——agent 激活完成后自行恢复。建议渲染逻辑：错误出现 < 3 次 → 只显示「重试」；≥ 3 次 → 追加「联系 founder」。

---

#### 3. action_unauthorized

```elixir
%{
  code: "action_unauthorized",
  trigger: {:error, :unauthorized},
  category: :permission,
  message: %{
    what: "你没有权限执行此操作",
    impact: "如需访问，请联系 workspace founder",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `runtime.ex:365,403`（CapBAC 拒绝）；`identity.ex:450,618,637,654,674`（VM-internal 防护）

---

#### 4. cross_workspace_denied

```elixir
%{
  code: "cross_workspace_denied",
  trigger: {:error, :cross_workspace_denied},
  category: :permission,
  message: %{
    what: "不允许跨工作区访问",
    impact: "此操作涉及的其他工作区不在你的访问范围内",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `runtime.ex:665`；`external_mirror/gates.ex:256`

---

#### 5. invalid_args

```elixir
%{
  code: "invalid_args",
  trigger: {:error, {:bad_args, _, _}},
  category: :validation,
  message: %{
    what: "输入内容不符合要求",
    impact: "请修改后重试",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `api_keys.ex:166,181,194`；`user_credentials.ex:154`
**说明：** `{:bad_args, msg, args}` 的 `msg` 可在渲染时提取展示。与 #14（`invalid_args_schema`）来自不同代码路径——#5 = handler 内部校验，**#14 = 框架层 schema 校验**。

---

#### 6. member_not_registered

```elixir
%{
  code: "member_not_registered",
  trigger: {:error, {:member_not_registered, _}},
  category: :validation,
  message: %{
    what: "目标成员未注册",
    impact: "无法完成此操作，目标成员可能尚未加入此工作区",
    fix_path: nil,
    fix_owner: :workspace_founder
  }
}
```

**来源：** `session.ex:855`

---

#### 7. quota_exhausted

```elixir
%{
  code: "quota_exhausted",
  trigger: {:error, :quota_exhausted},
  category: :resource,
  message: %{
    what: "工作区 API 调用配额已用完",
    impact: "Agent 暂时无法回复消息",
    fix_path: :workspace_quota_settings,
    fix_owner: :workspace_founder
  }
}
```

**来源：** 待实现——当前仓库无配额机制。需新建配额检查模块 + 钩入 `runtime.ex` dispatch pipeline。

---

#### 8. agent_not_found

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

**来源：** `invocation.ex:218,327,365,415,422,425`

---

#### 9. agent_startup_failed

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

**来源：** `invocation.ex:211,236` — ReadyGate 状态为 `:failed`

---

#### 10. agent_activate_timeout

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

**来源：** `invocation.ex:257`
**与 #2 的关系：** `agent_not_ready` = 启动中（暂时）；`agent_activate_timeout` = 超时（需干预）。

---

#### 11. unsupported_mode

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

**来源：** `invocation.ex:118`

---

#### 12. unknown_action

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

**来源：** `runtime.ex:723,784`；`behavior_set.ex:269`

---

#### 13. handler_exception

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

**来源：** `runtime.ex:879` — handler 执行中抛出异常。`fix_owner = nil` → 直接走 Layer 3 兜底。

---

#### 14. invalid_args_schema

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

**来源：** `interface_validator.ex:61` — 框架层 schema 校验。与 #5（handler 内部 `:bad_args`）互补。

---

#### 15. passive_actor_cannot_join

```elixir
%{
  code: "passive_actor_cannot_join",
  trigger: {:error, {:passive_actor_cannot_join, _}},
  category: :permission,
  message: %{
    what: "此成员无法加入会话",
    impact: "数据类型的成员不能作为参与者加入会话",
    fix_path: nil,
    fix_owner: nil
  }
}
```

**来源：** `session.ex:813`

---

#### 16. member_not_joined

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

**来源：** `session.ex:926`

---

#### 17. role_requires_user_uri

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

**来源：** `session.ex:920,923`

---

#### 18. human_role_not_declared

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

**来源：** `session.ex:948`

---

#### 19. invalid_role_name

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

**来源：** `session.ex:915`

---

#### 20. invalid_consent_command

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

**来源：** `session.ex:1022`

---

#### 21. sandbox_destroyed

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

**来源：** `sandbox.ex:306,382`

---

#### 22. config_dir_not_materialized

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

**来源：** `sandbox.ex:785`

---

#### 23. message_store_write_failed

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

**来源：** `session.ex:707`

---

#### 24. stale_incarnation

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

**来源：** `invocation.ex:419,534`

---

## 仅 Layer 3 兜底

以下 6 条为纯内部框架错误——用户几乎不可能遇到，即使遇到也无法采取任何行动。注册目的：**当这些错误意外暴露给用户时，系统自动登记 issue 而非显示裸 atom**。

| # | code | trigger | 来源 |
|---|------|---------|------|
| I1 | `handler_return_invalid` | `{:error, {:bad_handler_return, _, _, _}}` | `runtime.ex:870` |
| I2 | `missing_handler` | `{:error, {:missing_handler, _, _}}` | `runtime.ex:796` |
| I3 | `not_a_behavior` | `{:error, {:not_a_behavior, _}}` | `runtime.ex:754` |
| I4 | `snapshot_version_mismatch` | `{:error, {:snapshot_version_too_old, _, _}}` 或 `{:snapshot_version_too_new, _, _}` | `snapshot.ex:284,288` |
| I5 | `identity_read_unavailable` | `{:error, :identity_read_unavailable}` | `runtime.ex:413` |
| I6 | `buffer_full` | `{:error, :buffer_full}` | `invocation.ex:502` |

**统一兜底消息：** `fix_path = nil`，`fix_owner = nil`。渲染时跳过 Layer 1/2 判断，直接显示：「Agent 执行时遇到内部错误。此问题已自动登记（登记号 #N），团队会跟进处理」。

---

## 实施顺序

| 优先级 | 错误码 | 理由 |
|:--:|------|------|
| **P0** | #3 `action_unauthorized` + #1 `agent_credential_missing` | 最高频失败场景（权限 + 凭证） |
| **P1** | #8 `agent_not_found` + #9 `agent_startup_failed` + #10 `agent_activate_timeout` + #13 `handler_exception` | dispatch 层 agent 消失/坏掉/超时/崩溃 |
| **P2** | #2 `agent_not_ready` + #4 `cross_workspace_denied` + #5 `invalid_args` + #6 `member_not_registered` | 中频用户可感知 |
| **P3** | #15–#20（session 6 条）+ #21–#24（sandbox 4 条） | 用户操作触发，频率较低 |
| **P4** | #11 `unsupported_mode` + #12 `unknown_action` + #14 `invalid_args_schema` | 用户几乎不会直接触发 |
| **P5** | #7 `quota_exhausted` | 依赖新建配额机制 |
| **P6** | I1–I6（仅 Layer 3 兜底） | 内部框架错误，只需注册 trigger + 统一兜底消息 |

---

## 追加指南

新功能上线时，功能负责人按 SOP（`docs/plans/2026-07-17-error-mechanism-sop.md` §3）收集错误 case 后，在此文档末尾追加：

1. 在「用户可感知」或「仅 Layer 3 兜底」的总览表中新增一行
2. 在对应章节新增逐条定义（按 §2 Schema 格式）
3. 更新「实施顺序」表（如该错误码需要优先注册）

**命名规则：** `code` 使用 snake_case，格式 `{category}_{具体场景}`。新错误码编号从 #25 起（I 系列继续 I7、I8…）。
