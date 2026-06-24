# 设计 · `ezagent_plugin_mindmap`（df-prd 增量 1：思维导图双向打通）

> 分支 `feat/df-tech`（基于 e2abc02f）。本文是开发前设计 spec。
> 定位：df-prd 内部工具的第一个技术增量。**纯 plugin（路 A），不碰 core/domain，过仓库全部 PR gate。**
> 所有承重机制已对真实代码核实，引用带 file 路径（相对 worktree 根）。**杜绝想象。**

## 1 · 目标与成功判据

让"思维导图"和 ezagent **双向打通**，**ezagent 是真相源**：
- AI/调用方在 ezagent 里维护一棵节点树（增改移删）。
- 导出成一个 markmap markdown 文件，人在 XMind/markmap 里看、调整、存盘。
- 从（人改过的）文件导入回 ezagent，**文件那侧覆盖**（符合"存的文件覆盖、人也看得到"的使用习惯）。

**成功判据（增量 1 e2e gate）**：spawn 一个 mindmap 会话 → dispatch `add_node` ×3 → `export` 到文件 → 断言 markmap 内容 → 改文件 → `import` → `get_tree` 反映改动。全部 PR gate 绿。

## 2 · 边界（YAGNI，明确不做）

| 留到 | 不在增量 1 |
|---|---|
| 增量 2 | 节点 owner/认领/状态机、per-node 授权（CapBAC grant） |
| 增量 3 | external_mirror 实时推飞书/网页出口、入站 webhook |
| 增量 4 | cc agent 操作节点、群聊驱动 |
| 后续 | `.xmind` 二进制解析（本增量用 markdown/opml，XMind 能导入导出）、冲突合并（本增量=文件覆盖） |

## 3 · 架构与组件（纯 plugin，路 A）

新 OTP app `apps/ezagent_plugin_mindmap`（OTP app atom `:ezagent_plugin_mindmap`，模块前缀 `EzagentPluginMindmap`），`use Ezagent.Plugin` + `start/2 = Ezagent.Plugin.boot(__MODULE__)`。声明回调（框架代为注册，作者不碰 registry）：

| 组件 | 模块 | 职责 | 先例/契约 |
|---|---|---|---|
| 模板类 | `EzagentPluginMindmap.Template.MindmapSession` | `@behaviour Ezagent.Kind.Template`；`template_name "session.mindmap"`、`validate/1`、`instantiate/3` | 照抄 `apps/ezagent_plugin_advisor/lib/ezagent_plugin_advisor/template/advisor_session.ex`（`session.advisor`）；契约 `apps/ezagent_core/lib/ezagent/kind/template.ex:60-62` |
| 行为 | `Ezagent.Behavior.Mindmap` | 节点动作处理者，`use Ezagent.Behavior` + `action` 宏 + `handle_<action>/2` | 契约 `.claude/skills/ezagent-developer/references/new-contract.md` |
| 格式纯函数 | `EzagentPluginMindmap.Markmap` | `render/1`(树→markdown)、`parse/1`(markdown→树) | 无副作用、可往返测试 |
| 导出 CLI | `Mix.Tasks.Ezagent.Mindmap.Export` | `mix ezagent.mindmap.export <uri> <file>` → dispatch `export_markmap` → 写文件 | 走 `Ezagent.Invocation.dispatch/1`（P14，`apps/ezagent_core/lib/ezagent/invocation.ex:88`） |
| 导入 CLI | `Mix.Tasks.Ezagent.Mindmap.Import` | `mix ezagent.mindmap.import <uri> <file>` → 读文件 → dispatch `import_markmap` | 同上 |

**思维导图实例寻址** = `session://<ws>/mindmap/<名字>`（现成 scheme，`apps/ezagent_core/lib/ezagent/uri.ex:449` `URI.session/3`；template 段 = `mindmap`）。不新建 scheme、不新建 Kind 类型——复用 Session 当容器，跟 advisor 同构。

## 4 · 节点状态模型

节点树存在会话 state，**`{:set, key, value}` effect 写、`ctx[:read]` reader 读**（插件作者永不碰 slice/snapshot，`apps/ezagent_core/lib/ezagent/behavior/effects.ex:9,167`）：

```
:nodes    => %{node_id => %{parent_id: id | nil, title: String.t(), order: integer()}}
:root_id  => node_id
:seq      => integer()        # 单调计数器，生成确定性 node_id（禁用 Math.random）
```

- `node_id` = `"n" <> Integer.to_string(seq)`，每次 `add_node` 递增 `:seq`。确定性 → 可复现、可测。
- `order` 决定同一父节点下的兄弟顺序（markmap 渲染顺序）。

## 5 · 节点动作（`Ezagent.Behavior.Mindmap`）

| action | args | 返回 / effect | caps（增量 1） |
|---|---|---|---|
| `add_node` | `%{parent_id, title}` | `{:ok, %{id}, [{:set,:nodes,_},{:set,:seq,_}]}`；`parent_id=nil` 建根（连带 `{:set,:root_id,_}`） | admin cap |
| `rename_node` | `%{id, title}` | `{:ok, %{}, [{:set,:nodes,_}]}` | admin cap |
| `move_node` | `%{id, new_parent_id}` | `{:ok, %{}, [{:set,:nodes,_}]}`；禁环（不能把节点移到自己子树下） | admin cap |
| `remove_node` | `%{id}` | `{:ok, %{}, [{:set,:nodes,_}]}`；级联删子树 | admin cap |
| `get_tree` | `%{}` | `{:ok, %{tree}, []}`（经 `ctx[:read]` 读，无 effect） | admin cap |
| `export_markmap` | `%{}` | `{:ok, %{markdown}, []}`（读树 → `Markmap.render`） | admin cap |
| `import_markmap` | `%{markdown}` | `{:ok, %{count}, [{:set,:nodes,_},{:set,:root_id,_},{:set,:seq,_}]}`（`Markmap.parse` → 覆盖） | admin cap |

> 增量 1 统一用 admin cap（对齐 echo 的做法）；增量 2 才把 caps 换成 per-node 授权（CapBAC grant）。

## 6 · markmap 格式（人机交换面）

markdown 标题/缩进层级 = 树深度：

```markdown
# 根标题
## 子节点1
### 孙节点
## 子节点2
```

- `render/1`：深度优先遍历，深度 d → `(d+1)` 个 `#` 或缩进 bullet（第一版用标题层级，最稳）。
- `parse/1`：按标题层级重建父子关系；`seq` 重新编号。
- XMind / markmap 都能打开此 `.md`；人改完存盘即可。

## 7 · 双向数据流

```
建/改节点  caller ──dispatch(session://ws/mindmap/x?action=mindmap.add_node)──► handle_add_node ──{:set,:nodes}──► 落库
导出       mix …export <uri> <f.md> ──dispatch export_markmap(:call)──► 返回 markdown ──► 写 f.md
人         在 XMind/markmap 打开 f.md、改、存盘
导入       mix …import <uri> <f.md> ──读 f.md──► dispatch import_markmap ──{:set,:nodes 覆盖}──► 落库
```

## 8 · 错误处理（ezagent "谁会知道" 纪律）

- `add_node`/`move_node` 的 `parent_id` 不存在 → `{:error, :parent_not_found}`（`:call` 同步返回，caller 立即知道）。
- `move_node` 成环 → `{:error, :would_create_cycle}`。
- `import_markmap` 解析失败/空树 → `{:error, {:parse_failed, line}}`，**覆盖前校验，绝不静默清空已有树**。
- CLI 拿到 `{:error, _}` → 打印 + 非零退出码，不静默成功（不返回 `:ok` 却啥也没干）。
- 所有 dispatch 用 `:call` 模式（同步、要结果），失败即 `{:error,_}` 返回，不依赖 DLQ。

## 9 · 测试策略（TDD，过全部 PR gate）

| 层 | 测什么 |
|---|---|
| 单元 · Markmap | `parse(render(tree)) == tree` 往返；多层/中文/空树/畸形输入 |
| 单元 · Behavior | 每个 `handle_*` 产出的 `{:set}` 正确；`get_tree`/`export` 读回；错误分支（parent 不存在、成环、解析失败） |
| 编译 gate | `:ezagent_plugin_check` 绿（uses_behaviour / template_classes / no_direct_registry_calls / required_caps callbacks，`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex`） |
| e2e gate（增量 1 验收） | spawn mindmap 会话 → `add_node`×3 → `export` 到 /tmp → 断言 markmap → 改文件 → `import` → `get_tree` 反映改动 |
| 全 PR gate | `mix compile --force` → `mix ezagent.arch.scan` → `mix ezagent.check_invariants && .lifecycle` → `mix ezagent.doc.scan` → `mix test`（CONTRIBUTING.md） |

## 10 · 合规自查（不越界）

- 纯 plugin，**不改 core/domain 任何文件**；只新增 `apps/ezagent_plugin_mindmap/`。
- 跨 Kind 只走 `Invocation.dispatch`（P14），无 `PubSub.broadcast` 到入站 topic。
- 不手写 `def init/1`（Kind 宏负责）。
- 插件代码不 import `EventLog`/`SnapshotStore`/`StateRebuilder`/`Router internals`/`SagaRunner.execute/2`（SPEC §11 grep gate）。
- node_id 确定性生成（无 `Math.random`/时间依赖），测试可复现。
- 不发明新架构 Decision——复用 Session + 插件契约的 template_class 机制（advisor 先例），不动 ARCHITECTURE.md。

## 11 · 未决/待开发中确认（写实施计划时核死，不臆想）

- `instantiate/3` 如何把 `Ezagent.Behavior.Mindmap` 挂到会话上（对照 advisor `instantiate/3` 实现 + session 域 behaviors 组合）。
- `action` 宏 + `caps` 的确切语法（对照 `new-contract.md` + echo/curl 现有 Behavior）。
- `ctx[:read]` reader 读 slice 的确切 API（对照现有 Behavior 用法）。
