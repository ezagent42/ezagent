# Return: T2 Agent Console completeness

> 日期：2026-07-01
> 提交人：fatnine
> 分支：`fix/agent-console-completeness-0630`
> 基线：`origin/main` (`d8ffd6c0`)

## 一页结论

这轮 T2 从“功能完整性”角度看，已经基本收口：

- F1-F6 已有明确修复和验证证据。
- F7 只剩 `session delete/archive`，它不是清晰小修，而是 session lifecycle 设计问题。
- `mix assets.build` / `phoenix-colocated/ezagent_web` 失败在当前 worktree 已不可复现，不应据此再动 asset pipeline。

但从 PM dogfood 暴露的问题看，Agent Console 还存在一类**更偏设计的问题**：

> 底层能力有一部分已经存在，但 UI 没有把真实使用路径讲清楚。

这意味着：

- 从“功能是否存在”看，很多东西已经有了；
- 但从“用户能不能顺着页面把事情做成”看，信息架构和用户旅程还不够完整。

所以这轮的正确结论不是“功能都没做完”，而是：

- **功能完整性检查已基本完成；**
- **剩余主要问题已从小缺口转移为 UI/UX 设计问题。**

## 这轮确认下来的问题

### 1. 功能层剩余问题

1. `session delete/archive` 仍然缺失。
   - 这是当前最明确、也最需要单列的产品问题。
   - 它牵涉 authority、lifecycle broadcast、cascade cleanup、持久化清理等语义，不适合 drive-by patch。

2. `phoenix-colocated/ezagent_web` 构建失败不是当前 blocker。
   - 在当前 worktree 中，`mix assets.build` 与 `mix esbuild ezagent_web` 都已通过。
   - 因此这轮不建议为了一个不可复现的问题去改 config 或 pipeline。

### 2. 设计层问题

这轮 PM dogfood 暴露出的不是单个按钮缺失，而是以下设计问题：

1. **首页缺少“第一步”引导。**
   - 用户进入后，不容易快速理解“我现在能做什么”“我下一步该点哪里”。

2. **已有能力与可见入口之间存在断裂。**
   - 一些底层已存在的能力，没有被明确组织成可理解的用户路径。

3. **页面过于贴近系统对象，而不够贴近用户任务。**
   - 用户首先关心的是“继续工作”“创建助手”“进入某个协作场景”，而不是先理解底层对象分类。

4. **一级导航和二级导航的职责不够清楚。**
   - 有些页面承担了“主分类”“子过滤”“对象状态”三种不同角色，导致认知负担偏高。

5. **命名偏系统内部术语。**
   - 例如 `Identities`、`Capabilities` 这类命名，对实现者是清楚的，但对产品用户不够直观。

## 新设计要解决什么问题

我们这轮不是重新发明一套全新系统，而是要解决这几个实际问题：

1. **让新用户一进来就知道第一步。**
   - 所以默认 landing page 改成 `Overview`，先回答“我现在有什么”和“我下一步做什么”。

2. **让熟悉系统的人仍然有直达入口。**
   - 所以保留左侧稳定导航，不把所有东西都藏进首页。

3. **把内部模型翻译成产品语言。**
   - 不是改底层模型，而是改页面上的表达方式和导航组织。

4. **把工作流页面和系统配置页面分开。**
   - 这与仓库里已经落地的 `workspace perspective / admin perspective` 一致。

5. **让 Workspace 真正成为一个“工作空间”，不是一张列表。**
   - 工作区要能展开到成员、会话、模板、规则、应用、状态等多个维度。

## 新设计的核心想法

### 1. Overview first，但不牺牲直达入口

新的默认入口不是对象平铺，而是 `Overview`：

- 告诉用户当前有哪些对象和状态；
- 给出推荐下一步；
- 同时保留去 `Sessions / Roster / Workspaces / Plugins / Admin` 的直达路径。

这避免了两个极端：

- 纯对象平铺，导致新用户无从下手；
- 纯 dashboard 首页，导致熟悉用户找不到直达入口。

### 2. `Identities` 改为 `Roster`

我们判断 `Identities` 虽然贴近底层模型，但对产品用户不够直观。

当前更好的产品表达是：

- `Roster`

它更像“当前 workspace 的参与者总表”，里面既包含：

- People
- Agents
- Access

这样更贴近用户心智：“谁/什么在这个工作空间里参与工作”。

### 3. `Capabilities` 改为 `Access`

在产品语境下，用户更关心：

> 谁能做什么？

而不是先接受 `Capabilities` 这个内部术语。

所以在产品层面，我们建议把这类页面表达为：

- `Access`

底层 capability/capbac 语义不变，只是 UI 命名更人类友好。

### 4. Workspace 需要变深

之前的原型里，`Workspace` 还太粗。

这轮我们已经把方向收敛为：

- `Overview`
- `Roster`
- `Sessions`
- `Recipes & Templates`
- `Rules`
- `Apps`
- `Health`

也就是说，Workspace 不应该只是一个列表对象，而应该成为承接团队工作、定义、规则和状态的真实空间。

## 这轮原型做了什么

这轮原型已经不只是结构说明图，而是做成了可点击的 shell 原型，并补了以下关键点：

1. `Overview` 作为默认 landing page。
2. 保留左侧稳定导航。
3. 把 `Identities` 翻译为 `Roster`。
4. 把 `Capabilities` 翻译为 `Access`。
5. 给 `Roster` 增加可见二级导航。
6. 把 `Workspace` 从粗列表页扩展为多页结构。
7. 给 `Admin` 保留一级入口，并补出可见二级导航。

相关设计文档：

- [2026-07-01-agent-console-ia-design.md](file:///Users/daiming/workspace/ezagent42/ezagent/.claude/worktrees/fix-agent-console-completeness-0630/docs/superpowers/specs/2026-07-01-agent-console-ia-design.md)

## 这轮发现并修掉的明显设计问题

今晚在原型 review 过程中，我们还确认并修掉了一个明显问题：

1. **`Roster / Agents` 页二级导航与表格工具栏存在重复。**
   - 原型里 `subnav` 已经承担 `All / People / Agents / Access / New Agent` 的主切换。
   - 表格上方又重复了一排 `All / Users / Agents ...`，并且命名还不一致。
   - 这会让用户困惑：到底上面是页面切换，还是下面是页面切换？
   - 已调整方向：二级导航负责主切换；表格工具栏只保留搜索、状态和 flavor 这类补充过滤。

这个问题说明当前原型还在迭代中，但也说明它已经足够帮助我们发现真实设计问题，而不是停留在抽象层。

## Demo 是否已经足够说明想法

我的判断是：

**是，已经足够说明这轮设计意图，而且目前没有阻止今晚收尾的明显逻辑错误。**

原因：

1. `Overview + 左栏直达` 的关系已经讲清楚了。
2. `Roster` 替代 `Identities` 的方向已经能被看到和讨论。
3. `Workspace` 细分页方向已经从“抽象想法”变成了可点击的页面。
4. `Admin` 作为一等入口、且有可见子导航，这个想法也已经被原型表达出来。
5. 当前剩余问题更多是命名和细节优化，而不是“方向还没看明白”。

所以我建议：

- 今晚可以收尾到“领导可 review”的状态；
- 不必再继续打磨高保真细节；
- 等领导确认大方向后，再进入下一轮细化。

## 小修情况

### 代码 / 配置小修

- 无。

### 文档 / 原型小修

- 已新增 IA 设计文档。
- 已调整原型命名：
  - `Identities` → `Roster`
  - `Capabilities` → `Access`
- 已补出更细的 Workspace 页面。
- 已修正 `Roster / Agents` 页中二级导航与工具栏重复的问题。

## 缺失清单摘要

| ID | 严重度 | 现状 | 说明 |
| --- | --- | --- | --- |
| F1 agent flavor filter missing on `/identities/agents` | 低-中 | 已修复 | 已有测试与 UI 证据。 |
| F2 deleted/nonexistent agent detail renders hollow shell | 低-中 | 已修复 | 已有 not-found 状态与测试。 |
| F3 new session default used invalid `advisor` and failures were silent | 高 | 已修复 | 已有 dispatch/UI/LiveView 证据。 |
| F4 deleting bound agent from detail gave no UI feedback | 中高 | 已修复 | 已有 action error 反馈和测试。 |
| F5 Entity Caps `instance` column dumped raw `%URI{}` | 低 | 已修复 | 已有数据映射修复与测试。 |
| F6 py flavor requires script but UI allowed raw backend error | 中 | 已修复 | 已有表单约束和友好错误。 |
| F7 no remove-member/delete-session UI made bound agents hard to delete | 中高 | 部分修复 | remove participant 已有；session delete/archive 仍是设计问题。 |

## 设计问题单列

1. `session delete/archive`
   - 仍是当前最主要的设计缺口。

2. 首页需要承担“第一步引导”
   - 当前系统已有对象页，但缺少默认 landing 的产品解释层。

3. 页面命名要从内部术语转向产品语言
   - 已提出 `Roster / Access` 方向。

4. Workspace 需要从列表页升级为多层空间视图
   - 已提出 `Overview / Roster / Sessions / Recipes & Templates / Rules / Apps / Health` 方向。

## Tooling follow-up

1. `phoenix-colocated/ezagent_web` resolution failure 当前不可复现。
   - 当前 `mix assets.build` 通过。
   - 当前 `mix esbuild ezagent_web` 通过。
   - 当前 `_build/dev/phoenix-colocated/ezagent_web/index.js` 存在。
   - 结论：这轮不做 config/pipeline 修补。

2. Tailwind standalone 下载超时是环境 bootstrap 备注，不是当前 completeness blocker。

## 验证结果

通过的关键命令：

- `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs`
- `mix test apps/ezagent_plugin_world/test/ezagent/world/conversation_actions_test.exs`
- `mix test apps/ezagent_plugin_world/test/ezagent/world/agent_detail_config_fields_test.exs`
- `mix test apps/ezagent_plugin_world/test/ezagent/world/agent_delete_dispatch_test.exs`
- `mix test apps/ezagent_plugin_world/test/ezagent/world/agent_detail_live_status_test.exs`
- `mix test apps/ezagent_domain_session/test/ezagent/behavior/remove_participant_test.exs apps/ezagent_domain_session/test/integration/remove_participant_convergence_test.exs`
- `cd apps/ezagent_plugin_world/assets && npm run check:mounts`
- `mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:500`
- `env http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897 NO_PROXY=127.0.0.1,localhost mix assets.build`
- `mix esbuild ezagent_web`

结果：

- 上述验证均通过。
- `agent_delete_dispatch_test` 有一次非阻塞 DBConnection 日志噪声，但测试本身通过。

## 今晚建议动作

建议今晚按以下方式收尾：

1. 以“功能完整性已基本收口，剩余问题转为设计问题”为主结论。
2. 把这份 return 和 IA 设计文档一起交给领导 review。
3. 不再继续做更深一轮页面细节打磨。
4. 如无新的 review blocker，推送本分支并创建 PR。

这样做的好处是：

- 方向已经足够清楚；
- 原型已经足够说明问题和方案；
- 还没有进入过度设计或高保真细节泥潭。
