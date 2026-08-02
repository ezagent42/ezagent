# Agent SSH 凭据 — 任务 1a 设计（User SSH 身份）

**日期：** 2026-08-01
**状态：** 已实施（见分支 `feat/agent-ssh-credential`，整支终审 2026-08-02）
**基线：** `4edd3cfed`（main）
**上游 spec：** `docs/superpowers/specs/2026-07-31-git-credential-model-options-design.md` §8.4（形态 B2′、任务划分）
**决策人：** gaga（形态 B2′ 由 Allen 定）

---

## 0. 一句话

给 **User** 一个 SSH 身份：**生成 → 存 → 经 cap 授权读 → 撤销**。挂 User Kind，跟既有的 `UserTokens` / `ApiKeys` 同构。

**1a 交付一个完整但暂无消费者的能力** —— 把 key 交到 agent 手里是 1b，平台自己用是任务 2（A1）。因此 **1a 的验收是单元/集成测试，不是端到端 git 操作**。

---

## 1. 为什么切出 1a

上游 spec §8.4 原本把任务 1 当成一个整体。后续分析发现凭据面可以再切一刀，且这一刀**决定了哪部分工作在转向 A1 后不白费**：

| 部分 | B2′ 用 | A1 用 |
|---|---|---|
| **① key 存储 + 归属 + cap-gated read**（= 本文 1a） | ✅ | ✅ |
| ② 物化进 agent config_dir + 给 agent 的 `GIT_SSH_COMMAND` + cascade/grant（= 1b） | ✅ | ❌ 作废 |
| ③ provision 入口 + push stage + 完成信号 + 给平台 git 的 `GIT_SSH_COMMAND`（= 任务 2） | ❌ | ✅ |

> **⚠️ 已被取代（2026-08-02，整支终审）**：上面②行"物化进 agent config_dir
> + cascade/grant"的说法已被 1b 落地否决——`2026-08-02-agent-ssh-credential-1b-design.md`
> §1.2 查证后判定 git 身份**不进** `config_dir`，改用独立的
> `Ezagent.Sandbox.GitIdentityDir`（`resource://<ws>/git-identity/<agent>`，
> 三条理由见该文 §1.2），也不经既有 cascade/grant 铸造机制。②行的"物化进
> agent 目录"这个**定性**（1b 属于"给 agent 一份可用凭据"这一类工作）仍然
> 成立，只是**载体**变了。

**①是真正的共享底座。** 上游 spec §8.4 写的「最简 B2′ 不为 A1 预建底座」在这个切分下**不再成立** —— 需回填修订。②才是"把 key 交给 agent"这个决定的落地，也是 agent 权限变大的那一步，因此值得单独成为一个可独立决定的开关。

---

## 2. 归属模型 — key 归 User，不归 Agent

**已定（gaga，2026-08-01）：归属 User。**

理由不是偏好，是运维现实：agent 是**动态物化**的（session 创建时按 recipe 生成）。若 key 归 agent，则每物化一个 agent 就要去 GitHub 手工加一次 public key —— 用不了。

归属 User 同时与既有的 `UserTokens` / `UserCredentials` / `ApiKeys` 同构，它们都挂在 User Kind 上、都住 `ezagent_domain_identity`。

### 2.1 与既有凭据 cascade 的关系

`Ezagent.Credential.*`（core）是 **#17 agent-provisioning-cascade** 的专用轨，**是活的，不是死代码**：

- 覆盖策略 `pick_credential_source/1`（resolver.ex:153-213）：**explicit（agent 级）> user > workspace-shared > fail-loud**
- 语义规则：**absent 才 fall through；present-but-unavailable 一律 fail loud**（`:explicit_source_unavailable` / `:user_source_unavailable` / `:workspace_source_unavailable`）
- 配置入口活着：world UI `credential_cascade.ex:45` + `mix ezagent.credential.adopt`
- 生产调用活着：`CascadeRuntime.rehydrate_respawn_data` 被 cc_agent.ex:912 / codex_agent.ex:750 / codex_remote_agent.ex:352 调用

**但它有一个硬约束：source 必须是 agent。** `GrantCap.read_cap_for/1` 写死 `cap(:agent, Ezagent.ActionSet.Sandbox, :read, source, ws)`，读的是源 agent 的 sandbox slice。整条轨是为「agent B 读 agent A 的凭据」设计的。

**因此 1a 不复用这条 cascade 的载体，但沿用它的错误语义**（见 §5）。理由：

1. 复用载体意味着「为一把个人 SSH key 造一个源 agent」—— agent 在本系统中是会做事的 principal，当密钥容器用名不副实，且 UI 上无法向用户解释
2. **更关键**：若 key 只活在 agent 的 sandbox 里，**A1（平台持 key、agent 不持）就实现不了**。挂 User Kind 是唯一能同时支撑 B2′ 与 A1 的载体

---

## 3. 架构与模块边界

**Tier：`domain`（`ezagent_domain_identity`）。** 依据 P9「reads what data decides tier ownership」—— 它读的是 User 的凭据数据，而该 app 已经是 User Kind 凭据类 ActionSet 的家（同目录已有 `user_tokens.ex` / `user_credentials.ex` / `api_keys.ex` / `credential_grant.ex` / `user_default_credential_source.ex`）。

**不新建 app，不进 core**（core 是 primitives，SSH 身份是领域数据）。

### 3.1 新模块

```
Ezagent.ActionSet.UserSshIdentity
→ apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex
```

`use Ezagent.Lifecycle`（**唯一的开发者面** —— 禁 `use Ezagent.ActionSet` / `state_slice` / `init_slice` / `invoke/4`，Phase C gate `mix ezagent.check_invariants.lifecycle` 会 HARD-fail），挂 User Kind，与 `UserTokens` 完全同构。

### 3.2 两容器划分

| 容器 | 内容 |
|---|---|
| `state`（持久，框架自动快照） | `public_key`、`fingerprint`、`private_key`、`comment`、`created_at` |
| `transients`（永不持久） | **空** |

**transients 为空是一个正向信号**：没有 PID / port / ETS / 连接需要在 `activate/2` 重建，因此**结构上不可能出现 #110/#113/#114 那一族「fresh works, restart doesn't」的 bug**。`activate/2` 可省略或返回 `{:ok, %{}}`。

### 3.3 Action 面（四个）

```elixir
action(:generate_ssh_key,
  args: %{comment: :string},                # 可选；缺省时由框架派生自 ctx.self_uri
  returns: %{public_key: :string, fingerprint: :string},
  caps: [{:generate_ssh_key, kind: :user}],
  modes: [:call])

action(:read_ssh_public_key,
  args: %{},
  returns: %{public_key: :string, fingerprint: :string},
  caps: [{:read_ssh_public_key, kind: :user}],
  modes: [:call])

action(:read_ssh_key,                      # Allen 所称的 ssh.read
  args: %{},
  returns: %{private_key: :string},
  caps: [{:read_ssh_key, kind: :user}],
  modes: [:call])

action(:revoke_ssh_key,
  args: %{},
  returns: %{revoked: :boolean},
  caps: [{:revoke_ssh_key, kind: :user}],
  modes: [:call])
```

**公钥读与私钥读拆成两个 action、两条 cap** —— UI 回显公钥是常规操作，取出私钥是敏感操作，不共用一条 cap。这是最小权限的直接落地。

### 3.4 `known_hosts` 不在本模块

> **范围修正（实施时）：`known_hosts` 移出 1a，归 1b。** 1a 不发起任何 git
> 连接，known_hosts 在 1a 内没有可验证的对象 —— 放进来等于交付一段未经
> 验证的配置写入代码。它是 1b / 任务 2 的前置，跟着消费者走。本节描述的
> 做法（部署配置 + 刷新用 mix task + 不做运行时网络调用）**不变**，只是
> 落在 1b。

`known_hosts` 是 **provider/主机事实**（github.com 的主机公钥），与用户无关，**不是 User 数据**。

**做法：部署配置 + 一个刷新用的 mix task**（从 `https://api.github.com/meta` 的 `ssh_keys` 拉，写进部署目录）。**用 key 时不做运行时网络调用。**

> **⚠️ 已被取代（2026-08-02，整支终审）**：刷新 mix task 最终**不拉**
> `api.github.com/meta`——那是 GitHub-only 的主机发现，1b 落地时选了
> 主机无关的方案：`mix ezagent.git.known_hosts <host> --out <path>` 跑
> `ssh-keyscan`（`2026-08-02-agent-ssh-credential-1b-design.md` §4.1），支持
> 任意 git 主机（GitHub / Forgejo / 自建），不锁定单一 provider。「部署配置
> + 刷新用 mix task + 用 key 时不做运行时网络调用」这个**形态**结论不变，
> 只是**拉取源**变了。

两条理由：

1. 符合「一律按局部节点逻辑实施」（联邦 Decision #48 形态 A：每节点自治、share-nothing）—— 不引入运行时外部依赖
2. 避开「哪个 plugin 拥有 known_hosts」的归属问题（GitHub / Forgejo / 自建主机各有各的）

**这条不能省**：不配就得用 `StrictHostKeyChecking=no`，那 agent 会静默连上任何冒充主机 —— 属于「逻辑写错导致无意破坏」，是必须挡的事故面。

---

## 4. 数据流

```
① 生成   world UI「生成 SSH 密钥」→ dispatch :generate_ssh_key（cap 门）
         → System.cmd("ssh-keygen", ["-t","ed25519","-N","","-C",comment,"-f",tmp])
         → 读出私钥 + 公钥 → 写 state → 立刻删临时目录
         → 只返回 public_key + fingerprint（私钥不出这个 action）

② 回显   :read_ssh_public_key → 从 state 读公钥/指纹

③ 使用   :read_ssh_key（敏感 cap）→ 返回私钥给调用方
         （1a 内无调用方；1b / 任务 2 才是消费者）

④ 撤销   :revoke_ssh_key → 清除 state 中的**全部身份字段**
         （public_key / fingerprint / private_key / comment / created_at）
         → 之后 read 必须得 :absent 而非 :unavailable
```

### 4.1 为什么用 `System.cmd` 而不是 `OsProcess`

**X/Y 溯源**：Y 是「用哪个跑子进程」；X 是「**这个子进程的风险特征是什么**」。

**订正(2026-08-01，task-1 review D1)**：原稿在这里说 `ssh-keygen` "没有 `GitRunner` 要防的那些风险(网络挂死、大输出、孤儿进程树)"——这句话**错了**。风险不是"慢"，是"卡死";本地子进程一样会卡(二进制被换、文件系统 stall、熵不足),卡住就会无限期占住调用方的 GenServer(见 I2 / task-1-findings.md)。结论不变,理由改写如下。

`ssh-keygen` 是**本地、无网络、输出固定小**的命令,所以不需要 `OsProcess` 的 `pid_file` + 输出上限那一整套——但"卡死"风险是真实存在的,用 `Task.async` + `Task.yield` 限时解决(人类裁决,I2),并接受超时后 `Task.shutdown` 只能杀掉 Elixir 任务进程、底下的 ssh-keygen 子进程可能变孤儿这一已知取舍(极低概率事件,为它引入 `OsProcess` 的 pid_file + orphan reaping 那套重机制不划算)。

- `Ezagent.Runtime.OsProcess` 只有 `spawn/2`，是为**长命 sidecar / PTY** 设计的，无 run-and-collect
- `System.cmd` 在 core 内已有先例：`stress_metrics.ex:208`、`pid_file.ex:240`（都用它跑 `ps`）

**结论(不变)：用 `System.cmd` + `Task.async`/`Task.yield`/`Task.shutdown` 限时，不提取 `GitRunner` 的 run-and-collect，不动 `OsProcess` —— 不新建抽象。**

argv 中只有路径与 `-N ""`（空 passphrase 标志，不是密钥），**无敏感内容**，故 `/proc/<pid>/cmdline` 世界可读不构成泄漏。

### 4.2 为什么不用 OTP 自带的密钥生成

实测（2026-07-31）：OTP 能**解析** OpenSSH 私钥（`:ssh_file.decode(key, :openssh_key_v1)` 成功），但**编码**方向，试过的几种 key 表示（`{:ed_pub, :ed25519, pub}` / `{:ed_pri, :ed25519, pub, priv}` × `:openssh_key` / `:ssh2_pubkey` / `:openssh_key_v1`）**均未成功**。不排除还有正确形状未试到，但结论不受影响：`ssh-keygen` 一行即得标准 `-----BEGIN OPENSSH PRIVATE KEY-----` 与 `ssh-ed25519 AAAA…`，正确性无疑。

---

## 5. 失败语义

**四个 action 全部 `modes: [:call]`，没有 fire-and-forget 路径**，因此失败一律同步 `{:error, reason}` 返回，**不需要 DLQ / telemetry 兜底**（符合 CLAUDE.md 的 `:call` mode 约定：`{:error, _}` 同步返回）。

### 5.1 absent ≠ unavailable（沿用既有语义）

| 情况 | 判定条件（精确） | 返回 |
|---|---|---|
| 没有身份 | state 中**无任何身份字段** | `{:error, :ssh_identity_absent}` |
| 有身份但不完整 | state 中**存在身份记录**（如 `public_key` / `created_at` 在）**但 `private_key` 缺失或形状不合法** | `{:error, :ssh_identity_unavailable}` |

**为什么明文存储下仍需要 `:unavailable`**：它覆盖的是**部分写入**与**迁移遗留**（有公钥无私钥）这类真实状态。且当统一安全轨日后接手 at-rest 加密时，**解封失败**会成为这一类的主要来源 —— 分类从第一天就位，那时无需改调用方。

1a 只有 user 一层、没有 fall-through，但**这个区分必须从第一天就有** —— 否则将来接入覆盖策略（§2.1）时会出现静默降权：一个损坏的身份会被误当成"没配"而 fall through 到下一层，正是既有 `pick_credential_source` 明令禁止的静默降权。错误名刻意对齐既有的 `:user_source_unavailable`。

### 5.2 六条具体处理

**① `ssh-keygen` 失败 → `{:error, {:keygen_failed, reason}}`**
命令不存在 / 非零退出 / 输出不合预期，全部显式返回。**绝不返回 `:ok` 而实际没生成**（CLAUDE.md「不要 silent 失败」）。

**② 已有身份（任一身份字段存在）时再次 generate → 拒绝，`{:error, :ssh_identity_exists}`**（2026-08-02 订正——原文写「已有 key」，与 §5.1 的判定口径矛盾，见下；task-2-findings-round2.md R1）

判定依据与 §5.1 一致：**是否存在任一身份字段**（`public_key` / `private_key` / `fingerprint` / `comment` / `created_at`），**不是**「两个 key 字段是否都缺」。静默覆盖会让用户已在 GitHub 配好的公钥**突然失效**，且旧私钥已不可回退 —— 这是「逻辑写错导致无意破坏」的教科书案例，属于必须挡的事故面。metadata-only 状态（只剩 `fingerprint`/`comment`/`created_at`，两个 key 字段皆 nil）下虽然没有可用的 key，但有证据表明曾经存在过一份身份、用户很可能已把对应公钥注册在 provider 上——同样必须挡下，不能因两个 key 字段为 nil 就静默放行覆盖。**要求先显式 `:revoke_ssh_key` 再生成**：多一步操作，换掉一整类「我的 git 突然不能用了」的事故。

**③ 临时目录**
每次调用一个随机名临时目录；读出内容后**立刻 `File.rm_rf`**，不依赖进程退出或 GC；异常路径同样清理（`try/after`）。

**④ `comment` 含控制字符 → 拒绝，`{:error, :invalid_comment}`**（task-1 round-2 review 补，2026-08-01）

`comment` 原样传给 `ssh-keygen -C <comment>`，在调用前校验，判定条件是含 `\n` / `\r` / `\0` 三者之一：
- 含 `\n` / `\r`：会在 `.pub` 文件里提前结束首行并追加调用方可控的第二行 —— 一条语法合法但未被指纹覆盖的额外 `authorized_keys` 记录。
- 含 `\0`：不同 BEAM/libc 组合下行为不一致（实测 OTP 28 + Elixir 1.19 上 `System.cmd/3` 静默把该 argv 元素截到 NUL 处，而非抛错）；即便不抛错，也会导致持久化的 `comment` 字段与 ssh-keygen 实际写入公钥文件的注释不一致 —— 同属「不要 silent 失败」要挡的一类。

三者均在调用 `ssh-keygen` **之前**拒绝，不依赖后续解析兜底（防御深度：`keygen/1` 内部另外只取 `.pub` 输出首行，见实现注释）。

**⑤ `:read_ssh_public_key` / `:read_ssh_key` 的 absent/unavailable 判定落实**（Task 2，2026-08-01 补；2026-08-02 订正——原文与 §5.1 矛盾，见下）

两个 action 都应用 §5.1 的判定依据：**是否存在任一身份字段**（`public_key` / `private_key` / `fingerprint` / `comment` / `created_at`），**不是**「两个 key 字段是否都缺」。五个字段皆为 nil → `{:error, :ssh_identity_absent}`；任一字段存在，但本 action 需要的字段缺失或形状不合法 → `{:error, :ssh_identity_unavailable}`。

`:read_ssh_public_key` 需要的字段是 `public_key` 与 `fingerprint`——两者都是合法字符串才成功返回；任一缺失、但存在其它身份字段（例如只有 `private_key`，部分写入）时归 unavailable，**不是** absent。（订正：之前这里错误地断言"公钥字段本身要么完整要么不存在，没有公钥损坏的中间态"——这个前提不成立，`private_key` 在而 `public_key` 缺失就是一种真实可达的中间态，且原判定不校验 `fingerprint`，会返回违反本 action `returns` 声明的残缺结果。）

`:read_ssh_key` 需要的字段是 `private_key`（合法形状 = 以 OpenSSH 私钥头开头）。

两个错误原子均已在 §5.1 声明；这里是把该判定落实到具体 action 的实现条件，没有引入新原子。

**⑥ `:revoke_ssh_key` 无错误路径，幂等返回 `revoked` 布尔值**（Task 2，2026-08-01 补）

`:revoke_ssh_key` **不返回 `{:error, _}`**：本来就没有身份时视为幂等成功，返回 `revoked: false` 且不产生任何 state 变更、不留审计；有身份时清除全部身份字段（公钥/私钥/指纹/comment/created_at）并返回 `revoked: true`。清除的必须是**全部**字段而非只清私钥——只清私钥会让之后的 `:read_ssh_key` 落进 `:ssh_identity_unavailable`（"有公钥无私钥"的形状）而不是期望的 `:ssh_identity_absent`，见 §8 测试列表最后一条。

### 5.3 审计

`:generate_ssh_key` / `:revoke_ssh_key` / **`:read_ssh_key`** 各带一个 `{:emit, ...}` effect（对齐既有的 `{:emit, :default_credential_source_set, ...}`）。

**`:read_ssh_key` 也 emit** —— 「谁在什么时候取走了私钥」是这条线上最值得留痕的事，且成本极低。
`:read_ssh_public_key` 不 emit（高频、非敏感）。

---

## 6. at-rest：明文落 snapshot（有据可查的延后）

**1a 不做封存**，与既有凭据轨保持一致。

实证：
- `apps/ezagent_core/lib/ezagent/snapshot/*.ex` 与 actor 的 snapshot 中 `encrypt|seal|cipher` **零命中** → snapshot 明文落库
- `:api_keys` slice 写入路径亦无封存
- `SensitiveSliceRead` 是**读侧**保护（限制跨 actor 读哪些 slice），**不是存侧加密**
- `SealedEnvelope` 仅被 `provider_connection`（OAuth token）与 forgejo 使用 —— 是更晚、更严的车道，不是全局标准

依据 CLAUDE.md 安全姿态原文：

> 实施功能时**不要内联引入 caps 正确性以外的安全代码**。其它安全关切拆到**统一/中央机制**解决，不在功能 PR 里逐个做。

明文落库属于**攻击面**（需有人能读 DB），不属于「逻辑写错导致无意破坏」的事故面。给 SSH 单独加一套既有凭据轨都没有的封存，正是姿态禁止的「在功能 PR 里内联引入安全代码」。

**附带收益**：`SealedEnvelope` 住在 `ezagent_domain_provider_connection`，而该 app **依赖** `ezagent_domain_identity`（mix.exs 实证）—— identity 反向依赖即循环依赖。不做封存也就绕开了「把 `SealedEnvelope` 提到 core + 迁移 `EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID` 配置」这个架构决策，关键路径上少一次 review。

> **⚠️ 显式记录，不得静默接受**：这不是判断 SSH 私钥不值得封存。DB 泄漏的**暴露类别**未变，变的是**严重度** —— SSH 私钥泄漏 = 仓库写权限，api_keys 泄漏 = LLM 花费。**统一安全轨接手 at-rest 加密时，SSH 私钥应排在 api_keys 之前。**

---

## 7. 部署契约（实施时须显式引用）

来自上游 spec §8.2.1：租户隔离在本项目靠**不共享部署**实现，不是容器内隔离。

> **互不信任的租户各自一套 ezagent 部署**（workspace = 部署单元）。同部署内的多 workspace 仅用于同一 operator 的多环境（staging / prod / demo）。**SSH key 的隔离依赖这条契约。**

代码里没有任何东西强制这条契约 —— 它是运维约定。实施时把它写进模块 moduledoc，避免后人误以为有结构保证。

**socialware / 匿名用户是另一条线**（上游 §8.2.2）：防线在 **caps 分配**层 —— 不给匿名用户能影响的 session 里的 agent 发 SSH 相关 cap。`GitTaskAccess` 与本模块的 action 都要 cap，**不发就完全碰不到**。

---

## 8. 测试

抄 `UserTokens` 的测试形态。

**功能**
- generate → 返回公钥 + 指纹；state 中有私钥；**返回值中没有私钥**
- generate 二次 → `{:error, :ssh_identity_exists}`
- generate 遇 metadata-only 状态（两个 key 字段为 nil，其余身份字段仍在）→ 同样 `{:error, :ssh_identity_exists}`（task-2-findings-round2.md R1）
- read_ssh_public_key → 公钥 + 指纹
- read_ssh_key → 私钥，且产生审计 emit
- 无 key 时 read → `{:error, :ssh_identity_absent}`
- state 损坏时 read → `{:error, :ssh_identity_unavailable}`
- revoke → 清除；之后 read 得 `:absent`（**不是** `:unavailable`）
- `ssh-keygen` 不可用 → `{:error, {:keygen_failed, _}}`

**授权**
- 无 cap 的 dispatch 被 step-5.5 拒
- 持 `:read_ssh_public_key` cap **不能**调 `:read_ssh_key`

**卫生**
- 生成后临时目录不存在（happy path 与异常路径各一条）

**不做**：端到端 git 操作 —— 1a 无消费者。

**Gate**：`mix ci.fast`（显式 `timeout: 300000`；被 kill 的运行不算通过）。

---

## 9. 明确不在 1a 范围内

- 物化进 agent 专属目录、`GIT_SSH_COMMAND`（= **1b**；**⚠️ 已被取代
  （2026-08-02，整支终审）**：具体载体不是 config_dir、也不经 cascade/grant
  铸造——1b 落地用独立的 `Ezagent.Sandbox.GitIdentityDir`，见上文 §1 表格
  ②行的订正）
- provision 入口、push stage、agent 完成信号（= **任务 2 / A1**）
- `GitRunner` / `Provisioner` / `ChangeCollector` / `StageRunner` / 整个 `git_workflow` 的任何改动
- key 轮转（个人 key，秉持 user/agent 自己负责）
- 导入已有私钥（可选的次要入口，若做需额外确保私钥不进日志/错误信息）
- per-repo deploy key 管理、审计归属补救、ssh-agent 进程管理
- at-rest 封存（§6，归统一安全轨）
- `known_hosts` 配置与刷新 mix task（移到 1b —— 见 §3.4 范围修正）

---

## 10. 需回填上游 spec 的一处

`docs/superpowers/specs/2026-07-31-git-credential-model-options-design.md` §8.4 写的

> 「最简 B2′ **不为 A1 预建底座** —— 共享的只剩本来就存在的凭据轨。」

**在 1a/1b 切分下不再成立**。1a（key 存储 + 归属 + cap-gated read）是实打实的共享底座，A1 与 B2′ 都要；真正不共享的是 1b。实施 1a 时一并修订该段。
