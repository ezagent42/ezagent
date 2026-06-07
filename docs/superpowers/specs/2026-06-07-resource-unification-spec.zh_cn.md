# 资源统一（Resource-unification）— 规格说明（SPEC）

日期：2026-06-07
状态：SPEC（依据 `discuss/resource-unification` 分支上经 codex 两轮评审、已定稿的
讨论文档撰写）。设计已锁定；本文档负责落地规格化。
分支：`spec/resource-unification`
前置文档：`docs/superpowers/specs/2026-06-07-resource-unification-discussion.md`
相关不变量：#11（URI 形态 / 6 种 scheme 白名单 / 三段式 authority）、#14
（per-tenant 表 `workspace_uri NOT NULL`）、`unify-uri-query` CI 闸门
（`mix ezagent.uri_query.scan`）。

---

## 1. 问题

`Ezagent.Home.path/1` 事实上是全代码库访问磁盘工件（artifact）的路径 API。它返回
裸的 `<profile_dir>/<component>` 字符串，没有租户结构、没有解析接缝（seam）。与此
同时，项目已经有一个可用的寻址接缝——`Ezagent.UriQuery`（一张 `attr → resolver/1`
的 ETS 注册表）——但目前只有**一个**工件家族真正通过它走文件访问：socialware 配置
对象（`config_projection.ex`）。

由此产生两个结构性问题：

1. **租户工件缺乏结构性租户隔离。** uploads 与 per-agent config-dir 本就是租户作用域、
   本就有天然的 workspace，但其字节流由裸 `Home.path("uploads")` /
   `Home.path("<ns>-agents")` 寻址；租户隔离（若有）靠各调用点临时逻辑——例如
   uploads 下载按「会话参与」鉴权，而非按 URI 的 workspace 段
   （`uploads_controller.ex:134`）。
2. **缺乏旁路管控。** 任何开发者都能以任意目的调用 `Ezagent.Home.path/1`；没有闸门
   区分一次受认可的 boot/运维调用与一次本应走 resolver 的租户工件新调用。回退到裸路径
   无人拦截。

已被验证的 socialware 模式给出了正确形态：以 `resource://<ws>/<type>/<name>` 寻址、
在 `UriQuery` 接缝处解析为路径、并以 URI 的结构性 `<ws>` 段与所加载工件自身的
`workspace_uri` 比对来重申租户隔离
（`config_projection.ex` 的 `assert_workspace_authority!/2`）。本工作即是把这**一个
被验证的实例**推广到其它租户作用域家族，并**锁定裸 `Home.path` 面**以防迁移回退。

### 不属于本问题的范围（明确的范围上限）

这**不是**「每一个字节都走 `resource://`」。boot 关键工件与 OS 句柄工件（SQLite 库、
runtime cookie、pty pid 文件、codex app-server socket）**不是**租户作用域，且部分在
**任何 URI 机制存在之前**就需要。把它们塞进 `resource://` 需要一个哨兵 `<ws>`，那会
重新打开不变量 #11 的鉴权漏洞。它们留在裸 `Home`。详见 §4（决策 D2、D3）及非目标。

---

## 2. 目标与非目标

### 目标

- **G1.** 将**租户作用域、内容形态工件**的磁盘寻址统一到 `Ezagent.UriQuery` 接缝之后，
  复用现有 `resource://<ws>/<type>/<name>` scheme。`Ezagent.Home` 对这些 `<type>`
  降级为 resolver 背后的**默认后端**——不再是前门。
- **G2.** 交付一个**强化的、仅注册式（registration-only）**的通用 `resource://` 文件
  系统 resolver：封闭的 per-`<type>` 白名单、对 `.`/`..`/不安全段的显式拒绝、per-`<type>`
  authority 检查。无隐式 Home 兜底。
- **G3.** 按风险升序把剩余两个租户作用域家族迁到 resolver 之后：**先 per-agent
  config-dir，再 uploads**（uploads 的下载契约 + 鉴权修复先行）。
- **G4.** 在现有 `mix ezagent.uri_query.scan` 闸门上新增 `home_path_in_runtime_code`
  类别，**锁定运行期应用代码中的新增**裸 `Home.path`/`profile_dir`/`home` 调用——以
  行级锚定的基线 + 精确锚点豁免（boot/运维/OS 句柄的受认可面）为基准，对**新增**调用
  立即硬失败（hard-fail）。随家族迁移逐项消减基线。

### 非目标

- **N1. 不新增第 7 种 scheme（`home://`）。** 它与现有 `system://` 形态同构，却要在约 6
  处 scheme 匹配点加子句并修订 #11/SPEC，而候选工件**今天没有任何 URI 消费者**。（D3）
- **N2. 不把 db / runtime cookie / pty-pids / codex socket 走 `resource://`**（或任何
  租户 scheme）。它们留在裸 `Home`，且是**受认可**面（scan 闸门以精确锚点豁免）。（D2）
- **N3. 不把 `Home.path/1` 设为私有 / 完全内部化。** early-boot
  （`config/runtime.exs`）与运维 mix-task 在 `Application.start/2` **之前**调用它，彼时
  `UriQuery`/`SchemeRegistry` 的 ETS 表尚不存在。字面上的「不保留任何裸路径 API」会破坏
  boot。（D1）
- **N4. 不触碰凭据级联热路径**——`Ezagent.Credential.CascadeRuntime` /
  `Ezagent.Agent.Materializer`（`atomic_replace` / 回滚 / `recover_orphaned` /
  `copy_secret_relpaths`）。它们消费**已解析的路径字符串**，且已位于
  `UriQuery.resolve(:config_dir, …)` **之上**（`cascade_runtime.ex:74,107`）。
  「先解析后传入」；绝不把 URI 推进 Materializer。（D4）
- **N5. 不把全局凭据迁到 `resource://`。** 它们并非天然租户作用域；走 per-tenant scheme
  会捏造假 `<ws>`（正是 #11 要防的鉴权漏洞）。收益边际，延后。（D5）
- **N6. 寻址本身不留向后兼容 shim**，仅 P2 明确要求的那一处下载向后兼容窗口除外
  （见 §6 P2）。依 `feedback_let_it_crash_no_workarounds`，迁移删除旧字节路径，而非新旧
  并存。

---

## 3. 现状（经源码核对的锚点）

| 家族 | 当前字节路径 | 走 `UriQuery.resolve`？ | 租户作用域？ |
|---|---|---|---|
| socialware-config-object | `config_projection.ex` 投影到临时目录 | **是**（`:socialware_config_dir`，由 `:config_dir` 委派） | 是 |
| per-agent config_dir | `Sandbox.ConfigDir.path/2` → `Home.path("<ns>-agents")/<ws>/<name>`（`config_dir.ex:30-36`） | 否（作为裸路径计算；级联确有调 `UriQuery.resolve(:config_dir, …)`，但对 `entity`/`template` URI 返回的是**已存字符串**，并不经 `resource://` FS resolver） | 是 |
| uploads（写） | `admin_live.ex:701,731` `Path.join(Home.path("uploads"), stored_name)`；句柄在 `:733` `Ezagent.URI.resource(workspace_name, :uploads, stored_name)` | 否（句柄是装饰性的；字节是裸 `Home.path`，**字节路径里无 `<ws>`**） | 是 |
| uploads（读） | `uploads_controller.ex:108` `Path.join(Home.path("uploads"), safe)`；鉴权按 `caller_in_attaching_messages?/2`（`:134`），路由 `GET /files/:filename`（`router.ex:74`） | 否 | 是（但鉴权按会话，非按 `<ws>`） |
| db（SQLite） | `config/runtime.exs:14,17` `Home.path(:db)` | 否——**config-eval，在 `Application.start` 之前** | 否 |
| runtime cookie | `runtime.ex:28-29` `Home.profile_dir()/runtime/cookie` | 否——early boot | 否 |
| codex app-server socket | `codex_agent.ex:880-892` `default_app_server_socket_path/1` → `Home.path("codex")/<sha256 slug>/app-server.sock` | 否——OS 句柄，SUN_LEN ≈104B 短路径约束 | 有 per-agent 形态，但**不可内容寻址** |
| pty-pids | `Home.path(...)` | 否——OS 句柄 | per-deployment 形态 |
| logs / plugins / snapshots / inbox | `Home.path(...)` | 否 | 否 / 引擎内部 |

**设计所依赖的关键事实（逐条已核）：**

- `Ezagent.UriQuery`（`uri_query.ex`）：`register/2` 单 attr 单 owner
  （`:ets.insert_new`，重复注册硬失败）；`resolve/2` 对 `{:error, {:no_resolver, attr}}`
  硬失败；`:none` ≠ `{:error, _}`；resolver 返回值经规范化。
- `Ezagent.URI.resource/3` → `per_tenant("resource", ws, type, name)`
  （`uri.ex:425,456`）。`per_tenant/4` 调 `segment!/1`（`uri.ex:460-477`），**拒绝空段
  与含 `/` 的段**及空 `<ws>` host（`validate_3seg_shape!/2` `uri.ex:490-495`），**但不拒绝
  `.`/`..`，也不把 `<type>` 限制到目录白名单。** 这正是 P0 要堵的 codex-HIGH 缺口。
- `:config_dir` resolver 单 owner 为
  `EzagentDomainInstanceMessage.UriQueryResolvers`（`uri_query_resolvers.ex:28`），其
  `resource` 子句（`:105-107`）**委派至** `:socialware_config_dir`。这是 P1/P2 复用的扩展接缝。
- `seed_uri_schemes/0`（`application.ex:183-191`）在 `Application.start/2` **内部**只 seed
  六种 scheme（`entity workspace session template resource system`）。`home://` 会是第 7 种——拒绝（N1）。
- `config/runtime.exs:14` 在 config-eval 执行 `File.mkdir_p!(Ezagent.Home.path(:db))`，
  早于 supervision tree（故早于 `UriQuery`/`SchemeRegistry` ETS 表）。这是 boot 顺序硬约束（D1）。

---

## 4. 决策（含依据）

### D1 — 把「一切走 UriQuery」限定到运行期应用代码

**决策。** 约束性不变量为：*每一处运行期应用代码对租户工件的文件访问都走 `UriQuery`；
boot/config-eval 与运维 mix-task 保留受认可的裸 `Home` 面。* Allen 第二轮的措辞「先把
一切都走 UriQuery」予以记录，但**作为字面表述被否决**。

**依据。** `config/runtime.exs:14` 在 config-eval 解析 db 路径——早于
`Application.start/2`，故早于 `EzagentCore.EtsOwner` 创建 ETS 表、早于任何域 resolver 注册。
此处 `UriQuery.resolve(:db, …)` 会命中 `{:no_resolver, :db}` 并在最糟时机（发布 boot、
supervision 之前）硬失败。每个 app 未启动即运行的运维 mix-task 同理。故 resolver 接缝
**不能**作为通用 FS 前门；它治理的范围是运行期应用代码。

### D2 — db / cookie / pty-pids / codex socket 留在裸 `Home`（受认可）

**决策。** 四者全留 `Ezagent.Home`，不走任何 URI scheme。在 scan 闸门以精确锚点豁免（§5），
各附理由。在它们**之前 STOP**。

**依据。** db + cookie 是非租户节点单例，需在任何 workspace 存在之前（无 `<ws>` 可命名）。
codex socket 与 pty-pids 虽有 per-agent/per-deployment 形态，但其约束是**确定性身份 +
短 OS 路径（codex SUN_LEN ≈104B 要求 `codex_agent.ex:892,901` 的 sha256 短 slug）+
部署隔离 + 清理**——而非内容可寻址。通用 Home 后端 FS resolver 一项都保不住。四者均从不
**按 URI 取用**，URI 句柄无所增益。

### D3 — 放弃 `home://`；不新增第 7 种 scheme

**决策。** 不要 `home://`。若某节点单例确需 URI 句柄，按需复用现有 `system://`。

**依据。** `home://<type>[/<name>]` 与 `system://` *形态同构*（后者经 `system_principal/1`
已支持 1/2 段两形态）。第 7 种 scheme 是永久税：每个 scheme 匹配点（`workspace_of`、快照
分类 `kind/snapshot.ex`、持久化 `persistence.ex:78`、capability `:any` 列表
`capability.ex:960`、`path_for_routing`）都要永久加 `home` 子句，且新 scheme 会落入空操作
兜底 `validate_3seg_shape!(_uri, _raw), do: :ok`（`uri.ex:529`）——即**默认无结构校验**，
是路径穿越/类别混淆靶子。#11 把上限封在六种；第 7 种是无消费者撑腰的 SPEC 修订。（若日后复活
`home://`，须先满足硬前置：封闭类型目录、专属 `.`/`..`/斜杠拒绝、单 resolver 独占、每个
scheme 匹配点都审入 `home` 子句。）

### D4 — 不触碰凭据级联 / Materializer 热路径

**决策。** 级联与 Materializer 消费已解析路径字符串，已位于 `UriQuery.resolve(:config_dir,
…)` 之上（`cascade_runtime.ex:74,107`）。迁移改的是*路径如何被产出*（Home 调用 vs 通用
resolver），对该代码**零改动**。绝不把 URI 推进 Materializer；先解析后传入。

**依据。** Materializer 的 `atomic_replace`/回滚/`recover_orphaned` 不变量是最高风险面，
其设计上对 URI 寻址无感。把它「URI 原生化」是高风险低回报的搅动。

### D5 — 延后全局凭据

**决策。** 全局凭据非天然租户作用域；走 `resource://<ws>/...` 会捏造假 `<ws>` 或对空 `<ws>`
特判——正是 #11 要防的鉴权漏洞。收益边际；延后，直到出现具体需求。

### D6 — 回答 Allen 的明确问题：`Home.path(:db)` 能用 `system://` URI 吗？

**决策：不能——不能经运行期 `UriQuery` 解析。**

db 路径在 `config/runtime.exs:14`（config-eval）即需，早于任何注册表/ETS 存在（D1）。
`system://` URI 只有在有东西*解析*它时才有用，而解析住在 `UriQuery`（运行期 ETS）——彼时
不存在。boot 顺序禁止。

故 db（与 runtime cookie）留在**裸 `Home`（受认可豁免）**。`system://db/main` 句柄原则上只能
作为**装饰性**字符串、由**无 ETS 的纯函数**解析（如 `system_principal/1` 那样纯）——但今天
**没有任何消费者**需要 db 的 URI 句柄，故不引入。此为带 boot 顺序依据的明确决策，而非待设计的延后。

---

## 5. 强化 resolver 契约与 scan 闸门类别

### 5.1 通用 `resource://` 文件系统 resolver（P0）

新模块——拟为 `ezagent_core` 中的 `Ezagent.Resource.FsResolver`（推广 socialware 模式；
socialware 对 `socialware-config-object` 保留其自身的*投影式* resolver，因其物化内容而非命名
已存目录）。

**仅注册式 + 封闭 per-`<type>` 白名单。** 每个 `<type>` 显式注册：

```elixir
@type scope :: %{
        required(:workspace) => URI.t() | String.t(),  # 调用方所处的已认证 workspace
        optional(:principal) => URI.t() | nil
      }

@type type_spec :: %{
        backend_component: String.t(),            # 字节所在 Home 组件，如 "uploads" / "cc-agents"
        # per-type 鉴权：同时接收 URI 与调用方已认证 scope，断言 URI 的结构性 <ws> 段
        # 对此调用方有权威。纯 `(URI.t() -> ...)` 不够（codex HIGH）：无调用方上下文的
        # resolver 无从知道是谁在请求。
        authority: (URI.t(), scope() -> :ok | {:error, term()})
      }
```

**resolver 是带鉴权的，而非鉴权可选的。** `resolve/2` 把调用方已认证 `scope` 作为必备参数，并在
任何后端解析之前以它跑 per-`<type>` `authority/2`。不存在跳过鉴权的 `resolve/1`。调用点从其已认证
上下文取 `scope.workspace`（config-dir 取代理 workspace；uploads 取 controller/LiveView mount 的
workspace）——绝不从被解析的 URI 取（那是循环）。这正是「把 uploads 鉴权移入 resolver」成立的原因：
URI 的 `<ws>` 段须等于 `scope.workspace`，故以 scope `attacker` 解析伪造的
`resource://victim/uploads/name` 会鉴权失败。

**解析算法** `resolve(uri, scope)`，其中 `uri = resource://<ws>/<type>/<name>`：

1. **拒绝畸形：** `scheme == "resource"` 且经 `Ezagent.URI.workspace_name/1`、`type/1`、
   `name/1` 解析为三段。无法识别形态 → `:none`（不属于我）；结构为 `resource` 但缺段 →
   `{:error, {:malformed_resource_uri, …}}`。
2. **白名单检查：** `<type>` 未注册 → `:none`（单 `:config_dir` owner 随后落到 socialware
   resolver，与今天一致）。**无隐式 Home 兜底**——未注册 `<type>` 绝不解析到 Home 路径。
3. **不安全段拒绝（在任何 `Path.join` 之前）：** 若 `<ws>`/`<type>`/`<name>` 任一等于 `"."`/
   `".."`、含路径分隔符、含 NUL，或（纵深防御）不等于 `segment!/1` 会产出的精确段字符串，则拒绝。
   `Path.join` 绝不携带不安全段执行。（堵 codex-HIGH 缺口：`segment!/1` 不拒 `.`/`..`。）
4. **鉴权检查：** 以 `authority.(uri, scope)` 跑该 `<type>` 的 `type_spec.authority`，比对 URI 的
   结构性 `<ws>` 段与 `scope.workspace`（socialware 另重载对象比对 `workspace_uri`）。
   `{:error, reason}` → `{:error, reason}`（硬失败；跨租户不匹配致命，绝非静默 `:none`）。
5. **后端解析：** `{:ok, Path.join([Ezagent.Home.path(backend_component), <ws>, <name>])}`。
   （Home 是*后端*，仅在 1–4 通过后到达。）

**接线：** 单 `:config_dir` owner
（`EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir/1`）现已把 `resource` 子句
委派给 `:socialware_config_dir`（`:105-107`）。P0 引入通用 resolver 但**暂不**重接 `:config_dir`；
P1 把 `resource` 子句改为先试通用 resolver 已注册类型（config-dir 类型），未命中再落到 socialware。
顺序显式且完备——每个 `resource` config-dir URI 恰好匹配一个已注册 owner 或硬失败。

**经 `:config_dir` UriQuery attribute 穿入 `scope`。** `UriQuery` resolver 形态是 1 参
（`resolver/1`），级联今天调 `UriQuery.resolve(:config_dir, uri)`。为在不破坏该形态下携带调用方
已认证 scope，`:config_dir` 的 `resource` 子句在委派给通用 FS resolver 时把 `{uri, scope}` 作为
resolver 参数传入；config-dir 的 `scope.workspace` 即**代理的权威 workspace**（由级联正在物化的
代理/模板 URI 推出，是级联的已认证主体——非攻击者提供）。socialware 委派不变：它重载不可变对象比对其
存储的 `workspace_uri`，自鉴权且忽略 scope。uploads（P2）以请求 mount scope 直接调通用 resolver，
完全不依赖 `:config_dir` attribute。（精确参数元组形态于 P1 钉定；不变量为：通用 resolver 始终收到
scope 且始终跑 `authority/2`。）

**属性（resolver 验收不变量）：**

- **R-1.** 任何带未注册 `<type>` 的 `resource://` URI 都不解析为文件系统路径（返回 `:none`）。
- **R-2.** 任何等于 `.`/`..` 或含分隔符/NUL 的段都不到达 `Path.join`（解析前返回 `{:error,_}`）。
- **R-3.** 每个已注册 `<type>` 都有非平凡 `authority/2`；解析始终以调用方 `scope` 跑它；workspace
  段不匹配（`uri.<ws> != scope.workspace`）硬失败（不存在被当作「不属于我」吞掉的静默 `:none`）。
  不存在绕过鉴权的 `resolve/1`。
- **R-4.** `Home.path` 仅在 R-1..R-3 通过后的成功路径调用，且只用已注册 `backend_component`。

### 5.2 scan 闸门类别 `home_path_in_runtime_code`（P0.5）

扩展 `Ezagent.UriQuery.Scan`（`scan.ex`）：在 `@known_categories`（`scan.ex:28-37`）新增类别，
并经现有 `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code` 机制暴露
（`ezagent.uri_query.scan.ex:64-79` 已解析 `--fail-category`）。

**标记什么。** `apps/` 下生产 `.ex` 文件中对 `Ezagent.Home.path/1`、`profile_dir/0`、`home/0`
的调用，凡**不在**精确锚点豁免名单**且不在**行级锚定基线者。

**落地即对新增硬失败。** P0.5 立即把 `--fail-category home_path_in_runtime_code` 接入 CI，不走
warn-then-flip。既非锚点豁免、又不在基线的运行期 `Home.path` 新增/移动调用，在引入它的 PR 上即令
CI 失败。

**精确 模块/函数/行 锚点豁免——无 glob、无目录白名单。** 目录形或 glob 豁免（如「整个
`lib/mix/tasks/`」或 `ezagent.home.*`）会让某 OS 句柄文件或新加 task 成为宽泛裸路径逃逸口——某个
globbed task 文件下新加的 `Home.path` 调用会绕过对新增硬失败的闸门（codex MEDIUM）。故每条豁免都是
具体 `Module.function/arity` + 行锚点，各附理由。完整枚举集（无 `*`、无前缀匹配）——此处钉定，非「日后再钉」：

| 锚点（精确 `Module.function/arity` @ 行） | 理由 |
|---|---|
| `config/runtime.exs`（行 14、17） | config-eval 取 db 路径——`UriQuery` ETS 不存在（D1） |
| `config/dev.exs`（行 22） | config-eval 故意内联 env 逻辑 |
| `Ezagent.Runtime.cookie_path/0`（`runtime.ex:28-29`）+ node-name 函数 | early boot，supervision 之前 |
| `EzagentRuntime.PidFile.dir/1`（`runtime/pid_file.ex:95-98`，`Home.profile_dir/0`） | OS pid 文件（即「pty-pids」句柄）——节点/代理 pid 文件，独立于注册表（D2） |
| `Mix.Tasks.Ezagent.Home.Init.run/1` 及其 `Home.path`/`profile_dir` 辅助（`ezagent.home.init.ex:30,32,33,36,49,79,145,159`） | 运维 mix-task，app 未启动 |
| `Mix.Tasks.Ezagent.Home.Backup.run/1`（`ezagent.home.backup.ex:62`） | 运维 mix-task |
| `Mix.Tasks.Ezagent.Home.Restore.run/1`（`ezagent.home.restore.ex` 各 `Home.*` 点） | 运维 mix-task |
| `Mix.Tasks.Ezagent.Home.AdoptDb.run/1`（`ezagent.home.adopt_db.ex:61`） | 运维 mix-task |
| `Mix.Tasks.Ezagent.Bootstrap.run/1`（`ezagent.bootstrap.ex:89,90,91,92`） | 运维 mix-task |
| `Ezagent.Home.Migration` 各 `Home.*` 点（`home/migration.ex`） | 运维迁移工具 |
| `EzagentPluginCodex` `Ezagent.Template.CodexAgent.default_app_server_socket_path/1`（`codex_agent.ex:880-892`） | OS 句柄 socket，SUN_LEN 短路径，不可 URI 寻址（D2） |

> **P0.5 实现注：** 上表精确行号是 spec 时对 `origin/main` 的快照；P0.5 将各项钉为
> `Module.function/arity` 锚点（行号为次），扫描器测试（S-2）断言每条豁免都是具体 模块+函数——
> **拒绝任何含 glob（`*`）或裸路径前缀的条目**。新增豁免须新具体锚点 + 理由，在其 PR 中评审。

> 配置文件（`config/runtime.exs`、`config/dev.exs`）不在 `apps/**/*.ex`，故扫描器今天看不到它们。
> P0.5 的类别定义在 `apps/` glob 上；此处列出配置文件调用者只为补全受认可面，无需扫描器豁免。若扫描
> glob 日后纳入 `config/`，它们即成为带理由的精确锚点。

**行级锚定基线（消减清单）。** 类别随附显式基线文件，枚举每处*当前*运行期应用代码的 `Home.path`
调用点（文件 + 行 + 精确调用），如 `Sandbox.ConfigDir.path/2`（`config_dir.ex:31`）、
`admin_live.ex:701,731`、`uploads_controller.ex:108`，及其余 population-3 调用者（cc/codex 模板、
feishu 客户端、python server、agent_bridge token_store、identity application）。基线是消减清单而非
整体放行：基线调用仅在其记录锚点处容忍；移动或复制即失败。P3 随家族迁移逐项移除。基线清空即锁定完成。

**闸门验收不变量：**

- **S-1.** 一个*新增*运行期 `Home.path` 调用（非豁免、非基线）令
  `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code` 失败。
- **S-2.** 每条豁免都是带理由的精确 `Module.function/arity` + 行锚点；扫描器测试**拒绝任何含
  glob（`*`）或裸路径/目录前缀的豁免条目**，机械化地强制「精确锚点」保证。
- **S-3.** 基线只缩不增（P3）；豁免面永不扩大。

---

## 6. 阶段（带验收闸门的 PR）

风险升序、依赖正确。每阶段一个 PR（或小 PR 组）；每个均按
`feedback_codex_review_every_pr` 走 `/codex:adversarial-review`。

### P0 — 强化通用 `resource://` FS resolver（仅注册式）

- 按 §5.1 **构建** `Ezagent.Resource.FsResolver`（仅注册式、封闭 per-`<type>` 白名单、
  `Path.join` 前拒 `.`/`..`/分隔符/NUL、per-type `authority/2`）。初始注册**零**类型（或仅一个
  测试类型）——本 PR 引入机制，不做迁移。
- **暂不**重接 `:config_dir`；socialware 委派不动。
- **测试（TDD）：** R-1..R-4 单测——未注册类型 → `:none`；`.`/`..`/`a/b`/NUL 段 → `{:error,_}`
  且不碰 FS；鉴权不匹配硬失败；成功路径 join `Home.path(component)/<ws>/<name>`；一个枚举恶意
  `<type>`/`<name>` 的属性/表格测试。
- **验收闸门：** R-1..R-4 不变量测试通过；尚无生产调用点使用 resolver（休眠）；
  `mix ezagent.check_invariants` + 现有 `uri_query.scan` 不变。

### P0.5 — scan 闸门脚手架：`home_path_in_runtime_code`（对新增硬失败 + 基线）

- 按 §5.2 **扩展** `Ezagent.UriQuery.Scan` 新增 `home_path_in_runtime_code` 类别。
- **立即**把 `--fail-category home_path_in_runtime_code` 接入 CI（对新增硬失败）。
- **撰写**基线（当前 population-3 普查）与带理由的精确锚点豁免名单；钉定精确 pty-pid OS 句柄锚点。
- **测试：** S-1（fixture 中一个合成新增调用令类别失败）；S-2（豁免为精确锚点，结构性断言）；
  S-3（基线只缩守卫——基线文件须与实测一致，故未基线即加调用会失败，移除已迁调用须改基线）。
- **验收闸门：** 新类别在当前树为 GREEN（基线覆盖全部现有调用者）；故意加一个未基线调用在 CI 变 RED。

### P1 — 把 per-agent config-dir 迁为经 `resource://<ws>/<config-type>/<name>` 解析

*（config-dir 先于 uploads：它正是级联上已有的 socialware 接缝形态——级联今天已调
`UriQuery.resolve(:config_dir, …)`——风险更低；级联已是 URI 寻址，D4。）*

- 在 P0 resolver 上**注册**一个 config-dir `<type>`（如把现有 `"<ns>-agents"` 组件推广），其
  `authority/2` 以 URI 的 `<ws>` 段断言代理所属 workspace。
- 把 `Sandbox.ConfigDir.path/2`（`config_dir.ex:30-36`）**改写**为构造
  `resource://<ws>/<ns>-agents/<name>` URI 并经接缝解析，以 `Home.path("<ns>-agents")` 为已注册
  后端。解析结果与今天布局字节一致（`config_dir.ex` docstring 对 `"cc"` 保证字节一致）。
- 把 `:config_dir` resolver 的 `resource` 子句（`uri_query_resolvers.ex:105-107`）**重接**为
  先试通用 resolver 已注册 config-dir 类型，再落 `:socialware_config_dir`。顺序完备 + 硬失败。
- **D4 不动：** Materializer/级联继续消费已解析字符串；不向其推 URI。
- 从 P0.5 基线**移除**已迁的 `Home.path("<ns>-agents")` 调用。
- **测试：** 一个**字节一致 parity 测试**——`Sandbox.ConfigDir.path/2` 输出 == 同 agent URI +
  namespace 的 P1 前路径；现有 config_dir resolver 测试；鉴权测试（外来 `<ws>` → 硬失败）；级联
  respawn 路径解析到同一目录。
- **验收闸门：** parity 测试通过；级联/Materializer 测试不变且通过；P0.5 基线缩去 config-dir 项；
  config-dir 的 `Home.path` 调用已从运行期应用代码消失。

### P2 — 把 uploads 迁为经 resolver 存储 — 下载契约先行

> **契约改动须在字节迁移之前。** 今天字节落在 `Home.path("uploads")/<stored_name>`（仅文件名、
> **无 `<ws>`**；`admin_live.ex:731`），`UploadsController.show/2` 按会话参与鉴权
> （`uploads_controller.ex:134`），非按 URI 的 `<ws>`。若在路由仍为 `GET /files/:filename`
> （`router.ex:74`）时把字节迁到 `Home.path("uploads")/<ws>/<name>`，URL 将无法解析路径，且同名
> 跨 workspace 会歧义。

**P2a — 下载契约 + workspace 段鉴权（暂不迁字节）：**

- **改下载契约**，使请求携带/恢复完整的 **workspace-first** `resource://<ws>/uploads/<name>` URI
  ——经 `Ezagent.URI.resource(ws, :uploads, name)` 构造（workspace-first，见 §5.1 及下方文档漂移修正），
  **不是** `resource://uploads/<ws>/<name>` 的 type-first 形态（resolver 会把它误解析为 workspace=`uploads`、
  type=`<ws>`，导致白名单未命中 + 鉴权检查错误 + 下载失败——codex HIGH）。**机制（OI-1 已定）：编码完整
  ws 作用域 URI 的签名能力 token**——短 TTL、绑定到唯一 `resource://<ws>/uploads/<name>`、仅在授权后签发
  （内部：mint 时实时 cap-check；外部 customer-feed：由 approved-only 可见性门控）、对 feed 在 serve 时再校验。
  **不用**纯路由段——外部 React customer-feed（#601/#603）给无 session/caps 的观众供附件，故 bearer 能力
  token 是必要的统一机制（见 §10 OI-1）。token 必须以 workspace-first 顺序携带 `<ws>` 段。
- **把鉴权**改为经 resolver 对 `uploads` 类型的 `authority/2` 基于该精确 URI 的 `<ws>` 段——以
  `authority.(uri, %{workspace: request_scope_workspace})` 调用，其中 request scope 来自已认证的
  controller/LiveView mount，**非来自 URI**——替代/增强 `caller_in_attaching_messages?/2`。检查为
  `uri.<ws> == scope.workspace`。
- **向后兼容窗口：** 在声明的弃用窗口内，对已生成的仅文件名链接保留 `GET /files/:filename` 可解析
  （唯一受认可 shim，N6），并附**同名两 workspace** 回归测试，证明新契约消歧、旧契约今天仅因 UUID
  前缀文件名而无歧义。
- **修复**第二轮标记的陈旧文档漂移：`capability.ex:556` / `admin_live.ex` 注释写
  `resource://<type>/<workspace>/<name>`，而构造器 `URI.resource(ws, type, name)` 是 **workspace-first**。
  本 PR 一行文档修正。

**P2b — 把字节迁到 resolver：**

- 在 P0 resolver 上**注册** `uploads` `<type>`（后端组件 `"uploads"`，`authority/2` = workspace 段检查）。
- 经 resolver **写** uploads（`resolve(resource://<ws>/uploads/<name>)` → `Home.path("uploads")/<ws>/<name>`），
  替代 `admin_live.ex:701,731`。
- 在 controller 中经 resolver **读** uploads，替代 `uploads_controller.ex:108`。
- 从 P0.5 基线**移除** uploads 的 `Home.path("uploads")` 调用。
- **测试：** 同名两 workspace（写 + 读隔离）；外来 `<ws>` 下载被拒；窗口内向后兼容链接仍可解析；
  上传→下载往返；resolver `authority/2` 生效。
- **验收闸门：** 全部上传/下载测试通过；鉴权按 `<ws>` 段；字节落在 `…/uploads/<ws>/<name>`；
  基线缩去 uploads 项。
- **遗留子问题（自讨论带入，于 P2b 决定）：** uploads 是否需要*流式友好*的 resolver 返回（path vs
  IO 设备）以免大上传像 socialware 那样经物化临时目录往返？默认：返回 path（uploads 本就是磁盘文件；
  仅 socialware *投影*临时目录）。仅在出现大上传需求时复议。

### P3 — 消减锁定基线

- config-dir（P1）与 uploads（P2）迁完后，**移除**其基线项（已在 P1/P2 增量移除），并迁移其余
  population-3 调用者（cc/codex 模板的*租户作用域*配置写、feishu 客户端、python server、
  agent_bridge token_store、identity application）**仅在其为租户作用域内容处**——每个要么移到
  resolver 之后（注册其 `<type>`），要么若确为受认可非租户/OS 句柄面，则转为带理由的精确锚点豁免。
- **验收闸门：** `home_path_in_runtime_code` 基线**清空**；运行期应用代码中每处 `Home.path` 调用
  要么消失、要么是带理由的精确锚点豁免。锁定完成且限定于应用代码。

### 到此 STOP。

db / runtime cookie / codex socket / pty-pids 留在**受认可裸 `Home`**（D2，精确锚点豁免）。
全局凭据延后（D5）。无 `home://`（D3）。

---

## 7. 解析算法（合并参考）

```
resolve(:config_dir, {uri, scope}):             # 单 owner，uri_query_resolvers.ex
  case uri.scheme:
    "template" | "entity" -> 已存 config_dir 字符串                   # 不变
    "resource"            -> Resource.FsResolver.resolve(uri, scope)  # P1：先试通用
                             |> 命中 :none -> resolve(:socialware_config_dir, uri)
    _                     -> :none
  # config-dir 的 scope.workspace = 代理的权威 workspace（级联的已认证主体），非攻击者提供。

Resource.FsResolver.resolve(uri = resource://<ws>/<type>/<name>, scope):   # §5.1
  1. 解析三段                       -> 否则 :none / {:error, :malformed_resource_uri}
  2. <type> 在白名单？               -> 否则 :none              # R-1，无 Home 兜底
  3. 各段安全？                     -> 否则 {:error, _}        # R-2，在 Path.join 之前
       （拒 ".", "..", 分隔符, NUL；须等于 segment!/1 输出）
  4. type_spec.authority(uri, scope) -> 否则 {:error, _}       # R-3，uri.<ws> == scope.workspace
  5. {:ok, Path.join([Home.path(backend_component), <ws>, <name>])}  # R-4

# uploads（P2）从 controller/LiveView 直接以 Resource.FsResolver.resolve(uri, %{workspace: mount_ws})
# 调用——请求作用域，不经 :config_dir。
```

---

## 8. 测试策略

- **单测（每阶段 TDD）：** resolver R-1..R-4（P0）；scan 类别 S-1..S-3（P0.5）；config-dir 字节
  一致 parity + 鉴权（P1）；uploads 同名两 workspace + workspace 段鉴权 + 向后兼容（P2）。
- **不变量测试**（架构目标未达即失败的闸门，依 `feedback_completion_requires_invariant_test`）：
  - *resolver 完备性：* 枚举每个已注册 `<type>`，断言 (a) 有 `authority/2`，(b) 未注册类型返回
    `:none`，(c) `.`/`..`/分隔符段绝不到达 `Path.join`。若有人加隐式兜底或无鉴权类型即失败。
  - *锁定：* `home_path_in_runtime_code` 类别在树上为 GREEN，含一个未基线运行期 `Home.path` 调用的
    fixture 为 RED——开发者重引旁路即失败的闸门。
- **不对 live 节点做 hack**（`feedback_no_hack_use_cli_on_live_node`）；运维路径经 `mix ezagent` 行使。
  **E2E 面向生产**（`feedback_e2e_faces_production`）：uploads 往返经真实 controller 路由 + 鉴权测试，
  非 harness 捷径。

---

## 9. 验收标准（整篇）

1. 存在通用 `resource://` FS resolver，**仅注册式**，拒未注册 `<type>`（`:none`），在任何 `Path.join`
   前拒 `.`/`..`/分隔符/NUL，并跑 per-`<type>` 鉴权（R-1..R-4 绿）。
2. `home_path_in_runtime_code` scan 类别对任何**新增**运行期应用代码 `Home.path`/`profile_dir`/`home`
   调用自落地 PR 即硬失败，含精确锚点豁免（无目录白名单）与消减基线（S-1..S-3 绿）。
3. per-agent config-dir 经 resolver 解析且路径字节一致（parity 测试绿）；级联/Materializer 热路径不动（D4）。
4. uploads 经 resolver 存取，按 `<ws>` 段鉴权，下载契约改动在字节迁移**之前**落地，并有同名两 workspace
   回归测试绿。
5. P3 时锁定基线**清空**；运行期应用代码其余 `Home.path` 调用要么已迁、要么带理由的精确锚点豁免。
6. db / cookie / codex socket / pty-pids 留在受认可裸 `Home`；未新增 `home://`；未迁全局凭据。

---

## 10. 遗留项的决定（2026-06-07 与 Allen 敲定）

- **OI-1（下载契约形态，P2a）——已定：统一签名 token + ws 作用域 URI。** 不用显式路由段。依据：
  socialware 的 customer-feed 已存在（#601 结算闸门、#603 React feed），外部 React SPA 给**无 session/caps**
  的观众供附件，无法做实时 CapBAC 检查——签名能力 token（S3 presigned-URL 风格）是必要机制，且统一了
  内部+外部、可 CDN 卸载。实时检查本应提供的安全属性用设计兜回（全部**必须**）：
  ①**短 TTL**（压缩 bearer 泄漏窗口）；②token **绑定到唯一的 `resource://<ws>/uploads/<name>` URI**（不能
  平移到别的 ws/文件）；③**仅在授权后签发**——内部：mint 时实时 cap-check；外部：由 customer-feed 的
  **approved-only** 可见性门控（仅为已批准项签 token）；④**feed 的 serve 时再校验**——下载时复查该项仍
  approved（超过 TTL 的撤销杠杆，与 customer-feed approved-only 语义天然对齐）。resolver 返回 ws 作用域 URI，
  一层薄签名/验签包装 HTTP 面。（旧的 `GET /files/:filename` 按会话参与的路由被替换；§6 P2 有兼容窗口。）
- **OI-2（uploads 流式返回，P2b）——已定：path。** resolver 返回磁盘路径（uploads 本就是文件）。仅在出现
  大上传流式需求时复议。
- **OI-3（P3 其余调用者范围）——已定：不做广泛豁免；唯一的豁免维度是 boot 顺序，而非「没有 `<ws>`」。**
  仅当调用者运行在 **SchemeRegistry/UriQuery ETS 表存在之前**（config-eval / `Application.start` 之前——即
  `config/runtime.exs` 读 db + cookie）才豁免。其余一律**走 UriQuery**：租户作用域内容（agent_bridge per-agent
  token、python per-agent log、cc/codex 租户配置写）→ `resource://<ws>/<type>/<name>`；系统级/全局件（feishu
  全局 app cred 等）→ **`system://<type>`**（复用的 system scheme——仍过 UriQuery，只是 scheme 不同，**不是豁免**）。
  P3 PR 唯一要现场核的是 **identity application** 是否在 `Application.start/2` 里**早于** registry seeding 读凭据
  （若是则为真正的 boot-order 豁免，否则也迁移）。故 population-3 几乎全部迁移，boot-order 豁免清单保持最小且精确锚点。

> **已标记需人工协助步骤**（依 `feedback_flag_user_assist_steps`）：P0–P3 的*实现*均不需人工动作；
> P2 的 E2E 验收（uploads 经真实路由往返）可在可丢弃/docker E2E 栈以已 seed 用户运行——无需运维供凭据。
