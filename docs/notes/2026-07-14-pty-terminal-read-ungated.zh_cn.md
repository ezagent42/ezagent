# 任何登录用户都能围观任意 agent 的终端(跨 workspace)

**状态:** ✅ **已修(本 PR)。** Allen 2026-07-14 拍板:「谁看?肯定是创建者,创建者有权限。」

**性质:** 机密性泄露。**写**终端被 CapBAC 拦得死死的,**看**终端完全没有门禁。

**发现路径:** 调查「创建者进不了自己 agent 的 PTY」时,codex 的 claim-verification 反过来指出我把方向说反了;逐行复核代码后确认。

> ### ⚠️ 第一版修复只堵了 4 个出口里的 2 个
>
> 我最初以为只有两个读出口(终端路由的 state + 它的 PubSub 订阅),修完就收工了。
> **codex 的第二轮 review 和我自己的复扫同时指出:还有两个。** 其中一个是**活的、
> 客户端可直接触发的** —— 会话里的 `session.pty.open`,拿客户端传来的任意 agent URI
> 直接订阅它的输出流。**第一版修复对它完全无效,洞照样开着。**
>
> 这正是本文自己写下的那句话:**"两处是独立的数据出口,只堵一个等于没堵"** ——
> 我写了这句话,然后自己掉进去了。
>
> 教训落到代码里:**策略从 `plugin_world` 搬到了 `Ezagent.Domain.Pty.Access`** ——
> 住在被保护的东西旁边,四个出口都调它;`TerminalSeam` 改成**按构造自带门禁**
> (不传 caps 就订阅不了),这样未来新增的 host LV **没法靠"忘了检查"重新捅出这个洞**。

---

## 一句话

> **任何一个已登录用户,手敲一个 URL,就能实时围观任意 workspace 里任意 agent 的终端输出,并读到它的回滚缓冲。**
> 不需要任何 capability,不校验 workspace。

终端里会滚过什么:`claude /login` 的授权码、agent 的对话内容、源码、命令输出、被 echo 出来的密钥。

## 四个读出口(全部零授权)

| # | 出口 | 入口 | 泄露什么 |
|---|---|---|---|
| 1 | `IdentityData.component_state/5` 的 `pty_terminal` 分支 | `/identities/agents/:uri/terminal`(URL 可控) | **回滚缓冲** |
| 2 | `WorldLive.maybe_subscribe_pty/2` | 同上 | **实时输出流** |
| 3 | **`ConversationActions.switch_to_pty/3`** | **客户端事件 `session.pty.open`,`"agent"` 字段任意** | **实时输出流** |
| 4 | `EzagentDomainUi.Pty.TerminalSeam` | 可复用 seam(当时零调用方) | 缓冲 + 输出流 |

**出口 3 最要命:** 它连 URL 都不用改 —— 客户端直接发一个事件,`agent` 字段填**任意 agent URI**(跨 workspace 也行),服务端就把它订阅上了。`_session_uri` 参数**被显式忽略**,连"这个 agent 属不属于这个会话"都不查。

链条(以出口 1/2 为例):

| # | 位置 | 做了什么 |
|---|---|---|
| 1 | `ezagent_web/router.ex:36-53` | 只过 `RequireEntity` —— **任何已登录实体** |
| 2 | `world/routes.ex:234-242` | 正则从 **URL** 里抠出 agent URI,**不校验** |
| 3 | `world/identity_data.ex:207` | `component_state(…, _workspace, _caller, _caps)` —— **三个授权入参全部下划线丢弃** |
| 4 | `world/identity_data.ex:478` | 直接读**回滚缓冲** |
| 5 | `world_live.ex:859` | 直接订阅**实时输出流** |

第 3 步是关键:那三个下划线参数不是"暂时没用",而是**授权信息被显式丢弃**。

## 对照:写路径一直是有门禁的

`world_live.ex:284` 的 `handle_event("pty_input", …)` → `Invocation.dispatch/1` → CapBAC step 5.5。本 PR 之前它要的是 `cap(:agent, Pty, :write, <该 agent>)` —— 而**全仓库没有任何地方铸过这个 cap**,所以连创建者都没有。

**本 PR 之前的状态:**

| | 门禁 | 后果 |
|---|---|---|
| 写终端 | ✅ CapBAC | 连**创建者自己**都进不去(见 authority-gap note) |
| 看终端 | ❌ **无** | **谁都能看,任意 agent,跨 workspace** |

**该锁的没锁,该开的没开。**

## 修法(已实施)

新增 `Ezagent.Domain.Pty.Access.may_read?/2` —— 校验**该 agent 的 Manage cap**:

```elixir
Capability.Authorization.authorizes?(caps, %{
  kind: :agent,
  behavior: Ezagent.ActionSet.Manage,   # 精确
  action: :read,
  instance: agent_uri,                  # 精确 —— 只能看自己创建的那一个
  workspace_uri: Capability.workspace_of(agent_uri)
})
```

**四个出口全部接上**(策略住在 `Ezagent.Domain.Pty.Access` —— 被保护的东西旁边,而不是某个调用方里):

1. `IdentityData.component_state/5` —— 未授权时 buffer / 存活 / phase 全部不返回,访客除了自己敲进 URL 的那个 URI 之外**一无所获**
2. `WorldLive.maybe_subscribe_pty/2` —— 未授权**不订阅**输出 topic
3. **`ConversationActions.switch_to_pty/3`** —— 未授权直接 `error:unauthorized`,**一个 topic 都不订**
4. **`TerminalSeam.subscribe/2` + `push_initial_buffer/3`** —— 改成**按构造自带门禁**:不传 caps 就编译不过,传了不够就 `{:error, :unauthorized}`。未来的 host LV **没法靠"忘了检查"重新捅出这个洞**

**外加一条 chunk 绑定:** PTY 订阅会累积且从不退订(开过 A 再开 B,两个都订着)。`handle_info` 原本忽略 chunk 的 agent URI、无脑推给浏览器 —— A 的输出会漏进 B 的终端,**且在授权状态变化后仍在流**。现在 chunk 绑定到**屏幕上真正在看的那个 agent**。

**为什么是 Manage cap 而不是 Pty cap:** 创建者手里**只有** Manage cap(全仓库没有任何地方铸过 Pty cap),而 `ActionSet.Pty` 的 `:write` / `:restart` 现在也统一挂在 Manage 上。**一个权威覆盖整个终端:看、写、重启。零新 cap、零回填。**

workspace 轴自动收口:cap 的 `instance` 是精确 URI,别人 agent 的 Manage cap 匹配不上 —— 跨 workspace 围观自然被拒。

### 回归测试(每一条都验过:摘掉对应门禁 → 立刻变红)

`apps/ezagent_domain_pty/test/ezagent/domain/pty/access_test.exs`(谓词):
- 创建者的 Manage cap → 能看 · **别人 agent** 的 Manage cap → 看不了 · Pty cap → 看不了 · admin genesis → 能看 · 无 cap → 看不了 · 垃圾输入 → 拒绝而非崩溃

`apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs`(出口):
- **出口 1** 无 cap → 拿不到 buffer、拿不到存活状态
- **出口 3** 无 cap → `error:unauthorized`,而且**广播一条 PTY 输出过去,收不到**(证明真的没订阅)
- **chunk 绑定** → 别的 agent 的 chunk **不会**进这个终端

## ⚠️ 仍未修:`WorkspaceUserAdmin.create_user` 是个 confused deputy

**这条不在本 PR 修 —— 独立问题,独立 PR。**

同一轮 review 里 codex 指出、我复核确认:

`workspace_user_admin.ex:145-154` 的 `handle_create_user/2`:

```elixir
{:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str || "", Ezagent.Entity.User.admin_uri()),
{:ok, decoded} <- Ezagent.Users.create(user_uri, password, caps) do
```

- `caps_str` 是**调用者传进来的任意字符串**
- granter 被**硬编码成 `admin_uri()`** —— 不管实际调用者是谁
- 直接 `Users.create` 落库,**完全绕过 `Cap.issue/3`**,也就绕过了 `CapabilityRegistry` 的两道门禁(`:wildcard_action_grant_requires_admin_authority` / `rule_cap_bounded?`)

→ **持有 `workspace_user_admin.create_user` 的人(工作区级管理员,未必是全局 admin),可以造出一个持有任意通配 cap、且盖着 admin 印章的用户。** 提权路径。

有一处约束:`ensure_user_in_target_workspace/2` 限制新用户必须在目标 workspace 内。但 **caps 本身不受任何约束**(parser 默认 `action: :any, workspace_uri: :any`)。

---

**未在线上验证** —— canary 是只读的,没有实际去访问别人的终端。以上全部由代码逐行确认。

**相关:**
- `docs/notes/2026-07-13-agent-creator-pty-authority-gap.zh_cn.md` — 创建者进不了自己 agent 的 PTY(同一次调查的另一半)
