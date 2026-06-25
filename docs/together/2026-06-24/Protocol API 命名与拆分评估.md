# Protocol API 命名与拆分评估

  ## 结论

  不建议把 `ezagent_plugin_protocol_api` 拆成三个独立 plugin：

  - `openai-completions`
  - `openai-responses`
  - `anthropic-api`

  也不建议改名为 `restful-api`。

  更推荐保留一个 plugin，并将其定位明确为：

  > **LLM Protocol API**：ezagent 的入站 OpenAI/Anthropic wire-protocol 兼容层。

  短期建议：

  - 代码 app/slug 暂时保留 `ezagent_plugin_protocol_api` / `protocol_api`
  - UI 展示名、文档、模块结构逐步改成 `LLM Protocol API`
  - 内部按协议 endpoint 拆模块，而不是按供应商拆 plugin

---

  ## 原始设计思想

  `protocol_api` 原始设计不是普通 REST API，也不是单纯的 OpenAI API wrapper。

  它的目标是让外部工具可以把 ezagent agent 当成 OpenAI/Anthropic endpoint 来调用：

  - OpenAI `POST /v1/chat/completions`
  - OpenAI `POST /v1/responses`
  - Anthropic `POST /v1/messages`

  也就是说，它解决的是：

  > 外部 LLM 协议请求 → ezagent session/agent → 协议形态响应

---

  ## 与 Feishu Inbound 的关系

  原设计里，`protocol_api` 被明确建模为 **Feishu inbound 的同类物**。

  ### Feishu

  ```text
Lark webhook
    -> parse sender/chat
    -> resolve chat_id -> session
    -> build Ezagent.Message
    -> dispatch session.send
    -> agent replies async
    -> Feishu binding pushes back to Lark
  ```

### Protocol API

```  
OpenAI/Anthropic HTTP request
    -> parse bearer/api key
    -> resolve conversation_id -> session
    -> build Ezagent.Message
    -> dispatch session.send
    -> agent replies async
    -> reply waiter correlates ref_id
    -> HTTP/SSE/poll response returns protocol-shaped reply
```

  核心差异只有一个：

  > Feishu 是异步外部回复；Protocol API 需要同步 HTTP、SSE 或轮询式返回。

  所以 protocol_api 的核心不是 REST，而是 入站协议适配 + request-scoped reply transport。

---

  ## 当前实现状态

  当前 ezagent_plugin_protocol_api 已实现的主要内容：

  - POST /v1/chat/completions
  - GET /v1/chat/completions/:id
  - OpenAI Chat Completions 兼容入口
  - API key 验证：protocol_api_keys
  - conversation_id -> session 持久绑定
  - pending reply store
  - reply waiter
  - request id / ref_id 关联
  - ExternalAdapter :request_scoped 形态

  当前尚未实现：

  - OpenAI /v1/responses
  - Anthropic /v1/messages
  - 真正 token-level streaming
  - inbound tool calling
  - 完整 model -> agent routing UI

  因此现在的名字 Protocol API 容易显得抽象，因为实现面还只有 OpenAI Chat Completions。

---

  ## 为什么不拆成三个 plugin

  不建议拆成三个 plugin 的原因是：三种协议入口共享大量基础设施。

  共享内容包括：

  - API key 管理
  - workspace / entity / target agent 绑定
  - conversation_id 到 session 的映射
  - request id / reply ref_id 关联
  - pending reply 生命周期
  - reply waiter / SSE / polling
  - CapBAC / dispatch / session.send
  - model -> agent routing
  - per-key policy
  - 外部请求到内部 Ezagent.Message 的归一化

  如果拆成三个 plugin，会出现以下问题：

  - API key 表和 UI 重复
  - conversation binding 重复
  - request-scoped adapter 逻辑重复
  - 不同协议的 agent routing policy 容易分叉
  - 后续 tool calling / streaming 需要三处维护
  - plugin 数量增加，但边界没有变清楚

  除非未来明确需要：

  - 每个协议独立安装/禁用
  - 每个协议独立计费
  - 每个协议独立权限模型
  - 每个协议独立发布生命周期

  否则现在拆 plugin 成本大于收益。

---

  ## 为什么不建议叫 RESTful API

  restful-api 这个名字不合适。

  原因：

  1. 当前目标不是通用 REST API，而是 OpenAI/Anthropic wire protocol 兼容。
  2. repo 里已经有 /api/v1 这类内部通用 invoke API。
  3. RESTful API 容易让人误解成“ezagent 的资源管理 API”。
  4. OpenAI/Anthropic API 本身也不是严格 REST 资源语义，更像 RPC-style HTTP protocol。

  所以 restful-api 会比 protocol_api 更模糊。

---

  ## 推荐命名

  ### 首选展示名

  LLM Protocol API

  含义清楚：

  - LLM：限定领域
  - Protocol：说明是 OpenAI/Anthropic wire protocol
  - API：说明对外 HTTP 接口

  ### 可选名称

  LLM Compatibility API

  优点是用户更容易理解“兼容 OpenAI/Anthropic”。

  ### 不太推荐

  LLM Gateway

  原因：

  - Gateway 容易让人以为它是 outbound proxy，把请求转发给外部模型。
  - 但当前真实语义是 inbound：外部工具调用 ezagent agent。

---

  ## 推荐代码结构

  保留一个 plugin：

  apps/ezagent_plugin_protocol_api

  内部逐步整理为：

  EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug
  EzagentPluginProtocolApi.OpenAI.ResponsesPlug
  EzagentPluginProtocolApi.Anthropic.MessagesPlug

  Ezagent.ProtocolApi.RequestNormalizer
  Ezagent.ProtocolApi.ResponseRenderer
  Ezagent.ProtocolApi.ApiKeyStore
  Ezagent.ProtocolApi.ConversationRegistry
  Ezagent.ProtocolApi.PendingReplyStore
  Ezagent.ProtocolApi.ReplyWaiter

  也可以未来重命名 namespace：

  Ezagent.LlmProtocol.ApiKeyStore
  Ezagent.LlmProtocol.ConversationRegistry
  Ezagent.LlmProtocol.ReplyWaiter

  但不建议马上大规模 rename，避免影响：

  - protocol_api_keys
  - adapter_id: "protocol_api"
  - external_mirror_bindings
  - migrations
  - route
  - scripts
  - docs

---

  ## 推荐演进路径

  ### Phase 0：现状修正

  保留 app 名：

  ezagent_plugin_protocol_api

  但调整展示名和文档：

  Protocol API -> LLM Protocol API

  说明：

  > Inbound OpenAI/Anthropic-compatible API for calling ezagent agents.

  ### Phase 1：模块整理

  把当前 OpenaiChatPlug 拆到更清晰的位置：

  OpenAI.ChatCompletionsPlug

  抽出共享层：

  RequestNormalizer
  ResponseRenderer
  ReplyTransport

  ### Phase 2：补齐协议入口

  新增：

  POST /v1/responses
  POST /v1/messages

  分别对应：

  OpenAI.ResponsesPlug
  Anthropic.MessagesPlug

  ### Phase 3：统一内部请求模型

  将不同协议请求统一成内部结构：

  %ProtocolApi.Request{
    provider: :openai | :anthropic,
    endpoint: :chat_completions | :responses | :messages,
    model: string,
    messages: list,
    tools: list,
    stream?: boolean,
    conversation_id: string | nil,
    target_agent: URI.t()
  }

  所有 endpoint 最终都走：

  request -> Ezagent.Message -> session.send -> reply -> protocol response

  ### Phase 4：高级能力

  - SSE streaming
  - token-level streaming
  - tool calling
  - model -> agent routing
  - per-key allowed models
  - per-key cap policy
  - API key management UI

---

  ## 最终建议

  保留一个 plugin，不拆供应商 plugin。

  推荐定位：

  LLM Protocol API

  推荐原则：

  - plugin 级别：负责入站 LLM 协议兼容
  - module 级别：按 OpenAI / Anthropic endpoint 拆
  - shared 层：统一 API key、conversation binding、reply waiter、request normalization
  - route 层：兼容 OpenAI/Anthropic 原始 path

  一句话：

  > protocol_api 原方向是对的，问题主要是名字太抽象、当前实现只覆盖 OpenAI Chat Completions。应改清楚展示名和内部模块边界，而不是拆成多个 plugin。