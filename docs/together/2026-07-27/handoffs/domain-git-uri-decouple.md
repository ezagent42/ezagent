# Handoff：通用 git 基础设施里焊死了 kanban

- **类型**：平台 infra 修正(动 domain_git 的 task 抽象) → Allen 拍板
- **一句话**：`domain_git` 是"给 agent 挂 git 工作区"的**通用**基础设施,但它的授权策略里**硬编码了 `"kanban-task"`**——底座认识了上层的一个具体业务名。这是一类"通用 infra 混入具体业务"的问题,不是 kanban 独有。

---

## 1. 现象和需求

**具体现象**:`domain_git` 的授权策略里有这么一行(`git_task_access.ex:336`):

```elixir
task_uri == Ezagent.URI.resource(workspace, "kanban-task", policy.task_id)
```

一个**通用 git 设施**,判断"这个 task 坐标对不对"的时候,写死了 `"kanban-task"` 这个资源类型。更讽刺的是——`domain_git` **自己的架构边界测试**(`dependency_boundary_test.exs:10`)明令禁止依赖 kanban,**代码里却硬编码了 kanban 字面**,自相矛盾。

**通用问题(拔高)**:这跟"kanban"其实没关系,它是一类**通用底座里混入了某个上层业务名字**的问题——

> 一个**通用的基础设施**(git 工作区、消息路由、任何 domain 层能力),不该在代码里假设"我只服务某个具体的上层业务(kanban)"。底座不认识上层,是分层的红线。

今天是 domain_git 焊了 kanban;同一类病在别处也会犯(一个通用能力被第一个用它的业务"焊住")。

---

## 2. 原因:为什么会焊进去

`domain_git` 最早是为"**kanban 板挂一个代码库、看 PR 进度**"设计的,那时候一个 git task 就是一个 kanban 板节点,所以顺手把资源类型写成了 `"kanban-task"`。但 `domain_git` 的**定位是通用 git 设施**——任意 agent 的任意 task 都该能挂 git。

**根因不是"出现了 kanban 字面",是一个设计选择(XY)**:`exact_task_uri?` 判断 task 坐标时,**不去比对存下来的完整 task_uri,而是从 `task_id` + 一个硬编码的资源类型"重新拼"一个 task_uri 出来再比**(policy 里只存了 `task_id`,没存完整 task_uri,见 `git_task_access.ex:32`)。**一旦选择"重拼",就必须知道资源类型是什么——于是被迫写死 kanban。** 真正该改的是"用重拼代替存储"这个选择,kanban 字面只是它的症状。

---

## 3. 系统现有的支撑

好消息是 **`domain_git` 的架构骨架是对的**,只差 task 抽象这一处:

| 现成 | 是什么 |
|---|---|
| **通用骨架** | `GitTaskAccess`(策略/契约/端口)在 domain_git 脊柱 + `plugin_github`(具体 provider 经 ports 注入)——通用 spine + provider-via-ports,跟 actor 抽取同款模式,本身完全 URI/业务无关 |
| **task 标识** | policy 已经有 `task_id`,能唯一标识一个 task |

也就是说,底座的**结构**没问题,病灶只在"怎么确认 task 坐标"这一个方法里。

---

## 4. 现有支撑解决不了什么(缺口)

1. **policy 存的是 `task_id`,不是完整 `task_uri`**——所以比对时只能"重拼"完整 URI,而重拼就必须知道资源类型,于是焊死 kanban。存的信息不够,是根上的缺口。
2. **`domain_git` 目前是 dormant 的**(没有任何生产调用者)——这是"一个还没接通的通用设施,里面就先焊了个 kanban 假设",而且违反它自己的边界测试。等真有非 kanban 的业务想用 domain_git(比如另一个 agent 挂自己的代码库),它会**直接撞墙**——因为设施假设了"所有 git task 都是 kanban-task"。

---

## 5. 我们 propose 什么

**让通用 git 设施对 task 的 kind 无关**——task 是任意 URI,设施不该假设它是 kanban 还是别的。具体就是:**比对 task 坐标时,直接比对存下来的完整 task_uri,而不是从零件重拼。**

原则:**通用底座只认 URI,不认 URI 背后是什么业务。** 这跟"分享是对任意 URI 授 cap"(见姊妹 handoff `uri-share-authz`)是同一条线——底座对 URI 一视同仁,具体是什么 kind 是上层的事。

---

## 6. 怎么改

| 方案 | 怎么做 | 评价 |
|---|---|---|
| **A(推荐)** | policy **存完整的 `task_uri`**(而不是只存 `task_id`),`exact_task_uri?` 直接 `==` 比对,删掉"重拼"逻辑 → `"kanban-task"` 字面自然消失,task-kind 无关 | 最干净,根治"用重拼代替存储" |
| B | policy 带一个 `task_kind` 参数(不硬编码),重拼时用 policy 自己的 kind | 治标,仍在重拼;不如 A |

因为 `domain_git` 目前 dormant,**改动零业务影响**——这是一次纯粹的设计正确化,趁没接通生产、边界测试也还禁着 kanban,现在改代价最小。

---

## DoD

- [ ] Allen 定 task 抽象方向(存完整 `task_uri` vs 参数化 kind)
- [ ] 改完后 `domain_git` 里 grep 不到任何 `kanban` 字面,与它自己的 `dependency_boundary_test` 一致(真正零依赖)
- [ ] (可选)顺带审视 domain_git 还有没有别的"第一个业务焊进来"的假设

> 溯源:出自 kanban 示范重构(PR #1474)的 infra 硬编码审计。当时判定"加个字段补 bug"是给坏设计续命(XY),正解是根治"重拼 vs 存储";因涉及 task 抽象决策 + domain_git dormant,拆出本独立 PR 交 Allen。
