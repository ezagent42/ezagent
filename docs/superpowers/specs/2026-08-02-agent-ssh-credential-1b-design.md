# Agent SSH 凭据 — 任务 1b 设计（物化进 agent）

**日期：** 2026-08-02
**状态：** 已实施（见分支 `feat/agent-ssh-credential`，整支终审 2026-08-02）
**基线：** `d77f94f65`（分支 `feat/agent-ssh-credential`，1a 已完成）
**上游 spec：** `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md` §1（1b 范围定义）、`docs/superpowers/specs/2026-07-31-git-credential-model-options-design.md` §8.3/§8.4
**决策人：** gaga（形态 B2′ 由 Allen 定）

---

## 0. 一句话

把 1a 存下的 User SSH 私钥，在 agent 启动时**写进一个 agent 专属目录**，并通过 `GIT_SSH_COMMAND` 让该 agent 的 `git` 用上它。

**开关 = agent 是否持有一条指名道姓的 cap。** 不持有 → 什么都不发生，spawn 路径完全不变。

---

## 1. 三个决定，以及它们为什么长这样

1b 的全部设计空间被三个问题占满。以下是结论与实证依据。

### 1.1 谁拿到 key —— cap 本身既是开关，也是指针

上一轮讨论倾向"recipe 声明"。**查证后否决 —— 但下面是订正后的论据**（2026-08-02 整支终审 Important-1：早前一版写「`CapMint.mint/3` **写死** `kind: :agent, instance: agent_uri`」，**这句是错的**，见下）：

- `Ezagent.Agent.Recipe.CapMint.mint/3`（`apps/ezagent_core/lib/ezagent/agent/recipe/cap_mint.ex:43-48`）**本身是泛型的** —— 它从第二个参数**解构** `%{kind: kind, instance: %URI{} = inst, workspace_uri: ws, granter: granter}`，`:74-83` 的 `build_needed/4` 只是把**传进来的**轴注入。
- **写死发生在它唯一的生产调用点**：`Ezagent.ActionSet.Workspace.AgentCreate.RoleStep.mint_and_grant_caps/4`（`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/role_step.ex:194-200`）对每一个 recipe 物化出来的 agent 都传 `kind: :agent, instance: agent_uri`。

而 `:read_ssh_key` 的 cap 必须是 `cap(:user, UserSshIdentity, :read_ssh_key, <某个 user>, <ws>)`。所以**今天的 recipe 通道铸不出指向 User 的 cap** —— 但那是**调用点**的约束，不是 `CapMint` 的结构约束。要走 recipe 通道，需要给 `role_step` 增加"这条 requested_cap 指向别的主体"的表达，那是每条 recipe cap 都要过的路径上的改动，与"尽量简化"不成比例。

> **这处订正本身值得记**：本支实现者在 `agent_git_identity.ex:20-26` 的 moduledoc 里写的是**正确版本**，而设计文档一直是错的 —— 两者当面矛盾了整整五个 task 没人发现，直到整支终审逐条去读 `cap_mint.ex` 才抓出来。参见 `docs/notes/2026-08-02-ssh-identity-1b-friction-log.zh_cn.md` §4.4「论证错了但结论对了」。

同时查证：`Ezagent.WorkspacePlacement.owner_of/1`（`local_resolver.ex:9-11`）返回的是**节点 `RuntimeIdentity`**，即联邦放置身份，**不是 workspace 的属主用户**。所以"从 agent URI 推出属主 user"这条路**不存在**，不要去建。

**结论（这两条否决合起来指向同一个答案）：不推导归属，让 cap 自己说。**

> **一条 cap 同时承担三件事**：
> - **开关** —— 持有即启用，不持有即完全关闭
> - **授权** —— 就是 1a 那条 `:read_ssh_key` cap，走既有 step-5.5
> - **指针** —— cap 的 `instance` 字段**就是**要读哪个 user 的 key

运行期算法因此退化成：读 agent 自己的 cap 集 → 找 `behavior == UserSshIdentity ∧ action == :read_ssh_key` 的那条 → 拿它的 `instance` 当 dispatch target。**没有归属推导，没有新概念，不可能漂移**（开关与被读对象是同一个事实，无法各说各话）。

发放 = 运维显式动作：`mix ezagent.agent.grant_git_identity <agent_uri> <user_uri>`。人类明确说"agent X 可以读 user Y 的 SSH key"。

**这也正是 B2′/A1 的切换点**：A1 = 不发这条 cap（平台自己持 key，见任务 2）。切换机制不需要额外建设。

### 1.2 写在哪 —— 独立的 per-agent 目录，**不进 config_dir**

直觉是写进 `config_dir`（已 0700、per-agent、destroy 时清）。**否决**，理由有三（下面是查证后的版本 —— 早前一版在这里写"会经 cp_r 泄漏私钥、后果具体且可复现"，Task 1 两道独立复审 + 我自己复核后确认那条路径在当前代码下**不可达**，见③）：

1. **不同的复制策略归属。** `config_dir` 的内容已被既有机制分成两类：「config（`materialize_cascade` 逐层 merge）」与「secret（`secret_relpaths` 定向拷贝）」（`home_runtime.ex:490-520`）。SSH 私钥两类都不是 —— 放进去要么被误归一类，要么要求引入第三类。
2. **不同的生命周期与来源。** `config_dir` 由凭据轨在 agent CREATE 时物化一次；git 身份每次 spawn 重写（§1.3），来源是另一个 Kind（User）上的一个 slice，不是 cascade 的任何一层。
3. **今天没有可复现的泄漏路径，但那只是靠 `resolver.ex:95-108` 一个函数里硬编码的四层清单维持的，不是结构性保证。** `Ezagent.Credential.Resolver.resolve_layers/1`（`apps/ezagent_core/lib/ezagent/credential/resolver.ex:95-108`）枚举的四层写死为 `:flavor_base` / `:workspace` / `:user` / `:session`，没有一层是 agent URI —— 所以今天不存在"agent A 的 config_dir 被当作 agent B 的参考目录"这条路径；`materialize_single_reference` 的整目录 `cp_r`（`home_runtime.ex:629` 起）也只跑在这四层上，收的是显式 `reference_dir`（`home_runtime.ex:470`），不是任意 agent 的 config_dir。但这份"安全"完全系于这一个函数当前的四层清单，没有任何结构性的东西阻止将来某一层的 source 变成 agent URI。

**结论不变，只是论证换了：** `Ezagent.Sandbox.ConfigDir` 的路径机制是按 namespace 参数化的（`config_dir.ex:48-67`，走 `resource://<ws>/<ns>-agents/<name>` + `FsResolver`）。1b 复用这套机制，但**用一个独立的 resource type**，并且**给它自己的 authority 函数** —— 因为 `FsResolver` 的 `config_dir_type?/1` 是按 **authority 函数的身份**判定 config-dir 家族成员的（`fs_resolver.ex:301-304` 明写此不变式:"families must NOT share one fn reference"）。用同一个函数会让 git-identity 目录被 `resolve_config_dir/1` 判成 config-dir 类型，返回 `{:error, :config_dir_resource_requires_scope}`，被 `CascadeRuntime.layer_dirs/1` 当致命中止 —— 不是泄漏，是 spawn 失败；但把身份放在这套复制机制管不着的地方，是让"同部署内两个 agent 是否隔离，完全取决于有没有各自发那条 cap"这句话**不依赖 `resolver.ex` 那份清单将来会不会变**。

### 1.3 什么时候写 —— 每次 spawn，不是 create

实证：`create_agent_config_dir` **只在 `{:started, true, created_witness}` 这条臂上跑**（`cc_agent/spawn.ex:186-190`），即逻辑创建的赢家；respawn / rehydrate / adopt 都不跑。而 `build_claude_cmd` **每次 spawn 都跑**。

若在 create 时写，key 就与 agent 同寿：**撤销永远不生效**。若每次 spawn 写，撤销在下次重启生效 —— 这是本形态能提供的最强撤销语义，且不额外花一分钱。

> **但"每次 spawn 写"本身不足以让撤销生效** —— cap 撤销后走的是"不写"这条路，若不额外清理，旧 key 会一直躺在盘上。见 **§6.1**（该条是 Task 2 复审顺出来的设计缺陷修订）。

顺带解决时序：create 时 `create_agent_config_dir`（含 `swap_into_place`）先跑完，PTY 参数构建在后（`spawn.ex:190` → 后续 `ensure_pty_server`），**无竞态**。

---

## 2. 模块与 tier

| # | 模块 | tier / app | 职责 |
|---|---|---|---|
| ① | `Ezagent.Sandbox.GitIdentityDir` | core / `ezagent_core` | per-agent git-identity 目录的**路径权威**：`path/1`、`allocate/1`、`safe_to_destroy?/2`。镜像 `Sandbox.ConfigDir`，独立 resource type |
| ② | `Ezagent.Credential.GitIdentityRuntime` | core / `ezagent_core` | **纯机制**：给定私钥内容 + 目录 → 写文件、chmod、拼 `GIT_SSH_COMMAND`。不认识 User Kind，不 dispatch |
| ③ | `Ezagent.Identity.AgentGitIdentity` | domain / `ezagent_domain_identity` | **编排**：读 agent cap 集 → 找 cap → dispatch `:read_ssh_key` → 调 ② → 返回 env map |
| ④ | `mix ezagent.git.known_hosts` | domain / `ezagent_domain_identity` | `ssh-keyscan` 写节点级 `known_hosts` |
| ⑤ | `mix ezagent.agent.grant_git_identity` | domain / `ezagent_domain_identity` | issue + absorb 那条窄 cap |
| ⑥ | cc flavor 接线 | plugin / `ezagent_plugin_cc` | 两处各 merge 一次 env |
| ⑦ | destroy 清理 | core / `ezagent_core` | `Ezagent.ActionSet.Sandbox` destroy 时 wipe git-identity 目录 |

**③ 为什么在 `ezagent_domain_identity` 而不是 `ezagent_domain_agent`：** 它读两样东西 —— agent 的 cap 集、User 的 SSH 身份 —— **都是 identity 域数据**（P9「reads what data decides tier ownership」）。且 `Ezagent.Identity.list_caps_for/1` 就住这里，既有约定「cap 读留在 Identity 域 / display / tooling 内」（`host_login_adopt.ex:194-197` 注释里的 invariant p6）不被破坏。

**依赖方向已验证**：`ezagent_plugin_cc/mix.exs:51` 已依赖 `ezagent_domain_identity`；`ezagent_domain_identity/mix.exs` 只依赖 `ezagent_core` + `ezagent_actor`。**无循环依赖**，⑥ 直接调 ③ 即可。

---

## 3. 运行期流程

```
spawn（每次）
  │
  ├─ ③ AgentGitIdentity.materialize(agent_uri)
  │    │
  │    ├─ Identity.list_caps_for(agent_uri)
  │    │    找 behavior == Ezagent.ActionSet.UserSshIdentity
  │    │      ∧ action == :read_ssh_key
  │    │    ├─ 没有  → {:ok, :none}            ← 关闭态，默认，绝大多数 agent
  │    │    └─ 有    → user_uri = cap.instance
  │    │
  │    ├─ dispatch read_ssh_key（caller = agent_uri, caps = MapSet[那条 cap]）
  │    │    ├─ {:error, :ssh_identity_absent} → {:error, :owner_has_no_key}   ← 配错，要吵
  │    │    └─ {:ok, %{private_key: pem}}
  │    │
  │    └─ ② GitIdentityRuntime.write(agent_uri, pem)
  │         ├─ 节点级 known_hosts 未配置 → {:error, :known_hosts_unconfigured} ← 要吵
  │         └─ {:ok, %{"GIT_SSH_COMMAND" => "..."}}
  │
  └─ ⑥ Map.merge(cmd_env, env)
```

### 3.1 三种"没有身份"必须可区分

| 情形 | 返回 | 处置 |
|---|---|---|
| agent 没那条 cap | `{:ok, :none}` | **静默**。这是默认态，不是错误，不打日志（否则每个 agent 每次启动都刷一行） |
| 有 cap 但 user 没 key（1a `:ssh_identity_absent`） | `{:error, :owner_has_no_key}` | **吵**：Logger.warning + telemetry。运维发了 cap 却没生成 key = 配错，agent 会莫名其妙 clone 失败 |
| 有 cap 但 user 的 key 状态损坏（1a `:ssh_identity_unavailable`） | `{:error, {:owner_key_unavailable, reason}}` | **吵**：Logger.error + telemetry。与上一行**必须分开**：一个是"没配"，一个是"配了但坏了"，处置动作不同 |
| 有 cap、有 key，但节点没配 known_hosts | `{:error, :known_hosts_unconfigured}` | **吵**：Logger.error + telemetry，消息里带**具体修复命令** |

**沿用 1a §5.1 的 absent≠unavailable 语义：缺席才 fall through，配了但不可用一律 fail loud。** 1a 已把这两种状态在 action 返回值上分开，1b **不得把它们合并**成一个错误 —— 那会把 1a 花了一整轮 review 才修对的区分丢掉。

### 3.1.1 dispatch 的 ctx 怎么构造（实现要点）

1a 的授权测试用 `signed_invocation!/2` 走通 dispatch，容易被误读成"invocation 需要签名"。**实际不是**：该 helper 做的是往 `ctx` 里放 `:authenticated_principal`（`cap_helper.ex:258-260`）。cap 本身在 Path A 下**出生即签名**。

所以 ③ 的生产 dispatch ctx 是：

```
%{
  caller: agent_uri,
  authenticated_principal: agent_uri,   # 持 cap 的就是 agent 自己
  caps: MapSet.new([那一条 cap]),        # 只放这一条，不放 agent 的全部 cap
  reply: {:caller_inbox, self()}
}
```

**`caps` 只放找到的那一条**，不是 `list_caps_for/1` 的全集：全集会让这次读携带 agent 的其它所有权限，违背既有的窄授权惯例（`GrantCap` moduledoc：「caller 把这**单条** cap 作为 dispatch caps —— 绝不给一个宽集合」）。

### 3.2 失败不阻断 spawn

三种情形都**不让 agent 起不来**。理由：git 身份是 agent 能力的一部分，不是 agent 存在的前提；让一个 known_hosts 配置问题变成 agent 起不来，是把可恢复故障升级成不可用。

但**必须响**（invariant #9「no silent drops」的同源要求）：后两种走 Logger + telemetry。

---

## 4. `GIT_SSH_COMMAND` 的四个开关，逐条给理由

```
ssh -i <dir>/id_ed25519
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o UserKnownHostsFile=<dir>/known_hosts
    -o StrictHostKeyChecking=yes
```

| 开关 | 不加会怎样 |
|---|---|
| `IdentitiesOnly=yes` | ssh 会把它能找到的**所有** key 挨个试。私有仓库场景下这会用错身份认证成功，审计归属直接错掉（后果④） |
| `IdentityAgent=none` | 落到宿主的 ssh-agent —— **那是运维本人的 key**。这是 1b 最大的一条意外提权路径，且完全静默 |
| `UserKnownHostsFile=<per-agent>` | 落到 `~/.ssh/known_hosts`（宿主的），agent 之间互相污染 |
| `StrictHostKeyChecking=yes` | TOFU：首次连接无条件接受任何主机 key |

**这四条都不是"防攻击者"，是防"代码/配置走到默认路径就悄悄用错身份"** —— 正是 memory `feedback-gate-targets-accidents-not-attackers` 界定的 gate 类别，也是 CLAUDE.md 安全姿态允许的那类（caps 正确性 + 防漂移）。**不引入任何其它安全代码。**

### 4.1 known_hosts 的来源

节点级一份，`Application.get_env(:ezagent_core, :git_known_hosts_path)` 指向它；④ 负责生成并打印该配置行。

**不走 `Ezagent.Home.path/1`** —— 那条路有 `HomePathBaseline` 架构 gate（`home_path_baseline.ex`），为一个运维文件去动 gate 不值得。④ 接受 `--out <path>`（未给则取配置值，两者皆无则报错要求显式给出）。

**不预置 GitHub/GitLab 主机 key 进仓库**：会轮转，仓库里的 key 过期后表现为全局 clone 失败且无人知道该改哪。

---

## 5. 目录与文件

```
<FsResolver 解析 resource://<ws>/git-identity/<agent-name>>/    0700
├── id_ed25519      0600   私钥
└── known_hosts     0644   从节点级文件复制
```

- resource type 名 `"git-identity"`，`backend_component` 同名
- **独立的 authority 函数** `git_identity_authority/2`（断言与 `config_dir_authority/2` 相同的 workspace 一致性，但**函数身份不同**）—— 依据 `fs_resolver.ex:270-274`：家族成员按 authority 函数身份判定，共用会让本目录被 config-dir 层机制认领
- 注册在 **core**（不是 plugin 的 `resource_types/0`）：这不是 flavor 概念，是 agent 通用概念

**每次 spawn 覆写**：先写 staging 再 rename，或直接覆写 —— 此处**不需要**原子换入（没有并发读者：写发生在子进程启动之前）。**故意保持简单**，并在实现里写明为什么不需要，免得后人照 `stage_and_swap` 抄一套。

---

## 6. 撤销语义（如实记录，不粉饰）

> **2026-08-02 修订 —— 早前一版这里是错的。** 原文写「撤销 agent 的 cap → 下次 spawn 生效」。
> Task 2 复审（codex）指出 `write/2` 在 known_hosts 未配置时会**留下上一次写的私钥**；
> 顺着查下去发现这是一个**更大的洞的窄实例**：cap 被撤销时 `materialize/1` 返回
> `{:ok, :none}`，而**原设计里没有任何东西删掉已在盘上的 key** —— 于是撤销**永远不生效**，
> §1.3「每次 spawn 写所以撤销下次重启生效」这句论证跟着一起失效。
> 下面的 §6.1 是把那句话变成真的所需的机制。

### 6.1 清理规则（载重要求，不是优化）

**`materialize/1` 除 `{:ok, env}` 外的每一种结局，都必须先清空该 agent 的 git-identity 目录。**

| 结局 | 含义 | 必须清 |
|---|---|---|
| `{:ok, env}` | 授权且成功 | 否（刚写好的就是它） |
| `{:ok, :none}` | **cap 已撤销 / 从未授予** | **是 —— 这条就是让撤销生效的那一步** |
| `{:error, :owner_has_no_key}` | User 侧 `revoke_ssh_key` 过了 | **是** |
| `{:error, {:owner_key_unavailable, _}}` | User 的 key 状态损坏 | **是** |
| `{:error, :known_hosts_unconfigured}` 等 | 节点配置问题 | **是**（codex 找到的那条） |

并且 **`write/2` 一进来就先清目录**，语义变成「要么这个目录恰好装着这份身份，要么什么都没有」。这样每条错误路径不必各自记得清理 —— 少一处可漏。

**为什么"清掉一把能用的 key"是安全的**：key 每次 spawn 都从 User 的 slice 重新物化，**不存在状态丢失**。而反面（平台以为 agent 没有 key、实际盘上还躺着一把）严格更糟。

#### 6.1.1 已知边界 —— 一次性瞬时错误可能清掉一个正在跑的 agent 的 key（Task 5 复审 M2，记录不改行为）

`materialize/1` 由两条 cc 生产入口在**每次 spawn**（含 respawn/adopt）调用：PTY 侧
`SpawnPlan.build_claude_cmd/3`、headless 侧 `CcHeadlessAgent.cmd_env/2`。稳态下
`ensure_subprocess_alive/2` 在子进程已存活（`pty_server_alive?/1` / `SdkSidecar.alive?/1`）
时直接短路成 `:ok`，根本不重新构建 launch 参数，也就不会重新调用 `materialize/1`。

但两条入口各自的启动器都保留一条 adopt 分支，处理"目标进程其实已经在跑"的启动竞态：
PTY 侧 `start_pty/2` 的 `{:error, {:already_started, pid}}`
（`apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex:617`，注释自承是 #1096
的异常路径）、headless 侧 `ensure_sdk_sidecar/2` 的同形 `{:error, {:already_started, _pid}}`
分支。走到这两条分支时，`build_claude_cmd/3` / `sdk_sidecar_params/2` 已经在
`Pty.start/2` / `SdkSidecar.start/2` **之前**跑完了（含它们内部各自的 `materialize/1`
调用）。如果此刻 User Kind 正忙/超时（`AgentGitIdentity.materialize/1` 的
`catch :exit` 分支，`apps/ezagent_domain_identity/lib/ezagent/identity/agent_git_identity.ex:150`）
或数据库抖动，`materialize/1` 按上面 §6.1 的语义会 **wipe 掉目录并返回 error** ——
而这次 adopt 采用的是**已经在跑**的那个 PTY/sidecar 进程（它的 `GIT_SSH_COMMAND` /
子进程 env 指向的是它自己当初启动时那次 `materialize/1` 留下的目录），不是刚构建的
这份新参数。结果是：一个正常运行、cap 从未被撤销的 agent，其 git 身份目录被一次瞬时
错误清空，且它自己收不到任何信号。

**这个窗口可达，但是异常路径**（启动竞态 + 恰好撞上 User Kind 忙/DB 抖动的双重巧合），
不是稳态。后果是该 agent 的 `git` 操作从这一刻起开始失败（`GIT_SSH_COMMAND` 指向的私
钥文件已不存在），直到它的**下一次 spawn** 重新走 `materialize/1` 成功物化为止 ——
自愈，不需要人工介入，但期间是真实的功能中断。

**裁定：不改行为。** wipe-on-error 是 §6.1 明确要求的语义（文首 2026-08-02 修订记录的
教训就是"撤销必须真的生效"）；专门为这条异常路径开口子，会把 §6.1 从"每种非
`{:ok, env}` 结局都清空目录"这条无条件规则，变成一条要考虑"是不是 adopt 竞态"的有
条件规则，更难推理、更容易漏。这条路径本身也足够罕见（需要启动竞态与身份读失败两个
独立的偶发条件同时撞上），不值得为此让核心不变式带上例外。这是设计取舍，记在这里而
不是代码注释里。

### 6.2 生效时机

> **2026-08-03 重写 —— 本节此前整段作废。** 原文说「撤销 agent 的 cap → **下次 spawn** 生效，已在跑的 agent 手里的 key 文件不受影响」，并把这一点论证成「B2′ 的固有属性，不是本实现的缺陷」。
>
> **Allen 判定它值得修**，`#1693`（`ab12c63da`，2026-08-03）把撤销做成了**即时**的：在 `Ezagent.ActionSet.IdentityAdmin` 的两个 cap 移除 handler 上挂钩，被移除的 cap 恰为 `UserSshIdentity` 的 `:read_ssh_key` 且持有者是 agent 时，追加 `{:effect, {Ezagent.Credential.GitIdentityRuntime, :wipe}, [uri]}`，caps 变更提交后立即擦除。
>
> **`#1693` 未改动任何 `docs/superpowers` 文件**，所以本节曾与 main 的实际行为相反达数小时 —— 正是本条线反复出现的「结论过期的文档只会误导下一个读者」那一类。

| 动作 | 何时生效 | 机制 |
|---|---|---|
| 撤销 agent 的 cap（`EntityCaps.revoke/2` 与全部 Grant revoke 路径 → `:remove_cap`） | **立即** | `#1693` 的 `maybe_add_git_identity_wipe/3` |
| delivery-outbox 的 `:revoke_cap` 重放 | **立即** | 同上 |
| recipe-binding reconcile 掉该 cap（`:sync_recipe_binding` 整集替换） | **立即** | 本轮补齐（§6.2.1） |
| `revoke_ssh_key`（1a，撤的是 User 侧的 key 本身） | **下次 spawn** | §6.1 的 `{:error, :owner_has_no_key}` 清理 |
| agent 已被销毁 / spawn 失败回滚 / retire 清扫 | **立即** | 1b Task 5 + 整支终审 K1 的三处清理 |

#### 6.2.1 本轮补齐：`:sync_recipe_binding` 的整集替换

`#1693` 的 commit message 自己点名了两个未覆盖路径。查证后：

- **`:sync_recipe_binding`（`identity.ex:694`）—— 真缺口，已补。** 它做的是 `set_caps_effect(reconciled.caps)`，**整集替换**而非单条移除，所以 `#1693` 钩的两个 handler **都不触发**。触发路径实在：`RecipeCapBinding.sync_live/1` ← `definition_agents.ex:452 / 506 / 789`（session 创建、agent 定义）。
- **`EntityCaps.persist/2` —— 今天不可达，不补。** 全仓 grep 零生产调用点（只有 `identity.ex:634` 的文档注释提到）。按项目安全姿态（不内联引入 caps 正确性以外的安全代码），等它真有调用点再说。**记为 follow-up。**

判据与 `#1693` 不同：整集替换要比较**替换前后**该 agent 持有的 `:read_ssh_key` cap 集合，**只要发生变化就擦除** —— 既覆盖「有 → 无」（撤销），也覆盖「指向 User A → 指向 User B」（盘上那把是 A 的，此刻已不在授权范围内）。不变则不擦，绝大多数 reconcile 走这条路，零额外开销。

擦除是安全的：key 每次 spawn 从 User slice 重新物化，**无状态丢失**（§6.1 已论证）。

#### 6.2.2 仍然成立的那部分

**平台无法追回已经被 agent 进程读进内存的 key。** `#1693` 与本轮补齐关闭的是「key 文件继续留在盘上、下次仍可用」这个窗口；**已经在跑的进程当下持有的内存副本追不回来**，这仍是 B2′ 的固有属性（上游 spec §5.4 后果③）。

运维语义因此是：**撤销即刻切断后续使用，但不能保证正在进行中的那一次 git 操作失败。**

---

## 7. 部署契约（继承 1a §7）

租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。

1b 新增一条**同部署内**的说明：**同一部署内，两个 agent 是否隔离，完全取决于有没有各自发那条 cap。**

> **精确措辞（2026-08-02，整支终审 K4）**：上一句"否则 cascade 复制会在运维
> 不知情的情况下把它变成假话"曾经写得像是在断言**今天**就有一条可复现的
> 泄漏路径——不是。§1.2 第③点已查证：`resolver.ex:95-108` 枚举的四层
> （`:flavor_base`/`:workspace`/`:user`/`:session`）没有一层是 agent URI，
> 今天不存在"agent A 的 config_dir 被当作 agent B 的参考目录"这条路径。
> §1.2 把目录移出 `config_dir`，为的是让"隔离完全取决于有没有发那条 cap"
> 这句话**不必依赖 `resolver.ex` 那份清单未来也保持现状**就能成立——是把
> 一个今天正确、但系于一处硬编码清单的事实，升级成一个不依赖该清单的
> 结构保证，不是在堵一个已经打开的洞。

写进 ① 与 ③ 的 moduledoc。

---

## 8. 测试

**① 路径权威**
- `path/1` 对同一 agent 幂等；不同 agent / 不同 workspace 互不相等
- 非 agent URI → raise（镜像 `ConfigDir` 的 `raise_agent_uri!`）
- `safe_to_destroy?/2` 对非规范路径返回 false
- **git-identity type 的 authority 函数与 `config_dir_authority/2` 不是同一个函数**（这条是 §1.2 的结构保证，必须钉住；红演示：改成共用 → 断言必须红）

**② 写入机制**
- 写完后私钥 mode == 0o600、目录 mode == 0o700
- `GIT_SSH_COMMAND` 含全部四个开关（逐条断言，不是整串比对 —— 整串比对在加开关时会连带改测试，掩盖删开关）
- known_hosts 未配置 → `{:error, :known_hosts_unconfigured}`，且**目录里没有私钥残留**
- 覆写：连写两次不同 key，第二次内容生效

**③ 编排**
- 无 cap → `{:ok, :none}`，且**没有发生任何 dispatch**
- 有 cap → dispatch target 的 instance **等于 cap 的 instance**（钉住"cap 即指针"）
- 持 `:read_ssh_public_key` cap **不**触发物化（钉住不是"任意 ssh 相关 cap"都算）
- agent 另持若干无关 cap 时，dispatch 的 `ctx.caps` **只含那一条**（钉住 §3.1.1 的窄授权，红演示：改成传全集 → 断言必须红）
- user 无 key → `{:error, :owner_has_no_key}`；user key 状态损坏 → `{:error, {:owner_key_unavailable, _}}`，**两者互不相等**（钉住 §3.1 不得合并）
- 各条错误路径都**不抛异常**（调用方 spawn 不能被它掀翻）

**⑤ 发放 task**
- 发完后 `list_caps_for(agent)` 里有且仅有那一条新 cap，且 `instance == user_uri`
- ~~非 admin 调用被拒~~ —— **2026-08-02 撤回，这行是错的。** 它描述了一个**没有参数可查、也没有先例**的检查。运维 mix task 在本仓库的既定形态是 **admin 等价**：直接先例 `apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex:338` 同样用 `Ezagent.Entity.User.admin_uri()` 作签发者且不查调用方，其 moduledoc 明写认可的面就是「Behavior / admin LV / **mix tasks**」。（`host_login_adopt.ex` 之所以有 `require_host_operator/1`，是因为它从**运行时路径**接收 `installer_uri` 参数 —— 有一个外来主体可查；mix task 没有。）
  **真正的边界是"谁能在这台机器上跑 mix task"，即宿主 shell 访问权**，不是 VM 内的 cap 检查。这与当前安全姿态一致（不防 in-VM 恶意代码）。
- **已持有指向别的 User 的 `read_ssh_key` cap 时不得静默发放**（Task 3 复审顺出的事故场景：运维换身份忘了先撤旧的 → agent 以错误身份 push 且全程静默）。消费侧 Task 3 已 fail loud（`{:error, {:ambiguous_git_identity, _}}` 且清盘），发放侧再挡一道。指向**同一个** User 的重复发放是幂等的，不算冲突

**⑥ 接线**
- cc PTY 与 cc headless 两条 `cmd_env` 构建路径，在 ③ 返回 `:none` 时 env **逐字节不变**（钉住关闭态零影响）

**Gate**：`mix ci.fast`（显式 `timeout: 300000`，`POSTGRES_PORT=15432`；**被 kill 的运行不算通过**）。

---

## 9. 明确不在 1b 范围内

- **codex / py / curl flavor 接线** —— 机制在 core，各 flavor 一行接入，按需再做
- **World UI 发放入口** —— 1b 只有 mix task
- **一键撤销命令**（见 §6）
- **repo 从哪来** —— 1a 立的约束：key 投递与工作目录来源**解耦**。1b 只管身份，不碰 `GitRunner` / `Provisioner` / `ChangeCollector` / `StageRunner` / `git_workflow`
- **per-repo deploy key**、key 轮转、导入已有私钥（1a §9 已排除，此处不复活）
- **at-rest 封存** —— 1a §6，归统一安全轨
- **A1 与 B2′ 的运行期切换机制** —— 见 §10

---

## 10. 一条留给 A1 的已知约束（现在不建，但必须记下）

用户提出 B2′ 与 A1 应当是两种**可切换**的策略。上游 spec §8.3 的结论是：**可以按任务/按仓库二选一，绝不叠加**。

1b 增加一条硬约束：

> **切换粒度不能低于 key 的作用域。**

1a 已定 key 归 **User**。因此只要一个 session 里有**一个**仓库走 B2′，key 就进了该 agent 的文件系统 —— 此刻它手里的 key 覆盖**该 user 的所有仓库**。那些"本次走 A1"的仓库，隔离**同时失效**。

所以 A1 落地时，**按仓库切换是假的**；真实的最小切换粒度是 **agent**（= 那条 cap 的粒度，正好就是 §1.1 建的开关）。

**1b 不建切换机制**（A1 尚不存在，YAGNI）。只留这条约束，并且 §1.1 的 cap 开关天然就是正确粒度 —— A1 落地时不需要改开关，只需要不发。

---

## 11. 需回填上游 spec

`docs/superpowers/specs/2026-07-31-git-credential-model-options-design.md` §8.3 讨论共存/切换时，**未指出"切换粒度 ≥ key 作用域"**。按 §10 回填一段。
