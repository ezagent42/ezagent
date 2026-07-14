# 终端属于创建者 —— 三条 PTY 权限全部收敛到创建者已有的那一个 cap

**状态:** 全部实现(本 PR)。**看 / 写 / 重启** 三个终端权限,统一由创建者在 agent 创建时就已拿到的 Manage cap 携带 —— **零新 cap、零回填**,canary 上 6 个存量 agent 立刻可用。

**Allen 2026-07-14:「谁看?肯定是创建者,创建者有权限。」**

**⚠️ 本文 v1 有三条结论是错的,已在下方【撤回】小节逐条列明。** 错的部分由 codex 的 claim-verification 抓出,并用实测复核。留着不删 —— 错误的推导过程本身有信息量。

---

## 一、重启:Allen 2026-07-13「创建者有权恢复死掉的 agent」

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
| `Pty` cap | ❌ `:unauthorized` | 契约已移到 Manage,fail-closed |

> 注:测试里 workspace 必须用 `workspace://team-alpha`(生产形状)。我第一版硬写了一个 `entity://.../workspace/...`,系统里根本不存在这种 URI,导致测试假红。**红过一次,查明是 fixture 编错了 workspace,不是机制不通。**

---

## 二、`pty.write`(`/login` 出口)—— 也已修,同样免费

### Allen 2026-07-10 定的规矩

`Ezagent.Agent.CredentialPrecondition` 的 moduledoc:

> a user may deliberately create a credential-less cc agent and **run `claude /login` inside its PTY**

自动物化链之所以敢**硬拦**无凭证 agent,正因为「用户显式创建」这条链**有个出口** —— 用户自己进终端补登录。

### 出口原本不存在

- agent 创建时,创建者**只**拿到 Manage cap
- `grant_initial_caps(...)` 的**每一条**路径都铸给 **agent 自己**,不是创建者
- **全仓库没有任何地方铸过 `ActionSet.Pty` cap** —— 零个铸造点、零个 recipe 请求
- 创建者的 Manage 只有 `:delete` / `:reconfigure`,**没有自助铸 cap 的动作** → 无法自我提权

**canary 上 6 个 cc agent 无一有凭证。按 Allen 的模型,它们的创建者本该自己进终端补登录 —— 而他们进不去。**

### 修法(Allen 2026-07-14:**终端属于创建者**)

**不铸新 cap。让创建者已有的权威直接携带终端。**

```elixir
# ActionSet.Pty.required_caps/0
manage = Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)
%{write: manage, restart: manage}
```

`Ezagent.World.PtyAccess`(终端的**读**门禁)校验同一个 cap。于是:

> **对一个 agent 的权威 = 它的 Manage cap。这个权威携带终端:看、写、重启。**

**零新 cap、零回填、零 migration —— canary 上 6 个存量 agent 立刻可用**(它们的创建者早就持有这个 cap)。

### 为什么不是「铸一个 Pty cap 给创建者」(我的前一版方案)

**因为铸 cap 的那个地方,没资格提 `Pty` 这个模块。** 分层查实:

| app | 能引 `ActionSet.Pty` 吗 |
|---|---|
| `ezagent_core`(`CreatorGrant`) | ❌ core→domain 依赖环 |
| `ezagent_domain_workspace`(创建 agent 的地方) | ❌ deps 里**没有** domain_pty |
| `ezagent_plugin_world`(读门禁在这) | ✅ deps 里有 |

要绕过这堵墙就得发明新机制(比如「Kind 的创建者拥有哪些 behavior」注册表),那是**新架构**,得走 Allen。而 Manage 方案**一行都不用绕** —— `ActionSet.Pty` 在 domain_pty,引 core 的 `Manage` 天经地义。

### 刻意接受的后果

**手工发放的 `Pty` cap 不再授权 `pty.write`。** 全仓库没有任何地方铸过它,所以现实中大概率无人持有;万一有,**是 fail-closed**(拿到 `:unauthorized`,不是静默放行),重新授权就是补一个该实例的 Manage cap。

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

| | 修复前的门禁 | 现在 |
|---|---|---|
| **往终端写**(`pty.write`) | ✅ CapBAC —— 但**创建者拿不到 cap,进不去** | ✅ 创建者的 Manage cap |
| **看终端**(实时输出 + 回滚缓冲) | ❌ **零门禁 —— 任何登录用户,任意 agent,跨 workspace** | ✅ 同一个 Manage cap |

**该锁的没锁,该开的没开 —— 两边都已在本 PR 修。** 详见 `docs/notes/2026-07-14-pty-terminal-read-ungated.zh_cn.md`(独立安全 note)。

(另:admin **确实**可以在**建用户时**通过 `WorkspaceUserAdmin.create_user` 的 cap 字符串手工发一个 Pty cap。但那条路表达不了「我将来要创建的那个 agent」—— instance 必须是建用户时就已知的具体 URI,或者 `:any`(= 系统里每一个 agent)。所以它不是创建者的出口,是 admin 的后门,且它本身也有问题 —— 见同一份安全 note。)

---

**相关:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.zh_cn.md` — #1294 根因(是 `--continue`,不是认证)
- `docs/notes/2026-07-13-bridge-join-timeout-silent.zh_cn.md` — bridge join 超时静默(独立 bug)
- `docs/notes/2026-07-14-pty-terminal-read-ungated.zh_cn.md` — **终端可被任意登录用户围观(安全)**
