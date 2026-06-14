# Role-over-Flavor —— 设计（任务 #54）

> **设计 spec。** 方向 Allen 2026-06-14 已批（`agent = role × flavor`）。实现**排在
> socialware 基座化完成后（PR-9c 之后）** —— 现在写 spec，先不写代码。基于现状分析
> [`2026-06-14-role-over-flavor-analysis.zh_cn.md`](./2026-06-14-role-over-flavor-analysis.zh_cn.md)。
>
> 双语镜像：[`2026-06-14-role-over-flavor-design.md`](./2026-06-14-role-over-flavor-design.md)。

## 1. 纲领原则（Allen 2026-06-14）

> **sandbox 的内容是 ROLE；sandbox 如何被加载是 FLAVOR。**

精确且有代码佐证：

- **Role = sandbox 内容。** 装进一个 agent `config_dir`（它的沙箱）的东西：skills、plugins、
  system prompt / `CLAUDE.md` persona、它跑的 behavior 集、它的 caps、它的 session-template
  接线。今天这些被抹进 flavor 专属 bootstrap —— 如 `orchestrator_bootstrap.ex` *把 orchestrator
  **skill** 装进 cc agent 的 `config_dir`*。那个 skill 就是 role；它没有任何 cc 专属性。
- **Flavor = sandbox loader。** 那个 `config_dir` 如何被 provision 并绑进运行 runtime：
  `CLAUDE_CONFIG_DIR`（cc）/ `CODEX_HOME`（codex）/ 进程内（curl），加 `bridge_adapter` 和
  `kind`。这是现有 `AgentFlavorRegistry` 的职责，保持不变。

agent 由**选一个 role（填沙箱）+ 一个 flavor（如何加载沙箱）**物化 —— 两者独立组合。

## 2. 设计

### 2.1 Role 是一个 **Template 子类型**（Allen 2026-06-14 —— 不是新注册表）

一个 Role 是一等 **Template**（template-kind 轴新增 `role`，与 `agent` / `session` 并列）：
一个持久化、URI 寻址（`template://<ws>/role/<name>`）、**可 fork** 的 Template，其 content 是
沙箱内容配方：

```elixir
# template://<ws>/role/<name> 的 template content：
%{
  skills: [skill_ref],          # 装进沙箱 config_dir 的 skills
  plugins: [plugin_ref],        # 装进沙箱的 plugins
  prompt: prompt_ref | nil,     # system prompt / CLAUDE.md persona 片段
  behaviors: [module()],        # role 需要的 behavior 子集（与 flavor 的组合）
  caps: [cap_template],         # 「请求」caps —— materialization 时 fail-closed 授权（§2.3.1），不拷贝
  session_template: ref | nil   # 对一个 session-template 的「引用」（role 不拥有 session 代码）
}
```

配方是 **flavor 无关**的 —— 没有字段命名 cc/codex/curl。

**为什么是 Template 子类型，不是 `AgentFlavorRegistry` 式注册表？**（Allen 的问题，2026-06-14。）
两者*都能*代码声明 —— 内置 role 是代码 **seed** 的 Template，跟今天 `cc-orchestrator` 一样。
区别不在「代码 vs 非代码」，在*它运行时是什么*：

| | 注册表（flavor） | Template 子类型（role） |
|---|---|---|
| 存储 | 纯代码、boot 时 **ETS** 查找 | **持久化** DB 行 + 快照 |
| 身份 | 一个字符串 key | 一个 `template://` **URI** |
| 运行时可编辑性 | 无 —— 改 = 代码 + 重新部署 | **运营 fork / 编辑 / 创建** role |
| 生命周期/caps/ownership/版本 | 无 | 完整 Template 生命周期（fork 是通用 Template 关注点） |
| 创建路径 | 直接 register | **creation-unification** 收口 |

**flavor** 是真正的静态接线（传输 adapter 是代码），注册表合适。**role** 是*运营该编写的产品级
内容* —— 「agent 干什么」—— 所以必须是一等数据、不是冻结的代码表。Role-as-Template 复用整套
Template 机制（fork、caps、快照、creation-unification），不重造。（这取代分析文档里「注册表 +
Template 子类型」两选 —— Allen 选了只 Template。）

### 2.2 Flavor 不变

`AgentFlavorRegistry` 保持 `{kind, template_class, instance_behaviors, bridge_adapter}` +
config_dir 加载机制。不削弱。

### 2.3 组合 —— 在 materialization

从 `(role, flavor)` 创建 agent 时：
1. **Flavor** provision 空沙箱（`config_dir`）+ 定 kind + loader env（`CLAUDE_CONFIG_DIR` /
   `CODEX_HOME` / 无）。
2. **Role** 填沙箱：装 `skills` + `plugins`、写 `prompt` 片段、组合 `behaviors`（role 的 ∪ flavor 的）。
3. **Caps 经 fail-closed 授权步解析 —— 不拷贝**（见 §2.3.1）。
4. flavor 的 loader 把已填好的 `config_dir` 绑进 runtime。

「role 填沙箱」是今天 `*_bootstrap.ex` 安装器的泛化，做成 flavor-盲：role 的安装器往
「config_dir」写，不知道它是 `CLAUDE_CONFIG_DIR` 还是 `CODEX_HOME`。

### 2.3.1 Cap 组合是 fail-closed 的（codex adversarial-review，2026-06-14）

role 的 `caps` 是**请求**的 caps、不是授予的。把 role 的 cap 模板不论 flavor/runtime/租户盲拷
到 agent 会是 CapBAC 漏洞（"never weaken authz"）—— 例如 orchestrator role 请求一个驱动
PTY/bridge 的 cap，在没有 bridge 的 `curl` flavor 上无意义（且绝不能被静默授予）。所以
materialization 跑一个显式授权步：

```
effective_caps = authorize(role.requested_caps, flavor_policy, tenant_policy)
              = role.requested_caps ∩ {flavor/runtime + 租户允许的 caps}
```

**Fail closed：** flavor/runtime/租户策略不允许的请求 cap **被拒绝、绝不拷贝**。role 的*内容*
（skills、prompt、behaviors）跨 flavor 相同；*有效 caps* 是 flavor 校验过的、可以合法地不同。
这让 cap 收口（`Ezagent.Capability.matches?`）保持唯一权威 —— role 是*请求*，授权步是*授予*。

### 2.4 命名轴

agent URI 的名字前缀今天编码 flavor（`cc_…`、`curl_…`）。Role 成为独立属性（经统一 URI-query
查询，见 `2026-06-05-unify-uri-query-design.md`），**不**拼进名字 —— 避免重新纠缠身份。（已决定 —— §4。）

## 3. 迁移 —— orchestrator 是第一个 Role

`cc-orchestrator` 是承重的现存「role」。它变成：
- Role **`orchestrator`** = {orchestrator skill、orchestrator prompt、orchestrator behavior/caps、
  orchestrator session-template} —— `cc_orchestrator_seed.ex` + `orchestrator_bootstrap.ex` 安装的
  一切，去掉 cc 假设。
- Flavor **`cc`** = 它的默认（今天唯一）loader。

于是「orchestrator role、codex flavor」可通过把同一 role 配方装进 `CODEX_HOME` 沙箱表达。
`orchestrator_bootstrap.ex` 改写为查 **role Template** 并往*无论哪个* flavor 的 config_dir 写。
orchestrator role 以**代码 seed 的 role Template**（`template://system/role/orchestrator`）发布，
跟今天 `cc_orchestrator_seed.ex` 一样 seed —— 但作为可 fork 的 Template，于是租户能 fork+改。
风险面：假设 cc 的 team-routing + orchestrator-readiness 路径 —— 在 plan 里审计。

## 4. 子决策 —— 已定（Allen 2026-06-14）

1. **Role 存储 → Template 子类型**（不是注册表）。role 是可 fork、持久化的 template-kind `role`
   实体；内置的是代码 seed 的 Template。注册表-vs-Template 的理由见 §2.1。
2. **组合点 → template materialization**（role-Template × flavor → materialization 时出具体 agent）。
3. **session-template → 只引用。** role 的 `session_template` 是*引用*；role 不拥有 session 代码。
   （这是触及改名后 `session` 域的字段 —— 实现等 9c 后。）
4. **命名/身份 → role 作可查属性**，不是第二个名字前缀轴。

无遗留设计决策。下一步：实现 plan（9c 后）。

## 5. 排序

- **现在：** 本 spec +（你 review 后）实现 plan。
- **Codex-review gate：** 按 `feedback_spec_codex_adversarial_review`，实现前已跑 codex
  adversarial-review（cap 盲拷洞已修成 §2.3.1 fail-closed）。
- **Beachhead（可选，9c 后）：** 先在 `core`/Template 落 role-kind（flavor 侧、无 session 依赖）；
  `session_template` 字段接线在 9c 稳定 session 域后再做。
- **实现：** 基座化（PR-9c）合并 + gate 绿之后。

## 6. 完成判据（不变式）

完成测试（按 `feedback_completion_requires_invariant_test`）：**用 TWO 个不同 flavor 物化同一 role，
断言沙箱内容（skills / prompt / behaviors）相同、而 loader（config_dir env / kind / bridge）不同。**
Caps 断言为 **flavor 校验过、非相同** —— 按 §2.3.1 有效 caps 是 `请求 ∩ flavor/租户策略`，可合法不同。
该测试今天失败（role 不能跨 flavor 组合），只有当 role×flavor 解耦时才通过。

加一个**负向授权测试**（codex review）：orchestrator role 对一个**不支持**某请求 cap 的 flavor
（如对无 bridge flavor 请求驱动 bridge 的 cap）物化时，那个 cap 必须**被拒（fail-closed）、不拷贝** ——
证明 cap 组合是授权、不是拷贝。

## 7. 交叉引用

- 分析：`2026-06-14-role-over-flavor-analysis.md`。
- `Ezagent.AgentFlavorRegistry` / `Ezagent.Plugin` —— flavor 侧。
- `apps/ezagent_plugin_cc/lib/ezagent/template/{orchestrator,onboarding}_bootstrap.ex` —— 今天的沙箱内容安装器（待泛化）。
- `2026-06-05-unify-uri-query-design.md` —— URI-作为-不透明-id 的属性查询（role 属性用）。
- North Star：`feedback_north_star_plugin_isolation`。
