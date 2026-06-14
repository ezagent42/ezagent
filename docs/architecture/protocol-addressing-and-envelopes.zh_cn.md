# 协议 — 寻址与信封

> **持久架构参考。** ezagent wire 协议的薄形式化：东西如何被*寻址*（URI），
> 一个请求如何被*包裹*（Invocation 信封 + 它携带的 Message 载荷）。本文是权威
> 交叉索引；字段级穷举细节在内联引用的模块 `@moduledoc`。消息*流转*（IM → session
> → agent 扇出）见 [`communication-overview.zh_cn.md`](./communication-overview.zh_cn.md)。
>
> 双语镜像：[`protocol-addressing-and-envelopes.md`](./protocol-addressing-and-envelopes.md)。
> `file`/模块引用是时间点快照 —— 以当前代码为准。

## 1. 寻址 — URI

系统里每个可寻址的东西都由 URI 命名。真相源：`Ezagent.URI`
（`apps/ezagent_core/lib/ezagent/uri.ex`）—— URI 解析/构造的*唯一*授权之地
（CI 不变式禁止 product `lib/` 里直接用 stdlib `URI.*`）。

### 1.1 文法

```
address       = scheme "://" authority [ "?" "action=" verb ]
verb          = behavior "." action          ; 例如 session.send
```

per-tenant scheme 把 workspace 放在 authority 第一段，因此 workspace 身份可从路径
O(1) 提取（SPEC v3 §3.6）：

```
<scheme>://<workspace>/<type>/<name>[?action=<behavior>.<action>]
```

| scheme       | 形状                                       | `<type>` 轴                   |
|--------------|--------------------------------------------|------------------------------|
| `entity://`  | `entity://<ws>/<type>/<name>`              | `user` \| `agent`            |
| `session://` | `session://<ws>/<template>/<name>`         | session 实例化自的 template  |
| `template://`| `template://<ws>/<type>/<name>`            | `agent` \| `session`         |
| `resource://`| `resource://<ws>/<type>/<name>`            | 资源种类（`uploads` …）       |
| `workspace://`| `workspace://<name>`                      | —（租户根）                  |
| `system://`  | `system://<type>/<name>`                   | 跨 workspace                 |

### 1.2 两条承重原则

1. **路径是身份；query 携带动词。** 路径唯一标识*寻址的是什么*；
   `?action=<behavior>.<action>` 选择对它*调用哪个 Behavior + action*
   （`Ezagent.URI.behavior_action/1`、`with_action/3`）。裸路径（无 `?action=`）
   是身份引用；路径 + `?action=` 是派发 target。

2. **规范形（canonical form）是不变式，不是便利项。** 同一逻辑 URI 必须只有一个
   `%URI{}` 表示。`URI.parse/1`（stdlib，RFC-2396）产出 `authority: "<ws>"`；
   规范构造器产出 `authority: nil`（RFC-3986）。两者 `to_string/1` 字节相同但 struct
   不 `==`，于是用其中一个做 key、用另一个查的 map/ETS/MapSet 会**静默 miss**
   ——「整个系统最贵的 URI bug 类」（Allen 2026-05-30，*"地址静默错误是不可接受的"*）。
   防御，从强到弱：`new!/1`（规范构造器，校验 scheme + 形状，`canonical!` 后置条件）·
   `parse/1`（不抛的入站边界，同一规范形）· `canonical?/1`（谓词）·
   `canonical!/1`（响亮的结构守卫）· `with_action/3`（规范派发-target 构造器）。
   完整阶梯 + `UriCanonicalizationInvariantTest` CI gate 见 `Ezagent.URI` 的 `@moduledoc`。

### 1.3 Scheme 注册表（运行时，非编译期）

被接受的 scheme 是活的 `Ezagent.URI.SchemeRegistry` ETS allowlist，boot 时种入
`entity`、`workspace`、`session`、`template`、`resource`、`system`（SPEC §5.6）。
插件只能经 `Ezagent.SpawnRegistry.register/2` 扩展它 —— 新 Kind 的 scheme 与它的
spawn 接线一同注册，绝不硬编码。

## 2. 信封 — Invocation 与 Message

有两层嵌套信封。**Invocation** 是*任何*派发的通用请求外壳；**Message** 是
entity↔entity（chat/session）通信的身份不变*载荷*。

### 2.1 Invocation — 通用请求形状

`Ezagent.Invocation`（`apps/ezagent_core/lib/ezagent/invocation.ex`）。每个 adapter
（Feishu webhook、CLI、LiveView、MCP…）都构造同一个 struct 并调 `dispatch/1`；
12 步派发路径与 adapter 无关。

```elixir
%Ezagent.Invocation{
  target: %URI{},   # 地址（§1）含 ?action= 动词
  mode:   :call | :cast | :call_stream | :subscribe | :introspect,
  args:   %{},      # action 参数（消息场景：%{message: %Message{}}）
  ctx:    %{caller: %URI{}, caps: MapSet.t(Capability), reply: reply_target, ...}
}
```

- **`target`** —— *在哪 + 做什么*：被寻址的 URI 加 `?action=` 动词。
- **`mode`** —— 交互形状。`:call` 阻塞等回复（于是 cap 拒绝能冒泡回人，Decision #134）；
  `:cast` 是 fire-and-forget。
- **`ctx`** —— *谁 + 怎么回*：`caller`（URI）、`caps`（在 CapBAC 收口 step 5.5 校验的
  能力集）、`reply`（7 种 reply target 之一 —— `:caller_inbox` / `:phoenix_pubsub` /
  `:ignore` / 协议绑定的 `:plug_conn` / `:phoenix_channel` / `:stdio_pipe` /
  `:mcp_response`）。可选：`trace_id`、`deadline_ms`、`idempotency_key`。

派发是拆分的：`Invocation` 拥有 step 1-4 + 11-12（构建、路由、回复）；
`Ezagent.Kind.Runtime` 在目标 Kind 的 GenServer 里拥有 5-10 —— 含 step 5.5
（CapBAC `matches?`）与 step 5.6（workspace 隔离 → `{:error, :cross_workspace_denied}`，
与 `:unauthorized` 区分）。

### 2.2 Message — 身份不变的载荷

`Ezagent.Message`（`apps/ezagent_core/lib/ezagent/message.ex`）是 *Invocation `args`
形状的特化*（Decision #39/#40），作为 `args.message` 挂在 `session.send` / `*.receive`
invocation 上。

```elixir
%Ezagent.Message{
  id:          "<uuid hex>",     # 纯 UUID —— 不是 `message://` URI（PR #149 退役）
  sender:      %URI{},           # 创作它的 entity://user|agent
  mentions:    [%URI{}],         # @-目标
  body:        %{text: String.t(), attachments: [%URI{}]},
  ref_id:      String.t() | nil, # 回复某条 message id
  inserted_at: %DateTime{},
  visibility:  :customer_visible | :operator_only,
  # session_uri / workspace_uri 在持久化时盖戳；legend_triggers 是 VIRTUAL、
  # 不上 wire 的路由提示（从不序列化）。
}
```

**身份不变式（承重规则）。** 一条 Message 的身份 —— `sender`、`mentions`、`body`、
`ref_id`、`inserted_at` —— 在**任意多次 routing / forwarding 跳转中不可变**。中转者
（路由扇出、跨 session 再入、外部镜像）创建一个**新 Invocation** 把该 Message *携带*
给下一个接收者；它**从不修改 Message 本身**。这就是「谁说了什么」无论消息穿过多少
session 或 adapter 都稳定的原因。具体扇出（`session.send` → 每接收者 `*.receive`）
见 `communication-overview.zh_cn.md` §2-3。

Message 是 session 内部数据，不是可派发的 Kind —— 没有 `message://` scheme。它的 `id`
只活在 messages 表 + LiveView stream 的 `dom_id`。

## 3. 两层如何组合

```
adapter 事件 ─▶ 构建 %Invocation{ target: session://ws/tmpl/name?action=session.send,
                                   args:  %{message: %Message{…}},      ◀── 载荷（身份不变）
                                   ctx:   %{caller, caps, reply} }        ◀── 信封（谁/怎么回）
            ─▶ dispatch/1 ─▶ 路由解析接收者 ─▶ 对每个：
               构建一个新 %Invocation{ target: <recipient>?action=<kind>.receive,
                                        args: %{message: 同一个 %Message{}} }   ◀── 包裹，不修改
```

- **URI** 回答*在哪 + 做什么*（§1）。
- **Invocation** 回答*谁在请求、怎么回复、什么 mode*（§2.1）。
- **Message** 回答*说了什么*，并保证它在传输中不变（§2.2）。

## 4. 开放 / 推迟

- **Message schema 版本化**（本任务的代码部分）推迟到 im→session→agent 物理拆分之后
  （`Entity.Session` / `Message` 正在迁移中）。加入时，Message 信封上的
  `schema_version` 字段让 wire 格式可演进而不破坏已持久化的行或在途中转 —— 与首个
  向后不兼容的 body 改动一起出 spec。

## 5. 交叉引用

- [`communication-overview.zh_cn.md`](./communication-overview.zh_cn.md) —— 消息流转 + 扇出。
- `Ezagent.URI` `@moduledoc` —— 穷举 URI 规则、规范形阶梯、parser 分层。
- `Ezagent.Invocation` / `Ezagent.Message` 的 `@moduledoc` —— 完整字段语义。
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` —— 规范形硬化。
- `docs/superpowers/specs/2026-06-05-unify-uri-query-design.md` —— URI-作为-不透明-id 的查询模型。
