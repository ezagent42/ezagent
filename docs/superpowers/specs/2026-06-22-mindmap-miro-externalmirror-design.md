# mindmap ↔ Miro external_mirror 完整出入站设计 spec

> 2026-06-22 · df-tech · dev-together handoff 模板结构
> 合成自三份研究：`docs/superpowers/research/em-outbound.md` / `em-inbound.md` / `em-conventions.md`，
> 以及现有 `apps/ezagent_plugin_mindmap/lib/`（Behavior.Mindmap / Miro / Miro.Sync / Mindmap Kind / Application）。
> 引用全部带 file:line。**诚实标注 unverified 处。**

---

## 0 · 一句话

把 mindmap 节点树 ↔ Miro 板做成完整双向：
- **出站**（ezagent → Miro）走 external_mirror **`:push` adapter 契约**（`{MiroAdapter, MiroBinding}`），
  节点树变化 → publisher event → 纯函数翻译 → Binding 真推 Miro，复用同板 + 增量 diff。
- **入站**（人在 Miro 改 → 回灌 ezagent）external_mirror **没有对应 kind**（push/pull 都不是「外部写回」），
  走**独立轮询器 GenServer + `Ezagent.Invocation.dispatch/1`** 入站通路（对齐 feishu inbound）。

两条方向**共享一份 last-pushed 基线 + ez_id↔miro_id 映射**——echo-loop 防护是这份共享状态的自然产物。

---

## ① Locked decisions（开发前定死，不再讨论）

| # | 决策 | 依据 |
|---|---|---|
| L1 | **出站 = `:push` adapter**，不是裸脚本。`adapters/0` 声明 `{MiroAdapter, MiroBinding}`，编译期 Grill-5 双向校验。现有 `Miro.Sync.push_tree/2` 降级为 Binding 内部调用的 REST helper，不再是对外链路。 | em-outbound §2.3；`adapter.ex:74-80` |
| L2 | **入站 = 独立轮询器**，**不是** external_mirror adapter 回调。external_mirror 只贡献身份/cap/binding 表，**不贡献入站 transport**。`:pull` 是「外部 GET 我的只读快照」，**不写回树**——别误用。 | em-inbound §0；`adapter.ex:69-97` |
| L3 | **入站唯一入口 = `Ezagent.Invocation.dispatch/1`**（P14）。轮询器 diff 出的每个改动构造一个 Invocation 打到 `Ezagent.URI.with_action(mindmap_uri, :mindmap, :<action>)`，`mode: :call`（mindmap 全 action 都 `modes: [:call]`，`behavior/mindmap.ex:35-145`）。**禁止** `PubSub.broadcast` 到入站 topic，**禁止**直接改 Kind state。 | CLAUDE.md P14；事故 2.1 |
| L4 | **入站身份默认方案 A**：caller = 配置的「板 owner」user URI（放 `miro.yaml`，与 board_id 并列），`caps = Ezagent.Identity.list_caps_for(板owner_uri)`。**不新增** `system://miro-poller` principal（north star 在消除 system://，`catalog.ex:150-152`）。方案 B（admin entity + inline narrow cap，全权覆盖）仅当产品要「Miro 即真相」时启用。 | em-inbound §②；`sender_resolver.ex:55-80` |
| L5 | **echo 防护 = last-pushed 基线对比**，不是 origin flag。Miro 节点上无 ezagent 标记字段，feishu 的 `_feishu_origin` 借不了（em-inbound §③）。轮询 diff **vs 上次成功 push 的树快照**，只有相对基线变化的才算「人改的」。 | em-inbound §③ |
| L6 | **出站复用同板 + 增量 diff 是入站的前置**。出站每次建新板时入站轮询不知道盯哪块。落地顺序：**先出站复用板 + 基线，再入站轮询**。 | em-inbound §③ 末；`miro/sync.ex:9-10` |
| L7 | **mindmap 持久化已是 durable**（`{:snapshot, :on_change}`，`mindmap.ex:34`）。入站 dispatch 前冷实例需 `SpawnRegistry.ensure_live/1` rehydrate（抄 `inbound_dispatcher.ex:228-246`），never raw spawn。 | em-inbound §① |
| L8 | **不碰 core / world / ARCHITECTURE.md。** 所有新代码住 `apps/ezagent_plugin_mindmap/`。若 publisher 泛化（见 ④ U1）需改 external_mirror 域 → **暂停问 Allen**。 | CLAUDE.md grill 文化 |

---

## ② 出站（external_mirror `:push` adapter）

### 2.1 数据流（事件从哪来 —— 不是 adapter 监听，是 mindmap Kind 自己发）

```
mindmap 节点树 :tree slice 变 (任一写 action 经唯一 commit/1, behavior/mindmap.ex:404)
  → core 自动 SliceChange.broadcast {:slice_changed, event}
  → MindmapPublisherImpl（mindmap Kind 实现 @behaviour Ezagent.Behavior.Publisher）
        handle_signal({:slice_changed,_}) → bump cursor、造 %Ezagent.Publisher.Event{
            slice_key: :tree, payload: build_payload(old_tree, new_tree)}、append ring、fan_out
  → ExternalMirrorWorker（每绑定一进程，EM 域起）收 {:publisher_event, %Event{}}
        → handle_signal 返 {:dispatch, :publish} effect（走 Router，P14）
  → :publish handler:
        payload = MiroAdapter.event_to_payload(event)     # 纯函数，无 IO
        MiroBinding.publish(payload, binding_state)        # 唯一发外部字节处 (P14)
```

**关键认知**：「节点树变了就推 Miro」= **(A) mindmap Kind 成为 Publisher** + **(B) 写 `{MiroAdapter, MiroBinding}`** +
**(C) `adapters/0` 声明** + **(D) bind 一次拉起 Worker**。EM 域**完全不订阅 mindmap slice**（em-outbound §1.1）。

### 2.2 MindmapPublisherImpl（让 mindmap Kind 成为 push 源）

照抄 `apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex` 模式：

- `activate/2` 里 `Ezagent.SliceChange.subscribe_unverified(self_uri)`（`session_impl.ex:306-309`）。
- `handle_signal({:slice_changed, event}, ctx)`（`session_impl.ex:383-422`）：
  1. `new_cursor = cursor + 1`（单调，per-publisher）
  2. 造 `%Ezagent.Publisher.Event{cursor, publisher_uri, slice_key: :tree, event_at, payload: build_payload(...)}`
  3. `append_with_retention(ring,...)` + `fan_out`（`send(pid, {:publisher_event, event})`）
  - **对自己 `:publisher` slice 的变化 `:ignore`**，否则订阅者增减 → slice 变 → 死循环（`session_impl.ex:390-392`）。
- 实现 4 个 dispatchable Publisher action：`subscribe_from/3`、`snapshot/1`、`history/3`、`history_retention/0`
  （`publisher.ex:59-119`）。
- 注册到 mindmap Kind（像 `EzagentDomainInstanceMessage.Application` 给 Session 注 SessionImpl 一样）。

**mindmap 私有 payload 协议**（两边自己定，EM 不管，em-outbound §1.3）—— `build_payload/2` 产出：

```elixir
# slice 在事件里是 Lifecycle 两容器包过的 %{state: <持久>, transients: ...}，
# 先 unwrap :state 再读（不 unwrap → 静默漏发，feishu 生产事故，feishu_adapter.ex:216-217）
%{
  op_kind:  :tree_changed,
  new_tree: %{nodes: ..., root_id: ...},   # commit 后整棵树
  old_tree: %{nodes: ..., root_id: ...}    # 变更前（用于 adapter diff 增量）
}
```

> mindmap 的写全部收敛到单一 `:tree` key（`behavior/mindmap.ex:404` 的 `commit/1`），所以 payload 直接带新旧整树最简单；
> 增量由 adapter 在 `event_to_payload` 里 diff，不在 publisher 里拆。

### 2.3 MiroAdapter（`@behaviour Ezagent.ExternalMirror.Adapter`，纯函数）

必填 callback（`adapter.ex:140-278`，push kind）：

| callback | 实现 |
|---|---|
| `adapter_id/0` | `"miro"` |
| `display_name/0` / `description/0` | 运营面文案 |
| `adapter_kind/0` | `:push`（可省，默认即 push；为清晰显式声明） |
| `binding_module/0` | `EzagentPluginMindmap.MiroBinding`（Grill-5 双向） |
| `cap_subject/0` | `%{behavior_module: Behavior.ExternalAdapter.Miro.Allow, description: ...}`（Cap 2，约定命名 `Behavior.ExternalAdapter.<id>.Allow`） |
| `target_ownership_check/2` | **唯一允许 IO 的 callback**：用 token 调 `GET /v2/boards/{id}` 查 caller 对该板有无访问权，无 → `{:error, :not_a_member}`。**禁止**调 `Router/Invocation.dispatch`（bind 本身是 dispatch，死锁，`adapter.ex:63-67`）。可设 `target_ownership_check_timeout/0 => 10_000`（feishu 用 10s） |
| `event_to_payload/1` | **纯函数无 IO**：unwrap `:state` → diff `old_tree`/`new_tree` → 产出 tagged op 列表 `{:publish, %{ops: [...], mapping_hint: ...}}`；非 tree 变化或空 diff 返 `:skip`（em-outbound §1.4） |

`event_to_payload` 的 diff 产出（喂给 Binding 的 wire 描述）：

```elixir
{:publish, %{ops: [
  {:create_node, ez_id, content, parent_ez_id},
  {:update_node, ez_id, content},
  {:delete_node, ez_id},
  {:move_node,   ez_id, new_parent_ez_id}
]}}
```

> ez_id↔miro_id 映射是**有状态的**（建出来的 miro_id 要存），不能放纯函数 adapter。映射住 **binding_state**（见 2.4）。
> 所以 adapter 产 ez_id 级 op，Binding 在 publish 时查 binding_state 把 ez_id 翻成 miro_id（新建后回存）。

### 2.4 MiroBinding（`@behaviour Ezagent.ExternalMirror.Binding`，有状态 per-target）

`binding.ex:87-162`：

| callback | 实现 |
|---|---|
| `adapter_module/0` | `EzagentPluginMindmap.MiroAdapter`（反向 Grill-5） |
| `init/1` | 签名 `init({target_id, adapter, options})`，从 Worker `activate` 调（`external_mirror_worker.ex:284`）。读 creds（`Miro.read_creds/0`）；**复用同板**：opts/绑定行带 board_id 就用，否则 `Miro.create_board` 建并把 board_id 持久化回 binding 行 opts。state = `%{token, board_id, ez_to_miro: %{}, last_pushed_tree: nil}` |
| `publish/2` | **唯一发外部字节处**（P14）。按 op 列表调 `Miro.create_node`/`update`/`delete`/`move`（update/delete/move 端点见 U2），新建节点把 miro_id 回存 `ez_to_miro`；推完刷新 `last_pushed_tree` 基线。返回 `{:ok, new_state}`（含更新后映射+基线）/ 可恢复 `{:error, reason, new_state}`（不崩，Worker 记 error_count）。partial-publish（sent≥1 后失败）= **RAISE**（让 Worker 崩重启、cursor 不越过未处理数据，对齐 `feishu_chat_binding.ex:108-167`） |
| `terminate/2` | no-op（HTTP 无长连） |

### 2.5 复用同板 + 节点位置布局（避免重叠）

- **复用同板**：board_id 来源优先级 `bind opts > miro.yaml > Binding init 新建后持久化`。建一次存一次，之后所有 publish 复用（`miro/sync.ex:9-10` v1 TODO 收口）。
- **节点位置布局**：Miro mindmap_nodes 端点**第一个节点自动成根**、子节点带 `parent: %{id}`（`miro.ex:57-66`）。
  Miro 的 mind-map 布局引擎**自动排子节点位置**（不需手算坐标），所以建节点时**只给 parent 关系、不给 x/y**，
  靠 Miro 自身 mind-map auto-layout 避免重叠。
  > ⚠️ **unverified**：experimental 端点是否真的全自动布局、有无重叠，需真板探活确认（`miro.ex:14-16` 标 experimental）。
  > 若 auto-layout 不可靠，fallback = 建节点时显式给 `position: %{x, y}`，按 DFS order + 层级深度算非重叠网格坐标。
  > **此 fallback 的坐标公式留待出站 e2e 探活后定，先不写死。**

### 2.6 声明 + 凭证

- `application.ex` `adapters/0` 加 `[{MiroAdapter, MiroBinding}]`（对齐 feishu `application.ex:119-120`）。
- `behaviors/0` 注册 cap subject marker：`{EzagentPluginMindmap.Mindmap, :allow_miro, Behavior.ExternalAdapter.Miro.Allow}`
  （对齐 feishu `{SessionKind, :allow_feishu, FeishuAllow}`，`application.ex:97-110`）。
- boot 时 Grill-5 校验双向声明 + 自动注册表 + `AdapterInstall` 注册 cap subject + push kind spawn worker（`adapter_install.ex:82-97`）。
- 凭证 `system://credentials/miro.yaml`（`miro.ex:29`，已 sanctioned 过 uri_query.scan）。

### 2.7 bind 拉起 Worker

`Ezagent.ExternalMirror.bind(mindmap_uri, "miro", board_id_or_target, opts, ctx)`（`external_mirror.ex:152-180`）：
跑 Check1（bind cap）+ Check2（allow_miro cap）+ Check3（`target_ownership_check`）→ dispatch `:bind` → 写 binding 行 + spawn Worker。
Worker `activate` 订阅 mindmap Publisher + `MiroBinding.init`（建/复用板）→ 之后节点树每变实时推 Miro。

---

## ③ 入站（轮询器 GenServer + dispatch 回 mindmap）

### 3.1 形态：GenServer 定时 `GET mindmap_nodes` + diff + dispatch

放 plugin `children/0`（`application.ex:60-65` 已有 DynamicSupervisor，轮询器加旁边）：

```elixir
def children do
  [
    {DynamicSupervisor, name: EzagentPluginMindmap.InstanceSupervisor, strategy: :one_for_one},
    EzagentPluginMindmap.Miro.Poller          # 新增
  ]
end
```

```
init → schedule(:poll)   # env 开关 EZAGENT_MINDMAP_MIRO_POLL 默认关，防 CI 打真实 Miro（抄 ws_client.ex:65）
handle_info(:poll):
  1. Miro.read_creds() → token + board_id（miro.ex:24-39；无 board 绑定则跳过本拍）
  2. Miro.get_nodes(token, board_id) → 远端节点列表（miro.ex:68-76，已实测）
  3. 折回成树（按 miro_id + parent + content）
  4. diff(remote_now, last_pushed_baseline) + echo 防护（见 3.3）→ 过滤 no-op → 人改动 op 列表
  5. ensure_live(mindmap_uri) rehydrate 冷实例（inbound_dispatcher.ex:228-246）
  6. 逐 op Ezagent.Invocation.dispatch(mode: :call)；{:error,_} → Logger.warning + telemetry，不推进基线
  7. 成功改动 → 出站会自动 push 一次 → 刷新 last_pushed 基线 → 才 schedule 下一拍（防自激，见 3.3）
  8. 429/网络错退避（抄 ws_client.ex 5s backoff，:111/:131）
```

> v1 单板（`miro.yaml` 的 board_id）。多 mindmap↔多板 = binding 表 + 每板一子进程（复用那个 DynamicSupervisor），
> 跟出站「复用板」一起做（`miro/sync.ex:9-10`）。

### 3.2 身份 + caps（方案 A，default）

- caller = `miro.yaml` 配的「板 owner」user URI；`caps = Ezagent.Identity.list_caps_for(板owner_uri)`（`sender_resolver.ex:74`）。
- mindmap per-node 授权据此判（`behavior/mindmap.ex:427-437`）：板 owner 改未认领/自己认领的节点能过，改别人节点 `:forbidden`（合理且会 log）。
- 构造 `%Ezagent.Invocation{target: with_action(mindmap_uri, :mindmap, :<act>), mode: :call, args:, ctx: %{caller: 板owner_uri, caps:}}`。
- **不碰 system:// principal**（grep 自查，`catalog.ex:150-152`）。方案 B（`Ezagent.Entity.User.admin_uri()` + inline narrow cap，`granted_by: admin_uri`）仅「Miro 即真相全权」时。

### 3.3 echo-loop 防护（核心）

回环：出站 push 写 Miro → 下轮轮询读回**自己刚推的** → 误当人改 → dispatch 回 mindmap → 再触发出站 → 死循环。

1. **last-pushed 基线对比（主防线）**：出站 `publish` 推完把 `{树快照, ez_id↔miro_id 映射}` 存为基线（住 binding_state，2.4）。
   轮询 diff `remote_now` vs **基线**——ezagent 自己推的 == 基线 → diff 为空 → 不 dispatch。
2. **入站成功后刷新基线 + 顺序锁**：人改 dispatch 成功 → 树变 → 出站自动 push 一次 → 用新结果刷基线 →
   **才放下一轮轮询**（或轮询时跳过「正在出站」窗口）。**关键顺序**，否则把自己入站引发的出站再读回。
3. **内容级幂等兜底**：dispatch 前轮询器侧比对「目标==当前」过滤 no-op（现有 handler 非天然 no-op 短路，如 `handle_rename_node` 无条件 set `behavior/mindmap.ex:210-211`，故 no-op 过滤放轮询器侧更稳）。
4. **游标 = 树内容快照**（experimental 端点无原生 ETag/version，`miro.ex:14-16`）。若 Miro 后续给节点加 `modifiedAt` 可升级时间戳 diff。

### 3.4 失败处理（P18 no silent down）

- `{:error, reason}`（`:forbidden` / `:would_create_cycle` / `:node_not_found`）→ `Logger.warning` + telemetry，**不推进基线**，下轮重试或交人工。**绝不** silent `:ok`。
- 无 react 渠道（不像 feishu 能回 chat），至少 telemetry/日志可观测；进阶可「回灌 Miro 提示 + 回滚到 ezagent 正确态」（ezagent 仍真相源，em-conventions §③ 入站断言 5）。

---

## ④ 不碰 / 边界 / unverified

**不碰**：
- core / world / ARCHITECTURE.md（Allen 维护）。所有新代码在 `apps/ezagent_plugin_mindmap/`。
- P14：入站只走 `Ezagent.Invocation.dispatch/1`，零 `PubSub.broadcast` 到入站 topic；不直接改 Kind state。
- 不新增 `system://` principal（north star，`catalog.ex:150-152`）。
- 不为赶进度绕 gate；不发明新 Decision。

**gate 全集**（每 PR 过，em-conventions §②）：`mix compile --force`（含 `:ezagent_plugin_check`）/ `ezagent.arch.scan`（`set_effect_sites` cap=122 别超）/ `check_invariants` / `check_invariants.lifecycle` / `doc.scan`（`undocumented_public_defs` cap=374 别超）/ `uri_query.scan` / `format --check-formatted` / `mix test`（本插件全绿 + umbrella 编译干净）。

**本插件三条特有坑**（em-conventions §②）：
1. **set_effect_sites**：新增写状态走**单一 commit**，别散 `{:set}`（mindmap 已收敛到 `commit/1` `behavior/mindmap.ex:404`）。Publisher 的 cursor/ring 写若是新 Behavior，注意其 effect 站点计入 cap。
2. **uri_query**：用 `Ezagent.URI.with_action(mindmap_uri, :mindmap, :add_node)` 构造 dispatch 目标，**不手拼 `?action=`**（`miro.ex:27` 注释 + feishu `inbound_dispatcher.ex:286` 正例）。
3. **doc.scan**：MiroAdapter/MiroBinding/Publisher 的 public callback 要么真 `@doc`，要么 `@doc false`（mindmap 已大量用，`behavior/mindmap.ex:147` 等）。

**unverified（诚实标注）**：
- **U1（最关键，可能要问 Allen）**：Worker subscribe 路径目前把「被镜像 Kind」钉成 `session_uri` + cap 钉死 `Ezagent.Behavior.Publisher.SessionImpl`（`external_mirror_worker.ex:872-998`、`985-998`）。镜像 mindmap Kind 需要：**要么 mindmap 走 session URI 形状，要么 EM 泛化 publisher kind/behavior**。后者要改 external_mirror 域 → **暂停，写 issue，等 Allen**，别自作主张。
- **U2**：`Miro.create_node`/`get_nodes` 已实测（`miro.ex:57-76`），但 **update/delete/move 端点未实现也未探活**（experimental，`miro.ex:14-16`）。出站增量 diff 依赖这三个端点 → **写代码前先真 token 探活反推 schema**（照 outbound-evidence §1）。若 experimental 不支持 update/move，fallback = delete + recreate（会丢 miro_id 稳定性，需评估）。
- **U3**：节点位置 auto-layout 是否无重叠未验（2.5）。
- **U4**：方案 A 的「板 owner」user 是否已有对应 ezagent entity + Identity caps，需产品/数据确认。

---

## ⑤ DoD = 真实 Miro 往返 e2e（出/入两条，分别验）

DoD = **可演示产物**（一条数据真穿过新通路、外部真有变化），不是「测试绿」（`handoff-standard.md:6-18`）。照现有 mindmap 三份 evidence 写法。

### 出站 e2e（`:push` adapter，真推 Miro + GET 复核）

**断言**（em-conventions §③ 出站）：
1. **经契约非裸脚本**：`adapters/0` 声明 `{MiroAdapter, MiroBinding}`，编译期 `:ezagent_plugin_check` 过双向声明。
2. **链路真走**：节点树变 → publisher event → `MiroAdapter.event_to_payload`（纯）→ `MiroBinding.publish`（真 REST）。
3. **复用同板 + 增量**：第一次 bind 建/绑 board；**第二次推同板只发增量、不重建**；GET 复核：变化节点对、未变不重建、ez_id↔miro_id 映射稳定。
4. **关键断言三件**（照 outbound-evidence）：板上节点数对、根数=1、层级（父在子前）对。
5. **partial 不静默丢**（sent≥1 失败 = RAISE）；**per-binding 崩溃隔离**。
6. **可演示 stdout**：`PUSH_OK board_id=… 增量建/改 N` + `VERIFY_GET 板上实有节点=N 其中根=1`。

### 入站 e2e（轮询 GET + diff → dispatch，真 Miro 往返）

**断言**（em-conventions §③ 入站）：
1. **真板手改一个节点**（改标题/加子/删）。
2. **轮询一拍**：`get_nodes` 与基线 diff，识别「人为改动」。
3. **echo 防护**：纯出站推完后轮询**不**触发入站回灌（diff vs 基线为空）→ 断言无 echo 循环。
4. **身份绑定**：caller = 板 owner user + caps；per-node 授权生效（改别人节点 `:forbidden` + log）。
5. **CapBAC + dispatch**：`mode: :call` 让 cap-denial 同步返回；无权改动被拒、不落地。
6. **不静默丢**：dispatch 失败有 telemetry/Logger 出口。
7. **可演示 stdout**：手改 Miro → 轮询日志识别改动 → dispatch 成功/被拒 → `get_tree` 复核树变化（或被拒未变）。ExUnit 真实输出 `N tests, 0 failures`。

> umbrella 主线既有红（liveview/workspace 与本插件无关）诚实声明：本插件自身测试全绿 + umbrella 编译干净即可（照 `mindmap-e2e-evidence.md:61-65`），不伪造绿。

---

## ⑥ 分阶段（每阶段 e2e 可单独过）

### Phase A — 出站 adapter 先（external_mirror `:push` 收口）

A1. **探活 U2 端点**：真 token 探 Miro update/delete/move（或确认 fallback）。
A2. **MindmapPublisherImpl**：mindmap Kind 实现 Publisher 4 callback + `build_payload`（new/old tree）+ 注册。
A3. **MiroAdapter / MiroBinding**：纯函数 diff + 有状态传输 + 复用同板 + ez_id↔miro_id 映射 + last-pushed 基线。
A4. **声明 + cap**：`adapters/0` / `behaviors/0`（allow_miro marker）/ Grill-5 过。
A5. **解决 U1**（Worker subscribe 泛化）：若需改 EM 域 → 暂停问 Allen。
A6. **出站 e2e**（⑤ 出站全断言）+ 单测（`event_to_payload` 纯函数 diff、`tree_to_ops`）+ 全 gate。
→ **Phase A 出站 e2e 单独过**：bind mindmap→miro，改树两次，第二次只增量，GET 复核。

### Phase B — 入站 poller 后（依赖 A 的复用板 + 基线）

B1. **Miro.Poller GenServer**：`children/0` 挂载 + env 开关 + 定时 + 退避。
B2. **diff + echo 防护**：远端树折回 + vs 基线 diff + no-op 过滤（复用 A 的共享基线/映射）。
B3. **身份 + dispatch**：方案 A 板 owner + caps + `with_action` 目标 + `ensure_live` rehydrate + 逐 op `mode: :call`。
B4. **失败处理**：`{:error,_}` → telemetry/log、不推进基线；成功后刷基线再放下一拍（顺序锁）。
B5. **入站 e2e**（⑤ 入站全断言）+ 单测（diff、echo skip、no-op 过滤、cap-denial 回滚）+ 全 gate。
→ **Phase B 入站 e2e 单独过**：真板手改一节点 → 轮询 → `get_tree` 复核树变；纯出站不触发回灌（无 echo）。

---

## 关键 file:line 速查

| 关注点 | file:line |
|---|---|
| Adapter @callback 全集 + push/pull kind | `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex:69-278` |
| Binding @callback | `.../external_mirror/binding.ex:87-162` |
| Publisher 契约 4 callback | `.../behavior/publisher.ex:59-119` |
| Publisher 发事件参考（SessionImpl） | `apps/ezagent_domain_session/lib/ezagent/behavior/publisher/session_impl.ex:306-422,566-597` |
| Worker subscribe 钉 SessionImpl 的坑（U1） | `external_mirror_worker.ex:872-998` |
| bind facade（3 checks） | `.../external_mirror.ex:152-180` |
| feishu 出站 Binding 样板 | `.../plugin_feishu/feishu_chat_binding.ex:54-212` |
| feishu 入站全套样板 | `.../plugin_feishu/inbound_dispatcher.ex:57-303` / `sender_resolver.ex:39-80` |
| 冷实例 rehydrate | `inbound_dispatcher.ex:228-246` |
| 身份 north star（消除 system://） | `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:150-152` |
| mindmap Behavior（action 全 :call + 唯一 commit + per-node 授权） | `apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:35-145,404,427-437` |
| mindmap children/0（挂轮询器处） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/application.ex:60-65` |
| mindmap durable 持久化 | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/mindmap.ex:34` |
| Miro 客户端（creds/create/get） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro.ex:24-76` |
| 出站 push_tree + mapping（基线源） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro/sync.ex:9-10,43-61` |
| gate 全集 + DoD | `.claude/skills/dev-together/references/handoff-standard.md:6-18` |
