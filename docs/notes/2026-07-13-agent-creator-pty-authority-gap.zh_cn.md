# agent 创建者进不了自己 agent 的 PTY —— Allen 2026-07-10 的决策在代码里是空的

**状态:** 待实施。方案已收敛,只等 Allen 点头。

**性质:** 这**不是**为了 `pty.restart` 而引入的新权限。**这是一个既有的、静默的授权缺口** ——
Allen 自己定的一条决策所假定的东西,代码里从来没有实现。`pty.restart` 只是顺带白拿。

---

## Allen 2026-07-10 定的规矩

`Ezagent.Agent.CredentialPrecondition` 的 moduledoc 里白纸黑字:

> **Explicit agent creation** by a user is untouched: a user may deliberately create a
> credential-less cc agent and **run `claude /login` inside its PTY** (Allen, 2026-07-10).
> That is why this check lives in the automatic lane and NOT in `Ezagent.Credential.HomeRuntime`,
> which both lanes share.

**这条决策的整个前提是:创建者能进自己 agent 的 PTY。** 自动物化链之所以可以严格拦截无凭证的
agent,正是因为「用户显式创建」这条链**有一个出口** —— 用户自己进终端补登录。

## 但那个出口不存在

### 证据 1:agent 创建时,创建者只拿到一个 cap

`Ezagent.ActionSet.Workspace.AgentCreate` 里一共两处铸 cap:

| 调用 | 铸给谁 | 铸什么 |
|---|---|---|
| `grant_agent_creator_manage_cap/3` | **创建者** | `behavior: Ezagent.ActionSet.Manage, action: :any, instance: <该 agent>` |
| `RoleStep.mint_and_grant_caps/4` | **agent 自己**(`grant_initial_caps(agent_uri, …)`) | role recipe 声明的 caps —— **而且只在 `params[:role]` 存在时才走** |

**创建者唯一拿到的,是 `ActionSet.Manage` 上的 cap。**

### 证据 2:全仓库没有任何地方给 user 铸 `ActionSet.Pty` cap

```
grep -rn "ActionSet.Pty" apps/ --include=*.ex | grep -iE "cap\(|grant|mint"
  → 零处(除了 pty.ex 自己 moduledoc 里的一句历史说明)
```

### 证据 3:PTY 终端确实走 CapBAC

`world_live.ex:284` 的 `handle_event("pty_input", …)` → `dispatch_pty_input/3` →
`Ezagent.Invocation.dispatch/1` → CapBAC step 5.5。

### 证据 4:Manage cap 匹配不上 Pty

`Ezagent.Capability.Match.matches?/2` 是**逐字段**比对,cap 侧的 `:any` 才是通配符:

```elixir
field_match?(cap.behavior, needed.behavior)   # Manage vs Pty → false
```

实测:

```
创建者持有:  behavior=ActionSet.Manage  action=:any  instance=<agent>
需要 pty.write   → matches? = FALSE
需要 pty.restart → matches? = FALSE
需要 manage.*    → matches? = TRUE
```

## 结论

> **今天,只有 admin(genesis 通配符)能打开一个 agent 的终端。**
> **一个普通用户创建了 agent 之后,打不开它的终端 —— 也就无法按 Allen 的设计进去 `/login`。**

canary 上 6 个 cc agent **无一有凭证**。按 Allen 的模型,它们的创建者本该自己进终端补登录。
**而他们进不去。**

---

## 方案

在 agent 创建时,紧挨着已有的 `grant_agent_creator_manage_cap`,给创建者多铸一个:

```elixir
Ezagent.Capability.cap(
  :agent,
  Ezagent.ActionSet.Pty,
  :any,
  agent_uri,          # instance —— 精确到这一个 agent
  workspace_uri
)
```

### 为什么是 `action: :any`

因为 Allen 的决策要求的是「**能用这个终端**」,而不是「能用终端的某一个具体动作」。要 `/login`
就必须能 `pty.write`;要从熔断的 halt 里恢复就必须能 `pty.restart`。逐个列举意味着 Pty 每加一个
action 都要回来改一次授权,而每一次遗漏都是一个静默的洞 —— 正如这一次。

**它仍然是有界的:**

| 轴 | 值 | 边界 |
|---|---|---|
| `kind` | `:agent` | ✅ 精确 |
| `behavior` | `ActionSet.Pty` | ✅ **精确 —— 不是通配符** |
| `action` | `:any` | ⚠️ 通配,但**仅限 Pty 这一个 behavior 内** |
| `instance` | `<该 agent 的 URI>` | ✅ **精确 —— 只能碰自己创建的这一个 agent** |
| `workspace_uri` | `<该 workspace>` | ✅ 精确 |

**创建者拿到的是「对我自己创建的这一个 agent 的 PTY 的完全控制」** —— 这正是 Allen 决策的
自然形态,而且它**碰不到别人的 agent、碰不到 Pty 以外的任何 behavior**。

### 回填(已存在的 agent)

线上已有的 agent(含 `test-zyli-cc-1`)不会自动拿到这个 cap。但**回填是机械的、可审计的**:

- `Ezagent.CreatorGrant.manage_cap/4` 的 `granted_by` 字段**就是创建者**
- `Ezagent.Identity.list_caps_for/1` 可按持有者遍历

→ 走所有 `kind: :agent` 的 Manage cap,持有人即创建者,给他铸对应的 Pty cap。

建议做成 **`mix ezagent` 的一次性 task 而非 migration**:这是数据/授权层的补写(不是 schema
变更),而且需要能在 canary 上**手动、可观察地**跑一次并留证。

---

## 顺带解决:`pty.restart` 的落点

这个缺口一补上,`pty.restart` 的落点问题**自动消失**:

- `:restart` 加在 `Ezagent.ActionSet.Pty` 上(它在 `ezagent_domain_pty`,可以直接调
  `Ezagent.Domain.Pty.restart/1`)—— **零分层问题**
- 创建者的新 Pty cap 是 `action: :any` → **`:restart` 白拿,零额外授权**

对比另外两条被排除的路:

| 方案 | 为什么不行 |
|---|---|
| `:restart` 放 `ActionSet.Manage`(创建者的 cap 本来就能匹配) | `Manage` 在 `ezagent_core`,**core → domain 是依赖环**,调不到 `Domain.Pty.restart/1`。唯一"能过编译"的写法是让 core 硬编码 domain 模块名(`{:effect, {Module, :fun}}` 是运行时 `apply`)—— **过编译、破架构** |
| `manage.restart` = 终止 Kind,靠 rehydrate 复活 | **是空的**。`Domain.Pty.stop/1` 全仓库只有一处调用(codex 的 `rollback_sidecars`);cc 的 Template Class **没有** `deactivate`/`destroy` 钩子停 PTY。Kind 终止后 halted 的 PtyServer 仍活着、仍注册 → `start/2` 拿到 `{:already_started, pid}` → 什么也不发生 |

---

## 副产品:一条 CapBAC 的隐性契约(值得单独记住)

调查中实测出来的,**没有写在任何文档里**:

> **`required_caps/0` 无法给 action 做权限别名。**
>
> runtime 从**「dispatch 进来的 behavior 模块 + 被 dispatch 的 action 名」**推导所需 cap,
> **无视** `required_caps/0` 里声明的 capability 的 `behavior` 和 `action` 字段。
> 只有 `kind` / `instance` / `workspace_uri` 三个轴会被采纳。

实测:声明 `restart: Capability.cap(:agent, __MODULE__, :write)` 想复用 `:write` 的权限,
一个持有 `pty:write` 的 caller dispatch `pty.restart` → `{:error, :unauthorized}`。
给 `Ezagent.Kind.Runtime` 的授权分支打点:

```
needed_action = :restart      ← runtime 要的
held   action = :write        ← caller 持有的
```

**最阴的地方:单独对这两个结构调 `Capability.matches?/2` 返回 `true`** —— 不匹配只在 runtime
构造的 `needed` map 里才显现。**这正是那种 review 时看着对、上线才炸的东西。** 如果不写这条
实测,下一个人还会踩。

---

**相关:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.zh_cn.md` — #1294 根因(是 `--continue`,不是认证)
- `docs/notes/2026-07-13-bridge-join-timeout-silent.zh_cn.md` — bridge join 超时静默(独立 bug)
