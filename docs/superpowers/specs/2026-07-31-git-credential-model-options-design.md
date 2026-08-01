# Git 凭据模型选型 — 四形态对比（A0 为已出局基线）+ Plan A 三条 NO-GO 重核

**日期：** 2026-07-31
**状态：** 形态已定 = **B2′**（Allen）；实施划分已定 = **最简 B2′ → A1（provision 归 A1）**（gaga，见 §8.4）。本文仍不实施任何形态。
**基线：** `c0cb35e69`；**修订基线：** `4edd3cfed`（PR #1677 合入后，2026-07-31）
**决策人：** Allen
**触发：** Allen 提出方向转为「走 git ssh，走 CLI」；重估前先把证据摆齐

**已定输入（gaga，2026-07-31）：支持私有仓库是确定需求。** 因此 **A0（今天的实现）出局**——它不支持私有仓库不是可修补的缺口，而是其定义性质（§3 形态 A0）。A0 在本文保留为**基线与参照系**：它标出「离开它要放弃什么」，是四个候选的对照零点，不再是候选项。

---

## 0. 这份文档回答一个问题

> agent 要能操作**私有仓库**并**推送**，凭据应该以什么形态存在、供给到哪一层？

四个候选形态（A1 / A2 / B1 / B2）+ 一个已出局基线（A0），一张对比表，加上 Plan A 当年三条 NO-GO 的当日实测复核。本文**不**推进实现，也不修改任何运行时语义。

**关键提醒（本文最重要的一句）**：候选里的「形态」（凭据供给到哪层）与「传输」（SSH vs HTTPS）是**两个正交决定**。目前讨论中这两者被捆在一起，本文刻意拆开。

---

## 1. 当前状态与它的由来

### 1.1 现状（实证）

| 事实 | 证据 |
|---|---|
| 只支持公开仓库 | `GitRunner.prepare(%{visibility: :private})` → `{:error, :private_checkout_not_supported}`（git_runner.ex:69）|
| 传输只允许无 userinfo 的 HTTPS | `validate_https/1`（git_runner.ex:604-618）；其余 scheme → `:https_remote_required` |
| remote URL 由系统构造，外部无法注入 | `anonymous_remote(host, owner_path)`（provisioner.ex:342）|
| 结构上不可能认证 | `GIT_CONFIG_NOSYSTEM=1` / `GIT_TERMINAL_PROMPT=0`（git_runner.ex:16）+ 每条 argv 强制 `-c credential.helper= -c core.askPass=`（:17）|
| 无 push、无 commit、无 add | 子命令全集：`clone --bare` / `fetch` / `show-ref` / `rev-parse` / `worktree` / `branch -f` / `status` / `remote get-url` |
| 写回全走 provider REST API | GitHub Git Data（github_adapter.ex:364/391/422/460/513）；Forgejo `/contents`（forgejo_adapter.ex:412/634）|
| agent 不感知 git，也无 git tool | cc 插件中 `GitTaskAccess`/`provision_workspace`/`create_change_request` **零命中**；驱动方是 `StageRunner` 三段状态机（stage_runner.ex:154-158）|
| 全仓 `lib/` 无任何 SSH 代码 | `ssh://\|git@\|GIT_SSH\|ssh_key\|deploy_key\|id_rsa\|known_hosts` 零命中 |

### 1.2 由来

限制来自 Plan A（2026-07-16）的三条 NO-GO（`2026-07-16-git-provider-v1-a-decisions.md:13-18`）。

限制被**如实披露**过多次：设计文档 `2026-07-15-git-provider-v1-design.md:38-40`、Plan A 决策文档、当日交回件 `docs/together/2026-07-16/returns/gaga-git-provider-plan-a.md:25` 均写明 "public-repository-only"。

但有两处流程缺口，记录在此供后续避免：

1. **该范围决定从未进 Decision Log。** grep `GLOSSARY.md` 中 `git provider` / `public repo` / `private repo` / `checkout`：零命中。一个移除整类产品能力的决定只活在 Plan 级工程文档里。
2. **Plan A 决策文档状态至今为 "architecture/security review requested"**，而其 §7 写明 "Plan B: eligible to write **after review approves this interface**"。未找到批准记录（不作推断，可能口头进行）。

---

## 2. Plan A 三条 NO-GO 重核（2026-07-31 实测，基线 `c0cb35e69`）

**结论：三条只剩一条成立。**

| NO-GO | 2026-07-16 判据 | 2026-07-31 实测 | 判定 |
|---|---|---|---|
| ① 加密 secret 后端缺失 | "只有明文 application settings；`20260530000000_app_settings.exs` 明确记录无 at-rest 加密" | `Ezagent.ProviderConnection.SealedEnvelope` 存在：AES-256-GCM + 可轮转 keyring + purpose/aad 绑定；被 6 个模块使用（forgejo `credential_record` / `credential_backend` / `oauth_app`，provider_connection `exchange` / `reconciliation`）| **已失效** |
| ② SSH 私钥 parser 缺失 | "无 OpenSSH 私钥导入/解析依赖或模块" | OTP 28 自带：`:ssh_file.decode(key, :openssh_key_v1)` 直接解析 OpenSSH ed25519 私钥成功（一次性测试 key，已删除）| **已失效，且当年即为误判** |
| ③ agent-inaccessible SSH broker 隔离缺失 | 同 UID 可读 mode-0600 文件与 `/proc/<pid>/environ` | 探针 `os_process_secret_isolation_probe_test.exs` 重跑：`2 tests, 0 failures`（结论复现）；`OsProcess` 中 `uid\|gid\|namespace\|bwrap\|unshare\|setuid\|sandbox\|cgroup` 命中数 **0** | **仍然成立** |

### 2.1 ② 为何是误判

当年判据是「**仓库里**没有这个模块或依赖」，据此推出「平台没有这个能力」。但 OTP 标准库 `:ssh_file` 一直提供该能力，无需任何外部依赖。这条 NO-GO 从提出之日起就不成立。

### 2.2 ①③ 的适用范围被过度外推

三条 NO-GO 中，**私有仓库 HTTPS 检出只撞第三条**：

- ① 与写路径无关 —— 写路径本来就必须存储并使用 token 才能工作；且 `SealedEnvelope` 落地后该条已死。
- ② 是关于 SSH 密钥的，与 HTTPS token 无关。
- ③ 确实适用。但它是从「**一把长期有效、全仓库读写的 SSH 私钥交给常驻 broker**」实测推出的，被原样套用到「**一个 1 小时、单仓库、只读的 token 出现在 git 子进程 env 中数秒**」——两者风险不同量级，中间没有重新论证。

**方法教训（建议纳入方法轨）**：从最坏情形实测得到的禁令，套用到更轻情形前必须逐条重新论证适用性。

---

## 3. 候选形态（A1 / A2 / B1 / B2；A0 为已出局的对照零点）

### 3.0 谱系

```
A0 ──────── A1 ──────── A2 ──────── B1 ──────── B2
今天         平台 push    agent 可请求  full-shell   full-shell
                                      + 短命 token  + SSH key

凭据位置   仅 BEAM  →  平台子进程  →  平台子进程  →  agent 进程 →  agent 进程 + 磁盘
功能       只读公开  →  能写私有   →  + agent 自主 →  + 完整 git →  + 无 API 主机
四后果     4/4 满分 →  4/4 满分   →  ①②④ 满分   →  ①半④半    →  基本全丢
                      └── A1/A2 采用 fd-helper 投递凭据时（§5.4）──┘
```

**每向右一格，都是以某几条后果换取功能。** A0 在安全维度上是最优的那一端，但它**不支持私有仓库**——既然私有仓库已定为需求，**「不动」不是可选项**，问题只剩「向右移动几格」。A0 在下文保留为对照零点：它量化了每向右一格要放弃什么。

统一术语：
- **平台侧 git** = `GitRunner` 用固定 argv 计划拉起的 git 子进程（凭据可注入其 env）
- **agent 侧 git** = agent sidecar 自己在 shell 里跑的 git（与平台侧不同进程、不同 env）
- **本地 git** = 不触网的 git 操作（log/diff/status/add/commit/branch/rebase/checkout/stash）
- **网络 git** = 触网的 git 操作（clone/fetch/push）

### 形态 A0 — 凭据不出 BEAM（**今天的实现；已出局，保留为对照零点**）

`StageRunner` 状态机驱动全部 git 生命周期；检出匿名无凭据；网络写操作**不由 git 完成**，改由 provider REST API 完成，token 仅在 BEAM 进程内经 Req 使用（插件私有 `defp`）。

- **agent 体验**：只改文件，不感知 git，无任何 git tool。
- **凭据位置**：**仅 BEAM 进程内，从不进入任何 OS 子进程**。这是 A0 的定义性质。
- **保住**：四条后果全部（§5.4）。跨租户泄漏**真正为零**——同 UID 的被动读取（environ / 文件 / argv）在 git 这条线上一无所获。
- **失去**：§1.1 全部——公开仓库限定、无 push、upsert-only envelope、squash 单 commit、100 文件 / 1MB / 5MB 上限、无删除 / 无二进制 / 无权限位、agent 一旦 commit 则 `:no_changes_collected`。
- **新建**：0（现状）。

> **关键推论**：「只支持公开仓库」不是 A0 的缺陷，是 A0 的**逻辑必然**。私有仓库检出要求 git 子进程能够认证，而 A0 的定义就是凭据不出 BEAM，故私有仓库在 A0 下**在定义上不可能存在**。
>
> Plan A 三条 NO-GO 实际论证的是「我们不能离开 A0」，而非「私有仓库本身有何特殊风险」。这解释了 §2.2 的过度外推是如何发生的。

### 形态 A1 — 平台全驱动（A0 向右一格）

`StageRunner` 状态机驱动全部 git 生命周期，把 `collect_workspace_changes` 那一步替换为平台侧 `git push`。

- **agent 体验**：与今天完全一致——只改文件，不感知 git。可选地允许它本地 commit。
- **凭据位置**：仅平台侧 git 子进程 env。
- **保住**：CapBAC 完整；**remote 与 refspec 由 task policy 钉死**（这才是安全性的来源，见 §8.1）；碰不到任何其它 ref；审计可归属到每次 dispatch。
- **失去**：agent 无自主权——何时交付、交付几次由状态机决定。
- **新建**：push 阶段 + 凭据供给 seam。

### 形态 A2 — agent 可请求（受控 argv）

在 A1 基础上，把若干动作暴露为 agent 的 tool（例：`push_current_branch` / `refresh_from_upstream` / `open_change_request`），agent 自主决定时机。argv 仍由平台拼装。

- **agent 体验**：本地 git 全部可用（无需凭据，worktree 就在文件系统上）；网络 git 通过调用 tool 请求平台代做。
- **凭据位置**：同 A1，**从不进入 agent 进程**。
- **关键性质**：这条分界线**不是靠禁止形成的，是靠 agent 拿不到凭据自然形成的**——agent 直接跑 `git push` 会因无凭据而失败，无需任何拦截逻辑。
- **保住**：与 A1 相同的全部约束。`allowed_head_ref` 在有凭据后**依然可执行**，因为 ref 来自 `local_branch_ref`（provision_id 的 sha256 派生，git_runner.ex:57-65），agent 碰不到该参数。
- **失去**（相对 full-shell）：不能自行 fetch 上游、不能推多条分支做 stacking、不能 `pull --rebase`、跨仓库子模块失败、不能用 `gh` CLI。每一项都可通过「新增一个 action」解除——**默认收紧、按需放开、每次放开都有名字**。
- **新建**：A1 的全部 + agent git tool 面（cc 插件侧目前为空，需从零接线）+ 对应 caps。

### 形态 B1 — full-shell + 短命 per-repo token

agent 在自己 shell 里跑完整 git；凭据是**单仓库、按 profile、1 小时**的 installation token，经 credential helper 按需注入、不落盘。

- **agent 体验**：与人类开发者完全一致——commit / branch / rebase / stack / push 全部可用。
- **凭据位置**：agent 进程可达。
- **保住**：**CapBAC 对「哪个仓库」仍然有效**——cap 决定发哪个 token，token 的 scope 本身就只能到那一个仓库。授权表达从「argv 白名单」搬到「凭据 scope」，而这正是 installation token 的设计目的。跨租户泄漏窗口 = 1 小时 × 单仓库。
- **失去**：ref 级与操作级约束（force-push、删分支、任意 ref）→ 必须移交 remote 侧 branch protection；审计归属；bounded envelope。
- **新建**：凭据供给 seam（token 形态）+ credential helper 接线 + branch protection 运维约定。
- **既有可复用**：`GitHubInstallation.token_for_operation/3`（github_installation.ex:55-76）已在铸造 `%{repositories: [单仓库], permissions: profile}` 的 token 并做 `validate_scope`；新增一个 `:checkout_read` / `:push_write` profile 即可（installation_permissions.ex:23-29 现有 4 个 profile）。

### 形态 B2 — full-shell + SSH key

agent 在自己 shell 里跑完整 git；凭据是 SSH 私钥。

- **agent 体验**：同 B1。
- **凭据位置**：agent 进程可达，且 **ssh 要求密钥存在于文件系统上**。
- **保住**：若使用 per-repo deploy key，则「哪个仓库」仍受限；若使用账号级 key，则**完全不受限**。
- **失去**：B1 的全部，外加——密钥长期有效（无法 1 小时过期）、无法按 profile 分权限、吊销需到 provider 手动删除、必须落盘。
- **新建**：B1 的全部 + Entity SSH Identity 资源 + 密钥生成/导入/存储/轮转 + host-key policy（当年 broker 矩阵中每个候选都标注 "Not implemented; must bind repository host and pinned/approved host key"）。
- **唯一优势**：可对接**没有 API/token 机制的 git 主机**（自建裸仓库、非 GitHub/Forgejo 托管）。

### 形态 B2′ — **Allen 方案**（B2 + 复用已有凭据授权轨）

> **来源：Allen，2026-07-31。** 原话：「用最简单的方案就好了。跨租户泄露这些都不是 git plugin 要解决的事情，只保留最简单的**安装 git + 挂载 SSH + 操作**就可以了，ssh 的归属应该属于 **user/agent 自己**，每次用的时候用 **`ssh.read` 这样的 caps 授权**去读取。」

B2 的具体化：agent 在自己 shell 里跑完整 git，凭据是 SSH 私钥；**归属在 user/agent 侧，读取经 cap 授权**。

**关键发现：这个授权模型平台里已经有一整套在跑**（目前用于 LLM 凭据，不是 SSH）：

| 已有件 | 作用 | 证据 |
|---|---|---|
| `Ezagent.Credential.GrantCap.read_cap_for/1` | 每次读派生**一个 scoped 到确切 source 的窄 cap**；moduledoc 原话「never a broad set」「there is **no standing principal cap**」；`Capability.matches?/2` 要求 workspace URI 精确相等 | grant_cap.ex:27 |
| `Ezagent.Credential.UserDefaultSource` | 凭据按 `(owner, workspace, flavor)` **归属 user**；校验同 workspace / 同 owner / 同 flavor / 存在，且校验与写入**都在 cap-checked、有审计的 Behavior action 内**，模块本身无 cap-less mutator | user_default_source.ex:1 |
| `CascadeRuntime` / `Adopt` / `HomeRuntime` / `GrantMint` / `GrantCompensationLeaked` | user→agent 传播、采纳、装进 agent config_dir、grant 生命周期、泄漏补偿 | `apps/ezagent_core/lib/ezagent/credential/` |
| `SealedEnvelope` | at-rest AES-256-GCM + 可轮转 keyring | provider_connection/sealed_envelope.ex |

**所以 Allen 说的 `ssh.read`，实质上就是已有的 `sandbox.read` on source agent + `GrantCap` 派生的窄 cap。SSH 是接一种新 credential flavor 进这条轨，不是造新轨。**

**因此相对上文 B2 的修正**：

- **「Entity SSH Identity 是新子系统」这个前提是错的** —— 轨已存在。
- **成本从 5–8 天下修到 2–4 天。** 复用：`UserDefaultSource`（归属）+ `GrantCap`（窄 cap）+ `CascadeRuntime`（传播）+ `HomeRuntime`（装进 agent home）+ `SealedEnvelope`（加密）。新建：SSH flavor 接入、key 生成/导入入口、per-task ssh-agent 生命周期、`known_hosts` 策略。
- **跨租户泄漏从「失分项」改为「明确排除项」** —— Allen 判定不归 git plugin 管，故不再是本形态的验收项。

**一处必须修正的表述**：「每次用的时候授权」在 ssh 下**不可实现**。ssh 的密钥认证没有「每次回来问平台」的钩子（不像 HTTPS 的 credential helper），只有两种形态：key 文件在盘上，或 ssh-agent socket。实际流程是「一次 cap-checked read → key 落到 agent 的 `~/.ssh/` → 之后 N 次 git 操作零次 cap 检查」。

> **可行的近似 — per-task ssh-agent**：一次 cap-checked read → 把 key 加进 per-task 的 `ssh-agent` → 只把 `SSH_AUTH_SOCK` 交给 agent → 任务结束杀掉。这样 key **不落 agent 可读的盘**，且**任务边界即失效**。这是 ssh 协议约束下最接近「每次用的时候授权」意图的形态，实施时按此写。

#### B2′ 的防线分布 — 三分，不是全靠 remote

| 挡什么 | 谁在挡 |
|---|---|
| 能推到**哪个仓库** | **remote** — per-repo deploy key |
| 能推到**哪条 ref**、force-push、删分支、直接改 main | **remote** — branch protection |
| **谁能拿到这把 key** | **ezagent** — `GrantCap` 窄 cap + `UserDefaultSource` 归属校验（现成且强）|
| key 的 at-rest 加密 | **ezagent** — `SealedEnvelope` |
| 主机真伪（MITM）| **ezagent** — `known_hosts` pinning，remote 帮不了 |
| **key 泄漏之后** | **谁都不挡** —— ssh key 无 TTL，只能靠人发现并手工删 |

#### 最实质的变化：从结构保证降级为配置保证

A0 是**结构保证**——公开仓库、零凭据、argv 白名单，想出错都出不了错。B2′ 是**配置保证**——只有 remote 侧真的配了，防线才存在。

两者的**失败模式不同**：

- 结构保证失败 → 编译不过 / 测试变红 / 立刻有人知道
- 配置保证失败 → **什么都不会发生**。某个仓库忘了开 branch protection，代码照跑、测试全绿、PR 照开，只是那个仓库其实毫无保护，且无人察觉

**且 ezagent 代码里没有任何东西能验证 remote 侧配好了。** 这是 B2′ 最脆的一环——比密钥面的缺口更实际，因为密钥泄漏是小概率事件，而「某个仓库漏配」在仓库数变多后几乎必然发生。

**补救（建议采用方案 B）**：

- 方案 A：注册仓库时 preflight 读 branch protection 状态，未开则拒绝。缺点——读 protection 在 GitHub 需 admin 权限，而**为了检查限制去索取管理员权限本身是负收益**（能读即能改，能改即能关）。
- **方案 B（推荐）**：仓库接入 ezagent 前必须有人**显式确认**「已配 branch protection + 已用 per-repo deploy key」，确认带人与时间戳落库。仍是程序性的，但失败点从「静默无保护」变成「注册被拒 + 有据可查」，且不需要任何额外权限。

#### B2′ 的密钥面缺口清单

**真缺口（不在 Allen 的排除范围内）**：

1. **key 无法过期** —— ssh key 无 TTL，一把泄漏的 key **永久有效**直到人工删除。**ssh 协议内无解**，只能靠 per-repo deploy key 缩小范围 + 定期轮转（轮转机制目前为零，需建）。
2. **`known_hosts` 为零** —— 首次连接可被 MITM；容器/CI 默认做法 `StrictHostKeyChecking=no` 会让 agent 静默连上任何冒充主机。必补（拉 `https://api.github.com/meta` 的 `ssh_keys` 钉死）。
3. **`SealedEnvelope` 的 purpose 不受集中管束** —— moduledoc 原话「This module does not police which purposes a caller may open」，purpose 是调用方自选 atom、无注册表。密钥间隔离**靠代码评审保证，不靠结构**。
4. **主密钥在部署配置里**（`EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID` + keyring），无 HSM/KMS。归统一安全轨，不阻塞。

**Allen 已明确接受的（不计为缺口）**：同 UID 兄弟 agent 可读 key 文件或 ssh-agent socket；key 读走后无法约束用途；审计无法归属到具体 agent/task。

**Allen 可能未意识到的一条**：**cap 管不住「哪个仓库 / 哪条 ref / 哪些操作」**——这不属于「跨租户泄漏」那类被排除的关切，而是**授权模型表达不了业务意图**（CLAUDE.md 所定义的「防漂移」正是要防这类）。补救只在 remote 侧，ezagent 内补不了。

#### B2′ 的落地强制前置

1. **per-repo deploy key**，禁账号级 key —— 这是「哪个仓库」这条约束的唯一载体
2. **remote 侧 branch protection 先开**（保护 main、禁 force-push、禁删分支、强制 PR），并按方案 B 做注册确认
3. **`known_hosts` pinning**，不得用 `StrictHostKeyChecking=no`
4. **key 轮转机制**（因无法过期，只能靠定期换）
5. 「每次用的时候授权」按 **per-task ssh-agent** 实现

#### 运维成本随仓库数线性增长

deploy key 是 per-repo 的：10 个仓库 = 10 把 key + 10 次配置。对「团队自己的几个仓库」完全可接受；对「用户随便接入任意仓库」会很重。

对照：**B1 的 installation token 是零 per-repo 配置**（GitHub App 装一次，token 按仓库自动铸造，`github_app_jwt.ex` + `token_for_operation/3` 已在跑）。**注意 branch protection 两种方案都要配**——它挡的是 full-shell 带来的 ref 失控，与凭据类型无关。差别仅在 key 管理一栏。

> **书签**：若仓库数长到十几个以上，per-repo deploy key 的运维成本值得回头对比 installation token —— 那条路 per-repo 配置为零，且 App 已在运行。

---

## 4. 横向对比

| 维度 | A0 今天（已出局）| A1 平台全驱动 | A2 受控 argv | B1 full-shell + token | B2 full-shell + SSH |
|---|---|---|---|---|---|
| 网络写操作由谁完成 | **provider REST API** | 平台侧 `git push` | 平台侧 `git push` | agent 侧 `git push` | agent 侧 `git push` |
| 私有仓库 | **❌** | ✅ | ✅ | ✅ | ✅ |
| 完整历史 / 全分支 | ✅（公开仓库）| ✅ | ✅ | ✅ | ✅ |
| agent 多 commit 原样保留 | **❌** squash | ✅ | ✅ | ✅ | ✅ |
| agent 自主决定交付时机 | ❌ | ❌ | ✅ | ✅ | ✅ |
| agent 自行 fetch / rebase 上游 | ❌ | ❌ | 需加 action | ✅ | ✅ |
| **git stacked PR**（B 基于未合并的 A）| ❌ | ❌ | 需加 action | ✅ | ✅ |
| **合并顺序编排**（dev-together 的 "stack"，见 §8.1）| ✅ | ✅ | ✅ | ✅ | ✅ |
| 删除 / 二进制 / 权限位 | **❌** | ✅ | ✅ | ✅ | ✅ |
| **凭据是否进入 OS 子进程** | **否** | 是（平台侧）| 是（平台侧）| 是（agent 侧）| 是（agent 侧）|
| **凭据是否进入 agent 进程** | 否 | 否 | **否** | 是 | 是 |
| CapBAC 能表达「哪个仓库」 | ✅ | ✅ | ✅ | ✅（靠 token scope）| 仅 deploy key 时 ✅ |
| CapBAC 能表达「哪个 ref」 | ✅ | ✅ | ✅ | ❌ → branch protection | ❌ → branch protection |
| 碰不到其它 ref / 不能删他人分支 | ✅ 结构性（无 push）| **✅ 结构性（refspec 钉死）** | **✅ 结构性（refspec 钉死）** | ❌ → branch protection | ❌ → branch protection |
| 跨租户泄漏半径 | **零** | **可降至零**（见 §5.4）| **可降至零**（见 §5.4）| 1 小时 × 单仓库 | 长期 × key 可达范围 |
| 审计可归属到 task | ✅ | ✅ | ✅ | ❌ | ❌ |
| 凭据可自动过期 | n/a | ✅ 1 小时 | ✅ 1 小时 | ✅ 1 小时 | ❌ |
| 支持无 API 的 git 主机 | **必须有 API** | ❌ | ❌ | ❌ | ✅ |

---

## 5. 三条决策判据

### 判据一：CapBAC 是否还能表达你想表达的东西

CLAUDE.md 明写 caps 是**唯一确定必要的安全机制**，目的是**防漂移**——避免「功能可用但业务逻辑错」。

在 B2 且使用账号级 key 时，持有 repo A 之 cap 的 agent 可推送至凭据可达的任何 repo。此时**发不发 cap 结果相同**——这正是 CLAUDE.md 要防的那类漂移，而非它已同意容忍的那类安全加固削弱。

**B1 通过让 token scope 承载「哪个仓库」，避开了这一条。** 这是 B1 与 B2 之间最实质的差别，远大于「ssh 还是 https」这个表面差别。

### 判据二：单租户还是多租户

所有 sidecar（cc `SdkSidecar`、codex `AppServer`/`BridgeSidecar`、feishu `WsClient`、以及 `GitRunner`）统一经 `Ezagent.Runtime.OsProcess` 拉起，同 BEAM 同 UID，无任何隔离选项。结合探针结论：

> **任意一个 agent 可读取同机所有其它 agent 的凭据。**

- 单租户自用 → 影响有限
- 多租户（socialware / public_view / 匿名用户方向）→ **硬伤**：一个租户的 agent 可获得另一个租户仓库的写权限

### 判据三：注入面

agent 需读取仓库内容、issue、PR 评论。今天最坏情况是产出错误的文件改动，且须通过 collect 窄门（仅 upsert + 限额）再成为待 review 的 PR。B1/B2 下，README 中一段注入文本可直接成为一次 push。

**注意区分**：CLAUDE.md 的开发期姿态是「不防敌意 in-VM 代码」，但注入**不是 in-VM 代码，是外部输入**——来自待处理的仓库内容本身。两者不应混为一谈。

---

## 5.4 四种形态分别解决了哪些后果

§5 的三条判据来自四个具体后果。逐一对照：

| 后果 | A0 今天（已出局）| A1 平台全驱动 | A2 受控 argv | B1 full-shell+token | B2 full-shell+SSH |
|---|---|---|---|---|---|
| ① CapBAC 对 git 失效 | ✅ 完全解决 | ✅ 完全解决 | ✅ 完全解决 | ⚠️ 一半 | ❌（账号级 key 则全失效）|
| ② 同 UID 跨租户泄漏 | ✅ **真正为零** | ✅ **可为零**（fd-helper）| ✅ **可为零**（fd-helper）| ⚠️ 只缩小 | ❌ 最差 |
| ③ 注入 → 直接写远端 | ✅ 完全解决 | ✅ 完全解决 | ⚠️ 参数钉死 | ❌ 不解决 | ❌ 不解决 |
| ④ 审计归属 | ✅ 完全解决 | ✅ 完全解决 | ✅ 完全解决 | ⚠️ 平台侧可推断、provider 侧不可 | ❌ 不解决 |

**A0 是唯一四项全满分的形态，但它已因不支持私有仓库而出局。** 这正是本表的用途：既然必须向右移动，就必须放弃其中至少一项——本表回答的是「放弃哪一项代价最小」。

### ① CapBAC — 拆成四项能力看

| | 能否做 git | 哪个仓库 | 哪个 ref | 哪些操作 |
|---|---|---|---|---|
| **A0** | ✅ | ✅ | ✅ | ✅（无 push 路径可用）|
| A1 / A2 | ✅ | ✅ | ✅ | ✅ |
| B1 | ⚠️ 仅发放时刻的门 | ✅ token scope | ❌ | ❌ |
| B2 deploy key | ⚠️ 同上 | ✅ | ❌ | ❌ |
| B2 账号级 key | ❌ | ❌ | ❌ | ❌ |

A1/A2 四项全保住：argv 全部由 task policy 拼装，ref 是 `provision_id` 的 sha256 派生（git_runner.ex:57-65），remote 来自 policy，argv 中不含 `--force` / `--delete`。

B1 保住「哪个仓库」（token scope），丢掉「哪个 ref」与「哪些操作」——只能移交 branch protection。

**B1 的「能否做」存在真实降级**：cap 控制的是**发不发 token**，而非**发出后能否收回**。token 交付后在有效期内 agent 持续持有，撤销 cap 不影响它。这是「发放时刻的门」而非「持续的门」，其影响被 1 小时有效期限住。

B2 使用账号级 key 时整条失效——key 位于文件系统，发不发 cap 结果相同。这正是 CLAUDE.md 所定义的「防漂移」要防的那类失效。

### ② 跨租户泄漏 — A1/A2 可解，B1/B2 不可解

根因是同 UID 无隔离。**A0 为零是因为它根本不把凭据交给任何子进程**；向右移动后能否回到零，取决于凭据的投递方式（见下方三档）：

| | 凭据存在于 | 存活时长 | 其它 agent 可读性 |
|---|---|---|---|
| **A0** | **仅 BEAM 进程内** | n/a | **不可读** — 被动读取（environ / 文件 / argv）一无所获，仅 ptrace / 读 mem 这类主动攻击可达 |
| A1 / A2 ①env | 平台侧 git 子进程 env | clone/fetch/push 的**数秒** | 需恰在该窗口内读取 `/proc/environ` |
| **A1 / A2 ②fd-helper** | **仅进程内存** | n/a | **不可读**（ptrace_scope≥1）|
| B1 | agent 进程可达处 | **1 小时** | 全程可读 |
| B2 | 文件系统（ssh 要求）| **长期** | 全程可读 |

排序：A0 = A1/A2②档 = 零 ≪ A1/A2①档 ≪ B1 < B2。**B1/B2 无一为零**——对它们而言真正消除只能靠 Plan A 的隔离候选（独立 OS user / 容器沙箱 / 远程 signer），至今均未实现。

**限定**：本条仅就 git 这条线而言。agent 沙箱家目录中的 `~/.claude/.credentials.json`（§6）属另一条线，不受 A0 保护。

#### A1/A2 的泄漏窗口可以压到零 — 三档凭据投递方式

上表 A1/A2 的「数秒窗口」是**最朴素投递方式（env 注入）下的值**，不是这两个形态的下界。同 UID 之间到底能读到什么，由凭据藏在哪里决定：

**同 UID 兄弟进程可读性实测**（本机 2026-07-31）：

| 读什么 | 结果 |
|---|---|
| `/proc/<pid>/mem` | **Permission denied** — `ptrace_scope=1`（yama），只有**父进程**能 ptrace |
| `/proc/<pid>/environ` | **可读**（同 UID）|
| `/proc/<pid>/cmdline` | **可读**（且默认全局可读，连别的 UID 都能看）|

据此，A1/A2 有三档投递方式：

| 档 | 凭据藏在哪 | 兄弟 agent 能否读到 | 成本 |
|---|---|---|---|
| ① env 注入（朴素）| `/proc/<git pid>/environ` | **能** — 窗口 = git 命令存活的数秒 | 最低 |
| ② **fd-based credential helper** | 仅进程内存（管道传入）| **不能** — environ/cmdline/磁盘皆无，内存受 ptrace_scope 保护 | 几乎免费 |
| ③ loopback 注入代理 | 完全不进 git 进程 | **不能**，且 git 子进程恢复 A0 的零凭据状态 | 需独立设计 |

**②的机制**：git 的 credential helper 协议是「运行一个程序、从其 stdout 读 `password=...`」。让该 helper 从 BEAM 继承的管道 fd 读 token，则 token 不在它的 argv、不在它的 environ、不落盘，只存在于 helper 与 git 两个进程的内存里。而内存正是兄弟进程读不到的那一处。

> **⚠️ 绝不能用的两种投递**：token 写进 remote URL（`https://x-access-token:TOK@host/...`）会**落盘进 `.git/config`**，永久可读；token 放 argv 会进 `/proc/<pid>/cmdline`，**连别的 UID 都能读**。现有的 `execute_matching_remote/3`（git_runner.ex:414-419）已要求 `remote get-url origin` 等于干净 URL，顺带就是第一条的防线。

**③的思路**：git 指向 `http://127.0.0.1:<随机端口>/...`，由 BEAM 侧的短命代理在转发时加 `Authorization` 头。git 进程从头到尾不接触任何凭据——这让 A1/A2 在后果②上完全等同 A0，同时支持私有仓库。代价是需要一份独立设计（代理生命周期、端口绑定、调用方鉴别），本文不展开。

**结论**：**A1/A2 采用②档后，后果②的泄漏半径为零**——与 A0 相同，而 A0 做不到私有仓库。这使 A1/A2 成为「既支持私有仓库、又不放弃任何一条后果」的唯一区间。

**该结论的前提是部署主机 `ptrace_scope ≥ 1`**（本机为 1）。若部署在 `ptrace_scope = 0` 的主机上，兄弟进程可读任意同 UID 进程内存，②档退化回①档的强度。因此若选 A1/A2 + ②档，**须把 `ptrace_scope ≥ 1` 列为部署要求并在启动时自检**。

**B1/B2 用不上②③**：B1 的 token 是**交付给 agent 的**，agent 是合法持有者；full-shell 下无法约束它不把 token 写进 `~/.git-credentials` 或 env。B2 更彻底——ssh 要求私钥**必须落盘**，落盘即兄弟可读，无从加固。

B1/B2 用不上此加固，因其凭据本就必须交付给 agent。

### ③ 注入 → 直接写远端

- **A1 完全解决**：agent 无法发起网络操作；注入至多导致错误的文件改动，仍须通过 collect 窄门与 PR review。
- **A2 参数钉死**：注入**可**诱导 agent 调用 `push_current_branch`，但推送目标是钉死的仓库与钉死的 ref，argv 中无 `--force`。后果压缩为「提前推送一次自己那条 task 分支」，且仍须过 PR。
  **核心性质：攻击者能控制「做不做」，控制不了「对谁做」。**
- **B1 / B2 不解决**：注入可在凭据 scope 内做任何事；未开 branch protection 时包括 force-push 至 main。

### ④ 审计归属

- **A1 / A2 完全保住**：每次网络操作对应一次 dispatch，`OperationContext` 四字段（`task_access_uri` / `caller_uri` / `grantee_uri` / `idempotency_key`）齐备。
- **B1 一半**：provider 侧仅见 App 身份，无法区分具体 token；平台侧记录了「为 task X 铸过 token」，可事后关联。即**可推断、不可直接归因**。
- **B2 不解决**：deploy key 仅有 key 身份且长期复用，连推断锚点都没有。

### 小结

**①③④ 是形态问题**——选 A1/A2 基本解决，选 B1/B2 须靠 branch protection 兜底。
**② 是隔离问题，与形态无关**——四种形态只能缩小，真正解决须动 `OsProcess` 那条轨。

---

## 6. 一个必须纠正的前提

「agent 手里零凭据」**从来只在 git 这条线上成立**。

`mix ezagent.demo.seed_cc_sandbox` 会将 operator 的 `~/.claude/.credentials.json` 复制进 agent 的 sandbox 家目录（seed_cc_sandbox.ex:14、:121）。平台其余部分早已把凭据放在 agent 可达处。

因此选择 B1/B2 **不会打破一个平台级不变量**，只是让 git 这条线与其它线一致。但两类凭据爆炸半径不同：LLM key 泄漏 = 费用与配额滥用；git 写凭据泄漏 = **改写源码**，且无 branch protection 时可改写已合并历史。

---

## 7. 成本

**口径：agent 驱动的端到端墙钟**（spec/handoff → merged），非人日。本条线全部由 agent 建成，人日不是适用单位。

### 7.1 实测基线（本仓库同一条线的历史吞吐）

| PR | 内容 | spec/handoff → merged |
|---|---|---|
| #1643 | **整个 Forgejo 插件**：OAuth 凭证链 + 5 个 adapter 回调，12 模块 2710 LOC，16 测试文件 | 07-29 → 07-30 = **1 天** |
| #1641 | SealedEnvelope 收敛（合并两份并行密封实现）| 07-29 → 07-30 = **1 天** |
| #1653 | github adapter read-path fail-open 修复 | 07-30 → 07-31 = **1 天** |
| #1614 | **Plan E 全部 P1–P4e**：整个 workflow 层，新 app 3823 LOC，24 测试文件 | 07-24 → 07-29 = **5 天** |
| #1445 | **domain spine + connection framework + GitHub OAuth 插件**（三个子系统）| 07-15 → 07-22 = **7 天** |

规律：**有 spec 的 bounded slice ≈ 1 天；多 slice 的 plan ≈ 5 天；新子系统 ≈ 5–7 天。**

### 7.2 重估

| 形态 | 工作量 | 分解 |
|---|---|---|
| A0（已出局）| — | 不支持私有仓库，非工时问题 |
| **最简 B2′（已定，任务 1）** | **1–2 天** | 只动凭据侧，agent 自己 clone；不碰 GitRunner / provision / StageRunner（§8.4）|
| A1 | **2–3 天** | 凭据 seam（新契约面，无 template）1–2 天 + GitRunner 注入 / 新 gate / push 阶段 1 天 |
| A2 | **3–4 天** | A1 + agent git tool 面。cc 的 tool 机制现成（已有 13 个 tool），加几个不构成新子系统 |
| B1 | **2–3 天** | 同 A1 的 seam；无需把 push 接进状态机，但多出 credential helper 与 branch protection 约定 |
| B2 | **5–8 天** | B1 + Entity SSH Identity 属**新子系统**（新资源 + 密钥生成/导入/轮转 + host-key policy），对标 #1445 的单子系统量级 |

上表数字**已含评审与测试**——实测基线本身即为含评审的端到端墙钟。

**区间的含义**：上下限差别不在「写多久」，在「评审几轮」。#1643 那种 1 天量级的前提是**有 template 可抄**（github 插件作模板）；凭据 seam 是全新契约面、无模板，故取区间上限，风险集中于评审轮次。

### 7.3 不随 agent 速度缩短的四项

1. **人类裁决等待** —— 不含在上述任何数字内。§9 四个问题未答则无法开工。
2. **跨 Task 集成正确性** —— `docs/notes/2026-07-21-git-provider-system-closure-retrospective.zh_cn.md` §3 结论：「多个 Task 被当作独立正确性闭环，但正确性实际住在同一条跨 Task 状态机里」「局部绿灯在没有集成 Closure checkpoint 时被当成闭环」。此项只随评审轮次缩短，不随实现速度缩短。
3. **测试跑绿的物理时间** —— 受影响的四个 app 共 88 个测试文件，依赖 DB，且复盘要求经 guarded runner 串行（`MemoryHigh=4G` / `MemoryMax=5G` / `ERL_FLAGS='+S 4:4'`）。
4. **契约设计返工** —— agent 重写很快，但评审轮次会整轮重复。

### 7.4 被本次选型 obviate 掉的备选方案

以下方案曾在选型讨论中评估过，选定 A1 及以右任一形态后**不再需要**。此处仅作记录——**它们从未进入任何已批准计划**：

- **commit 序列 collect**（把 agent 的 commit 序列经 provider API 逐个重放）—— agent commit 可直接 push，无需重放。曾是最大的一项（agent 口径 5–8 天）。
- **FileChange envelope 扩展**（删除 / 重命名 / 二进制 / 提上限）—— 这些限制源于「把改动搬运过 API」，push 路径上不存在。仅当保留 API 写路径作 fallback 时才需要。
- **两侧 adapter 的 Git Data 重放与幂等 reconciliation** —— 现存约 1480 行中的主体，写路径上不再需要；开 PR 只剩 `POST /pulls` 传 head/base。

**净效应：任一形态都是简化，而非增量负担。**

---

## 8. 推荐

**前提**：以下推荐均假定采用 §5.4 的 **②档 fd-based credential helper** 投递凭据（几乎免费，且是 A1/A2 泄漏半径为零的前提）。若用①档 env 注入，A1/A2 的后果②退化为「数秒窗口」。

### 决策树

**不需要 agent 自主性 → A1 + HTTPS token + fd-helper。**
这是**严格优于 A0 的点**：四条后果全满分（与 A0 相同），同时支持私有仓库、push、多 commit、删除/二进制。既然 A0 已因私有仓库需求出局，而 A1 在安全上不比 A0 差，**A1 是新的安全最优解**。代价只有一条：agent 无自主权，交付时机由状态机决定。

**需要 agent 自主性（dev-together 那种形态）→ A2 + HTTPS token + fd-helper。**
相对 A1 只让出后果③的一部分——注入可诱导 agent 调用 push tool，但推送目标是钉死的仓库与钉死的 ref，`--force` 不在 argv 里，**注入能控制「做不做」，控制不了「对谁做」**。①②④ 仍全满分。

**要求与人类完全一致的 git 体验（自主 fetch/rebase/多分支 stacking）→ B1 + 短命 per-repo token。**
B1 是 full-shell 里唯一不失控的形态——授权表达从「argv 白名单」搬到「token scope」。但要清楚换掉了什么：后果②无法归零（token 交付给 agent 后无法约束它写进 `~/.git-credentials` 或 env）、③不解决、④只能推断、cap 管不住 ref 与操作（移交 branch protection）。

**不推荐 B2。** 除非确认目标包含**没有 API/token 机制的 git 主机**——这是 SSH 的唯一独占理由。在 full-shell 下 SSH 比 token 差得更多：shell 凭据已够不着 argv 白名单保护，唯一剩下的保护就是「凭据多窄、多短命」，而这恰是 token 强、SSH key 弱之处；且 ssh 要求私钥落盘，落盘即兄弟进程可读，无从加固。

### 8.1 A1 vs B2′ — 基于代码实证的重算

形态由 Allen 选定为 B2′。本节记录选型讨论中对 A1 的**四处修正**——初稿低估了 A1 的能力，据此得出的对比不成立。若后续回头评估，应以本节为准。

#### 修正一：A1 支持 rebase

`git rebase` 是**纯本地操作，不需要任何凭据**，agent 在 worktree 中随时可做，A1 不拦截。

可 rebase 的目标范围也比初稿宽：provision 用 `clone --bare` + `fetch +refs/heads/*:refs/ezagent/origin/heads/*` + tags **全量**拉取（git_runner.ex:86-91），故 bare cache 内有上游**全部**分支与 tag。

唯一缺口：rebase 到 provision **之后**上游新落的提交——需一次 fetch → 需凭据 → **平台加一个 refresh stage 即可解除**。

#### 修正二：A1 的安全性来自 refspec 钉死，不是来自禁 force

初稿把「禁 force-push」列为 A1 的结构性保障，**不准确**。那条 ref 是 `provision_id` 的 sha256 派生（git_runner.ex:57-65），**无人共享它**——对自己的 task 分支 force-push 是标准做法且无害。

真正的保障是 **refspec 钉死 → 碰不到任何其它 ref**。因此 **rebase-after-push 在 A1 下同样可支持**：argv 用 `--force-with-lease`、refspec 保持钉死即可。

#### 修正三：dev-together 的 "stack" 不是 git stacked PR，A1 完全支持

`.claude/skills/dev-together/SKILL.md` 实证：

- `:93` — `stack.md  # lead (push): returns in analyzed merge order`
- `:243` — `push | lead | stack the returns + analyze merge order → stack.md`
- `:79` — 「Branch model — Task branches merge into `main` only」
- `:284` — 「Per-task branches + lead-merges keep parallel devs from colliding」

即该工作流的 "stack" = **独立 per-task 分支 + lead 分析合并顺序**，而非「B 基于未合并的 A」。**这正是 A1 的模型。** A1 缺的是 git stacked PR，而该工作流不使用它。

#### 修正四：团队共用同一 repo 在 A1 下不麻烦，且比 B2′ 更可控

`Paths.derive` 中 `cache_identity(repository_uri, base_ref)`（paths.ex:47）**不含 provision_id**，而 `worktree_identity(provision_id, generation)` 含。故**同一 repo + 同一 base_ref 的所有 task 共享一个 bare cache，各挂一个 worktree**——git worktree 的标准用法：磁盘一份对象库，一个 task 的 fetch 更新共享 cache，**其它 task 立即可见新 refs**。

并发写共享 cache 在 A1 下**由平台仲裁**（`branch_owner` 三态 `:available` / `:same_target` / `:conflict`）；**B2′ 下 agent 自行 fetch，平台不知情，共享 cache 的并发无仲裁**。

其余同步顾虑逐条：

| 顾虑 | 实际情况 |
|---|---|
| base 陈旧 | 该工作流靠 planning 阶段划分 owned surfaces/files 避免冲突（SKILL.md:153、:284），**不靠 rebase 解冲突**，与 A1 的快照式 base 契合 |
| PR 合并时 base 落后 | GitHub "Update branch" 是**服务端操作**，无需本地 fetch，agent 不参与 |
| CI 在陈旧 base 上跑 | 所有 per-task branch 模型的通病，B2′ 亦然，非 A1 特有 |

#### 重算后的 A1 缺口

| 初稿认为 A1 缺 | 修正后 |
|---|---|
| 不能 rebase | **能**；缺的只是 rebase 到最新上游（加一个 refresh stage）|
| 不能 stacking | **该工作流的 "stack"（合并顺序）能**；git stacked PR 不能，但该工作流不用 |
| 不能 force-push | **能**；对自己钉死的 ref force 是安全的 |
| 团队共用 repo 会麻烦 | **不麻烦**，且并发仲裁比 B2′ 强 |

> **A1 剩余的真实缺口只有一条：agent 不能自己决定何时 fetch / 何时交付，时机由状态机决定。**

#### 决定性问题

> 这个 git 能力是给**流水线**用的，还是给**协作者**用的？

- **流水线**（一 task → 一 PR → 人 review → lead 排序合并）→ **A1 更划算**：4/4 安全满分、零 remote 配置、零 per-repo 运维、凭据自动过期、审计可归属到 task
- **协作者**（agent 自主掌握 git 全部时机，需自行 fetch / rebase 到最新上游）→ **B2′**

Allen 选择 B2′，对应「协作者」意图。**本节的记录目的**：若后续实际使用中「agent 改代码、交一个 PR」占绝大多数、极少真正需要自主 fetch，**A1 是可回头的更优点**——它更便宜（2–3 天 vs 2–4 天）、更安全（结构保证而非配置保证）、且无 per-repo 运维。

### 8.2 多租户下的 B2′ 风险 — 两条破坏路径与 A1 的结构性免疫

**提出者：gaga，2026-07-31。** 「如果平台要承载多用户、多租户，B2′ 存在的安全问题就很大——有心搞破坏的人指挥 agent 破坏所有仓库；A1 应该就没这个问题。」

经核实**该判断成立**。但机制需分清：有两条不同的破坏路径，**只有一条是平台漏洞**。

#### 路径一：坏人指挥自己的 agent、用自己的 key、破坏自己能碰的仓库

**不是平台漏洞** —— 等同于该用户自己在终端敲命令。任何系统都挡不住「用户用自己的凭据干坏事」。

#### 路径二：坏人指挥自己的 agent，偷同机上**其它租户**的 key，破坏**别人**的仓库

**是平台漏洞，且 B2′ 下完全挡不住。** 实测（§5.4）：同 UID 可读 mode-0600 文件、可读 `/proc/<pid>/environ`；ssh-agent socket 同样同 UID 可达。

**关键：per-repo deploy key 与 branch protection 都挡不住路径二。** 它们限制的是「一把 key 能干什么」，不是「能不能偷到别人的 key」——偷到别人的 per-repo key，照样能破坏那个仓库。

#### A1 为什么结构性免疫

**因为没有可偷的东西。** agent 进程中从来不存在凭据；配 fd-helper 后连平台侧 git 的内存都读不到（`ptrace_scope=1` 实测 `/proc/<pid>/mem` 为 Permission denied）。

且即便 agent 被完全操纵，其**破坏天花板**为：

- 只能改自己 worktree 内的文件
- 平台只会推到**它自己那条 sha256 派生的 ref**（`refs/heads/ezagent/task/<digest>/g<gen>`，git_runner.ex:57-65）
- 碰不到任何其它 ref、任何其它仓库
- 最终产物是**一个需人 review 才能合并的 PR**

> **A1 下一个被完全操纵的 agent，最大伤害是「制造一个垃圾 PR」；B2′ 下是「force-push 抹掉别人仓库的历史」。不是一个量级。**

#### Allen 那句话的准确性质

Allen 说「跨租户泄露这些都不是 git plugin 要解决的事情」——**该判断本身正确**，隔离确实不该由 git 插件承担，它是平台级职责。

**但该问题被移出 git plugin 范围后，并未被移进任何其它范围——它现在无主。** 实测：

- `OsProcess` 中 `uid` / `gid` / `namespace` / `bwrap` / `unshare` / `setuid` / `sandbox` / `cgroup` 命中数 **0**
- Plan A 当年四个隔离候选（独立 OS user / 容器沙箱 / 远程 signer / 不做）最终选定 **"不做"**（broker-options:26），当时判 NO-GO 的四条理由（无 provisioning、无 runtime uid/gid 选项、无 service unit、无 CI fixture）**今天一条都没变**

#### 结论（**已于 2026-07-31 修订，见 §8.2.1**）

初稿结论为「B2′ 隐含单租户前提，需确认，否则是设计缺陷」，并把 §9.3 升级为阻塞项。

**该结论过重。** 部署形态调研（§8.2.1）显示：租户隔离在本项目**本就靠「不共享部署」实现**，且已文档化。B2′ 的前提与既有部署契约**一致**，不是被忽略的缺口。§9.3 相应**从阻塞项降回「实施时须显式引用的部署契约」**。

#### 8.2.1 修订依据 — 租户隔离靠「不共享部署」，不是容器内隔离

`docs/notes/workspace-as-deployment-unit.zh_cn.md` 的定位就是「**workspace = 部署单元**」，并列出两种形态：

> - **跑在不同主机上（multi-tenant SaaS）** —— 不同 DB、不同 Phoenix endpoint、不同 routing rules
> - **同主机共存（单机 operator 跑多个环境 —— staging / prod / demo）** —— 独立 workspace 记录，共享 backend

**关键在第二条的用例限定**：同主机多 workspace 服务的是「**同一 operator 的多个环境**」，**不是互不信任的租户**；互不信任的租户走第一条——不同主机、不同 DB、不同 endpoint。

实物佐证：`docker/docker-compose.dev.yml` 只有**一个 `ezagent` service**（另两个是 cloudflared 隧道与 e2e 用的 chromium），**无 per-tenant / per-workspace 容器**。

| 部署形态 | 跨租户偷 key |
|---|---|
| 一租户一部署（不同主机 / 容器）| **不存在** —— 不同机器，谈不上同 UID |
| 同部署多 workspace（同一 operator 的 staging / prod / demo）| 存在，但**都是自己的环境**，不构成威胁 |

**因此 §8.2 路径二（偷他人 key）在既有部署契约下不成立。** 实施时须把该契约**显式写入**，而非默认：

> **部署契约**：互不信任的租户各自一套 ezagent 部署。同部署内的多 workspace 仅用于同一 operator 的多环境。**SSH key 的隔离依赖这条契约。**

**仍需留意三点**：

1. **代码里没有任何东西强制这条契约** —— 它是运维约定，不是结构保证。
2. **同部署内 workspace 之间的隔离比「部署单元」这名字听起来的弱** —— 该笔记自列 gap（Phase 8c 时点，其中「共享 SQLite」已 stale，现为 Postgres）：entity 非 per-workspace、cap 非 per-workspace scoped、跨 workspace dispatch 未强制。这反而印证「互不信任的租户不该同部署」。
3. **socialware / 匿名用户是另一条线，见 §8.2.2。**

#### 8.2.2 socialware / 匿名用户 — 属 caps 分配层，不属凭据模型

socialware / `public_view` 的匿名参与者**不是「另一个租户的 workspace」**，而是**同一部署内的参与者**。风险形态因此不同：不是「偷 key」，而是「**通过消息操纵持有 key 的 agent**」（prompt injection）。

**A1 同样挡不住「被操纵」本身** —— 两个形态都挡不住。差别只在**后果上限**：

| | 注入能让 agent 做什么 |
|---|---|
| B2′ | agent 手里有 key → force-push 到 main、删分支、碰该 key 可达的任何仓库 |
| A1 | agent 手里无 key → 至多写进自己那条钉死的 ref，产出**一个待人 review 的 PR** |

> **凭据模型决定「后果上限」，不决定「能否被操纵」。**

**真正该挡这条的是 caps 分配，且两个形态下都成立**：`GitTaskAccess` 的全部 action 都要 cap，**不发 git cap 的 agent 完全碰不到 git**。

> **配置层防线：不要把持有 git 能力的 agent 放进匿名用户能影响的 session。**

socialware 的前台 / 客服类 agent 本就不需要 git cap。**「哪个 agent 能碰 git」这一层 CapBAC 始终有效**；失效的是「碰到之后能碰哪个仓库 / 哪条 ref」那一层（B2′ 下移交 remote）。

因此三条防线是**正交**的：① caps 分配（决定谁有 git 能力）② 凭据模型（决定后果上限）③ 人 review PR（决定改动能否落地）。**socialware 撞的是①，不是②，故不构成 A1 vs B2′ 的差别点。**

### 8.3 A1 与 B2′ 能否并存 — 成本、重叠与叠加禁忌

#### A1 的一句话定义

> **A1 = agent 拥有全部 local git + 平台垄断 remote git。**

| | 谁做 | 为什么 |
|---|---|---|
| **local git**：log / diff / status / add / commit / branch / **rebase** / checkout / stash | **agent 自己** | 不需要凭据，worktree 就在文件系统上 |
| **remote git**：clone / fetch / push | **平台** | 需要凭据，而凭据不在 agent 的 env 里 |

这条分界线**不是靠禁止划的，是靠凭据自然形成的**——agent 跑 `git push` 会因无凭据而失败，无需任何拦截逻辑。

#### 技术上不冲突，但叠加会让 A1 的安全价值归零

A1 的全部价值命题是「凭据从不进入 agent 进程」——argv 钉死、refspec 钉死、审计归属，都建立在这一条上。**B2′ 就是给 agent 凭据。**

同一个 task 上两者都开启时：agent 手里有 SSH key，可完全绕过 A1 的所有约束自行推送。**实际安全水位 = B2′ 的水位**，A1 那套约束退化为「agent 愿意配合时才有效」。

> **结果：付了 A1 的建设成本，拿不到 A1 的安全收益。**

#### 四个具体实现冲突点

| 冲突点 | 说明 | 好解吗 |
|---|---|---|
| **remote URL 传输不同** | A1 用 `https://host/owner/repo.git`，B2′ 用 `git@host:owner/repo`；同一 worktree 的 `origin` 只能是一个，而 `execute_matching_remote/3`（git_runner.ex:414-419）断言 `remote get-url origin` **精确等于**预期 URL | 好解 —— 配两个 remote 或统一传输，但需放宽该断言 |
| **那条 ref 归谁** | A1 推 `refs/heads/ezagent/task/<digest>/g<gen>`；B2′ 下 agent 想推哪条推哪条。两边都推则 PR 开在哪条上不确定 | **语义冲突** —— 一个 task 的交付物必须唯一 |
| **`verify/1` 断言** | 要求 `HEAD == resolved_base_commit` 且工作区干净（git_runner.ex:177-186）；B2′ 下 agent 会 commit、会移 HEAD | 目前只在 pre-start 跑（Reconciler 只扫 `:ready`，store.ex:231-235），运行中不受影响；但 A1 状态机若在 agent 干活后再 verify 会失败 |
| **安全语义** | 见上 | **不好解，本质冲突** |

#### 并存的正确形态：按 task / 仓库二选一，而非叠加

- **高约束场景**（核心仓库、不完全信任的 agent、多租户）→ 走 **A1**
- **高自主场景**（团队自有 repo、需 rebase / 自主交付）→ 走 **B2′**

两者不在同一 worktree 内同时生效，各自的约束就都成立。**叠加在同一个 task 上 → 不要做。**

#### 成本不是简单相加 — 大部分底座共享

| | A1 | B2′ | 共享？ |
|---|---|---|---|
| provision workspace | ✅ | ✅ | **共享，已存在** |
| E2-B 触发入口 | ✅ 要驱动 4 状态机 + **agent 完成信号**（今天不存在）| ✅ 只要一个 provision 入口 | **共享底座**，A1 要的更多 |
| `SealedEnvelope` | ✅ | ✅ | **共享，已存在** |
| 凭据授权轨 `Ezagent.Credential.*` | 取 token | 取 ssh key | **共享，已存在** |
| 独有部分 | push stage + 完成信号 | ssh-agent 挂载 + remote 侧配置 | — |

**故两者一起做约 4–6 天，而非 2–3 + 2–4 = 5–7 天。**

#### 建议顺序：先 B2′，A1 留作可选高约束模式

理由不是安全，是**驱动面**：

- **B2′ 只需要一个 provision 触发点**，agent 自己当驱动
- **A1 需要把 E2-B 那条 dormant 的状态机真正接上**（`EzagentPluginGitWorkflow.Application` moduledoc：「E2-A dormant declarative contract only」「zero surfaces」「Authorization ingress is deferred to E2-B」；`StageRunner.advance/2` 全仓仅测试调用），**还要发明一个今天不存在的「agent 完成信号」**（`ezagent_domain_agent` 无 `:complete` action）

且**先做 B2′ 会把共享底座建好**（E2-B 入口、凭据轨接 SSH、provision 触发）。日后真需要 A1 那种高约束模式时，增量只剩 push stage 与完成信号。

反过来先做 A1 的话，B2′ 仍要重走一遍 key 挂载与 remote 配置，而 A1 建好的约束**一开 B2′ 就作废**。

> **例外**：若 §8.2 的租户模型答案是「会走多租户」，则顺序应反转 —— A1 是结构性免疫的那一个，B2′ 在隔离轨建成前不应启用。

### 8.4 实施任务划分（**已定** — gaga，2026-07-31）

> 「最简 B2′，在 B2′ 之后再考虑 A1；**provision 作为 A1 的内容，可选，也能为 B2′ 服务一下**。」
> 「B2′ 本身方向安全性就不足，实施尽量简化——确保共享底座、必要的 B2′ 依赖；其余如 key 轮转，本身就是个人 key，轮转反而增加麻烦，**策略秉持 user/agent 自己负责**。」

#### 任务 1 — 最简 B2′（1–2 天）

> **已再切分为 1a / 1b（2026-08-01）** —— 设计见 `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`。
> **1a**（本节的凭据侧主体）是 A1/B2′ **共享底座**；**1b**（物化进 agent + 给 agent 的 env）是 B2′ 独有、A1 下作废，单列为可独立决定的开关。

**范围：只动凭据侧。agent 自己 `git clone`。**

几乎全部是「在已有机制上加一个值」而非建新机制：

> **⚠️ 已被取代（2026-08-02，final-review M4）**：下表前三行描述的存储方向
> ——key 经 `SealedEnvelope` 封存、按 `UserDefaultSource` 的 `(owner,
> workspace, flavor)` 归属、cap 走 `GrantCap.read_cap_for/1`——已被
> `2026-08-01-agent-ssh-credential-1a-design.md` §2.1 / §6 明确拒绝：
> `SealedEnvelope` 住在 `ezagent_domain_provider_connection`，而该 app
> **依赖** `ezagent_domain_identity`，反向引用即循环依赖。**最终实现**：SSH
> 身份是 User Kind 自己的 state slice（`Ezagent.ActionSet.UserSshIdentity`，
> `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex`），
> 不经 `SealedEnvelope`/`UserDefaultSource`；四个 action（`generate_ssh_key`
> / `read_ssh_public_key` / `read_ssh_key` / `revoke_ssh_key`）各自声明专属
> `kind: :user` cap，不复用 `GrantCap`。at-rest 明文落 snapshot 是有意延后
> 的决定，见 1a design §6。下表后两行（物化进 agent 目录 / 给 agent 传
> env）是 1b 的范畴，不受本条影响。

| 需要 | 复用什么 |
|---|---|
| key at-rest 加密 | `SealedEnvelope`（现成）+ 一个新 `purpose` atom |
| key 归属 user | `UserDefaultSource` 按 `(owner, workspace, flavor)`——**flavor 是现成维度**，SSH 是新 flavor 值 |
| cap 授权读取（`ssh.read`）| `GrantCap.read_cap_for/1`（现成，每次派生窄 cap，无 standing cap）|
| 物化进 agent 目录 | `HomeRuntime.create_agent_config_dir`（现成路径——cc 的 `.credentials.json` 就是这么进去的）|
| 给 agent 传 env | `cmd_env` → `EZAGENT_CC_SDK_ENV`（现成通道，sdk_sidecar.ex:279）|

**真正新建的只有三件**：key 供给入口（cap-checked 写路径，抄 `UserDefaultSource` 的模式，形态见 §8.4.1）、`known_hosts` pinning（拉 `api.github.com/meta` 的 `ssh_keys`）、以及把 `GIT_SSH_COMMAND` 接进 `cmd_env` 的那处接线。

**不做**（按「自己负责」原则砍掉）：key 轮转、per-repo deploy key 管理、审计归属补救、ssh-agent 进程管理。

#### 8.4.1 key 从哪来 — **web 应用下「生成」优先于「导入」**（2026-07-31 修订）

初稿把「key 生成」列入砍掉项，理由是「用户本来就有 key」。**该理由建立在「operator 用 CLI / mix task 导入本机已有 key」的假设上，而 ezagent 是 web 应用——用户只能从 world UI 交互，operator 无法代每个用户导入其个人 key。** 故该假设不成立，结论随之修订。

**web 场景下两条路的实际对比**：

| | 用户上传私钥 | **平台生成密钥对**（推荐）|
|---|---|---|
| 用户操作 | 自己 `ssh-keygen` → 粘贴/上传私钥 | 点一下生成 → **复制公钥**贴到 GitHub |
| 私钥是否过浏览器 / 网络 | **是** —— 新增一条真实暴露面（需确保不进日志） | **否** —— 私钥从不离开服务器 |
| 需处理的格式 | 各种私钥格式与错误输入的解析验证 | 无 —— 自己生成，格式自己定 |
| 与「key 归属 user/agent」冲突？ | 否 | **否** —— key 仍归该 user，只是由平台代为生成与保管 |

**生成路线同时更简单且更安全**，且是业界标准做法（CI / GitHub Actions 均如此）。

**实现方式：`ssh-keygen` 子进程**（已有 `Ezagent.Runtime.OsProcess` 可用）。实测（2026-07-31）：

- OTP 能**解析** OpenSSH 私钥 —— `:ssh_file.decode(key, :openssh_key_v1)` 成功（§2 NO-GO ② 的依据）
- 但**编码**方向，我试过的几种 key 表示（`{:ed_pub, :ed25519, pub}` / `{:ed_pri, :ed25519, pub, priv}` × `:openssh_key` / `:ssh2_pubkey` / `:openssh_key_v1`）**均未成功**——不排除还有正确形状未试到，但结论不受影响：
- `ssh-keygen -t ed25519 -N "" -C <comment> -f <tmpfile>` **一行即得**标准 `-----BEGIN OPENSSH PRIVATE KEY-----` 私钥与 `ssh-ed25519 AAAA…` 公钥，正确性无疑

**因此任务 1 的 key 供给入口 = 生成为主**：world UI 一个「生成 SSH 密钥」动作 → cap-checked action → `ssh-keygen` 子进程 → 私钥经 `SealedEnvelope` 封存进 `UserDefaultSource`（flavor `"ssh"`）→ **只回显公钥与指纹**，供用户粘贴到 GitHub。

> **⚠️ 已被取代（2026-08-02，final-review M4）**：「私钥经 `SealedEnvelope`
> 封存进 `UserDefaultSource`」这一步已改向，原因同上（`SealedEnvelope`
> 所在的 `ezagent_domain_provider_connection` 依赖 `ezagent_domain_identity`，
> 反向即循环依赖——见 1a design §2.1 / §6）。**最终实现**：私钥经一个
> `:set` 效果直接写进 `UserSshIdentity` 挂在 User Kind 上的 `state`
> slice，取用经专属 `read_ssh_key` cap（不是 `GrantCap`）。「生成优先于
> 导入」「只回显公钥与指纹」两条结论不变。

「导入已有私钥」作为**可选的次要入口**，若做需额外确保私钥不进日志 / 不进错误信息。

**不碰**：`GitRunner`（771 行）、`Provisioner` / `Paths` / `ChangeCollector`、`StageRunner` / `ExecutionSeam` / 整个 git_workflow——**连 provision 触发入口（E2-B）都不需要**，因为没有 provision 这个动作了。

#### ⚠️ 任务 1 必须守住的设计约束

> **key 投递必须与「工作目录从哪来」解耦。**

key 写进 agent 的 config_dir + `GIT_SSH_COMMAND` 指过去——这套机制**不应依赖 cwd 是 agent 自己 clone 的还是平台 provision 的**。

**若把两者耦合，任务 2 建好 provision 后 B2′ 将用不上它**，「provision 也能为 B2′ 服务」这个设计意图会失效。这是任务 1 唯一的前瞻性要求，成本为零，但漏掉就要返工。

#### 任务 2 — A1（后续，可选）

**provision 入口归入 A1 范围。** 建成后可回头服务 B2′——B2′ 届时可选择使用平台 provision 的 worktree 替代自己 clone，从而拿回 worktree 隔离、共享 bare cache（磁盘/带宽不再随 agent 数线性增长）、provision 幂等与 reconciler 回收。

A1 的其余增量：push stage + **agent 完成信号**（今天不存在，见 §8.3）。

#### 该划分放弃了什么（如实记录）

> **修订（2026-08-01）**：本节初稿称「最简 B2′ 不为 A1 预建底座」，**该判断已被 1a/1b 再切分推翻** —— 详见 `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`。下文已按修订后的事实重写。

**任务 1 再切一刀为 1a / 1b**，切分依据是「哪部分在转向 A1 后不白费」：

| 部分 | B2′ 用 | A1 用 |
|---|---|---|
| **1a — key 存储 + 归属 + cap-gated read** | ✅ | ✅ **共享底座** |
| **1b — 物化进 agent config_dir + 给 agent 的 `GIT_SSH_COMMAND` + cascade/grant** | ✅ | ❌ 作废 |
| 任务 2 — provision 入口 + push stage + 完成信号 + 给平台 git 的 `GIT_SSH_COMMAND` | ❌ | ✅ |

- **1a 是实打实的共享底座**（凭据面的全部主体），A1 与 B2′ 都要。**故「不为 A1 预建底座」这句作废。**
- **真正不共享的是 1b** —— 它是「把 key 交给 agent」这个决定的落地，也是 agent 权限变大的那一步，因此单列为一个**可独立决定的开关**：若中途转向 A1，1b 不做，直接接任务 2。
- **仍然放弃的**：worktree 隔离、共享 bare cache（每 agent 一份完整 clone，磁盘/带宽随 agent 数增长）、provision 幂等、reconciler 回收、base commit 钉死。这些今天都有，最简 B2′ 用不上；**任务 2 建成 provision 后可选择性拿回**。

### 两条前置

**A0 已出局**：四条后果全满分、工时为零，但不支持私有仓库——不是可补的缺口，是其定义性质（§3 关键推论）。私有仓库已定为确定需求，故 A0 仅作对照零点。

**若选 A1/A2 + ②档，须把 `ptrace_scope ≥ 1` 列为部署要求并在启动时自检**（本机实测为 1）。在 `ptrace_scope = 0` 的主机上兄弟进程可读任意同 UID 进程内存，②档退化回①档强度。

**关于租户模型**：若 §9.3 答案是「会承载互不信任的租户」，B1/B2 的后果②无解，隔离轨成为前置项；而 A1/A2 + ②档不受此影响（泄漏半径本就为零）。**这可能是四选一中权重最大的一条。**

---

## 9. 需要 Allen 决策的点

1. **形态**：**A1 / A2 / B1 / B2** 之一。（A0 已因「私有仓库为确定需求」出局——见文首「已定输入」。）
2. **传输**：HTTPS token 还是 SSH key。**与形态正交** —— 请分别决定。
3. **租户模型**：ezagent 是否会在同一节点承载互不信任的租户？**已由部署契约回答（§8.2.1）——不会：互不信任的租户各自一套部署。** 故本条从阻塞项降为「实施时须显式引用的部署契约」。以下为初稿论述，保留供追溯： 答「是」则 B2′ 不可接受：存在「agent 偷他人 key → 破坏他人仓库」的路径，而 per-repo deploy key 与 branch protection **均挡不住**（它们限制一把 key 能干什么，不限制能否偷到别人的 key）。此时须先建隔离轨，或改用结构性免疫的 A1。
4. **是否存在无 API 的目标 git 主机**？这是 SSH 的唯一独占理由。

---

## 10. 选定 B1 或 B2 时的强制前置条件

以下三条缺一即为失控，不是建议：

1. **凭据必须 per-repo**（deploy key 或单仓库 installation token）。禁止账号级凭据。
2. **remote 侧 branch protection 先行开启**：保护 main、禁 force-push、禁删分支、强制 PR。这是 agent 跑飞时唯一仍有效的防线。
3. **凭据生命周期绑 task**，任务结束即失效。installation token 天然满足；SSH key 无法满足。

---

## 附录 A — 复现命令

```bash
# NO-GO ③ 隔离探针（本文结果：2 tests, 0 failures）
cd <worktree>
SHELL=/bin/bash \
MIX_DEPS_PATH=/home/huangjiajia/ezagent/deps \
MIX_BUILD_PATH=<worktree>/_build \
POSTGRES_PORT=15432 ERL_FLAGS='+S 4:4' \
mix test apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs

# NO-GO ③ OsProcess 隔离选项（本文结果：0）
grep -cniE "uid|gid|namespace|bwrap|unshare|setuid|sandbox|cgroup" \
  apps/ezagent_core/lib/ezagent/runtime/os_process.ex

# NO-GO ② OTP 自带 OpenSSH 私钥解析（本文结果：openssh_key_v1 成功）
#   ssh-keygen -t ed25519 -N "" -f <一次性 key>
#   :ssh_file.decode(File.read!("<一次性 key>"), :openssh_key_v1)

# 同 UID 兄弟进程可读性（本文结果：mem 拒绝 / environ 可读 / cmdline 可读）
cat /proc/sys/kernel/yama/ptrace_scope        # 本机 = 1（仅父进程可 ptrace）
sleep 60 & v=$!; sleep 0.3
cat /proc/$v/mem      >/dev/null 2>&1 && echo "mem 可读" || echo "mem 拒绝"
cat /proc/$v/environ  >/dev/null 2>&1 && echo "environ 可读"
cat /proc/$v/cmdline  >/dev/null 2>&1 && echo "cmdline 可读"
kill $v

# 现有凭据边界 gate（本文结果：7 + 1 + 10 = 18 tests, 0 failures）
POSTGRES_PORT=15432 mix test \
  apps/ezagent_domain_provider_connection/test/architecture/secret_boundary_test.exs \
  apps/ezagent_domain_git/test/architecture/adapter_registry_boundary_test.exs \
  apps/ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs
```

**注意**：本机 Postgres 监听 `15432`，而配置默认为 `55432`（config/test.exs:63）。不设 `POSTGRES_PORT` 会以连接超时失败。

---

## 附录 B — Decision Log 条目草稿

选定形态后，将下列条目填充并加入 `GLOSSARY.md` Decision Log（本文档不代为写入）：

> **#NNN** — **支持私有仓库；Git 凭据模型定为 `<A1|A2|B1|B2>` + `<HTTPS token|SSH key>`**（2026-07-31，本 spec）。
> **需求前提**：支持私有仓库为确定需求（gaga，2026-07-31），故维持现状（A0）不是可选项——A0 不支持私有仓库是其定义性质而非可修补的缺口。
> 撤销 Plan A「public-repository-only」范围限制——该限制的三条依据中，①加密 secret 后端缺失、②SSH parser 缺失均已失效（`SealedEnvelope` 落地；OTP `:ssh_file` 自带解析），仅③同 UID 隔离缺失仍成立。
> 接受的边界：`<按选定形态填写：凭据出现在何处、暴露给谁、窗口多长>`。**这是本项目 git 线上首次让凭据离开 BEAM**，须显式记录以免后人误以为此处仍是零凭据。
> 该边界**收口归统一隔离轨**，非本次范围。
> 强制前置：`<若 B1/B2，列出 §10 三条>`。

---

## 附录 C — 本文档不做的事

- 不修改 `ARCHITECTURE.md`（Allen 维护）
- 不写入 `GLOSSARY.md` Decision Log（待决策后另行提交）
- 不实施任何形态
- 不改动任何运行时语义或既有测试
