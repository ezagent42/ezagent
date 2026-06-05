# URI 设计 —— 当前状态 + 待决问题

状态：讨论草稿（Allen ↔ uri-design 子智能体）
开始日期：2026-05-19
负责人 / 决策者：Allen

目标是把代码库中所有 URI 收敛到一种一致的形状，让插件作者不必猜测"类型"放在哪里、子资源从哪里开始，或者主机段表示"身份"还是"命名空间"。我们已有的结构规则（`<instance>[/<sub-resource>]`）是健全的。不一致之处在于 **`<instance>` 在每个 scheme 下到底长什么样**。

---

## §1 清单

`apps/` 下当前被构造或解析的所有 URI scheme。列含义：

- **Scheme** —— `xxx://`
- **实例形状（Instance shape）** —— 用什么标识 Kind
- **子资源？（Sub-resource?）** —— 实例之后是否还会追加 `/...`
- **生成方式（Spawned via）** —— 注册机制
- **是否持久化？（Persisted?）** —— 能否跨 phx 重启保留
- **定义文件（Defining file）** —— 构造该 URI 的权威位置

| Scheme | 实例形状 | 子资源 | 生成方式 | 持久化 | 定义文件（行号） |
|---|---|---|---|---|---|
| `agent://` | `agent://<type>/<name>`（PR #131，带类型） | `/behavior/<kind>/<action>` | `SpawnRegistry("agent")` → `AgentTypeRegistry` | 是（通过 Workspace.session_templates） | `apps/ezagent_core/lib/ezagent/agent_type_registry.ex:96` |
| `session://` | `session://<name>`（扁平） | `/behavior/<kind>/<action>` | `SpawnRegistry("session")` | 快照 | `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:176` |
| `user://` | `user://<name>`（扁平） | `/behavior/identity/<action>` | `SpawnRegistry("user")` | 快照 | `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:71` |
| `workspace://` | `workspace://<name>`（扁平） | `/behavior/workspace/<action>` | n/a —— 由 Workspace API 创建 | 快照 | `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:78` |
| `template://` | `template://<class>/<name>[@<hash>]` —— 两种主机值：`agent`（无版本）与 `session`（带 `@hash`） | 原则上允许 `/behavior/...` | `SpawnRegistry("template")` 按 `uri.host` 分支（`agent` vs `session`） | 快照 | `apps/ezagent_domain_instance_message/lib/ezagent/entity/session_template.ex:136`、`apps/ezagent_domain_instance_message/lib/ezagent/entity/agent_template.ex:19` |
| `resource://` | `resource://uploads/<filename>` —— 主机段是"命名空间" | 当前无 | 非活跃 Kind —— 纯数据引用 | 磁盘文件系统 | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:230` |
| `system://` | `system://bootstrap`、`system://other`（扁平哨兵） | 无 | 非派生 —— 固定哨兵 | n/a | `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:24`、`apps/ezagent_core/lib/ezagent/capability.ex:10` |
| `message://` | `message://<uuid16>`（16 位十六进制，自动生成） | 无 | 非 Kind —— 不透明引用 | 是（messages 表） | `apps/ezagent_core/lib/ezagent/message.ex:101` |
| `feishu://` | `feishu://<chat_id>`（如 `oc_…`） | `/behavior/chat/<action>`（Receiver Kind） | `SpawnRegistry("feishu")` | 临时（DB 中规则指向它；按需 spawn） | `apps/ezagent_plugin_feishu/lib/ezagent/entity/feishu_chat.ex:44` |
| `pty-input://` | `pty-input://default`（单例） | `/behavior/pty/write` | 启动时 spawn | 临时 | `apps/ezagent_plugin_cc/lib/ezagent/entity/pty_input.ex:32` |
| `routing-admin://` | `routing-admin://default`（单例） | `/behavior/routing_admin/<action>` | 启动时 spawn | 临时 | `apps/ezagent_core/lib/ezagent/entity/routing_admin.ex:33` |

**遗留 / 已移除**：
- `curl-agent://<name>` —— 已删（PR #131 重写为 `agent://curl/<name>`）。
- `agent://<name>`（无类型段） —— 同一 PR 中删除；验证阶段会报错。

**解析层次说明**（`apps/ezagent_core/lib/ezagent/uri.ex`）：

- `parse!/1` 的 `@known_schemes` 是 `~w(agent session user resource system)` —— **5 个 scheme**。
- 实际使用中有 **11+** 个 scheme（见上表），还有 `feishu://` 以及若干单例。
- 因此 `Ezagent.URI.new!/1` 在遇到 `workspace://default`、`template://session/X@hash`、`feishu://oc_xxx`、`message://abcd`、`pty-input://default`、`routing-admin://default` 时会崩溃。
- 实际情况是大家都直接用 `URI.parse/1`（stdlib）来处理这些 —— 绕开了白名单。今天这个白名单是局部文档，而非被强制执行的不变量。
- `instance/1` 与 `subresource/1` 通过两个子句实现 scheme 感知：`agent://`（path = `/<name>/<sub>...`）与其它一切（path = `/<sub>...`）。`template://session/X@hash` 之所以能工作，是因为当后续没有路径时 `subresource("/")` 为空；但若有人尝试 `template://session/X@hash/behavior/...`，agent 风格的 2 段切分会错误地把 `X@hash` 当作 name、把 `behavior/...` 当作子资源 —— 这碰巧也是对的！ —— 不过纯属巧合；实际走的是"非 agent"分支，它会吞掉整个路径。

---

## §2 不一致之处

### 2.1 Authority 布局 —— agent 与 template 有"类型"，其它都没有

| 模式 | Scheme |
|---|---|
| `<scheme>://<name>`（主机段 = 身份，无子命名空间） | `session`、`user`、`workspace`、`message`、`feishu`、`pty-input`、`routing-admin`、`system` |
| `<scheme>://<type>/<name>`（主机段 = 类型，第 1 个路径段 = 名称） | `agent`、`template` |
| `<scheme>://<namespace>/<filename>`（主机段 = 命名空间，第 1 个路径段 = 条目 id） | `resource` |

三种不同的"主机段是什么？"约定。写新 scheme 的插件作者得读完所有现有 scheme 才知道该套用哪一种 —— 这一约定是隐式的。

### 2.2 `template://` 让主机段同时承担两种语义

- `template://agent/<name>` —— host="agent" 表示"Class 是 AgentTemplate"，无版本。
- `template://session/<name>@<hash>` —— host="session" 表示"Class 是 SessionTemplate"，通过 `@hash` 进行内容寻址。
- `template://session/<name>:<tag>` —— 同一 scheme，但用 `:tag` 代替 `@hash`（可变指针；`apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:74` 提到了，但我没找到写入方 —— 可能只是设计层）。

所以 `template://` 同时在做四件事：
1. 声明"这是一个模板"（scheme）。
2. 区分模板下的 Kind（host = "agent" vs "session"）。
3. 命名模板（第 1 个路径段）。
4. 可选地固定版本（`@hash`）或标签（`:tag`）。

这跟 `agent://<type>/<name>` 用类型段解决的是同一个模式 —— 只是 `template://` 加了版本化，而 `agent://` 没有。

### 2.3 `resource://uploads/...` 把主机段当作扁平命名空间

`resource://uploads/<filename>` 今天只有一个命名空间（"uploads"）。这个形状暗示"我以后可能会增加更多命名空间"（`resource://snapshots/X`？`resource://logs/Y`？），但实际并不存在。主机段在做的事情和 `agent://` 的类型段相同，但概念上叫法不同（"namespace" vs "type"），而且没有与 `AgentTypeRegistry` 对应的 `ResourceTypeRegistry`。

### 2.4 Behavior 子路径：精神上 scheme 无关，代码上 scheme 相关

子资源 `/behavior/<kind>/<action>` 是通用的 —— 每个 Kind 都通过它来分派。但在 URI 中它的 **起始位置** 取决于 scheme：

- `agent://cc/demo-builder/behavior/chat/receive` —— 子路径从 `/behavior/...` 开始，是第 2 段（在 `/<name>` 之后）。
- `session://main/behavior/chat/send` —— 子路径从 `/behavior/...` 开始，是第 1 段（紧跟在 host 之后）。

PR-A（PR #132）通过位置切分解决了 **解析器** 的歧义（解析器知道每个 scheme 的实例段在哪里结束）。但 **约定** 仍然是 scheme 相关的：一个新贡献者读到 `agent://X/Y/behavior/Z/W` 完全可能猜测 `Y` 是 behavior 路径的一部分。位置切分能工作，靠的是带外规则（agent 有 2 段实例段，其它只有 1 段）。

### 2.5 内容寻址只存在于 `template://`

`@hash` 是 SessionTemplate 独有的。没有其它 scheme 拥有任何版本 / 内容寻址。如果将来某个 Agent Kind 想要快照不可变的身份（例如 `agent://cc/demo-builder@v3`），没有共享约定可以依靠 —— 只能逐 scheme 自行发明。

### 2.6 Scheme 白名单漂移

`Ezagent.URI.@known_schemes` 列了 5 个；代码库实际用了 11 个。任何选择 `Ezagent.URI.new!/1` 而不是 stdlib `URI.parse/1` 的人都会撞上幻象失败。这是文档腐烂，同时也是一个什么都拦不住的安全网。

### 2.7 单例合成 scheme 与实例 scheme 形态分歧

`pty-input://default` 与 `routing-admin://default` 是管理用单例。它们的 URI 用 `default` 作为"唯一实例"的占位。`system://bootstrap` 用 `bootstrap` 担当相同角色。三个哨兵，三种命名风格。

### 2.8 Class 字符串和 URI 类型段携带了重复的同一信息

工作区模板条目的 DB 形状形如：

```json
{"class": "cc.agent", "agent_uri": "agent://cc/demo-builder"}
```

`class` 字段又一次编码了 "cc"。PR-D2 前的分裂（`cc.pty` vs `cc.channel_instance`）正被合并成 `cc.agent`，因为面向运维的"模式"原本计划要挪到 URI 子资源（或 query string）里、从 class 字符串中移除。也就是说 class 字符串正在缩小，URI 在吸收越来越多的语义。值得一问：极限情况下，`class` 还有存在必要吗？还是 `agent_uri` 已经自描述？

### 2.9 插件的 scheme 注册按 scheme 而非按 type

`SpawnRegistry.register("feishu", ...)` 声明整个 scheme。`AgentTypeRegistry.register("curl", ...)` 声明 `agent://` 的一个子命名空间。所以插件可以二选一 —— 拥有一个全新 scheme，或在 `agent://` 下添加一个类型。cc 插件选了类型路线，feishu 插件选了整 scheme 路线。它们面对的是同一个架构选择（贡献一个参与 chat 的 Kind 类型），却做出了不同决策。两者都能工作，但不一致是实实在在的。

---

## §3 待决设计问题

每个问题都有一个默认提案，并列出相对其它替代方案的取舍。

### Q1 —— 统一的两段式 authority：是否所有 scheme 都应该采用 `<scheme>://<type>/<name>`？

**现状**：`agent://cc/demo-builder` 是两段式；`session://main`、`user://admin`、`workspace://default` 是一段式。

**提案 A（统一两段式）**：所有 scheme 都改为 `<scheme>://<type>/<name>`。
- `session://generic/main`（与 `template://session/main@hash` 的 class 对照）
- `user://human/admin`、`user://service/cron-runner`
- `workspace://default/feishu-seed`（其中 "default" 是今天唯一的 Class）
- 优点：一条规则，机械清晰。
- 缺点：对于今天只有一种 Class 的 scheme（`session`、`workspace`）需要多打几个字。

**提案 B（scheme 即类型）**：回滚 PR #131 —— `cc-agent://demo-builder`、`curl-agent://my-deepseek`，`session://main` 保持原样。
- 优点：scheme = 类型，无需嵌套命名空间。
- 缺点：scheme 白名单会无界增长；PR #131 明确朝相反方向走。它走相反方向的理由（Allen 2026-05-19 03:21）："agent" 是用户脑子里的名词；"cc" / "curl" 是实现风味。把它们混进 scheme 会让"用户视角的身份"和"后端接线"搅在一起。

**提案 C（维持现状 + 文档化）**：保留当前布局。把规则记为：同一名词有多种实现的 scheme 用 `<scheme>://<type>/<name>`；只有单一实现的 scheme 保持扁平。
- 优点：改动最小。
- 缺点：每加一个 scheme 都是一次判断题。Feishu 插件选了"全新 scheme"是因为它和 agent 在语义上是完全不同的名词；`template://` 选了"单 scheme，host = class"是因为模板就是模板。各自局部都对；全局图景却难以传授。

### Q2 —— `template://` 该拆开还是保持统一？

**现状**：`template://agent/<name>`（无版本）和 `template://session/<name>@<hash>`（带版本） —— 同一 scheme，按主机段不同走不同形状。

**提案 A（拆开）**：`agent-template://<name>` + `session-template://<name>@<hash>`。按 Q1-B，scheme = Kind。
- 优点：每个 scheme 只有一种形状。
- 缺点：scheme 更多；从语义上讲"它们都是模板"。

**提案 B（统一两段式）**：保留 `template://<class>/<name>`；要求始终带 `@hash`（哪怕是 AgentTemplate）。今天 AgentTemplate 无版本，是因为它是"人工编辑"的（`apps/ezagent_domain_instance_message/lib/ezagent/entity/agent_template.ex:19`）。强制带 hash 能统一形状，但会失去人工编辑模型。
- 优点：所有 template URI 形状一致。
- 缺点：AgentTemplate 得引入一个它目前并不需要的版本化模型。

**提案 C（维持现状 + 禁用 tag）**：删掉从未实现的 `template://session/X:<tag>` 形态，把两种显式形状写进文档。

### Q3 —— Behavior 子路径：位置式 vs query string

**现状**：`agent://cc/X/behavior/chat/say` —— `/behavior/...` 是路径，位置取决于 scheme。

**提案 A（query string）**：`agent://cc/X?action=chat.say` —— 子资源变成 query，解析器天然变得 scheme 无关。
- 优点：解析器变成 scheme 无关。Capability 匹配仍按实例位置进行。
- 缺点：路由表语法（`/behavior/chat/receive`）到处都是。迁移量大。`URI.to_string/1` 会把 query 放在 path 之后 —— 仍然可读，但形状变了。

**提案 B（实例总是两段式 authority）**：等同于 Q1-A。这样 `/behavior/...` 永远从 path[1] 开始。无需 query。

**提案 C（维持现状 + 位置切分）**：已经在 PR-A（PR #132）中完成。解析器是正确的。唯一的成本是每个 scheme 的隐式规则。

### Q4 —— `resource://` 命名空间：真正的泛化，还是事实上的单例？

**现状**：只存在 `resource://uploads/<filename>`。主机段是为未来命名空间（`snapshots`、`logs` 等）保留的 —— 这些目前都还没有。

**提案 A（承诺命名空间化）**：添加一个与 `AgentTypeRegistry` 对应的 `ResourceNamespaceRegistry`。插件注册一个命名空间 + fetcher。
- 优点：为"任何插件都能暴露可下载资产"奠定基础。
- 缺点：投机性 —— 今天只有一个命名空间。

**提案 B（坍缩成扁平）**：去掉主机段 —— `resource://<filename>`，只有一个扁平 uploads 命名空间。等第二个命名空间出现时再把主机段加回来。
- 优点：最简单。当前唯一消费者是 admin_live.ex 第 230 行。
- 缺点：未来如果（当）我们加 snapshots/logs，会发生向后不兼容的破坏。

**提案 C（维持现状 + 文档化）**：保留形状，把 `resource://<namespace>/<id>` 写进约定，任何插件添加命名空间时同时注册一个解包器。

### Q5 —— 单例哨兵命名：`default` vs `bootstrap` vs ？？？

**现状**：`pty-input://default`、`routing-admin://default`、`system://bootstrap`。三个哨兵，两种名字。

**提案**：择一。`default` 表示"该 Kind 的单例实例"；把 `system://` 留给名字本身携带含义的 capability/audit 哨兵（`system://bootstrap`、`system://migration-pr131`、`system://admin-override`）。

### Q6 —— 插件的 scheme 贡献：什么时候独占一个 scheme，什么时候加一个类型？

**现状**：隐式。Feishu 拥有 `feishu://`。cc 与 curl 共享 `agent://`。

**提案**：把规则写成一个三角形。插件应当：
- 当其 Kind 是与 core 中任何东西都不同的**名词**时独占一个 scheme（例如 `feishu://` 是一个聊天平台 receiver，不是一个 agent）。
- 当其 Kind 是已有名词的某种**风味**时，在已有 scheme 下加一个类型（例如 `agent://cc/...` 是 agent 的一种风味）。
- 其它一切（如插件提供的模板、插件提供的资源）通过子注册表（TemplateRegistry、ResourceNamespaceRegistry）扩展已有命名空间。

这是 **plugin isolation 北极星** 规则在 URI 上的具体化。

### Q7 —— `@hash` 内容寻址：只给 template，还是推广？

**现状**：`template://session/X@hash` 是唯一一个内容寻址的 URI。Snapshot URI、message URI、agent URI 都是不透明身份（UUID 或人类名字）。

**提案 A（推广到其它有版本的事物）**：在任何 Kind 拥有内容版本化身份的地方都允许 `<scheme>://<type>/<name>@<hash>`（未来：blueprint 快照、冻结的 agent 配置）。

**提案 B（维持现状）**：`@hash` 保持仅模板专用；模板是唯一一个"身份就是其内容"的 Kind。

### Q8 —— `Ezagent.URI.@known_schemes` 应否成为唯一可信来源？

**现状**：它列了 5 个 scheme；现实有 11+。这是文档漂移。

**提案 A（闭环）**：让 `SpawnRegistry.register/2` 同时调用 `Ezagent.URI.register_scheme/1`。白名单变成由插件喂入的运行时 ETS 表。`Ezagent.URI.new!/1` 查它。`pty-input` 这类单例在启动时自行注册。

**提案 B（删除白名单）**：它什么也拦不住 —— 把它从 `parse!/1` 里去掉，直接委托给 stdlib `URI.parse/1`。

---

## §4 讨论记录

（讨论在此处随推进追加。本节内最新的条目放在顶部。）

---

## §5 最终规范

（达成共识前留空。）
