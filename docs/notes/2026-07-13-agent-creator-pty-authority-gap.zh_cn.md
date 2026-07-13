# 创建者能不能碰自己 agent 的 PTY —— 一半已修,一半是既有缺口

**状态:** `pty.restart` **已实现**(本 PR,零新授权)。`pty.write`(`/login` 出口)仍是缺口,方案已收敛,等 Allen。

**⚠️ 本文 v1 有三条结论是错的,已在下方【撤回】小节逐条列明。** 错的部分由 codex 的 claim-verification 抓出,并用实测复核。留着不删 —— 错误的推导过程本身有信息量。

---

## 一、Allen 2026-07-13 的决策:创建者有权恢复死掉的 agent

**已实现,而且是免费的。**

`pty.restart` 加在 `Ezagent.ActionSet.Pty` 上(它在 `ezagent_domain_pty`,直接调 `Ezagent.Domain.Pty.restart/1`,零分层问题),它声明的 required cap 是**agent 的 MANAGE cap**:

```elixir
restart: Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
```

**创建者今天手里就有这个 cap** —— `CreatorGrant.manage_cap/4` 在 agent 创建时铸给他:
`cap(:agent, Manage, :any, instance: <该 agent>, workspace: <该 ws>)`。

所以:**零新授权、零回填、零 migration。canary 上已有的 6 个 agent 今天就能用。**

### 为什么这样是对的(而不是走私)

这是**既定惯例**,不是新发明。`Ezagent.ActionSet.ConfigGovernance` 的 7 个 CR action 全部这么写:

```elixir
manage = Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
%{open_cr: manage, stage_item: manage, ..., rollback_cr: manage}
```

它的注释写明:**"the agent's MANAGE cap(lead decision OQ-4)— no separate publish/reviewer cap"**。
`ConfigEvolve` 同理。**Pty 是第三个。**

语义上也正:**把一个死掉的 agent 拉起来,是对该实例的「管理动作」,不是「往终端里打字」。** 而 Manage cap 的定义(`manage.ex`,#533 §3.3)逐字就是 **"any management action on THIS instance"**。

### 授权形状(3 条测试钉死,`pty_test.exs`)

| 持有 | dispatch `pty.restart` | |
|---|---|---|
| 创建者的 Manage cap(**生产真实形状**,`workspace://<ws>`) | ✅ 授权 | 这就是全部理由 |
| **别人 agent** 的 Manage cap | ❌ `:unauthorized` | instance 精确有界 |
| `pty:write` cap | ❌ `:unauthorized` | 不产生扩权 |

> 注:测试里 workspace 必须用 `workspace://team-alpha`(生产形状)。我第一版硬写了一个 `entity://.../workspace/...`,系统里根本不存在这种 URI,导致测试假红。**红过一次,查明是 fixture 编错了 workspace,不是机制不通。**

---

## 二、`pty.write` —— 这一半仍是缺口

### Allen 2026-07-10 定的规矩

`Ezagent.Agent.CredentialPrecondition` 的 moduledoc:

> a user may deliberately create a credential-less cc agent and **run `claude /login` inside its PTY**

自动物化链之所以敢**硬拦**无凭证 agent,正因为「用户显式创建」这条链**有个出口** —— 用户自己进终端补登录。

### 出口不存在

- agent 创建时,创建者**只**拿到 Manage cap(`grant_agent_creator_manage_cap`)
- `grant_initial_caps(...)` 的**每一条**调用路径(RoleStep / world agent_actions / `agent.create --caps`)第一个参数都是 **`agent_uri`** —— 铸给 **agent 自己**,不是创建者
- 全仓库没有任何 recipe 请求过 Pty cap
- 创建者手里的 Manage 只有 2 个 action(`:delete` / `:reconfigure`),**没有任何自助铸 cap 的动作** → 无法自我提权

`Capability.Match` 逐字段比,`Manage ≠ Pty` → **创建者 `pty.write` 拿不到。**

**canary 上 6 个 cc agent 无一有凭证。按 Allen 的模型,它们的创建者本该自己进终端补登录 —— 而他们进不去。**

### 方案(修正版:用**具体 action**,不用 `:any`)

创建时,紧挨着 `grant_agent_creator_manage_cap` 再铸一个:

```elixir
Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Pty, :write, agent_uri, workspace_uri)
#                                                       ^^^^^^ 具体 action,不是 :any
```

**为什么改用具体 action(推翻了此前"选 `:any`"的结论):**

1. **`:any` 的唯一理由已经消失。** 原本要 `:any` 是为了让 `restart` 白拿 —— 但 `restart` 现在走 Manage,根本不经过 Pty cap。剩下要授的只有 `write` 一个动作,没有理由再开通配。
2. **`:any` 会撞发放门禁。** `CapabilityRegistry` 对「精确 instance + `action: :any`」的 grant 会拒:
   `:wildcard_action_grant_requires_admin_authority`(codex 发现)。具体 action 直接绕开这道门(`action_of(cap) != :any -> :ok`)。
3. 更小的授权面,同样满足 Allen 的决策。

已实测:一个 `cap(:agent, Pty, :write, <agent>, workspace://<ws>)` 能授权 `pty.write`(`pty_test.exs`)。

### 回填

`CreatorGrant.manage_cap/4` 的 `granted_by` 就是创建者,`Identity.list_caps_for/1` 可遍历 → 走所有 `kind: :agent` 的 Manage cap,持有人即创建者,补铸对应的 `Pty/:write` cap。

建议做成 **`mix ezagent` 一次性 task**(不是 migration):这是授权数据补写,且需要在 canary 上手动、可观察地跑一次并留证。

---

## 三、【撤回】v1 里三条错误结论

### ❌ 撤回 1:"`required_caps/0` 无法给 action 做权限别名"

**错。** `Kind.Runtime` 只覆盖 **action** 轴,**honour 声明的 behavior 轴**:

```elixir
# apps/ezagent_core/lib/ezagent/kind/runtime.ex:468
%{
  kind: kind_axis,
  behavior: declared.behavior,   # ← 取自 required_caps/0 的声明
  action: action,                # ← 取自 dispatch
  ...
}
```

我此前的实验只变了 action 轴(两边 behavior 都是 `__MODULE__`),却把结论过度推广成"behavior 也被覆盖"。**正是这条错误结论让我以为必须给创建者铸 Pty cap 才能 restart。** 它一撤,`pty.restart` 就变成免费的。

### ❌ 撤回 2:"这条契约没写在任何文档里"

**错。至少两处,而且都带决策编号:**

- `Ezagent.ActionSet.Manage` moduledoc(`manage.ex:32-37`)—— **#533 §3.3**:
  > "dispatch overwrites the needed-cap action with the concrete dispatched action and `matches?` compares the cap's action to it"
- `Ezagent.ActionSet.ConfigGovernance` 的 `required_caps` 注释 —— **lead decision OQ-4**

它不是没被记录,是**被记在一个你不会去翻的地方**(某个 ActionSet 的 moduledoc,而非 CapBAC/Behavior 契约参考)。**真正该做的是把它提到契约参考里** —— 那才是下一个人会看的地方。

### ❌ 撤回 3:"今天只有 admin 能打开一个 agent 的终端"

**这句话把方向说反了。** 精确的事实是:

| | 门禁 |
|---|---|
| **往终端写**(`pty.write`) | ✅ 走 dispatch → CapBAC。**创建者拿不到 cap → 进不去**(即上面第二节) |
| **看终端**(实时输出 + 回滚缓冲) | ❌ **完全没有 cap 门禁 —— 任何登录用户,任意 agent,跨 workspace** |

**该锁的没锁,该开的没开。** 详见 `docs/notes/2026-07-14-pty-terminal-read-ungated.zh_cn.md`(独立安全 note)。

(另:admin **确实**可以在**建用户时**通过 `WorkspaceUserAdmin.create_user` 的 cap 字符串手工发一个 Pty cap。但那条路表达不了「我将来要创建的那个 agent」—— instance 必须是建用户时就已知的具体 URI,或者 `:any`(= 系统里每一个 agent)。所以它不是创建者的出口,是 admin 的后门,且它本身也有问题 —— 见同一份安全 note。)

---

**相关:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.zh_cn.md` — #1294 根因(是 `--continue`,不是认证)
- `docs/notes/2026-07-13-bridge-join-timeout-silent.zh_cn.md` — bridge join 超时静默(独立 bug)
- `docs/notes/2026-07-14-pty-terminal-read-ungated.zh_cn.md` — **终端可被任意登录用户围观(安全)**
