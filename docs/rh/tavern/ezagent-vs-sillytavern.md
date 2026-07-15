# Ezagent 能否满足二次元酒馆(SillyTavern)需求

> 作者：RH ｜ 日期：2026-07-02 ｜ 状态：可行性判断，未立项
> 一句话结论：**技术上可行且核心抽象契合得出奇地好；但"该不该做"取决于你要哪一种酒馆——单人本地 ❌，托管多用户 / 群像叙事 ✅。**

---

## 1. 什么是酒馆(SillyTavern)

### 1.1 一句话定义

酒馆(SillyTavern，直译"傻瓜酒馆")是一款**开源的 AI 角色扮演软件**。它让大模型为你构建一个虚拟世界与角色，然后**根据你的实时输入引导剧情发展**——不像传统 RPG 有固定剧情和固定选项，酒馆里所有对话、走向都是依你的指引即时生成，"想要什么就来什么"。

### 1.2 三件套（缺一不可）

酒馆本身只是一个**方便你与大模型对话的界面软件**，不含大脑也不含内容。要跑起来需要三块：

| 元素 | 作用 |
|---|---|
| **客户端本体** | 聊天界面、角色卡管理、历史记录，本身不含 AI |
| **AI 大模型** | 生成大脑，外部接入（如 Claude sonnet，走中转 API） |
| **角色卡** | 定义了角色 + 世界观的**提示词包**，通常内嵌在一张 PNG 图片里，从外部导入 |

### 1.3 隐含的产品能力（教程没明说、但酒馆生态默认有的）

真正让酒馆"好玩"的，是客户端多年沉淀的一堆功能：

- **群聊(group chat)**：多个角色同场，各自反应
- **persona**：用户给自己也建一个角色
- **lorebook / world info**：按关键词把世界观设定动态注入上下文（类 RAG）
- **swipe / 重生成 / 编辑消息**：对生成结果不满意可以反复重摇、手动改写
- **采样参数暴露**：temperature、top_p 等直接给用户调
- **破限 / 越狱**：突破大模型自身的内容生成限制（酒馆玩家的核心诉求之一）

> 记住这一层——第 3 章的"差别"主要就差在这里。

---

## 2. Ezagent 概念能否 / 如何与酒馆映射

### 2.1 先立心智：ezagent 是 message router，不是 chatbot app

映射之前必须先纠正一个直觉误区。**Ezagent 不是"一个聊天机器人应用"**，而是：

- **一个 message router runtime**——系统形状是 "IRC-style multi-tenant message bus over Phoenix transport"。核心三元组：
  - `Session` = 房间（routing context owner，类似 IRC channel）
  - `Agent / User` = 房间里的成员（Principal，类似 IRC nickname）
  - `Message` = 成员间通信的信封；`Behavior` 处理 Invocation 做出反应
- **一个 socialware platform**——一个 session 可以 `install` 一个或多个 **socialware**（human+program 混合 flow，config-as-data）。关键是：**human-in-the-loop gating 是 first-class**——程序产出的内容在到达外部观众前，operator 可以 hold / approve / take over。
- 它刻意**不是** fullstack web app、**不是** framework（core 才 ~920 LOC），部署形态是"单文件 SQLite + 单 BEAM 节点 = 一个目录"，能跑在树莓派级硬件上。

有了这个心智，映射就顺了：酒馆的"跟角色在一个房间里聊天"，在 ezagent 里天然就是"一个 session 房间里放几个 Agent 成员"。

### 2.2 概念映射表

| 酒馆概念 | Ezagent 对应物 | 契合度 |
|---|---|---|
| 角色卡（提示词包） | **Agent Recipe**（`config://<ws>/recipe/<name>`，"an agent is built from what"） | ★★★ 概念几乎一一对应 |
| 与角色对话 | **Session**（房间）里放一个 Agent principal + chat socialware（world Conversation） | ★★★ |
| 聊天历史 | **MessageStore**（chat history 的单一真相源，Decision #89） | ★★★ |
| **多角色群聊** | 一个 session 多个 Agent principal + routing rules | ★★★★ ezagent 本命 |
| persona（用户角色） | User Kind / Principal | ★★☆ |
| 多渠道接入（不止网页） | Feishu / Slack / CLI / MCP / HTTP adapter | ★★★ ezagent 强项 |
| LLM 后端 | Agent flavor（cc / codex / py / curl / native） | ★★☆ 见 §2.4 |
| 客户端 UI（酒馆本体） | 只有 LiveView dogfood IM + world admin | ★☆☆ 产品级缺失 |
| lorebook / world info（RAG 注入） | 无 first-class 概念 | ☆ 缺失 |
| swipe / 重生成 / 编辑消息 | 无（ezagent 不是 req/resp 聊天 UI） | ☆ 缺失 |
| 越狱 / 破限 | 取决于底层 LLM；ezagent 整套是 governed | ⚠ 哲学相反（见 §3.3） |

### 2.3 最漂亮的映射：角色卡就是 Recipe

酒馆的"角色卡"和 ezagent 的 **Recipe** 是**同一个抽象**——"一个 agent 是由什么构成的"（flavor-agnostic 的 sandbox-content recipe）。

更关键的是，ezagent 的架构原则明确**鼓励**这种扩展：

- **P1（plugin-isolation north star）**：加一种新 agent flavor / recipe，只需写一个 plugin OTP app，**不碰 core / domain / 其它 plugin**。
- **P24**：plugin 通过在已有 scheme 的 name 前缀上扩展、或在已有 core Kind 上注册 Behavior 来贡献 Kind。

所以"把角色卡做成 ezagent 的一等公民"在架构上是被支持、被鼓励的动作，**不是 hack**。

### 2.4 最大的技术 gap：缺"纯扮演 persona" flavor

ezagent 现有的 flavor（`cc` = Claude Code headless、`codex` 等）都是**工具执行型 agent**——它们的本命是干活、调工具、写代码、跑 kanban，是"任务型 agent"，不是"始终扮演萧炎、绝不出戏"的**纯 chat-completion persona**。

要做酒馆式扮演，你需要一个新的能力：**"系统提示词（角色卡）+ 历史 → 补全，且严格保持人设"**。这个 persona flavor / recipe 大概率还不存在，得新写。

好消息是：这是 **plugin / recipe 层的活**，正好落在 ezagent 设计允许的口子里（见 §2.3），不需要动 core。

### 2.5 架构红线：新角色类型是 role × flavor，绝不是新 Kind

如果真要做，有一条**必须遵守的红线**（skill 的 pre-flight checklist 第一条硬规则）：

> **加"roleplay persona"绝不能写成一个新的 `Ezagent.Entity.*` Kind。**

正确姿势是：在 unified `Ezagent.Entity.Agent` 上加一个 **role × flavor 的 recipe**，通过 plugin 的 `roles/0` 回调注册。
（`agent = role（它做什么）× flavor（它怎么执行）`。own-Kind-per-type 在 P4b 已经被废弃——`Entity.PyAgent` 被合并回 unified `Entity.Agent`，因为它破坏 P1/P24/P9。）

一句话记忆：**新角色 = 一个 recipe，不是一个新 Kind。**

---

## 3. 最火的酒馆 SillyTavern 与我们的差别

### 3.1 产品形态差别：单人本地客户端 vs 多租户消息总线

这是最根本的差别，其它差别都是它的推论：

| | SillyTavern | Ezagent |
|---|---|---|
| 形态 | 单人、本地跑的**客户端软件** | 多租户、服务端的**消息总线 runtime** |
| 部署 | 装个软件接个 API | 单 BEAM 节点 + SQLite（可托管多用户） |
| 用户模型 | 一个人自娱自乐 | 多 principal、workspace 隔离、CapBAC 授权 |
| 核心价值 | 极致的**创作自由 + 沉浸** | **编排、治理、可观测、可拦截** |

### 3.2 缺失的酒馆专属功能

ezagent 目前**没有**、要做酒馆就得从零补齐的：

- **roleplay 客户端 UI**——ezagent 只有 LiveView dogfood IM 和 world admin，不是打磨过的扮演前端
- **PNG 角色卡导入**——酒馆的角色卡是内嵌提示词的图片，ezagent 无此导入链路
- **lorebook / world info 注入**——无 first-class 概念
- **swipe / 重生成 / 编辑消息**——ezagent 是 router，不是 req/resp 聊天 UI，没有这套交互
- **采样参数 UI**——temperature 等没有暴露给终端用户的界面

这些是纯粹的**产品功夫**，酒馆生态积累了多年；在 ezagent 上重建它们投入巨大。

### 3.3 哲学差别：破限(uncensored) vs 受治理(governed)

这是**必须点破的方向性冲突**：

- 酒馆玩家的核心快感之一是**破限 / 越狱**——让模型产出不受约束的内容。
- ezagent 的整套设计方向**恰好相反**：CapBAC 授权、audit 审计、human-in-the-loop gating，目的是让产出**被治理、可观测、可拦截**。

这不是"能不能实现"的问题，是"你在逆着这个产品的世界观用它"。
（说明：破限本身不在本文的实现范围；但**受治理的角色扮演平台**是完全正当的产品方向。）

### 3.4 反过来——ezagent 独有、酒馆做不到的优势

差别是双向的。以下是 SillyTavern（单人本地）做不了、而 ezagent 天生就有的：

- **多渠道**：同一个角色能同时活在 Feishu / Discord / 网页 / CLI 里
- **多租户隔离**：每个用户互相隔离（workspace），天然适合做成服务
- **人工 gating**：角色的产出在推给用户前可人工 hold / approve（内容运营/审核场景）
- **群像原生**：多角色同台各自反应，在酒馆里是拼出来的功能，在 ezagent 里是**原生的路由模型**（多 principal + routing rules + dispatch）

---

## 4. 结论与建议

### 4.1 三种场景判断

"能不能满足需求"要分场景回答，不能一概而论：

| 场景 | 判断 | 理由 |
|---|---|---|
| **单人本地自娱自乐** | ❌ 错的工具 | SillyTavern 极简、生态成熟；ezagent 的 CapBAC / 多租户 / DLQ / 幂等在单人场景纯属过剩，且你要从零补一整套 roleplay 前端 |
| **托管的多用户、多渠道、可运营/审核的"酒馆即服务"** | ✅ 主场 | 多渠道、多租户隔离、人工 gating、审计、持久化——全是 SillyTavern 做不了、ezagent 天生就有的 |
| **群像 / 多角色叙事引擎** | ✅ 有独特优势 | 多角色同台各自反应 = ezagent 的原生路由模型，不是拼出来的功能 |

### 4.2 下一步

如果对**场景 2 / 3（托管多角色叙事 / 运营型酒馆）**有兴趣，这是个真命题，值得推进：

1. 走一轮 `superpowers:brainstorming`，把三件事想清楚：
   - MVP 到底做哪几个"角色卡 → recipe"的映射
   - persona flavor 具体怎么加（role × flavor recipe，不碰 core）
   - 前端用 LiveView 自建，还是接一个现成的 roleplay 客户端只把 ezagent 当后端
2. brainstorm 产物落到一张 **kanban 卡**（`.devtool/features/`），不单独建 spec/plan 文件。

---

## 附：本文档依据的 ezagent 权威源

- `ARCHITECTURE.md` §1（项目定位：socialware platform）、§1.2（router vs req/resp 两条核心差异）、§3.0（socialware / base / recipe / responsibility 概念轴）
- `.claude/skills/ezagent-developer/references/design-principles.md` — P1（plugin-isolation north star）、P24（plugin 扩展方式）
- `.claude/skills/ezagent-developer/SKILL.md` §"Extending agents without violating the architecture" — role × flavor 红线
