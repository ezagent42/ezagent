# Return: app-package 设计日 (2026-07-02) — socialware 收口从讨论到 codex 实施

> **From:** Allen (lead) + Claude · **分支:** `integration/app-package` → `feat/app-t1-foundation` / `feat/app-t2-apppackage`
> **状态:** SPEC×2 + PLAN 定稿(3 轮 spec + 2 轮 plan codex 对抗性评审)→ 2 个 opus subagent 开发中。

## 1. 一句话
把"ezagent 上一个 app 是什么"收口成:**不新建 app 概念,把 socialware Definition 变胖成发布单元**;顺带清掉 pre-prod 最后窗口的命名/寻址债。拆成 **T1(基建)+ T2(app-package)** 两个任务,分 PR 交 codex 实施。

## 2. 收敛出的核心决策(Allen grill + 代码调研 + codex 评审)

| # | 决策 | 依据 |
|---|------|------|
| 1 | **不新建 "app" 概念** | 三层:socialware Definition(发布单元/mode)· SessionTemplate(装哪些 mode)· session(运行实例=左栏对话)。app=变胖的 Definition,用户面不引入 app 字眼。 |
| 2 | **发布单元 = socialware Definition**(不是 SessionTemplate) | Definition 已有 10 字段,几乎是完整对外交付单元;fatten 它比 fatten SessionTemplate 干净 |
| 3 | **openness 留 Definition.visibility_policy**(per-socialware,不回 template) | P4 决定;hello 对外/kanban 对内,一 session 内 diverse |
| 4 | **views-as-behavior**:view=渲染 ActionSet,其 required_caps=权限 handler | view 塌缩成"引用可解析",gate 统一;匿名可见=anon 真实用户 mint 时授 view read-cap |
| 5 | **统一 authorize_view 下沉 SessionView 契约** | 消灭直读 slice 绕过;所有渲染入口(PageView/ExternalFeed/tab)一条路 caller-aware |
| 6 | **view 唯一动作名 `<sw>_render`**(决策1=a) | `{kind,action}` 注册唯一;否决 view 各自成 Kind(过度建模)+ cap 加维度(动 cap 结构) |
| 7 | **role = 纯标识符,无需 Ezagent.Role 模块** | #127 已把配置义 role→recipe;role_name(路由)/recipe(配置)各就各位;role 无自己的数据 |
| 8 | **T2 字段正名 `agents:[%{recipe,role_name}]`** | recipe=配置义(带 caps)· role_name=路由义(per-session 唯一);两义分清 |
| 9 | **config:// 伪 URI → 结构化非-URI subject**(T1) | ConfigStore subject 长得像 URI 但不被 Ezagent.URI 解析、不跨引用;去 URI 化 + gate 兜底 |
| 10 | **Behavior → ActionSet 改名**(T1,pre-prod 窗口) | Behavior 名不副实(是 action handler 集)+ 撞 @behaviour;cap 身份嵌 module→上线后迁移贵 |

## 3. 产出物(全在 `docs/together/2026-07-02/`)
- `specs/T1-preprod-foundation.md` — ActionSet 改名 + config 去URI + URI gate 兜底 + role(配方义)→recipe 收尾。
- `specs/T2-app-package.md` — fatten Definition(agents+views)+ authorize_view + conformance gate(10 条)。
- `plans/app-package-plan.md` — T1(A1/A2/B/C/D/Skill)→T2(1/1b/2a/2b/3/4/5) PR-by-PR。
- （早期讨论稿 `specs/app-as-fat-session-template.md` v1-v3,保留追溯。）

## 4. codex 对抗性评审收敛轨迹(findings 逐轮缩小 = 设计扎实)
- **spec 第1轮**(误跑 stale 分支)→ 假阳性(openness/config)剔除,真项(views 匿名/改名迁移)留。
- **spec 第2轮**(钉 main)→ 多 view `{kind,action}` 撞车 + authorize_view 真契约是 SessionView + roles 无物化消费者。
- **spec 第3轮** → 全"实施精度"(view 进 behavior set / anon-cap scope / prompt_ref gate);设计 closed。
- **plan 第1轮** → 4 项(含我一个 stale 事实:Ezagent.Role 早已不存在)。
- **plan 第2轮** → 4 项 handoff 粒度(cap-only ActionSet / 复用 add_managed_member 封套 / recipe 前缀 helper / 文档 gate allowlist)。

## 5. 交付方式
- 不写 handoff 文档;**实施约束焊进 subagent prompt**。
- 2 个 opus subagent 各在 esr-ng worktree 开发(T1/T2),commit+push 到各自 target 分支,不 merge main、不开 PR。
- **main-agent(我)负责:验收(全套 gate)+ T2 rebase 到 merged-T1 reconcile 改名 + 合并 + 填 dev-together。**

## 6. 与官网需求线的关系(团队今日 PR #1129-1134)
app-package 模型正好承载官网旅程需求:
- "客服 agent 兜底官网 session" = T2 `agents` 字段(socialware 级声明)。
- "导游 agent 进每个用户 session" = SessionTemplate default 层(全局默认,非 socialware 级)。
- "发布为模板"(#1134)= SessionTemplate 发布;"一键复制 session 配置" = SessionTemplate fork。
→ 官网线与 app-package 线并行、不冲突,且 app-package 落地后官网可作为 conformance example。

## 7. 待续
- [ ] T1/T2 subagent 完成 → main-agent 验收 + 合并。
- [ ] T2 rebase 到 merged-T1(reconcile Behavior→ActionSet + recipe 前缀)。
- [ ] role=纯标识符 decision 记进 GLOSSARY。
- [ ] app-package gate 上线后:kanban + 官网当 2 个 conformance example。
