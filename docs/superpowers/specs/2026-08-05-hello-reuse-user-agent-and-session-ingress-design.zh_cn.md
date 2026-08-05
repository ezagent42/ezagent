# Hello：复用用户 LLM agent 与 Session 入站处理设计

## 状态

设计已确认，待进入实现计划。本文件不允许以“同 flavor”为由绕过 recipe 兼容性检查。

## 问题

创建 `session.hello` 目前会物化 `front-desk` 与 `llm` 两个 agent。前者只是确定性的“聊天消息 → Session action”转发器；后者没有复用创建者已经认证的 agent，因而产生不必要的新身份，并可能要求再次登录。

## 决策

1. Hello **template** 只描述团队结构，不能保存用户 agent URI 或凭证。
2. 创建 Hello **session** 时选择 LLM agent。表单支持 Hello 支持的全部 LLM flavor；用户选择其中一个 flavor 后，表单只列出当前用户可管理、已就绪/认证、flavor 一致且 recipe 为 `hello.llm` 的 agent。`codex` 只是其中一个例子，不是特例。
3. 把选择冻结进该 session 的 `hello` install 配置：

   ```elixir
   %{role_name: "llm", install_mode: :reuse, reuse_agent_uri: agent_uri, flavor: selected_flavor}
   ```

   安装只将其加入 session；不会重新创建、重新认证或在 session 删除时退休该 agent。
4. 移除 `front-desk` Hello role，不再物化它。确定性路由与受控出站消息职责迁回 Hello Session。

## 架构

### 通用 Session 入站机制

domain-session 增加通用、声明式的 Session 入站投递机制。socialware definition 可以声明某个已注册的 Session action 是入站消息处理器。通用层负责解析与调用，不能出现任何 Hello 专用分支。

Hello 在其 definition 中声明该 handler。Hello plugin 的 action 调用现有意图与所有权路由，再对 Session dispatch `rebuild`、`answer`、`share`、`publish` 或 `delegate_to_kanban`。这取代当前“路由到 agent，再由 AgentBridge 处理”的路径。

ingress 是默认用户消息的唯一入口。mention 被复用的 `llm` 成员不能直接投递，也不能绕过 owner/visitor 策略：它仍作为普通输入交由 ingress 处理。移除当前 web 层对 `front-desk` 的 mention 注入；通用 mention fan-out 也不能把 Hello 消息直接投递给内部 `llm` 成员。

页面生成说明、问答和分享的发送者改为 Session，不再以 `front-desk` 作为 actor。发送者必须保持 session 范围和可审计性，不能引入伪造 agent 身份。

### Domain 边界清理

既有 `role_slots` 覆盖与 reuse 机制已经是通用 domain 能力，保留该通用性，不能为本需求增加任何 `hello` 条件。

下列现有生产特例必须移除或泛化：

- domain-agent 中仅为即将退休的 `front-desk` 而存在的 `"hello" -> :hello_sync_result` AgentBridge 返回 action 映射；
- domain-agent-bridge 中的 `hello_completion_request_id` payload key，改为通用 completion request identifier。
- web Session-feed 对 `front-desk` 的 mention 注入。World view 中 `:hello_page` fallback 也改为只依赖通用 view registry。

`Ezagent.Socialware.Demo.Hello` 只是读取已发布 manifest 的测试 fixture，不属于生产运行时的 Hello 行为。可以后续迁移，但不属于本次 ingress/reuse 的运行时设计。

### 复用安全性

候选列表只是便利；创建命令在 install 前必须重新验证：

- URI 是当前调用者在选定 workspace 中可管理的 agent；
- 该 agent 的 live/durable 状态为所选 flavor，且凭证已就绪；
- durable recipe 精确为 `hello.llm`。

沿用既有 reuse 路径负责加入成员和绑定已兼容的 recipe。仅 flavor 一致不足够：flavor 定义执行方式；recipe 定义角色、沙箱配置、技能与授权契约。

## 错误与生命周期

- 无候选 agent：禁用提交，并提示先创建或认证兼容的 `hello.llm` agent。
- 提交时发现选择已失效、无权、未就绪或不兼容：以明确、用户可见的错误拒绝创建；绝不降级为创建新的无凭证 LLM agent。
- 移除或删除 Hello session 只删除 membership edge；复用 agent、其凭证与原有 ownership 必须保留。
- 已存在 session 保留已物化的 `front-desk`。如需迁移，必须另行显式设计，确保升级过程中的消息路由持续可用。

## 验证

测试必须证明：

1. selector 支持 Hello 的全部 LLM flavor，且只返回调用者可管理、已就绪、flavor 匹配且 recipe 为 `hello.llm` 的 agent；
2. 选定的 `codex` agent 被复用为 `llm`，不会创建新的 LLM agent；
3. 缺失或无效选择可见失败，不会 fallback；
4. 新 Hello session 没有 `front-desk` member，但用户消息仍到达声明的 Session ingress，并执行同样受保护的 action；
5. 删除 session 或 member 不会退休复用 agent，且保持其 ownership 与凭证；
6. 授权与防循环行为继续 fail-closed。
7. `@llm-agent` 不能直接调用复用 agent，也不能绕过 owner/visitor 策略。
