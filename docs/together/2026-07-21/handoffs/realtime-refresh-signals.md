# Handoff → zyli:实时刷新的两个通用信号(view_changed / caps_changed)

> **Date:** 2026-07-21 · **From:** kanban 线(升悦) · **To:** zyli(world 通用机制)
> **Base:** 独立分支,从 `origin/main` 开——**不 stack 在 kanban PR #1474 上**(理由见 §2)
> **实证底稿:** 全部 file:line 已核对最新 origin/main + feat/kanban-collab-round2

## 0. 一句话

会话里"一个人改了看板/权限,别人的页面不自动刷新"这个体验 bug,根子在 world 的刷新只认 kanban 专属信号。把它换成两个**通用**信号,world 对所有插件用同一套刷新逻辑、零插件字面——这是 world 通用能力,该从 main 独立走,不该被业务 PR 绑住。

## 1. 现象(两个刷新 bug)

1. **对端不自刷**:A、B 同看一块板,A 加卡/删卡后,B 的页面不动,要手动刷新才看到。
2. **批准后不自刷 + 首写偶被拒**:B 申请编辑、板主批准(read→operate 升级)后,B 的界面不知道自己已经能写了,affordance 不更新;甚至"建板后第一次写偶尔被拒一次、重试就好"。

## 2. 根因(X 分析)——为什么不能 stack 在 kanban PR 上

**刷新 bug 1 的根:kanban 自己另起炉灶发专属信号。**
- kanban 写动作成功后播 `{:kanban_changed, board_uri}` 到会话 `:events` topic(`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/world_actions.ex:537-551`,该 topic 同会话成员天然 fan-out,§5.7.6 观察者面,invariant #1 allowlist 已登记)。
- world 侧有一个**kanban 专属 handler** 接它:`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:255-265`,收到后调 `EzagentPluginKanban.WorldData.board_state/2` 重拉整板。
- **这个 handler(:260-262)是 world 里唯一残留的 kanban 字面耦合**——正是 UiSurfaceProvider 去硬编码线(#1472/#1473)要清掉的那类。让"通用刷新能力"去依赖一个本来就要删的硬编码信号,方向是反的。

**为什么不能直接用现成的 `slice_changed`(`apps/ezagent_core/lib/ezagent/slice_change.ex`):** 语义其实对(它的 `event.uri` 就等于 board_uri,知道哪块板变了),但两个工程面不合:
- **订阅模型**:slice_changed 是 per-entity topic(`esr:entity:<uri>:slice_changed`,slice_change.ex:80),WorldLive 只订登录者**自己**的(`world_live.ex:1003`);看板刷新要"同会话所有成员一订全到",靠的是会话 `:events` 的 fan-out。为每块板逐个订/退既重又违背会话观察面设计。
- **消费契约**:slice_changed 的 handler(`world_live.ex:247-248`)只把事件塞进 toast 环,**不重拉数据**;真正的刷新语义(按接收方自己 caps 重渲整板)只在 kanban_changed handler 里。

**刷新 bug 2 的根:caps 变更根本没有信号。** `approve_edit` 走 `Mount.mount_for_person(access: :operate)` 升级后(`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/world_share_actions.ex:248-274`)**无任何广播**;grep `caps_changed/cap_changed/caps_updated` 全仓为空。socket 的 `current_caps` 挂载时定死,只有 dispatch 时 `refreshed_presenter_caps`(`world_live.ex:589-591`)临时 union 一下 live caps,UI 渲染用的 current_caps 要整页重载才更新。

**结论**:这两件是 world/前端的**通用**刷新能力,机制层零 kanban。"需要 kanban 场景来 e2e 验证" ≠ "机制代码依赖 kanban"。把通用能力焊在业务 PR 上,后果是 world 刷新要等 kanban 大 PR 合并才能上线,本末倒置。所以独立从 main 走。

## 3. 提案:两个通用信号(此文档即契约)

### 信号1 —— 视图刷新 `{:view_changed, %{plugin: key, entity_uri: uri}}`
- `key` = `PluginPageRegistry` 的 component key(如 `"kanban"`);`entity_uri` = 变更的数据宿主(如 board_uri)。
- **广播时机**:插件写动作成功后,播到会话 `session_events_topic(current_session_uri)`(沿用 kanban_changed 那条传输,天然全员 fan-out)。
- **world 通用 handler(对所有插件同一套,零字面)**:`PluginPageRegistry.by_key(key)` 取 `page.data_builder` → `data_builder.state_for(entity_uri, ctx)`(registry 已有的统一约定,`world_live.ex:879`)→ push `"world:state"`。**替换掉 `world_live.ex:255-265` 的 kanban 专用子句**。

### 信号2 —— caps 刷新 `{:caps_changed, %URI{} = entity_uri}`
- **现在完全不存在,新增**。
- **广播时机**:任何改变某实体持有 cap 的动作成功后(第一例=approve_edit 升级)。
- **world 通用 handler**:若 `entity_uri == current_entity_uri`,`EntityCaps.load/1` 重载 → re-assign `current_caps` → 重推 affordance state。

## 4. 分工

| 事 | 谁 | 从哪开 |
|---|---|---|
| world 两个通用 handler(view_changed 走 registry 重拉 / caps_changed 重载 socket caps)+ 删 kanban 专用子句 | **zyli** | **origin/main 独立分支**(本 handoff 的 PR) |
| kanban 发信号侧:`broadcast_kanban_changed` 改发 `{:view_changed, %{plugin:"kanban", entity_uri: board_uri}}`;`approve_edit` 成功后补发 `{:caps_changed, grantee}` | 我们(kanban) | 迁移轮(并入 #1472/#1473 去硬编码线) |

**依赖顺序**:先合 zyli 的通用 handler,我们的 kanban 迁移再跟上。两侧信号名/payload 形状以本文档为契约。这样 kanban PR 不再挡 world 通用刷新上线。

## 5. 证据清单

- kanban_changed 广播/handler:`world_actions.ex:537-551`、`world_live.ex:255-265`(唯一 kanban 字面耦合 :260-262)
- slice_changed 不适用:`slice_change.ex:80`(per-entity topic)、`world_live.ex:247-248,1003`(只订自己、只发 toast)
- caps 变更无信号:`world_share_actions.ex:248-274`(approve_edit 无广播)、`world_live.ex:589-591`(current_caps 临时 union)
- registry 统一约定:`world_live.ex:879`(`data_builder.state_for`)、`plugin_page_registry.ex`(by_key/data_builder)
