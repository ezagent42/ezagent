# 任何登录用户都能围观任意 agent 的终端(跨 workspace)

**状态:** 待 Allen 定夺。**安全问题,不在当前 PR 修** —— 独立 bug、独立取证、独立 PR。

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

## 建议修法

`component_state/5` 对 `pty_terminal` 分支必须停止丢弃 `_caller` / `_caps` / `_workspace`:

1. **cap 检查** —— 读终端应当要求一个 cap。最自然的形状是复用写侧的 instance 轴:持有该 agent 的 Pty cap(或 Manage cap)才能看。
2. **workspace 校验** —— `entity_uri` 来自 URL,必须断言它属于 `socket.assigns.current_workspace_uri`,否则跨 workspace 直接拒。
3. **订阅点同样要拦** —— `maybe_subscribe_pty/2` 独立订阅 PubSub topic,**即使 state 那条路补上了检查,这里不补一样漏**(两条路都能拿到输出)。

第 3 条最容易漏:两处是**独立**的数据出口。

## 顺带:`WorkspaceUserAdmin.create_user` 是个 confused deputy

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
