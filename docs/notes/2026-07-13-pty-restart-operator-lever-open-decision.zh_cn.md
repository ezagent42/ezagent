# `pty.restart` —— 被 halt 的 agent 需要的 operator 杠杆,以及它卡住的那个 cap 决策

**状态:** 待 Allen 拍板。实现约 65 行,已经写完并跑通、随后**主动撤回** —— 卡住的
不是代码,是授权。

**背景:** PR #1366 加了重生熔断器(`Ezagent.Domain.Pty.RespawnPolicy`)。一个永远起
不来的子进程被有界重试若干次后进入 **HALT**:PtyServer 还活着,但不跑子进程、也不再
拉起新的。

---

## 缺口

halt 是**刻意的终态** —— 一个连续 N 次起不来的子进程需要人来看一眼,而不是再重试一次。
`Ezagent.Domain.Pty.restart/1` 就是给人用的杠杆:它清掉熔断器(halt + 失败历史 +
backoff)并驱动一次全新的 spawn。

**但没有任何人够得着它。** 没有任何 operator 表面在调它:

| 表面 | 暴露了什么 |
|---|---|
| world UI(`Ezagent.World.AgentActions`) | `agents.create` / `agents.delete` / `agents.config.*` —— **没有 stop/restart** |
| `mix ezagent` | 只有 `agent.create` |
| PTY 终端 LV(`TerminalSeam`) | 只有 `?action=pty.write` |

于是熔断器现在是用**无限重生循环**换来了一个**永久死掉的 agent**,唯一的出路是删了重建。
这不是一个可以接受的落点,而且它是 #1294 原交接单 DoD 里**最后一条未满足**的
(「人工恢复:operator「重启 agent」动作清除终态 + 重生」)。

## 修复长什么样

给 `Ezagent.ActionSet.Pty` 加 `action :restart`(~10 行)、`handle_restart/2` 调已有的
`Domain.Pty.restart/1`(~10 行)、`TerminalSeam.dispatch_restart/2` 照抄
`dispatch_input/3`(~15 行)。**注册免费** —— `SessionBehaviorRegistration` 本来就是
`Enum.each(PtyB.actions(), ...)`,新 action 自动被拿到;`mix ezagent` 走同一条 dispatch,
也白拿。

这些全都写完了、编译过了、dispatch 也测通了。**它是能工作的。** 问题不在这儿。

## 卡点:哪个 cap 授权它?

原计划是**复用 `:write` cap** —— 能往这个 agent 的 PTY 里敲原始字节的人,本来就能敲
`exit` 进去,所以重启的破坏性**严格小于**他已经持有的权限;复用意味着零新增授权要管理。

**这条路走不通,而且值得记录**,因为那段声明**看起来就该成立**:

```elixir
def required_caps do
  %{
    write:   Ezagent.Capability.cap(:agent, __MODULE__, :write),
    restart: Ezagent.Capability.cap(:agent, __MODULE__, :write)   # ← 看着像复用
  }
end
```

用一个只持有 `:write` cap 的 caller 去 dispatch `?action=pty.restart`,返回
`{:error, :unauthorized}`。给 `Ezagent.Kind.Runtime` 的授权分支打点后真相是:

```
needed_action = :restart          # runtime 要的
held   action = :write            # caller 持有的
```

**runtime 是从「被 dispatch 的 action 名」推导所需 cap 的 action 轴的,而不是从 Behavior
在 `required_caps/0` 里声明的那个 capability 的 `action` 字段。** 那个声明里的 `:write`
被**直接无视**。Behavior **无法**用这种方式把一个 action 的权限别名到另一个上 —— 每个
action 在 action 轴上都携带自己的 cap,没有例外。

(这是**实测**出来的,不是推理:单独对这两个结构调 `Capability.matches?/2` 返回
`true`,不匹配只在 runtime 的 `needed` map 里才显现。**这正是那种「review 时看着对、
上线才炸」的东西。**)

## 所以 `:restart` 是一个【新 cap】—— 而这是个产品决策

`Ezagent.ActionSet.OrchestratorAdmin` 已有先例,而且它**显式**做了同样的选择:

```elixir
action :restart, caps: [:restart],
  description: "restart this session's orchestrator agent (session-owner authority)"

def required_caps, do: %{restart: Ezagent.Capability.cap(:session, __MODULE__, :restart)}
```

一个独立的 `:restart` cap,授权范围被**刻意命名**。要发 `pty.restart`,就得为 PTY 回答
同一个问题 —— 而这**不是实施者该独自拍板的事**(CLAUDE.md:不要发明新 Decision):

**谁持有 `Capability.cap(:agent, Ezagent.ActionSet.Pty, :restart)`?**

- **所有已经能往 PTY 里打字的人**(即每个 `pty:write` 持有者)?
  说得通(见上面 `exit` 那条),但那就必须在**今天授 `pty:write` 的每个地方**同时显式授
  `pty:restart`,而且已有的 operator 需要**回填授权**,否则这个杠杆一出生就是死的。
- **只有 workspace admin**?更安全,但在终端里盯着一个 crash-loop agent 的人往往**不是**
  admin —— 而他恰恰是那个看得见哪里坏了的人。
- **agent 的创建者 / owner**?这跟 `CredentialPrecondition` 的框架一致(Allen 2026-07-10:
  一个用户**故意**建了无凭证的 agent,就该由他自己进去修),也跟 `OrchestratorAdmin` 的
  「session-owner authority」对齐。

每个答案对应**不同的授权路径**(`default_caps` / DB grant / role recipe),以及对**已存在
的 agent 的不同回填方式**。

## 建议

**先定持有者,实现就是个很小的后续 PR。** 在那之前 PR #1366 交付熔断器 + 域层杠杆
(`Domain.Pty.restart/1`,已测),但**没有 operator 表面** —— 一个被 halt 的 agent 只能靠
删了重建来恢复。

这是一个真实的、有名有姓的代价 —— **记录在此,而不是粉饰过去。**
