# Git 凭据模型选型 — 四形态对比（A0 为已出局基线）+ Plan A 三条 NO-GO 重核

**日期：** 2026-07-31
**状态：** 待决策（decision required）— 本文不实施任何形态
**基线：** `c0cb35e69`（main，2026-07-31 FF）
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
四后果     4/4 满分 →  ①③④ 满分  →  ①④ 满分    →  ①一半④一半 →  基本全丢
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
- **保住**：CapBAC 完整；remote 与 ref 由 task policy 钉死；无 force-push / 无删分支路径；审计可归属到每次 dispatch。
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
| 多分支 stacking | ❌ | ❌ | 需加 action | ✅ | ✅ |
| 删除 / 二进制 / 权限位 | **❌** | ✅ | ✅ | ✅ | ✅ |
| **凭据是否进入 OS 子进程** | **否** | 是（平台侧）| 是（平台侧）| 是（agent 侧）| 是（agent 侧）|
| **凭据是否进入 agent 进程** | 否 | 否 | **否** | 是 | 是 |
| CapBAC 能表达「哪个仓库」 | ✅ | ✅ | ✅ | ✅（靠 token scope）| 仅 deploy key 时 ✅ |
| CapBAC 能表达「哪个 ref」 | ✅ | ✅ | ✅ | ❌ → branch protection | ❌ → branch protection |
| 禁 force-push / 禁删分支 | ✅ 结构性（无 push）| ✅ 结构性 | ✅ 结构性 | ❌ → branch protection | ❌ → branch protection |
| 跨租户泄漏半径 | **零** | 几秒窗口（见 §5.4）| 几秒窗口（见 §5.4）| 1 小时 × 单仓库 | 长期 × key 可达范围 |
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
| ② 同 UID 跨租户泄漏 | ✅ **真正为零** | ⚠️ 只缩小 | ⚠️ 只缩小 | ⚠️ 缩小得少 | ❌ 最差 |
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

### ② 跨租户泄漏 — 离开 A0 后无形态可解

根因是同 UID 无隔离，属形态之外的问题。**A0 之所以为零，是因为它根本不把凭据交给任何子进程**；一旦向右移动，就只能缩小窗口：

| | 凭据存在于 | 存活时长 | 其它 agent 可读性 |
|---|---|---|---|
| **A0** | **仅 BEAM 进程内** | n/a | **不可读** — 被动读取（environ / 文件 / argv）一无所获，仅 ptrace / 读 mem 这类主动攻击可达 |
| A1 / A2 | 平台侧 git 子进程 env | clone/fetch/push 的**数秒** | 需恰在该窗口内读取 `/proc` |
| B1 | agent 进程可达处 | **1 小时** | 全程可读 |
| B2 | 文件系统（ssh 要求）| **长期** | 全程可读 |

排序 A0 ≪ A1/A2 ≪ B1 < B2。**离开 A0 之后无一为零**——真正消除只能靠 Plan A 的隔离候选（独立 OS user / 容器沙箱 / 远程 signer），至今均未实现。

**限定**：本条仅就 git 这条线而言。agent 沙箱家目录中的 `~/.claude/.credentials.json`（§6）属另一条线，不受 A0 保护。

**A1/A2 可用的近零加固（几乎免费）**：凭据不经 env，改由 **credential helper 从 BEAM 继承的 fd 读取**。git 的 credential helper 协议是「运行一个程序、从其 stdout 读 `password=...`」，该程序可从继承管道取得 token。如此 token **不在 environ、不在磁盘、不在 argv**，仅存在于两个进程的内存中——同 UID 的被动读取（读文件、读 environ）全部失效，只剩 ptrace / 读 mem 这类主动攻击。

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

**首选 A2（受控 argv + agent 可请求）+ HTTPS token。** 理由：拿到 agent 自主 git 的绝大部分收益，同时凭据从不进入 agent 进程，`allowed_head_ref`、单仓库、禁强推三条**继续结构性有效**；不需要建立密钥生命周期。

**次选 B1（full-shell + 短命 per-repo token）。** 若要求与人类开发者完全一致的 git 体验（自主 fetch/rebase/stacking），B1 是 full-shell 里唯一不失控的形态——因为它把授权表达搬到了 token scope 上。

**不推荐 B2。** 除非确认目标包含**没有 API/token 机制的 git 主机**。在 full-shell 模型下 SSH 比 token 差得更多：shell 凭据已够不着 argv 白名单保护，唯一剩下的保护就是「凭据本身多窄、多短命」，而这恰是 token 强、SSH key 弱之处。

**A1 仅在明确不需要 agent 自主性时选择。**

**A0 已出局**：它在四条后果上全满分、工时为零，但不支持私有仓库——这不是可补的缺口，是其定义性质（§3 形态 A0 的关键推论）。私有仓库已定为确定需求（见文首「已定输入」），故 A0 不再是候选，仅作对照零点。选择范围是 A1 / A2 / B1 / B2。

**关于后果②**：一旦离开 A0，同 UID 跨租户泄漏就无形态可解，只能缩小窗口（§5.4）。若 §9.3 的租户模型答案是「会承载互不信任的租户」，则隔离轨不是可选项而是前置项，且它独立于本文的形态选择。

---

## 9. 需要 Allen 决策的点

1. **形态**：**A1 / A2 / B1 / B2** 之一。（A0 已因「私有仓库为确定需求」出局——见文首「已定输入」。）
2. **传输**：HTTPS token 还是 SSH key。**与形态正交** —— 请分别决定。
3. **租户模型**：ezagent 是否会在同一节点承载互不信任的租户？此答案直接决定 B1/B2 是否可接受。
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
