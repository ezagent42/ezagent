# Handoff: UiSurfaceProvider 扩展——plugin UI 四面自声明(协议设计)

> **Date:** 2026-07-19 · **From:** kanban-progress-board 线 · **To:** Allen(协议设计)/ zyli(world 实施建议)
> **Tracking:** D6 债②残余(#1394 永久线)的实施提案 · **Base:** `origin/main` @ `c66971977`
> **Status:** proposed(D6 此前拍「缓」并备案边界,见 `2026-07-18/handoffs/D6-plugin-ui-registry-deferred.md`;本 handoff 是把「缓」变「排期」的具体化——盘点已做完,只差协议拍板)
> **实证底稿:** `docs/notes/2026-07-19-mount-and-selfdeclare.md` §Q2(全部 file:line)

## 0. Mission

给「带 UI 的 plugin」一个**一处声明**的自声明协议:pages / dispatch 白名单 / 数据 reader /
前端 renderer 四面收进 plugin 侧,world 只做壳。载体 = 扩展既有
`Ezagent.World.UiSurfaceProvider`(duck-typed 读端范式已在,零实现者),不发明新机制。

## 1. 现象

**每加一个带 UI 的 plugin(或给现有 plugin 加一个动作/页面),都要改 world 四处**:

1. `plugin_page_registry.ex:32-45` @pages 手写条目(route/nav/data_builder);
2. `plugin_page_registry.ex:30` `@kanban_actions` 动作字面白名单——⑲(delete_board)、
   ㊲(download_artifact)两条注释就是「plugin 加动作 = world 发版」的历史实证;
3. world assets:`main.tsx:1042+` PLUGIN_PAGE_RENDERERS 手写 map + `main.tsx:39`
   FULL_BLEED_FAMILIES + `Conversation.tsx:953` mode 硬 switch + 组件本体
   (`Kanban.tsx`/`KanbanCanvas.tsx`)物理住 world、Vite 静态打包;
4. `conversation_data.ex:23,191` render-mode 硬点名(`@native_react_ids` +
   `id in [:page, :hello_page] -> "external"`)。

hello 走了另一条路(view 自注册 + iframe external)也没躲干净:`isHelloSession`/
`HelloPagePreview`(`Conversation.tsx:307,1168,1886`)+ `ezagent_web/assets/js/app.js:33`
跨 app 相对 import 注册 phx-hook——**两个样板 plugin,两套残端**。

## 2. 根因

五个注册面里只有 session-view tab 一面有自声明协议(`SessionViewRegistry`,plugin
Application 自注册,✓);其余四面(pages / dispatch 白名单 / 数据 reader / 前端 renderer)
**没有任何自声明协议**,只能以编译期常量/手写 map 形式住在 world。
`plugin_page_registry.ex:22` 自己就写着:「编译期常量起步;插件自声明协议(UiSurfaceProvider
扩展)留给 follow-up」——follow-up 一直没排。而 `UiSurfaceProvider`(`ui_surface_provider.ex`)
目前只定义 nav/session_tabs 两个 callback 且**全仓零实现者**:协议壳在、面不全、没人住。

## 3. 方案方向(供 grill,不锁死)

扩展 `UiSurfaceProvider` 为四面自声明,读端沿用它已有的范式(PluginRegistry 枚举 +
`function_exported?` 探测 + fail-closed 逐条 shape 校验):

- **pages 面**:plugin 声明 `%{key, route, detail_route, nav, data_builder,
  renderer_families}`——`PluginPageRegistry.pages/0` 从编译期常量改为「枚举 installed
  plugins 的声明 ∪ 校验」,机制模块保留、数据源反转;
- **dispatch 面**:action 白名单 + actions_module 随 pages 声明走(fail-closed 语义原样:
  未声明动作一律拒,P22 姿态不变;白名单真相源从 world 字面移到 plugin 声明);
- **数据 reader 面**:data_builder 即声明的一部分(现状已是 module 引用,只是行住错了地方);
- **前端 renderer 面(唯一有真取舍的面)**:**一步到位做原生组件分发**——plugin 自带
  JS bundle + 运行时注册(module federation / 独立 entry + window 注册表),
  Kanban.tsx 搬回 kanban plugin;iframe/json-render 保留为协议里的 `:external`
  render-mode 兜底档,但**不做「iframe 先行、bundle 后置」的过渡期**。理由:
  hello 原作者已离开开发序列,iframe 过渡态落地后没有 owner 维护,只会变成
  第三套残端;两段式意味着 kanban/hello 各迁一次、共迁两轮。一步到位后
  **kanban/hello 一轮统一迁移**,过渡成本归零。

conversation 三处特判(`world_live.ex:105/346/773`)是同根不同枝:ConversationView 已注册,
差的是「session 生命周期钩子 + 原生 dispatch 面」的声明位——建议纳入协议 grill 范围但允许
单独排期。

## 4. 受益

- **kanban 残端消失**:D6 备案的例外清单(@kanban_actions 字面、@pages 条目、PLUGIN_PAGE_RENDERERS
  条目)全部变成 plugin 侧声明;加动作/加页面不再改 world;
- **hello 归一**:3 处 world/web 硬编码(render-mode 点名、HelloPagePreview 特判、app.js
  跨 app hook import)随统一迁移一轮清掉(原作者已离开,残端没有别的清理时机);
- **第三个 plugin 零边际**:mindmap/dealscout 等后来者按协议声明即得全部 UI 面——这是
  socialware「装了就能用」承诺在 UI 面的补齐;
- 与 mount 线对齐:数据面(mount)已通用化,UI 面是 D6 债②最后一块。

## 5. 分工建议

| 事 | 谁 | 说明 |
|---|---|---|
| 协议设计(四面声明 shape + fail-closed 校验口径 + bundle 分发机制选型 + conversation 钩子是否入协议) | **Allen** | grill 后进 GLOSSARY Decision Log;是否并入 #1394 Entity 双向-caps 一起排,Allen 定 |
| world 读端实施(PluginPageRegistry 数据源反转 + bundle 运行时装载 + 特判溶解) | **zyli** | world/前端归属线(#1450 G5 前端同域);一步到位,不做 iframe 过渡期 |
| kanban/hello 统一迁移到新声明 + e2e 证据 | 我们(kanban 线) | 一轮迁完两个样板 plugin,迁移即回归验证,顺带销 D6 例外清单 + hello 遗留残端 |

## 6. Required reading

`docs/notes/2026-07-19-mount-and-selfdeclare.md` §Q2(盘点实证)·
`docs/together/2026-07-18/handoffs/D6-plugin-ui-registry-deferred.md`(缓的边界与例外清单)·
`docs/together/2026-07-16/handoffs/allen-decisions.md` §D6(决策背景)·
`apps/ezagent_plugin_world/lib/ezagent/world/ui_surface_provider.ex`(既有协议壳)·
`apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex:22`(follow-up 自注)。
