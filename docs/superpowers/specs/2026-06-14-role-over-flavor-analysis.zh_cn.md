# Role-over-Flavor —— 现状分析（任务 #54）

> **这是分析，不是设计。** 它梳理 agent「flavor」今天怎么工作、role 和 flavor 在哪里
> 纠缠、并框出待定的设计问题 —— 是 brainstorm 的铺垫，不是已定方案。代码引用是时间点快照。
>
> 双语镜像：[`2026-06-14-role-over-flavor-analysis.md`](./2026-06-14-role-over-flavor-analysis.md)。

## 1. 今天「flavor」是什么

flavor 是 `Ezagent.AgentFlavorRegistry`
（`apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`）里注册的一个 bundle，由每个
agent 插件的 `agent_flavors/0` 声明、经 `Ezagent.Plugin.boot/1` 注册：

```elixir
%{
  flavor: "cc" | "codex" | "curl" | …,   # entity 名前缀
  kind: module(),                         # Entity.Agent（共享）或专用 Kind
  template_class: module(),               # spawn/template 接线
  instance_behaviors: (-> [module()]) | nil,  # 折叠到共享 Kind 时的 behavior 子集
  bridge_adapter: module()                # 传输 adapter
}
```

三个 flavor 的差异几乎全在**agent 如何接到它的 runtime**（`bridge_adapter` + kind）：

| flavor | runtime / 传输（真正的差异） |
|--------|------------------------------|
| `cc`    | PTY 里跑 `claude` CLI + MCP bridge 子进程（`EzagentPluginCc.BridgeAdapter`） |
| `codex` | `codex` 二进制经 UDS WebSocket bridge + thread 连续性（`EzagentPluginCodex.BridgeAdapter`） |
| `curl`  | 进程内 HTTP 打 LLM 端点，无 bridge 子进程（`EzagentPluginCurlAgent.BridgeAdapter`） |

这里的插件隔离做得好：加一个 flavor 只动它自己的插件目录（resolver 查注册表，不是硬编码 map）。
**flavor = 传输/runtime 基底。这部分是健康的。**

## 2. role 和 flavor 在哪里纠缠

问题是**「这个 agent 是干什么的」(它的 ROLE) 今天只能表达为 flavor 专属的 template
class。** 最清楚的例子是 orchestrator：`cc_orchestrator_seed.ex` ——
*"`flavor: "cc"` —— orchestrator 是一个 `claude` PTY agent。"* role **orchestrator**
被硬绑到 flavor **cc**。

后果：
- 没有 flavor 无关的 role 概念。「orchestrator」「reviewer」「客服」等（若存在）以每 flavor
  定制的 `*-orchestrator` template class 形式散落。
- 要「一个 orchestrator，但 codex flavor」就得另写一个 `codex-orchestrator` template
  class —— role 不能跨 flavor 组合。
- feature/scenario 设计泄漏 flavor 名：scenario 04（"codex external agent"）+ scenario 06
  专门点 codex，而关注点本是通用 agent 行为（两者 2026-06-14 因此被标记/删除）。

这种纠缠与 **North Star（插件隔离）** 相反：未来作者应能组合 role × flavor 而无需协调，
且用户面向的概念应是 ROLE（干什么），不是 FLAVOR（怎么接线）。

## 3. 修复的形状（待 brainstorm —— 未定）

目标是 **role 成为凌驾 flavor 的一等抽象**，于是 agent = `role × flavor`，各自独立选择：

- **Flavor** 保持现职：传输/runtime 基底（PTY+MCP / UDS / 进程内）。注册表的强度不变。
- **Role** 成为 flavor 无关的「agent 干什么」定义：它的 system prompt / persona、behavior
  集、caps、session-template 接线 —— 今天全被抹进 `*-orchestrator` 式 template class 的东西。
- agent 然后由**选一个 role + 一个 flavor** 物化；orchestrator role 无论用 cc/codex/curl
  实现都成立。

## 4. 待定设计问题（给 Allen）

1. **Role 住哪？** 一个与 `AgentFlavorRegistry` 平行的新 `Role` 注册表（role →
   {prompt, behaviors, caps, session-template}）？还是 role 作为数据行（`Template` 子类型）
   而非模块？
2. **组合点。** role × flavor 在哪里合 —— template 物化时、agent spawn 时、还是作为
   双轴 template key？
3. **orchestrator 的迁移。** cc-orchestrator 是承重的现存「role」。它是否成为第一个
   `Role`、cc 只是它的默认 flavor？team-routing / orchestrator-readiness 路径会断什么？
4. **范围 vs 基座化。** role 触及 session-template 接线，那在 codex 正改名的
   `instance_message`→`session` 域（9b）。#54 应等 9c 之后，还是 Role 注册表可先独立落在
   `core`（注册表是 flavor 侧、非 session 侧）？
5. **「role」是对的轴吗，还是也需要「capability profile」/「team position」作为独立轴？**
   （避免重新纠缠。）

## 5. 交叉引用

- `Ezagent.AgentFlavorRegistry` / `Ezagent.Plugin`（`agent_flavors/0`、`bridge_adapter`）。
- `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex` —— role-flavor 纠缠示例。
- North Star：`feedback_north_star_plugin_isolation`。
- [`../../architecture/communication-overview.zh_cn.md`](../../architecture/communication-overview.zh_cn.md) §5 —— flavor 投递路径。
