# Handoff A — 导游/客服（concierge）机制讨论

- **类型**: `clarify_first`（研究 / 设计讨论，**不写实现代码**）。产出 = 设计对齐文档 + 建议的 build 切片 + DoD。
- **建议 owner**: ruihua（设计），可拉 gaga/zhaomato 对齐代码现状。
- **必读 skill**: `ezagent-socialware`、`ezagent-developer`。
- **一句话目标**: 定清楚「导游（迎新）」和「客服（兜底）」在**当前已落 main 的机制**上**怎么落**，重点是**要讨论/要拍的设计问题**，不是写代码。

---

## 你要先看懂的当前机制（都已在 main 上，代码已核对）

**① 通用机制：socialware Definition 可以声明「随会话拉起的 agent」——这套管子已经有了。**
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex`
  - `Definition.agents :: [%{recipe: String.t(), role_name: String.t()}]`
  - `recipe` = **配置义**（一个 `RecipeRegistry` 名字，接受 `guide` 或结构化 `recipe:guide`）；`role_name` = **路由义**（会话内唯一标识,`{:role, name}` 路由规则解析到它）。
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
  - `materialize_definition_agents/4`：建会话时把这些 agent **物化为 spawned member**——role_name 唯一性检查 → 按 workspace 解析 recipe → spawn（recipe→cc AgentTemplate content→在确定性 per-session URI 上 spawn）→ faceted `session.join` 带 `role_name` → 最后授 recipe 的 `requested_caps`（fail-closed）。
- **结论**：「一个 agent 自动加入某个 session」这件事**不需要新机制**——在 Definition 里声明一条 `agents` 就行,建会话时自动物化。

**② 但 #1134 里的 concierge 是「另写的一套」,不是走 ① 这条通用路。**
- `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_concierge.ex` + `.../entity/hello_concierge.ex` + `turn_driver.ex` + `prompts.ex`
- 前端 `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx` 有 `concierge-bubble`、`isConcierge`（`sender` 含 `/agent/concierge`）、导航动作（switch_tab/scroll_to/open_url）。
- 即 #1134 把 concierge 做成了 **hello 插件里的专用 Behavior/Entity**,而不是 `Definition.agents` 的一条声明。**这是本讨论的核心张力。**

**③ 兜底路由的现状**：路由规则机制存在（`{:always}`、`{:from}`、`{:role,name}`),但**没有**「等一会没人回 → 转客服」这种带超时的 fallback 触发器（我查了 `default_rules.ex`,没有 timeout/unanswered 规则）。

---

## 重点：要讨论 / 要拍的设计问题

1. **通用 vs 专用（最重要）**：导游/客服应该是 **`Definition.agents` 的通用声明**（recipe=`guide`/`support` + role_name),还是像 #1134 那样**另写 concierge 专用代码**？
   - lead 的直觉是「不需要特殊处理」→ 倾向通用。若走通用,#1134 的 `HelloConcierge` 是**重构上 `Definition.agents`**、还是**保留共存**、还是**删掉**？这条定了,#1134 才能收。

2. **导游落在哪一层**：SessionTemplate 默认层（**全局**——每个会话都自动加迎新）还是 website socialware 的 `Definition.agents`（**只官网**）？（lead 早上倾向「可配默认」:官网模板开、内部模板可关。）

3. **客服的触发语义**（唯一算「新」的一点）：
   - (a) 永远转发：一条路由规则把用户消息发给 support；
   - (b) 超时兜底：N 秒没 agent 回 → 转 support（需要计时器/watcher,是新行为）；
   - (c) 显式升级：用户点「转人工/客服」或 @客服。
   - 拍哪个（或组合）。

4. **导游/客服的「性质」**：
   - 客服 = **AI agent**（一个 support persona 的 recipe）还是**转真人**？
   - 导游 = 真的需要是一个 **agent** 吗,还是**建会话时的一条固定欢迎消息/系统卡片**就够（若是固定话术,可能根本不是 agent）？

5. **recipe 的 flavor/model**：导游/客服各用什么后端——便宜 completion flavor（够用、省钱）还是 cc（工具循环,重）？

6. **team 成员进官网会话**（关联项）：把 team.md roster seed 进官网 session,和导游/客服是不是同一套 `Definition.agents` 声明？

---

## 交付物（clarify 阶段,不写实现）

一份对齐文档（`docs/together/2026-07-03/` 或 `docs/superpowers/specs/`）：
- 逐条回答上面 6 个问题,给出**推荐**;
- 明确 #1134 `HelloConcierge` 的去留（重构/共存/删）;
- 拆出可执行的 **build 切片**（每片一句话 + 落点文件）;
- 写出 **DoD**（用户层可验证:官网建会话 → 导游迎新可见 + 客服兜底触发可见,附真实 channel 成功 transcript + 回归测试的计划）。

**明确不做**：不写实现代码;`HelloConcierge` 的改动等这份讨论定稿后再开 build handoff。

---

## 怎么快速看现状（命令）

```bash
# ① 通用 agents 机制
git show origin/main:apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex | sed -n '1,120p'
git show origin/main:apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex | sed -n '1,90p'
# ② #1134 的 concierge 专用实现
gh -R ezagent42/ezagent pr diff 1134 | grep -iE "concierge|HelloConcierge|guide|support"
# ③ 路由规则现状（确认没有 timeout fallback）
git show origin/main:apps/ezagent_core/lib/ezagent/routing/default_rules.ex
```
