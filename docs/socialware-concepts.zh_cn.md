# Socialware 概念指南

本文定义 ezagent 使用的 socialware 模型，是 base / socialware / fixture
三层 taxonomy 的独立作者指南。

## 为什么叫 "socialware"，不是 "app"

socialware 是人和程序协作的混合流程，不是纯软件 app。它是被人操作的：
一个负责的人和一个或多个 agent 在同一个可观察的 turn surface 里协作；
在人把输出交给外部受众之前，可以 hold、settle、approve，也可以接管程序输出。

纯 app 隐藏内部状态并自动运行。socialware 则把内部协作过程暴露给负责人，
并把人的 gating 变成一等能力。

具体来说，socialware 把能力基座（base）和流程形状（shape）组合起来。
socialware 是操作者打开并使用的东西；base 本身不是直接给用户打开操作的产品。

## 三层模型

```text
FIXTURE
  某个业务里对 socialware 的一次 seeded instance / 配置化使用。
  例子：autoservice = 用于客服业务的 chat。

SOCIALWARE
  人和程序协作的混合流程，由一个或多个 base 加一个 shape 组成。
  它是直接给操作者使用的对象。
  例子：chat、kanban。

BASE
  被组合进 socialware 的能力基座。
  base 提供能力，不是产品。
  例子：orchestrator、surface、pty、sandbox、cc-headless-agent。
```

### Base

base 是可复用的能力基座。代码里，大多数 base 是拥有持久 state slice 和
dispatchable action 的 Behavior。一个 base 可以被多个 socialware 组合使用。

已验证的 base：

| Base | 代码 | 作用 |
| --- | --- | --- |
| orchestrator | `Ezagent.ActionSet.Template` recipe content + `Orchestrator.Tools` + `SessionManager` | 已存在的编排组合。不新增 `Behavior.Orchestrator`，也不重构 `Behavior.Template`。 |
| surface | `Ezagent.ActionSet.Surface` | 渲染/外部 surface 基座，包含不可变 page versions、approved pointer 和 settlement commit。 |
| pty | `Ezagent.ActionSet.Pty` | 终端/PTY 基座。 |
| sandbox | `Ezagent.ActionSet.Sandbox` | 每个 agent 的 config directory 和插件扩展基座。 |
| cc-headless-agent | `Ezagent.ActionSet.CcHeadlessAgent` | Claude Code SDK / headless-agent 基座。 |

orchestrator base 是对已存在 recipe + tools + executor 组合的概念简称。
`Behavior.Template` 仍然只是 AgentTemplate / SessionTemplate Kind 上的
template-content storage；它不是挂载到 Session 上的运行时 base。

### Socialware

socialware 是可以被直接操作的流程，由 base 加 shape 组合而成。

`chat` 是 world Conversation surface。它是通用 chat，没有 customer service、
autoservice 等业务语义。在目标模型中，chat 组合 orchestration base、surface
base 和 conversation shape。当前 `main` 仍然有分裂：普通 chat session 不挂载
Turn/Surface，而 socialware/hello 路径会挂载。P3 会把这个选择移动到 `installs`
数据字段里。

`kanban` 是 board/task socialware，带有明确的任务业务语义和 board/task shape。
当前 `main` 中 kanban 只是 role recipe；它还没有使用 `role_name`、
`{:role, name}` routing 或 routing rules。目标模型会通过 recipe、
responsibility 和 routing 表达这些语义。

### Fixture

fixture 是某个业务中对 socialware 的配置化实例或 seeded use。它不是概念层对象。

`autoservice` 是 fixture：为客服业务配置的 chat。它会增加 team、persona 和
adapter 配置，但不会给模型增加新层，也不能作为概念进入核心 taxonomy 或 schema。

## Shape

shape 是流程特有的 behavior 和 recipe，它把 base 组合成某种具体流程。

对 chat 来说，shape 是 conversation turn protocol，也就是
`Ezagent.ActionSet.Turn`。Turn 拥有 `:turns` slice，只适用于 conversation flow，
所以它是 shape，不是 base。

对 kanban 来说，shape 是 board/task protocol，也就是
`Ezagent.ActionSet.Kanban`：nodes、stages、claims、statuses、artifacts、
metrics、Miro sync 和 board configuration。

Surface 不同：渲染外部 surface 可以被无关流程复用，所以
`Ezagent.ActionSet.Surface` 是 base。

## Base 如何组合成 Socialware

socialware 通过已存在的 declaration-free mount 路径，把需要挂载到 Session 的
base 和 shape 安装到 session host 上。session 的 active behavior set 是所有已安装
socialware 的 base 和 shape 的并集。

socialware definition 是 config-as-data。它定义：

- 要挂载到 session host 的 bases 和 shape behaviors；
- members 和 B1 responsibilities；
- routing rules；
- prompt templates、legends 和 orchestrator template URI；
- 外部 adapters，例如 web feed、Feishu、Slack；
- visibility policy，包括匿名 web access 和 publish policy。

definition 存放在结构化的非 URI ConfigStore subject 下：

```text
socialware:<name>
```

该 subject 是一个不透明标识符，而非 `<scheme>://` URI。workspace 是独立的
ConfigStore 字段，不嵌入 subject（T1 project B）；ConfigObject key 为
`"socialware"`。不存在 `socialware://` scheme，socialware 也不是新的 Kind。

## 如何编写一个 Socialware

这是 P3-P7 完成后的目标 authoring model。P9 之前只能编写 B1 responsibility，
例如 `bot`、`reviewer`、`orchestrator`。命名的 `supervisor` B2 pool 只在 P9
引入。

1. 选择流程需要的 base：orchestration、surface、pty、sandbox、
   cc-headless-agent，或其他真实 base。
2. 定义 flow shape：conversation Turn、Kanban，或新的流程专用 Behavior。
3. 声明 B1 responsibilities 和 routing：给每个 member 分配 `role_name`，
   并路由到 `{:role, name}`。
4. 如果 socialware 有外部 surface，添加 adapters：web feed、Feishu、Slack，
   或其他 `ExternalMirror.Adapter`。
5. 把 socialware definition 写成 config-as-data，并通过 SessionTemplate 的
   `installs` composition 字段安装。

开发者不需要增加新的 host Kind，不需要让 `domain_session` 声明所有 base，
也不需要为每个 socialware 增加新的 spawn call site。host 是通用 Session；
install 是数据加已有 mount 机制。

## 反模式

- 纯 unattended app 不是 socialware。
- autoservice 这类 fixture 不是概念层 socialware 类型。
- hello 插件是 surface/page-builder base code，不是单独的 socialware vertical。
- orchestrator 是多个 base 之一，不是唯一 base。
- 不要新增 `socialware://`。
- 不要创建新的 `Behavior.Orchestrator`。
- 不要把 `Behavior.Template` 改造成挂载到 Session 的运行时 base。
- P9 之前不要引入命名的 `operator` 或 `supervisor` role。

