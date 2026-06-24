# external_mirror 出站(push)契约研究 — mindmap↔Miro 落地用

> 只读分析。所有引用带 file:line。worktree 根 = `/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech`。
> 路径相对该根，文件全在 `apps/ezagent_domain_external_mirror/lib/`(简称 EM)和 `apps/ezagent_plugin_feishu/lib/`(简称 feishu)。

---

## 0. 一句话结论

push 出站是一条**"Publisher 源 → 每绑定 Worker → Adapter 翻译 → Binding 发送"**的流水线:

```
某个 Kind 的某个 slice 变了
  → SliceChange.broadcast  (core 自动发的)
  → Publisher(实现 @behaviour Ezagent.Behavior.Publisher 的那个 Kind)收到 {:slice_changed,_}
      在自己的 :publisher slice 里 bump cursor、造一个 %Ezagent.Publisher.Event{}、append 进环形 ring、fan_out 给所有订阅者 pid
  → ExternalMirrorWorker(每个绑定一个进程)收到 {:publisher_event, %Event{}}
      → handle_signal 返回 {:dispatch, :publish} effect(走 Router,不是直接调)
  → :publish action handler:
        payload = adapter_module.event_to_payload(event)   # 纯函数,无 IO
        binding_module.publish(payload, binding_state)     # 唯一发外部字节的地方
```

所以「让 mindmap 节点树变了就推 Miro」= **(A) 让 mindmap 节点树 Kind 成为一个 Publisher** + **(B) 写一对 push Adapter/Binding(Miro)** + **(C) 在 mindmap plugin 的 `adapters/0` 声明这对** + **(D) bind 一次把 worker 拉起来**。

---

## 核心要回答 ①:mindmap Kind 怎样成为 push 源(发什么事件 / event_to_payload 收到什么 / 谁触发)

### 1.1 谁触发 —— 不是 Adapter,是「Publisher 这个 Kind 自己」

push 路径里 EM 域**完全不订阅 mindmap 的 slice**。EM 的 Worker 只订阅一个**实现了 `Ezagent.Behavior.Publisher` 契约的 Kind**(`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/publisher.ex:9-18`:"Implementing this behaviour on a Kind is HOW that Kind becomes mirrorable")。

目前唯一的 Publisher 实现是 Session(`session_impl.ex`)。它的工作机制(可照抄给 mindmap):

- `activate/2` 里订阅自己的 SliceChange 主题:`Ezagent.SliceChange.subscribe_unverified(self_uri)`(`session_impl.ex:306-309`)。
- 任意 slice(`:chat` 等)变化 → core 广播 `{:slice_changed, event}` → `handle_signal({:slice_changed, _}, ctx)`(`session_impl.ex:383-422`)做三件事:
  1. `new_cursor = cursor + 1`(单调递增,per-publisher)
  2. 造 `%Ezagent.Publisher.Event{cursor, publisher_uri, slice_key, event_at, payload: build_payload(event, ctx)}`(`session_impl.ex:402-409`)
  3. `append_with_retention(ring, ...)` 进环 + `fan_out` 直接 `send(pid, {:publisher_event, event})` 给每个订阅者(`session_impl.ex:411-413`、`617-619`)
- **重要**:对自己 `:publisher` slice 的变化要 `:ignore`,否则订阅者增减→slice变→再发事件→死循环(`session_impl.ex:390-392`)。

> 这就是为什么 mindmap 要做 push 源,**必须自己实现 Publisher 的 4 个 callback**(下面 1.3),而不是 EM 来"监听 mindmap"。

### 1.2 Publisher 契约的 4 个 callback(mindmap Kind 要实现)

`publisher.ex`:
- `history_retention/0`(:67)—— 环大小,V1 默认 100
- `subscribe_from/3`(:85)—— 订阅 + replay,返回 `{:ok, current_cursor}`
- `snapshot/1`(:100)—— 不订阅只取当前 cursor+state
- `history/3`(:114)—— 取 `(from, to]` 区间事件

Session 的做法:这 4 个是 dispatchable action(`Ezagent.Behavior.Publisher.SessionImpl`),Kind 把它们 route 过 `Ezagent.Router.dispatch/1`(`publisher.ex:24-32`)。mindmap 照搬一个 `MindmapPublisherImpl`(行为)即可。

### 1.3 `event_to_payload/1` 收到什么

收到的就是上面 Publisher 造的 `%Ezagent.Publisher.Event{}`,字段在 `apps/ezagent_domain_external_mirror/lib/ezagent/publisher/event.ex:35-44`:

```elixir
%Ezagent.Publisher.Event{
  cursor:        non_neg_integer(),  # 单调,首事件=1
  publisher_uri: %URI{},            # 产事件的 Kind URI(mindmap 节点树 URI)
  slice_key:     atom(),            # 变的那个 slice 的 key
  event_at:      DateTime.t(),
  payload:       map()              # slice diff,见下
}
```

`payload` 的具体形状由 **Publisher 的 `build_payload/2` 决定**,不是 EM 固定的。Session 版(`session_impl.ex:566-597`)产出:

```elixir
%{action: atom(), caller: URI.t()|nil, new_slice: <剥掉transients的slice>, old_slice: ...}
```

feishu adapter 就是按这个形状读的:`event_to_payload(%Event{slice_key: :session, payload: %{}=payload})` → 取 `payload[:new_slice]`/`[:old_slice]`,diff 出"有没有新 chat send"(`feishu_adapter.ex:206-271`、`379-391`)。

> **mindmap 落地要点**:mindmap 自己的 `build_payload/2` 决定 `slice_key` 和 `payload` 形状(比如 `slice_key: :nodes`,`payload: %{op: :add_node|:update|:move, node_id, content, parent_id, new_tree | diff}`),然后 Miro 的 `event_to_payload/1` 按这个约定读。两边是你自己定的私有协议,EM 不管。

### 1.4 注意两个坑(从 feishu 的注释里学到的)

- **每次 slice 变都会发事件**,哪怕不是你关心的那种变化 → adapter 必须能 diff 出"真的是我要镜像的操作",否则返回 `:skip`(`feishu_adapter.ex:228-236` 的 `chat_send_occurred?`;mindmap 同理:不是节点增删改的 slice 变化要 skip)。
- **Lifecycle 两容器包装**:slice 在事件里是 `%{state: <持久>, transients: ...}` 包过的,`event_to_payload` 里要先 unwrap `:state` 再读(`feishu_adapter.ex:216-217`、`298-299`),否则永远读不到内容→静默漏发(feishu 踩过这个生产事故)。

---

## 核心要回答 ②:Adapter @callback 全集 + Binding/Worker 职责分工 + plugin `adapters/0` 怎么声明

### 2.1 Adapter @callback 全集(`adapter.ex`)

Adapter 是**无状态纯函数模块**(`adapter.ex:9-14`),一个 Adapter 对一个外部系统。push 与 pull 两种 kind,push 是默认(`adapter.ex:69-96`)。

**两种 kind 都必填**:
- `adapter_id/0`(:143)—— 注册键,如 `"miro"`
- `display_name/0`(:145)
- `description/0`(:148)

**push 必填**(`adapter.ex:151-159` 说明:列在 `@optional_callbacks` 只是为了不让编译器对 pull 报警,真正的 per-kind 强制在 `AdapterRegistry.assert_required_callbacks!`):
- `binding_module/0`(:170)—— 配对的 Binding(Grill-5 双向声明)
- `cap_subject/0`(:186)—— 返回 `%{behavior_module, description}`,授权"谁能 bind 这个 adapter"(Cap 2)
- `target_ownership_check/2`(:217)—— **唯一允许做外部 IO 的 callback**,bind 时检查 caller 是否拥有外部 target(如"caller 是不是这块 Miro 板的成员/拥有者")。返回 `:ok` / `{:error, :not_a_member | term}`。**禁止**再调 `Router/Invocation.dispatch`(bind 本身就是 dispatch,会死锁,`adapter.ex:206-211`)
- `event_to_payload/1`(:233)—— **纯函数无 IO**,把 Event 翻成 wire payload,返回 `{:publish, payload}` 或 `:skip`

**可选**:
- `target_ownership_check_timeout/0`(:246)—— 覆盖默认 5s(feishu 用 10s,`feishu_adapter.ex:104-105`)
- `adapter_kind/0`(:253)—— `:push`(默认)/`:pull`
- `render/2`(:264)—— 仅 pull 用

> Miro 的 `target_ownership_check/2`:用 token 调 Miro REST 查这块板 caller 有没有访问权(`GET /v2/boards/{id}` 或 members 接口),没有→`{:error, :not_a_member}`。

### 2.2 Binding @callback(`binding.ex`)+ 职责分工

Binding 是**有状态的 per-target 传输层**——一个 Binding 实例 = 一个被监督的进程 = 一个外部 target(`binding.ex:9-14`)。

- `adapter_module/0`(:95)—— 配对 Adapter(Grill-5 反向)
- `init/1`(:126)—— 签名 `init({target_id, adapter, options})`,打开传输(HTTP client / token),返回 `{:ok, state}` / `{:error, reason}`(失败→Worker raise→PerBindingSupervisor 重启)。**从 Worker 的 `activate/2` 调,不是从 init_slice**(`external_mirror_worker.ex:284`)
- `publish/2`(:143)—— `publish(payload, state)`,**唯一发外部字节的地方**(P14)。返回 `{:ok, new_state}` 或可恢复 `{:error, reason, new_state}`(不崩,Worker 记 error_count 继续);不可恢复就 raise
- `terminate/2`(:160,可选)—— 优雅 unbind 时释放传输

**职责分工三层**:
| 层 | 谁 | 状态 | 干啥 |
|---|---|---|---|
| Adapter | 纯函数模块 | 无 | Event→payload 翻译(`event_to_payload`)+ bind 时成员检查(`target_ownership_check`) |
| Binding | 模块,实现传输 callback | 有(binding_state) | `init` 开连接、`publish` 发字节、`terminate` 关 |
| Worker Kind | `Ezagent.Entity.ExternalMirrorWorker` | 有(slice+transients) | GenServer 骨架:订阅 Publisher、收 event、走 `:publish` action、dedupe、cursor、retry、监督边界 |

Worker 持有 binding_state:它是 transient(活传输句柄,不进快照),Adapter/Binding 模块每次启动从注册表 resolve(`external_mirror_worker.ex:106-142` 注释、`246-312` activate)。

### 2.3 plugin `adapters/0` 怎么声明

plugin 的 OTP Application `use Ezagent.Plugin`,实现 `adapters/0` 返回 `[{AdapterMod, BindingMod}]`(feishu:`application.ex:119-120`):

```elixir
@impl Ezagent.Plugin
def adapters, do: [{FeishuAdapter, FeishuChatBinding}]
```

`Ezagent.Plugin.boot/1` 在启动时:
1. Grill-5 编译期校验这对(双方实现各自 behaviour、双向 `binding_module/adapter_module` 互指、两个模块不同 —— `binding.ex:36-47`)
2. 注册进 `AdapterRegistry` + `BindingRegistry`
3. 两个注册表都到位后,`AdapterInstall.install/1` 自动:注册 per-adapter cap subject(`allow_<id>` 行为) + 把所有持久化的 binding 行 spawn 成 Worker(`adapter_install.ex:82-97`、`200-262`)。**push 才 spawn worker**,pull 不 spawn(`adapter_install.ex:92`)

cap subject 那个 marker Behavior 还要在 `behaviors/0` 里注册到 Session Kind(feishu:`application.ex:97-110`,`{SessionKind, :allow_feishu, FeishuAllow}`)。

---

## 核心要回答 ③:"节点树变了就推 Miro" 具体怎么接(事件从哪来)

事件**不是从 Miro adapter 来的,是从 mindmap 节点树 Kind 自己发的**。完整接法:

1. **mindmap 节点树 Kind 实现 `@behaviour Ezagent.Behavior.Publisher`**(照抄 SessionImpl 模式):
   - `activate/2` 里 `Ezagent.SliceChange.subscribe_unverified(self_uri)` 订自己的 slice 变化
   - `handle_signal({:slice_changed, event}, ctx)` 里 bump cursor、造 `%Event{slice_key: :nodes, payload: build_payload(...)}`、append ring、fan_out(对 `:publisher` slice 的变化要 ignore)
   - 实现 4 个 dispatchable action:`subscribe_from`/`snapshot`/`history`/`history_retention`
   - 把 Publisher impl Behavior 注册到 mindmap Kind(像 `EzagentDomainInstanceMessage.Application` 给 Session 注 SessionImpl 一样)

2. **Worker 怎么订上 mindmap Publisher**:看 `external_mirror_worker.ex:872-916`——它 dispatch `?action=publisher.subscribe_from` 到 **publisher URI(即 session_uri 那个字段)**。现在硬编码成 `Ezagent.Behavior.Publisher.SessionImpl`(`worker_subscribe_caps/0`,`:985-998`)。**坑**:Worker 当前把"被镜像的 Kind"叫 `session_uri` 且 subscribe cap 钉死 SessionImpl —— 要镜像 mindmap Kind,这里要么让 mindmap 也走 session URI 形状,要么 EM 要支持泛化 publisher kind/behavior(这是要确认的边界,可能需要改 EM 或等 Allen)。

3. **Miro Adapter `event_to_payload/1`**:读 mindmap 自定义 payload(如 `%{op: :add_node, node_id, content, parent_id}`),翻成 Miro REST 调用描述,如 `{:miro_create_node, board_id, content, parent_miro_id}` / `{:miro_update_node, miro_id, content}`;非节点操作 `:skip`。需要本地维护 `ezagent_node_id → miro_node_id` 映射(放 binding_state 或 opts)。

4. **Miro Binding `publish/2`**:按 tag 调 `EzagentPluginMindmap.Miro.Sync` 的 REST 客户端(`POST /v2-experimental/boards/{b}/mindmap_nodes`),返回 `{:ok, new_state}`(把新建的 miro_id 存进 state)/可恢复 `{:error, reason, state}`。`init/1` 里:若 opts 没带 board_id 就 `POST /v2/boards` 建板并存 binding_state(复用同板=把 board_id 持久化到 binding row 的 opts)。

5. **bind 一次拉起 Worker**:`Ezagent.ExternalMirror.bind(mindmap_uri, "miro", board_id_or_target, opts, ctx)`(`external_mirror.ex:152-180`)。它跑 Check1(session bind cap)+Check2(allow_miro cap)+Check3(`target_ownership_check`),过了 dispatch `:bind` → 写 binding 行 + `WorkerSpawn.spawn` 出 Worker。Worker `activate` 订阅 mindmap Publisher + `Miro.Binding.init`(建/复用板)→ 之后节点树每变一次,事件流自动推到 Miro。

---

## "mindmap 接 push adapter" 落地步骤清单

1. **[Publisher 源]** 给 mindmap 节点树 Kind 加一个 Publisher impl Behavior(照抄 `session_impl.ex`):`activate` 订自身 SliceChange、`handle_signal({:slice_changed,_})` 造 Event、实现 4 个 Publisher action;注册到 mindmap Kind。定义 mindmap 自己的 `build_payload/2` 形状(`slice_key` + node diff)。
2. **[Adapter]** 写 `EzagentPluginMindmap.MiroAdapter`,`@behaviour Ezagent.ExternalMirror.Adapter`:`adapter_id "miro"`、display/description、`binding_module/0`、`cap_subject/0`(指向一个 `Behavior.ExternalAdapter.Miro.Allow` marker)、`target_ownership_check/2`(Miro REST 查板权限,可设 `target_ownership_check_timeout 10_000`)、`event_to_payload/1`(纯函数,unwrap `:state` 后读 node diff → tagged tuple / `:skip`)。
3. **[Binding]** 写 `EzagentPluginMindmap.MiroBinding`,`@behaviour Ezagent.ExternalMirror.Binding`:`adapter_module/0` 反指、`init/1`(建/复用 board,存 board_id + id 映射进 binding_state)、`publish/2`(调 Miro REST,新建节点回存 miro_id)、`terminate/2` no-op。
4. **[声明]** mindmap plugin Application `adapters/0` 加 `{MiroAdapter, MiroBinding}`;`behaviors/0` 注册 `{SessionKind/或 mindmap Kind, :allow_miro, MiroAllow}`。boot 时 Grill-5 校验 + 自动注册表 + cap subject。
5. **[凭证]** Miro token 从 `system://credentials/miro.yaml` 读(Binding `init` 或共享 Client GenServer 里 peek)。
6. **[确认边界]** Worker 的 subscribe 路径(`external_mirror_worker.ex:872-998`)目前把被镜像 Kind 钉成 session_uri + SessionImpl cap。镜像 mindmap Kind 需要:要么 mindmap Kind 走 session 形状,要么 EM 泛化 publisher kind/behavior。**这一条很可能需要改 EM 或先问 Allen**,别自作主张。
7. **[bind]** 用 `Ezagent.ExternalMirror.bind/4-5`(或对应 mix task)把 mindmap URI bind 到 `"miro"` + board target,Worker 自动拉起,之后节点树变化经 Publisher→Worker→Adapter→Binding 实时推 Miro。

---

## 出站关键 file:line 速查

| 关注点 | file:line |
|---|---|
| Adapter @callback 全集 + push/pull kind | `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex:140-278` |
| Binding @callback(init/publish/terminate) | `.../external_mirror/binding.ex:87-162` |
| Publisher 契约 4 callback | `.../behavior/publisher.ex:59-119` |
| Event 结构 | `.../publisher/event.ex:35-44` |
| Publisher 发事件(slice_changed→Event→fan_out) | `apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex:383-422` |
| build_payload(payload 形状) | `session_impl.ex:566-597` |
| Worker 收 publisher_event→dispatch :publish | `.../behavior/external_mirror_worker.ex:337-357`、`927-953` |
| Worker :publish handler(event_to_payload→publish) | `external_mirror_worker.ex:645-687`、`757-809` |
| Worker activate(resolve+binding.init+subscribe) | `external_mirror_worker.ex:246-312` |
| Worker subscribe Publisher(钉 SessionImpl 的坑) | `external_mirror_worker.ex:872-998` |
| plugin adapters/0 声明 | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:119-120` |
| AdapterInstall(注册表→cap subject + spawn worker,push gate) | `.../external_mirror/adapter_install.ex:82-97`、`200-262` |
| bind facade(3 checks + dispatch) | `.../external_mirror.ex:152-180`、`541-566` |
| feishu Adapter(event_to_payload/target_check 参考实现) | `.../plugin_feishu/feishu_adapter.ex:83-273` |
| feishu Binding(init/publish 参考实现) | `.../plugin_feishu/feishu_chat_binding.ex:54-212` |
