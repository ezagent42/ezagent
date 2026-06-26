# Kanban 全自动闭环：还缺什么工具 + 开发任务清单

> 写作日期：2026-06-26 ｜ 基线分支：`feat/kanban-agent-e2e`（worktree `kanban-agent-e2e`）
> 方法：已加载 skill-1（project-discussion-esr-ng）核实；下面每条论断都带 `文件:行号` 实证，是逐行读当前代码得来的，不是凭记忆。
> 读者：新人也能照着干——每条任务都写了"动哪个文件、为什么、怎么验"。

---

## 0. 先把"全自动闭环"这个词定义清楚

我们想要的理想链路（一个产品需求从提出到落地，全程不需要人在中间手动点按钮）：

```
人在 chat 里说一句需求
  → 看板 agent（kanban-manager）自动把需求拆成节点树
  → 某个会思考的 agent 认领节点、写代码、开 PR
  → PR 号自动登记回对应节点
  → CI/PR 合并后，节点自动标记 done
  → 全程 Miro / GitHub 双向同步，人只在 chat 里看进度
```

**核查结论：这条链路目前是"半自动"，中间有 4 个人工断点 + 2 个根本没接的能力。**
下面先讲现状（哪些已经通了），再按优先级列要补的工具和任务。

---

## 1. 现状：已经通了的部分（不用重做，避免新人重复造轮子）

| 能力 | 实证 | 状态 |
|---|---|---|
| 看板 = 一个 agent（role `kanban-manager` × flavor `native`） | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:64`（`roles/0`）、`:76`（recipe） | ✅ 合规 |
| 24 个看板动作经 `entity://<ws>/agent/<id>?action=kanban.<x>` dispatch | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（`action/3` 声明）、`required_caps/0` 列全 24 个 | ✅ |
| GitHub 出站：建 issue / post 评论 / 读 PR / 推 commit status（硬 CI 门） | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex`（`create_issue`/`post_comment`/`get_pull`/`create_commit_status`） | ✅ 出站可用 |
| Miro 双向同步（含人工新增的非破坏性入站回灌） | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex:7`（入站检测 + `dispatch add_node`）、`:50`（一键推/绑） | ✅ |
| 接力机制骨架：动作完成后向绑定会话发一条 `[kanban:<event>]` 公告 | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:702`（`@relay_actions`）、`:705`（`post_handle`）、`:730`（`relay_text`） | ⚠️ 骨架在，触发链没接全（见 §2.3） |
| `sync_prs`：轮询已登记 PR，merged/closed → 节点 set done | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:206` 动作声明、`connectors.ex:193` 实现 | ⚠️ 动作在，但没人定时触发它（见 §2.1） |

**关键事实**：看板 agent 用的是 `native` flavor——一个"无引擎的通用宿主"（skill-1 模块索引：native = "generic 无引擎宿主"）。
意思是**看板 agent 自己不会思考**，它只是一个被动的数据容器（`application.ex:71` 注释明写 `passive: true`：不可被 @、不收 chat、只在直接 `kanban.<action>` dispatch 上动作）。
所以"自动拆需求""自动写代码"必须靠**另一个会思考的 agent**（cc / cc-headless）接进来——这正是下面最大的缺口。

---

## 2. 四个人工断点（"半自动"的真相）

### 2.1 断点一：`sync_prs` 没有定时器，PR 合并后节点不会自己变 done

- `sync_prs`（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex:193`）是**拉取式**：调一次，去 GitHub 查一轮已登记 PR 的状态，merged/closed 的节点 set done。
- 但**没有任何东西周期性调它**。对比 Miro：Miro 有自己的轮询进程 `MiroSync`，用 `Process.send_after(:tick)` 自己定时跑（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex` 的 tick 循环）。GitHub 这边**没有对称的轮询器**——`github.ex:9` 注释直说"纯出站……无 inbound webhook"。
- 后果：PR 合并了，除非有人手动再点一次 `sync_prs`，节点永远停在 in-progress。**这是闭环最后一公里的人工断点。**

### 2.2 断点二：`register_pr` 是人工动作，PR 和节点的关联要手填

- `register_pr`（`connectors.ex:116`）签名是 `%{id: 节点id, pr: PR号}`——**得有人/有 agent 明确告诉系统"这个 PR 对应这个节点"**。
- 系统没有任何机制能自动建立这个关联（比如从 PR 标题/分支名解析出节点 id）。`github.ex` 全是出站，**没有读"仓库里新开了哪些 PR"再反查节点的能力**。
- 后果：agent 开完 PR 后，必须额外调一次 `register_pr` 把 PR 号塞回去，否则后续 `sync_prs`、`push_pr` 全都因为 `:no_pr_registered` 失败（`connectors.ex:94`）。

### 2.3 断点三：接力"公告"发了，但没人配路由规则把它接到下一个 agent

- 看板做完 `claim_node`/`set_status`/`register_pr` 后，`post_handle`（`kanban.ex:705`）会向绑定会话发一条文本：`[kanban:claimed] by <用户>`（`kanban.ex:730` 的 `relay_text`）。
- 这条文本**只是个触发器**，靠的是路由规则按 `[kanban:<event>]` 字样匹配、触发对应 agent（`kanban.ex:752` 注释明写"路由规则按 [kanban:<event>] 匹配触发对应 agent"）。
- **但全代码库里没有任何地方自动创建这些路由规则**——实证：`grep -rn "kanban:" apps/ --include=*.ex` 除了 Behavior 自己和 world slot 注册，**没有任何 `add_routing` / RoutingRegistry 写入 `[kanban:*]` 规则的代码**。
- 还有前置依赖：得先 `bind_session`（`kanban.ex:185` 区附近的动作声明）把看板绑到一个会话，公告才有地方发（`board_session/0` 取不到就 `:cont` 静默跳过，`kanban.ex:709`）。
- 后果：即使你绑了会话，公告发出去了，**没人配规则就没有 agent 被触发**。接力链是"骨架接好了、神经没接上"。

### 2.4 断点四：需求拆解（goal → 节点树）没有自动化入口

- 加节点全靠手动 `add_node`，或 `import_markmap` 一次性导入一棵已经画好的树。
- **没有"给一句话需求，自动拆成节点树"的动作**——实证：`grep -rni "decompose|auto_derive|拆解|派生" apps/ezagent_plugin_kanban` 在看板插件里**零命中**（`auto_derive` 那一堆命中全在 world 的 credential cascade，跟看板拆需求无关）。
- 后果：闭环的"起点"也是人工的。

---

## 3. 两个根本没接的能力（不是断点，是整块缺）

### 3.1 缺：会思考的"工人 agent"没有和看板接线

看板 agent 是 `native`（不思考）。要真正"自动认领、写代码、开 PR"，需要一个 cc / cc-headless agent：
- 订阅绑定会话里的 `[kanban:*]` 公告；
- 收到后调 `get_tree` 读看板真相源（`kanban.ex` 的 `get_tree` 动作），挑一个未认领节点；
- 调 `claim_node` → 干活 → `sync_github`/开 PR → `register_pr`。

**现状：这个 agent 不存在、也没有模板/role 把它装出来。** 这是从"半自动"到"全自动"最大的一块。

### 3.2 缺：`/plugins/kanban` 在本分支没有导航入口（config_surface 未声明）

- `application.ex` 末尾（本分支文件尾部那段大注释）明写：config_surface/0 **故意没在本后端 PR 里声明**，留到 K4 world-rewire PR 才补，"Re-add config_surface/0 in K4"。默认值 → `nil`。
- world 的 `/plugins` 列表页只会给有 `config_surface/0` 的插件渲染可点链接（架构调查实证：`workspace_plugin_data.ex:269` 读 `config_surface()`，nil → 不可点）。
- 后果：在 `/plugins` 页面**点不进看板**，只能手敲 URL。新人第一眼会以为"看板没接上"。

> 注：架构调查里还提到列表页 `KanbanList`（`Kanban.tsx:70`）是空壳、零看板时死锁——那是 world 前端 PR（K4）的活，属于"UI 可用性"而非"自动闭环"，本文聚焦闭环，K4 前端工作单独排。

---

## 4. 开发任务清单（按优先级）

> 三层边界铁律（来自 skill-1 + CLAUDE.md P14/P22）：连接器逻辑只能在 kanban **插件**层（`Behavior.Kanban` + `Connectors` + 自有进程），world 永远是纯 dispatcher，**core 不碰**。跨 Kind 一律走 `Invocation.dispatch`。改前先 load `ezagent-developer` skill。

### P0 — 打通"工人 agent ↔ 看板"接力（闭环的心脏，缺它一切免谈）

**任务 P0-1：定义并装配一个"工人 agent" + 自动建路由规则**
- 动哪：kanban **插件**层新增（或在 `create_kanban` 路径里）——给绑定会话自动注册 `[kanban:claimed]` / `[kanban:status]` 等路由规则，指向一个 cc-headless flavor 的工人 agent。
- 为什么：§2.3 + §3.1，公告骨架已在（`kanban.ex:705/730`），只差"规则 + 收公告的 agent"。
- 怎么验：bind_session 后 `claim_node`，工人 agent 真的被触发并 `get_tree`（看 telemetry / 会话消息流）。
- 风险点：路由规则写入要走正规 RoutingRegistry 接口，别 `PubSub.broadcast` 到 inbound（P14 红线）。**这是 core 边界附近的活，动手前找 Allen 确认设计**（skill-1：P0=core 工作先跟 lead 确认）。

**任务 P0-2：让 `bind_session` 在建看板时自动发生（或给 UI 一个明显入口）**
- 动哪：`KanbanActions.create_kanban`（`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:296`）建完看板后顺手 bind，或在 world 前端给"绑会话"按钮。
- 为什么：§2.3 前置依赖，不绑会话接力链整条断在起点。

### P1 — GitHub 入站，补上 PR 自动登记 + 自动 done（闭环最后一公里）

**任务 P1-1：给 GitHub 加一个对称的轮询器（仿 MiroSync）**
- 动哪：kanban **插件**层新建 `EzagentPluginKanban.GithubSync`（GenServer，仿 `miro_sync.ex` 的 `Process.send_after(:tick)` 自轮询），监督树挂在 `application.ex:101` 那个 `children/0` 里（现在只有 MiroSync 的 Registry + DynamicSupervisor）。
- 干两件事：① 定时 dispatch `sync_prs`（解决 §2.1 PR 合并后不自动 done）；② 拉取仓库新开的 PR，按分支名/标题约定反查节点，自动 dispatch `register_pr`（解决 §2.2 人工登记断点）。
- 为什么：`github.ex:9` 明写"无 inbound webhook"，`sync_prs` 没定时器（§2.1）。
- 怎么验：开一个 PR、合并它，节点在一个 tick 周期内自动登记 + 自动 done，无人工。
- 边界：dispatch 身份用系统 admin（对齐 MiroSync `miro_sync.ex:183` 的先例），全程 `Invocation.dispatch`，不复用 external_mirror 域（它绑 session、kanban 绑 agent，套不上——见 mirror-vs-plugin 调查）。

**任务 P1-2（P1-1 的更优替代/增强）：GitHub webhook 真入站**
- 动哪：需要一个 web 入站端点（`apps/ezagent_web` 或 kanban 插件自带 Plug），收 GitHub `pull_request` / `status` webhook → 走 `Ezagent.Router.dispatch` 转成 `register_pr`/`sync_prs`。
- 为什么：轮询有延迟 + 费 API 配额；webhook 是事件驱动、即时。
- 注意：入站要做 `idempotency_key`（webhook 会重试，CLAUDE.md "重复 inbound" 条款）+ 签名校验。**这是新入站路径，属于架构面，先找 Allen。**
- 取舍：P1-1（轮询）实现快、能先跑通闭环；P1-2（webhook）是正解但工程量大。建议先 P1-1 验证闭环，再 P1-2 升级。

### P2 — 需求自动拆解（闭环的起点自动化）

**任务 P2-1：加一个 `derive_tree`（或让工人 agent 干）动作**
- 动哪：两条路——① kanban 插件加一个动作，内部 dispatch 给一个会思考的 agent 让它产出 markmap 再 `import_markmap`；② 不加新动作，纯靠 P0 的工人 agent 收到"需求"公告后自己 `add_node`。推荐 ②，少加表面积。
- 为什么：§2.4，目前只有手动 `add_node` / `import_markmap`。
- 怎么验：chat 里发一句需求 → 看板自动长出节点树。

### P3 — 补 world 入口（让人能看见，不影响自动闭环但影响可用性/演示）

**任务 P3-1：在 K4 world-rewire 落地时补 `config_surface/0`**
- 动哪：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` 末尾，按注释指引声明 `def config_surface, do: %{kind: :route, path: "/plugins/kanban", label: "看板"}`。
- 为什么：§3.2，本分支故意没声明，`/plugins` 点不进去。
- 前置：必须等 world 端 handler + React（`Kanban.tsx` / `kanban_data.ex` / `kanban_actions.ex`）都在，否则点进去 404（注释明确警告）。本分支看 world 侧是否已具备，再决定是否能立即补。
- 怎么验：`/plugins` 页面出现可点的"看板"链接。

---

## 5. 一句话总结给 Allen / lead

骨架基本齐了（看板=agent、24 动作、GitHub 出站、Miro 双向、接力公告、CI 硬门都合规可用），**但闭环靠 4 个人工断点 + 2 块没接的能力撑着**：
最该先做的是 **P0（工人 agent 接线 + 自动路由规则）** 和 **P1-1（GitHub 轮询器补 PR 自动登记/自动 done）**——这两块做完，"chat 一句话 → 自动拆 → 自动写 → 自动 done"的主干就能端到端跑通；P1-2（webhook）、P2（自动拆解动作化）、P3（导航入口）是增强。
**P0 和 P1-2 触碰 core/入站路径，按 grill 文化先跟 Allen 确认设计再动手。**
