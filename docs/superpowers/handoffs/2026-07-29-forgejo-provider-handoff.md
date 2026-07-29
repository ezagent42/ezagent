# Handoff: Forgejo Provider Plugin — 设计与实施

> **日期：** 2026-07-29 · **来自：** Plan E live-E2E session · **给：** 接手 Forgejo 的 session
> **worktree：** `/home/huangjiajia/ezagent/.worktrees/forgejo-provider`
> **分支：** `feat/forgejo-provider-design`，锚在 `origin/main@c4ec7b478`（含 Plan E 全部成果）

---

## 0. 一句话

GitHub provider 已经打通并合入 main（PR #1445 → #1614），包含**打真实 GitHub 的 E2E**。
现在要做 Forgejo。**架构层几乎全可复用，adapter 实现要重写，认证模型有本质差异。**

---

## 1. 先读这些（按顺序）

| 文件 | 为什么 |
|---|---|
| `docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md` | Plan E 设计权威。**§2.1 / §3 / §6.1 / §6.2 / §8 / §11 必读** |
| `docs/guide/github-plugin-config.md` | 凭证链逐环验证、二次批准陷阱、代理要求。**Forgejo 的对应文档要照这个写** |
| `apps/ezagent_domain_git/lib/ezagent/domain_git/adapter.ex` | 五个 provider-neutral callback —— 这就是你要实现的契约 |
| `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex` | GitHub 的实现，作为**对照**读，不要照抄 |
| `apps/ezagent_plugin_git_workflow/test/e2e/github_live_*.exs` | 真实 E2E 的结构，Forgejo 版可以照搬骨架 |

`CLAUDE.md` + `.claude/skills/ezagent-developer/SKILL.md` 照常先读。

---

## 2. 已验证的 Forgejo 事实（**别再花时间重验**）

实例：`https://code.hyprial.com/`
`GET /swagger.v1.json` **公开可读**（828KB）；`GET /api/v1/version` 要登录。

### 2.1 与 Gitea 同源，确证

```
Forgejo API  15.0.5+gitea-1.22.0
                  ^^^^^^^^^^^^^^ 版本串直接内嵌 Gitea 版本
```

Forgejo 是 Gitea 的硬分叉（2022 年底），API 层至今保持兼容。
**结论：一个 adapter 应当同时服务 Forgejo 和 Gitea**，但要做版本探测，别假设永远兼容。

### 2.2 GitHub 的 Git Data 写链在 Forgejo 上**不存在**

```
/repos/{o}/{r}/git/blobs          GET          ← GitHub 是 POST
/repos/{o}/{r}/git/blobs/{sha}    GET
/repos/{o}/{r}/git/trees/{sha}    GET          ← GitHub 是 POST
/repos/{o}/{r}/git/commits/{sha}  GET          ← GitHub 是 POST
/repos/{o}/{r}/git/refs           GET          ← GitHub 是 POST（且 GitHub 用它建分支）
/repos/{o}/{r}/git/refs/{ref}     GET
```

**Git Data 全只读。** 设计 §2.1 的 blob→tree→commit→ref 四步链整条不可用。

### 2.3 替代路径存在，而且更简单

```
POST /repos/{o}/{r}/contents     批量改文件（ChangeFilesOptions）
POST /repos/{o}/{r}/branches     建分支
GET/PATCH/DELETE /repos/{o}/{r}/branches/{branch}
```

**关键：`ChangeFilesOptions` 的字段**

```
author, branch, committer, dates, files, message, new_branch, signoff
  dates     → CommitDateOptions { author, committer }
  author    → Identity
  committer → Identity
```

**`dates` 存在，含 author + committer** —— 这意味着**设计 §6.1 的确定性 commit 保得住**：
可以显式传 `run.inserted_at`，重试产出同一个 commit sha。

这是当时最担心会崩掉整个设计的一条，**已确认没问题**。

而且 `new_branch` 让「建分支 + 提交一批文件」可以一次调用完成，比 GitHub 的四步更简单。

### 2.4 认证模型有本质差异 —— 这是最大的一块

| | GitHub | Forgejo |
|---|---|---|
| 模型 | App JWT → installation token | PAT 或 OAuth2 |
| 粒度 | **每次操作铸一个最小权限、短期 token** | 账号级、长期 |
| 对应物 | `InstallationPermissions.for!(:checks_read)` 等四档 | **没有** |

设计 §3 那套「一次 callback 一个 operation-scoped token」在 Forgejo 上**没有对应物**。

「凭证不出 plugin」仍能保证；但「最小权限 + 短期」**保不住**。
**这条必须在 Forgejo 的设计文档里明写，不能假装一样。** 它是安全姿态的实质差异，
不是实现细节。

---

## 3. 还没验的（需要一个能登录的 Forgejo 账号/token）

这两条决定 §6.2 的 crash window 怎么处理，**动手写 adapter 之前应当先验**：

1. **`POST /contents` 的幂等性** —— 同样的 files + message + dates 重复调，是返回同一个
   commit，还是每次建新 commit？
   GitHub 那边靠 blob/tree/commit 内容寻址天然幂等；Forgejo 这条**必须实测**。
   若不幂等，§6.2 窗口 1（commit 建了、ref 没推进）的恢复策略要重新设计。

2. **PR 的 find-or-create 语义** —— `GET /pulls` 能否按 `head` + `base` 精确过滤？
   GitHub 可以（`?head=owner:ref&base=main&state=open`），这是 §6.2 窗口 3
   （PR 建了、receipt 丢了）能恢复的全部依据。

验法：拿一个 PAT，照 `docs/guide/github-plugin-config.md` 里「逐环验证」那节的形式，
写四步探针。**建 blob 那种最小写探针在 Forgejo 上不适用**（没有该端点），
改用「在一个丢弃仓库上 `POST /contents` 建一个文件」。

---

## 4. 复用矩阵

| 层 | 复用 | 说明 |
|---|---|---|
| `DomainGit.Adapter` 五个 callback | ✅ **完全复用** | 契约本来就是 provider-neutral，这就是它存在的意义 |
| `GitTaskAccess` policy / caps / dispatch | ✅ **完全复用** | 与 provider 无关 |
| workflow / StageRunner / Observation / facts / Blocker | ✅ **完全复用** | P1–P4d 全部 |
| `AdapterRegistry` | ✅ 加一个 `"forgejo"` 注册即可 |
| 本地 E2E + 真实 E2E 的**结构** | ✅ 骨架照搬，换 provider |
| `GitHubAdapter` 实现 | ❌ **重写**（但更简单：4 步 → 1–2 步） |
| `GitHubClient` / error 映射 | 🔶 形状可抄，**状态码语义要重查** |
| `GitHubInstallation` / `GitHubAppJwt` / `InstallationPermissions` | ❌ **不适用**，Forgejo 无此模型 |

---

## 5. 本机环境（**踩过的坑，别再踩**）

### 5.1 Postgres 在 15432，不是默认也不是 55432

55432 落在 Windows 保留端口段（WSL2 `networkingMode=mirrored`），连不上。
worktree 的 `.claude/settings.local.json` 已预置 `POSTGRES_PORT=15432`（被全局 gitignore，不进仓库）。
命令里仍需显式带上：`MIX_ENV=test POSTGRES_PORT=15432 mix test ...`

### 5.2 mix 必须从 umbrella 根跑

`cd apps/<app> && mix test` 只加载该 app 的依赖，会产出**假的 `UndefinedFunctionError`**，
让人追鬼。一律 `mix test apps/<app>/test`。

### 5.3 两处代理，都不认环境变量

- **Req/Finch 不认 `HTTPS_PROXY`** —— 经 `:adapter_req_opts` 显式传
  `connect_options: [proxy: {:http, "127.0.0.1", 7890, []}]`。
  不配的症状是 `%Req.TransportError{reason: :timeout}`，而客户端把它映射成
  `:provider_unavailable` —— **与「provider 真的挂了」无法区分**（这是一个已知的、
  未修的呈现缺陷，见 §8）。
- **`GitRunner` 用 `clear_env: true` 起 git**（只留 `GIT_CONFIG_NOSYSTEM` /
  `GIT_TERMINAL_PROMPT`），`https_proxy` 到不了它。这是刻意加固，**不要为了测试改它**。
  live E2E 的解法：测试自己用代理把真实仓库镜像成本地 bare repo 再供给，
  `resolved_base_commit` 仍是真实 head sha。见 `github_live_case.ex` 的 `mirror_real_repo!/2`。

### 5.4 `mix precommit` 在本机跑不完，用 `mix ci.fast`

### 5.5 sub-step-gate hook 现在是好的

`#1601`（本人）+ `#1603`（Allen）已在 main，主 worktree 已同步。它会 gate **正在提交的
那个 worktree** 并跑 `ci.fast`。不再需要临时停用它。

---

## 6. 方法论要求（这一轮验证有效，请继承）

### 6.1 每条测试都问：「如果我把它名字所指的东西删掉，它会红吗？」

**能便宜地变异验证就去验，并把结果写进报告。** 这一轮靠它抓到：

- `authorize_receiver`（Git Provider 真正的业务授权）**此前没有任何测试能在它被删除时变红** ——
  换成 `do: :ok`，`domain_git` 仍是 170 tests / 0 failures；
- 我自己写的一条「POST/PATCH 各一次」测试**是空转的**（Req 的 `:safe_transient` 只重试
  GET/HEAD），已改名并把真实作用域写进注释。

**一条名字承诺得比实际多的测试，比没有这条更糟。**

### 6.2 断言「发生了几次」和「一次都没有」时，别用替身数

`github_live_case.ex` 的**透传观察器**是这一轮最有用的装置：`plugins:` 挂一个 Req
request step，请求飞向真实 provider **之前**抄一份 `{method, path}` 给测试进程。
不拦截、不伪造、不改写。

**拿替身数请求，数的是替身的行为，不是 provider 的。** Forgejo 版直接复用这个装置。

### 6.3 别从截断/失败的操作下结论

这一轮我犯过四次：`head -4` 看日志、错误的 mix 调用、`grep -c` 自匹配、
python 替换脚本静默未命中却当成"变异没效果"。

**脚本化改动一律加 `assert count == 1` 守卫；命令输出被截断就重跑取完整输出 + 退出码。**

---

## 7. 真实 E2E 的既有资产

GitHub 版跑法（Forgejo 版照此形状）：

```bash
GITHUB_APP_ID=... GITHUB_APP_PRIVATE_KEY="$(cat app.pem)" \
EZAGENT_LIVE_GITHUB_REPO=owner/repo \
EZAGENT_LIVE_GITHUB_PROXY=http://127.0.0.1:7890 \
mix test apps/ezagent_plugin_git_workflow/test/e2e --include live_github
```

- **默认排除**（`test_helper.exs` 里 `exclude: [:live_github]`），照
  `apps/ezagent_plugin_kanban` 的 `:live_miro` 先例。不带 `--include` 时
  `404 tests, 0 failures (10 excluded)`，CI 不受影响。
- `:req` 是 `only: :test` 依赖 —— 测试要直接问 provider「远端现在是什么状态」，
  那是断言的锚点。**不给 lib 开口子**：`architecture_test` 仍在每个 lib 源文件里拒绝 `Req.*`。
- 覆盖：§8 里**所有涉及 GitHub 的部分**（断言 3–8、注入 1/2/3/5/7/8、§6.2 窗口 1/2/3/5）。
  刻意留在替身上的只有两类：**429/5xx**（无法让 provider 按需故障，测的是我们的映射逻辑）、
  **digest 冲突 / CAS 竞态**（纯本地）。

本机 GitHub 凭证在 `/home/huangjiajia/ezagent/github-app.txt` 与
`provider-test-for-ezagent.2026-07-28.private-key.pem`（都已加进 `.git/info/exclude`，
该规则对所有 worktree 共享）。

---

## 8. 已知未解决问题（Forgejo 会同样遇到）

### 8.1 §6.2.1 —— ref-at-base provenance 缺口，**未关闭**

`github_adapter.ex` 的 KNOWN LIMITATION：deterministic ref 已存在但仍停在 base 时，
adapter 分不清「自己上次重试留下的」与「外部 planted 的」。

设计 §6.2.1 已记录**它没被关闭**，以及为什么：
`deterministic_head_ref` 全仓一处写、零处读，且无条件写；而 ref 名本就由
`DeterministicRef.derive/2` 纯函数从 run.id 推导 —— **持久化它没提供任何本来推导不出的信息**。
P4c 的写序是**必要条件**，不是关闭。

关闭它需要一个有判别力的事实（例如「本 run 创建 ref 时它指向的 sha」）并在 adapter 的
resume 分支真正读取。那是 provider owner 与 workflow owner 之间的契约变更。

`plan_e_restart_reconciliation_test.exs` 里有一条明确标注的 characterization 测试
（`"a ref planted at base by someone else is resumed onto — the gap P4c did NOT close"`），
将来真正关闭时它会变红。**Forgejo adapter 会有同类问题，设计时就该考虑。**

### 8.2 传输超时与 provider 5xx 映射成同一个码

`GitHubClient` 把 `%Req.TransportError{}` 和「其它 HTTP 状态」都映射成 `:provider_unavailable`。
对操作者这是两件完全不同的事（**你的网络断了** vs **provider 挂了**），现在分不出来。

这一轮发现但**没修**（怕搅乱范围）。Forgejo client 写的时候可以一并做对。

---

## 9. 建议的推进顺序

1. **先验 §3 的两个未知**（`POST /contents` 幂等性、PR 精确过滤）—— 它们可能改变设计
2. **写 Forgejo 设计文档** —— 照 Plan E 的格式，重点写清楚 §2.4 的认证模型差异
   与 §2.2/§2.3 的写路径差异；明确「§6.1 确定性 commit 如何在 Forgejo 上保住」
3. **切片实施** —— adapter 是唯一的大块；workflow 侧一行不用改
4. **真实 E2E** —— 照搬 `github_live_case.ex` 骨架，换 provider 与认证

---

## 10. Plan E 的边界（别越界宣称）

设计 §11 允许说：**Plan E 本地 provider-owned PR loop 当前切片完成**，
且 §8 中涉及 GitHub 的部分已在真实 GitHub 上验证。

**不可以说**：production authorization 已接线 / managed Agent canary /
GitHub merge loop / Kanban-socialware projection。
真实 mutation 与 canary 仍在设计 §10 的 operator gate 之后，该 gate 未解除。

Forgejo 这条线继承同样的边界。
