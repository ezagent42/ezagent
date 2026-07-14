# 任何登录用户都能围观任意 agent 的终端(跨 workspace)

**状态:** ✅ **已修(本 PR)。** Allen 2026-07-14 拍板:「谁看?肯定是创建者,创建者有权限。」

**性质:** 机密性泄露。**写**终端被 CapBAC 拦得死死的,**看**终端完全没有门禁。

**发现路径:** 调查「创建者进不了自己 agent 的 PTY」时,codex 的 claim-verification 反过来指出我把方向说反了;逐行复核代码后确认。

---

## 一句话

> **任何一个已登录用户,手敲一个 URL,就能实时围观任意 workspace 里任意 agent 的终端输出,并读到它的回滚缓冲。**
> 不需要任何 capability,不校验 workspace。

终端里会滚过什么:`claude /login` 的授权码、agent 的对话内容、源码、命令输出、被 echo 出来的密钥。

## 链条(逐行,零授权)

| # | 位置 | 做了什么 |
|---|---|---|
| 1 | `ezagent_web/router.ex:36-53` | `live "/identities/agents/:uri/terminal"`,只过 `RequireEntity` —— **任何已登录实体** |
| 2 | `world/routes.ex:234-242` | 正则从 **URL** 里抠出 `:uri` → `entity_uri: parse_entity_uri(encoded)`,**不校验** |
| 3 | `world/identity_data.ex:207-213` | `component_state(%{component: "pty_terminal", entity_uri: agent_uri}, base, _workspace, _caller, _caps)` —— **`_workspace` / `_caller` / `_caps` 三个全部下划线丢弃** |
| 4 | `world/identity_data.ex:478-480` | `pty_initial_buffer(agent_uri)` → `Domain.Pty.Server.snapshot_buffer(agent_uri)` —— **直接读回滚缓冲** |
| 5 | `world_live.ex:859-866` | `PubSub.subscribe(Domain.Pty.Server.output_topic(agent_uri))` —— **直接订阅实时输出流** |

第 3 步是关键:那三个下划线参数不是"暂时没用",而是**授权信息被显式丢弃**。

## 对照:写路径是有门禁的

`world_live.ex:284` 的 `handle_event("pty_input", …)` → `Invocation.dispatch/1` → CapBAC step 5.5 → 需要 `cap(:agent, Pty, :write, <该 agent>)`。

**所以现状是:**

| | 门禁 | 后果 |
|---|---|---|
| 写终端 | ✅ CapBAC | 连**创建者自己**都进不去(见 authority-gap note) |
| 看终端 | ❌ **无** | **谁都能看,任意 agent,跨 workspace** |

**该锁的没锁,该开的没开。**

## 修法(已实施)

新增 `Ezagent.World.PtyAccess.may_read?/2` —— 校验**该 agent 的 Manage cap**:

```elixir
Capability.Authorization.authorizes?(caps, %{
  kind: :agent,
  behavior: Ezagent.ActionSet.Manage,   # 精确
  action: :read,
  instance: agent_uri,                  # 精确 —— 只能看自己创建的那一个
  workspace_uri: Capability.workspace_of(agent_uri)
})
```

**两个出口都接了**(这是最容易漏的一点 —— 它们是**独立**的数据出口,只堵一个等于没堵):

1. `IdentityData.component_state/5` 的 `pty_terminal` 分支 —— 未授权时 buffer / 存活 / phase 全部不返回,访客除了自己敲进 URL 的那个 URI 之外**一无所获**
2. `WorldLive.maybe_subscribe_pty/2` —— 未授权**不订阅**输出 topic

**为什么是 Manage cap 而不是 Pty cap:** 创建者手里**只有** Manage cap(全仓库没有任何地方铸过 Pty cap),而 `ActionSet.Pty` 的 `:write` / `:restart` 现在也统一挂在 Manage 上。**一个权威覆盖整个终端:看、写、重启。零新 cap、零回填。**

workspace 轴自动收口:cap 的 `instance` 是精确 URI,别人 agent 的 Manage cap 匹配不上 —— 跨 workspace 围观自然被拒。

### 回归测试

`apps/ezagent_plugin_world/test/ezagent/world/pty_access_test.exs`:
- 无 cap 的访客 → **拿不到 buffer、拿不到存活状态**(把门禁摘掉这条**立刻变红**,已验证)
- 创建者的 Manage cap → 能看
- **别人 agent** 的 Manage cap → 看不了
- Pty cap → 看不了(契约已移走)
- admin genesis → 能看

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
