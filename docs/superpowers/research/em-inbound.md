# external_mirror 入站 + Miro 轮询入站 研究

> 任务：把 mindmap↔Miro 做成完整 external_mirror 出入站。出站已有雏形（`Miro.Sync.push_tree`，每次建新板）。
> 本文只研究**入站**：人在 Miro 改 → 回 ezagent 改树。Miro 无服务端长连（不像 feishu WSS），只能轮询。
> 全程只读分析，带 file:line。

---

## 0. 先认清两种 adapter kind（决定入站怎么搭）

`Ezagent.ExternalMirror.Adapter` 有一条 **KIND 轴**（P3-1，`adapter.ex:69-97`、`:107`）：

- **`:push`**（默认）—— 有配对的 `Binding` GenServer 拥有 per-binding 外部 transport。`:bind` 时 Domain 起一个 Worker，每个 Publisher event 调 `binding_module.init/1` 再 `publish/2`（`adapter.ex:74-80`）。这是**出站**方向（ezagent → 外部）。Feishu 出站就是这条：`FeishuChatBinding`（`feishu_chat_binding.ex:1-79`）。
- **`:pull`**（P3-2）—— **无** per-binding transport（无 `binding_module/0`、无 `target_ownership_check/2`、无 `event_to_payload/1`），注册时**不起 Worker**（`adapter.ex:83-88`）。改为实现 `render/2`，被**调用方的 Phoenix channel 按需调**。customer feed 就是这条（`customer_feed_adapter.ex:40-99`）。

**关键结论**：external_mirror 的 `:push`/`:pull` 两种 kind **都不是「外部主动改 → 回写 ezagent」的入站**。

- `:push` 是 ezagent→外部（出站）。
- `:pull` 是「外部读 ezagent」（外部 GET 一个 render 快照），方向上看像入站但**只读**，不写回树。

→ **Miro 入站（外部写 → 改 ezagent 树）在现有 external_mirror 抽象里没有对应 kind**。它必须走**和 feishu inbound 一样的独立入站路径**：一个常驻进程拿到外部变更 → 翻译成 action → `Ezagent.Invocation.dispatch/1`。external_mirror 框架在这里**只贡献身份/cap/binding 表**，不贡献 transport。这点要在 plan 里跟 Allen 讲清楚，别误以为 `:pull` adapter 能写回。

---

## ① 入站统一怎么走（P14）

**唯一合法入口 = `Ezagent.Invocation.dispatch/1`**，禁止 `PubSub.broadcast` 到入站 topic（CLAUDE.md P14 / 事故 2.1）。feishu 两个 transport（HTTP webhook plug + WSS 长连）都汇到**同一个** `InboundDispatcher.dispatch/1`，再到 `Ezagent.Invocation.dispatch`：

- WSS 长连 `ws_client.ex:215-231`：sidecar 吐 JSON event → `handle_event/2` → `InboundDispatcher.dispatch(chat_id:, message_id:, sender:, body:)`。
- 统一入口 `inbound_dispatcher.ex:57-207`，核心序列：
  1. `SenderResolver.resolve(sender)` → `{:ok, caller_uri, caps}` / `{:pending, _}` / `{:error, _}`（`inbound_dispatcher.ex:64`、`sender_resolver.ex:39-80`）。
  2. 解析目标（feishu 是 chat_id→session_uri；mindmap 是 board_id→mindmap_uri）。
  3. 构造 `%Ezagent.Invocation{target:, mode: :call, args:, ctx: %{caller:, caps:, ...}}` → `Ezagent.Invocation.dispatch(inv)`（`inbound_dispatcher.ex:292-303`）。
  4. **失败必须让人知道**（P18 no silent down）：cap-deny → 回 feishu 一条文字 + THUMBSDOWN react（`inbound_dispatcher.ex:106-124`、`345-358`）。

**mindmap 对应做法**：轮询器读到 Miro 的人为改动，diff 出一组 `add_node/rename_node/move_node/remove_node`，**每个改动构造一个 Invocation 打到** `entity://<ws>/mindmap/<name>?action=mindmap.<act>`，`mode: :call`（mindmap 所有 action 都是 `modes: [:call]`，见 `behavior/mindmap.ex:35-145`），`ctx: %{caller:, caps:}`。失败（如 `:forbidden`、`:would_create_cycle`、`:node_not_found`）**同步回到** `{:error, _}`，轮询器 log + 不推进游标（见 ③ 防回环 + 错误处理）。**绝不**直接改 Kind state 或 PubSub。

dispatch 前若 mindmap 实例冷（节点树是 `{:snapshot, :on_change}` durable，`mindmap.ex:34`），需先 rehydrate——抄 feishu 的 `SpawnRegistry.ensure_live/1`（`inbound_dispatcher.ex:228-246`），never raw spawn。

---

## ② 轮询器怎么搭、放哪层、身份用谁

### 形态：一个 GenServer，定时 `GET mindmap_nodes` + diff + dispatch

对照 feishu WSS：`WsClient` 是 `use GenServer`，常驻，`handle_info` 驱动，失败重连（`ws_client.ex:32-135`）。Miro 没有长连，把「等 sidecar 推」换成「`Process.send_after` 自己定时拉」：

```
init → schedule(:poll)
handle_info(:poll):
  1. Miro.read_creds() → token + board_id（miro.ex:24-39；board_id 来自 miro.yaml 或绑定表）
  2. Miro.get_nodes(token, board_id) → 远端 mindmap 节点列表（miro.ex:68-76，已实测）
  3. 读当前 ezagent 树：dispatch get_tree（behavior/mindmap.ex:123-129/344-348）拿 %{nodes, root_id}
  4. diff(远端, 本地) + echo 防护（见 ③）→ 一组 {act, args}
  5. 逐个 Ezagent.Invocation.dispatch（mode: :call），失败 log，不推进 last-pushed 基线
  6. schedule(:poll)  # 固定间隔，如 10s；429 退避
```

`Miro.get_nodes` 端点已存在且实测（`miro.ex:68-76`）；建/读节点端点是 Miro **experimental**（`miro.ex:14-16`），行为可能变，diff 要对字段缺失健壮。

### 放哪层：plugin 的 `children/0`

mindmap 是纯 plugin（路 A），`children/0` 已经挂了一个 `DynamicSupervisor`（`application.ex:60-65`）。轮询器是 plugin 私有常驻进程 → **加进 `children/0`**：

```elixir
def children do
  [
    {DynamicSupervisor, name: EzagentPluginMindmap.InstanceSupervisor, strategy: :one_for_one},
    EzagentPluginMindmap.Miro.Poller    # 新增
  ]
end
```

`Ezagent.Plugin.boot/1` 会把 `children/0` 挂进监督树（`application.ex:21`）。建议加 env 开关（抄 feishu `EZAGENT_FEISHU_WS=0`，`ws_client.ex:65`），如 `EZAGENT_MINDMAP_MIRO_POLL=0` 默认关，避免无 board 绑定时空转 + 防 CI 打真实 Miro。

> 多实例问题：一个轮询器对一块板。v1 先固定单板（`miro.yaml` 的 `board_id`，`miro.ex:31`）；多 mindmap↔多板要一张 binding 表（board_id↔mindmap_uri）+ 每板一个轮询子进程（可复用那个 `DynamicSupervisor`）。这部分建议跟出站「复用板」一起做（`miro/sync.ex:9-10` 的 v1 TODO 已点名）。

### 身份用谁：genesis admin entity + inline narrow cap（**不要**新造 system:// principal）

这是最容易踩坑的点。catalog 明确：`system://` 临时身份正在被**全面消除**，north star 只剩 genesis `system://bootstrap`，其余 dispatch 一律改用**真实 genesis admin entity** `entity://system/user/admin`（`Ezagent.Entity.User.admin_uri/0`）+ **inline narrow per-action cap**（`granted_by: admin_uri`，可问责）——见 `system_principal/catalog.ex:150-152、236-241、318-324、362-364`。

→ 轮询器入站的 caller **不要新增 `system://miro-poller`**（会被 north star 方向打回）。两条合规选择：

- **(A) 绑定某个 user + caps（推荐，对齐 feishu）**：feishu 入站把外部身份映射到一个**绑定的 ezagent user**（`sender_resolver.ex:55-80`：open_id→`entity://user/...`，caps 从该 user 的 Identity slice 读 `Ezagent.Identity.list_caps_for/1`，`:74`）。Miro 没有「谁改的」逐操作身份（轮询只看到结果 diff），所以选一个**配置的「板 owner」user URI**（放 `miro.yaml`，与 board_id 并列），`caller = 该 user`，`caps = Ezagent.Identity.list_caps_for(user_uri)`。mindmap 的 per-node 授权（`behavior/mindmap.ex:427-437`：`caller==node.owner` 或持 wildcard admin cap）据此判定——板 owner 改未认领/自己认领的节点能过，改别人节点会 `:forbidden`（合理，且会 log）。
- **(B) genesis admin entity + inline cap**：若要「Miro 上的改动有全权」（绕过 per-node owner），`caller = Ezagent.Entity.User.admin_uri()`，`ctx.caps` 放该实例所需 action 的 inline narrow cap（`granted_by: admin_uri`）。这是「系统性写回」的合规姿势（catalog `:318-324` 的模式）。

**建议**：默认 (A)（人在 Miro 协作，身份=板 owner，per-node 授权仍生效，符合 mindmap「认领=问责+权限闸」设计 `behavior/mindmap.ex:22-24`）；(B) 仅当产品要「Miro 即真相、全权覆盖」时。**两者都不碰 `system://` principal。**

---

## ③ echo-loop 防护（核心）

回环来源：ezagent 出站 `push_tree` 把树写到 Miro → 下一轮轮询 `get_nodes` 读回**自己刚推的内容** → 误当成「人的改动」→ dispatch 回 mindmap → （可能再触发出站）→ 死循环。

feishu 的做法是**origin 标记**：inbound 给 body 盖 `_feishu_origin: true`（`inbound_dispatcher.ex:258-261`），出站 mirror 见到这个标记就 skip，不回推 feishu。但 Miro 轮询**读不到** ezagent 的标记（Miro 节点上没有「这是 ezagent 推的」字段，只有 content + parent + miro_id），所以 origin-flag 这条**直接照搬不了**。Miro 入站要用「**对比 last-pushed 基线**」+「**幂等 diff**」组合：

1. **维护 last-pushed 映射 / 基线**（首选）。出站 `push_tree` 已经返回 `mapping`（ez_id↔miro_id）和推送时的树（`miro/sync.ex:43-61`）。把「**最近一次成功 push 后的树快照** + ez_id↔miro_id 映射」存进轮询器 state（或 mindmap 实例 state 旁挂）。轮询时：
   - `remote_now = get_nodes()` 折回成树形（按 miro_id + parent + content）。
   - **diff(remote_now, last_pushed_remote)**：只有**相对上次推送基线变化**的节点才算「人改的」。ezagent 自己推的内容 == 基线 → diff 为空 → 不 dispatch。**这是主防线**，把「读回自己推的」从源头消掉。
2. **入站成功后更新基线**：人的改动 dispatch 进 mindmap 成功 → 树变了 → ezagent 会**再出站 push 一次**（保持 Miro 与树一致）→ push 完用新结果**刷新 last-pushed 基线**。这样下一轮轮询的 diff 自然为空。**关键顺序**：先让出站推完、基线刷新，再放下一轮轮询（或轮询时跳过「正在出站」窗口），否则会把自己入站引发的出站再读回来。
3. **内容级幂等兜底**：即使基线对比漏判，dispatch 的 action 也应幂等——`rename` 到同名、`move` 到同父，handler 写回相同 state。可在轮询器**dispatch 前**先比对「目标 == 当前」跳过 no-op（省一次 dispatch + 避免无意义 snapshot）。注意现有 handler 不是天然 no-op 短路（如 `handle_rename_node` 无条件 set，`behavior/mindmap.ex:210-211`），所以 no-op 过滤放轮询器侧更稳。
4. **游标/版本**：Miro mindmap_nodes 无原生 ETag/version 游标（experimental 端点 `miro.ex:14-16`），所以**用「树内容快照」当游标**（基线即游标）。若后续 Miro 给节点加 `modifiedAt`，可升级为按时间戳 diff（更省）。

> 与出站「复用同板」的耦合：现在出站每次建新板（`miro/sync.ex:9-10` v1），**入站轮询必须等出站改成「复用同板 + 增量 diff」之后才有意义**（否则板 id 一直变，轮询不知道盯哪块）。所以落地顺序：**先做出站复用板 + last-pushed 基线（增量 4 下半），再做入站轮询**——两者共享同一份 last-pushed 基线 + ez_id↔miro_id 映射，echo 防护是这份共享状态的自然产物。

---

## 落地步骤（建议给 Allen 的 plan 骨架）

1. **出站先收口（前置）**：`push_tree` 改「复用 board_id（miro.yaml/绑定表）+ 增量 diff（建/改/删节点）」，推完把 `{树快照, ez_id↔miro_id 映射}` 存为 **last-pushed 基线**（共享状态，放哪个进程要定）。`miro/sync.ex:9-10` 已点名这是 v1 TODO。
2. **新增 `EzagentPluginMindmap.Miro.Poller`（GenServer）**，挂 `application.ex` 的 `children/0`；env 开关 `EZAGENT_MINDMAP_MIRO_POLL`（默认关）；`Process.send_after` 定时 `:poll`；429/网络错退避（抄 `ws_client.ex` 5s backoff 与重连思路 `:111、:131`）。
3. **diff + echo 防护**：`get_nodes` 折成树 → diff vs last-pushed 基线 → 过滤 no-op → 得「人的改动」op 列表。
4. **逐 op `Ezagent.Invocation.dispatch`**（`mode: :call`），`target = entity://<ws>/mindmap/<name>?action=mindmap.<act>`，`ctx: %{caller: 板owner_uri, caps: Identity.list_caps_for(板owner)}`（方案 A）；dispatch 前 `SpawnRegistry.ensure_live/1` rehydrate 冷实例（抄 `inbound_dispatcher.ex:228-246`）。
5. **失败处理（P18）**：`{:error, reason}` → log（无 react 渠道，至少 telemetry/Logger.warning），**不推进基线**，下轮重试或交人工。**绝不** silent `:ok`。
6. **成功后**：触发一次出站 push（让 Miro 与树一致）→ 刷新 last-pushed 基线 → 才放下一轮轮询（防自激）。
7. **身份合规自查**：grep 确认**没有**新增 `system://` principal（catalog north star，`system_principal/catalog.ex:150-152`）；caller 必须是真实 entity（板 owner user 或 `admin_uri()`）。
8. **不变式自查**：`grep PubSub.broadcast`（入站零容忍，P14）；diff→dispatch 路径无直接改 Kind state。

---

## 关键文件索引

| 主题 | file:line |
|---|---|
| adapter KIND 轴 push/pull（入站无对应 kind 的依据） | `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex:69-97,107` |
| pull adapter 范例（只读 render，不写回） | `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed_adapter.ex:40-99` |
| pull adapter 注册位置（plugin adapters/0） | `apps/ezagent_plugin_advisor/lib/ezagent_plugin_advisor/application.ex:43-45` |
| feishu 统一入站入口（P14 唯一路径） | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex:57-207,292-303` |
| 入站身份解析 →{caller_uri,caps} | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex:39-80` |
| 冷实例 rehydrate（ensure_live） | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex:228-246` |
| echo origin 标记（feishu 出站 skip，Miro 借不了的对照） | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex:258-261` |
| 常驻 GenServer + 重连/退避范例（WSS 长连） | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex:32-135` |
| mindmap children/0（挂轮询器处） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/application.ex:60-65` |
| mindmap action（add/rename/move/remove，全 :call） | `apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:35-145` |
| mindmap per-node 授权（owner/admin） | `apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:427-437` |
| mindmap durable 持久化（节点树真相源） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/mindmap.ex:34` |
| Miro 客户端 get_nodes/read_creds（轮询数据源） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro.ex:24-76` |
| 出站 push_tree + mapping（last-pushed 基线源） | `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro/sync.ex:43-61` |
| 身份 north star：消除 system://，用 admin entity + inline cap | `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:150-152,236-241,318-324` |
