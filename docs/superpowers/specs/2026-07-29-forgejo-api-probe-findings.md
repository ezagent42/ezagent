# Forgejo API 实证结论 —— Plan E 移植的可行性边界

> **日期：** 2026-07-29 · **前置：** `docs/superpowers/handoffs/2026-07-29-forgejo-provider-handoff.md`
> **状态：** 交接文档 §3 的两个未知**均已关闭**（实写探针已跑，目标实例 `code.hyprial.com`）
> **本文是后续 Forgejo 设计文档的 §2 素材，不是设计文档本身。**

---

## 0. 一句话

两条结论都跟交接文档的预判不同，且**方向相反**：

- **§6.1 的确定性 commit —— 保住了，而且是实证的**：同内容同 base 的两次独立调用
  产出逐字节相同的 commit sha。
- **`POST /contents` —— 不幂等，实证**：内容完全没变，它照样建一个新的空 commit
  并推进分支。必须 read-before-write。

另外 §3 未知 #2（PR 精确过滤）的答案是**「有专用端点，但它是个陷阱」**。

---

## 1. 证据来源与可信度

| 来源 | 版本 | 用途 | 凭证 |
|---|---|---|---|
| `code.hyprial.com/swagger.v1.json` | `15.0.5+gitea-1.22.0` | schema / 端点存在性 | 无需（公开可读） |
| `code.hyprial.com` **实写探针** | 同上 | **§3 全部行为结论** | PAT（`repository:write`），仓库 `gagameow/ezagent-forgejo-test` |
| `codeberg.org` 活体 API | `16.0.0-dev-626+gitea-1.22.0` | §2 的 PR 端点行为 | 无需（匿名读公开仓库） |

**口径说明：** §3 的结论跑在**目标实例本身**，无版本外推风险。§2 的 PR 端点行为跑在
Codeberg（目标实例 `GET /version` 返回 403，匿名打不了，而该实例上没有可用的
历史 PR 语料）。两者同为 `gitea-1.22.0` 基座但大版本不同
（16.0.0-dev vs 15.0.5）—— **§2.2 的行为结论应在目标实例上补一次复核**，
方法见 §6。端点存在性来自目标实例自己的 swagger，无此风险。

---

## 2. 【已关闭】未知 #2 —— PR 的 find-or-create 语义

### 2.1 列表端点没有 head/base 过滤

目标实例 swagger，`GET /repos/{owner}/{repo}/pulls` 的全部 query 参数：

```
state, sort, milestone, labels, poster, page, limit
```

**没有 `head`，没有 `base`。** GitHub 的 `?head=owner:ref&base=main&state=open`
（`github_adapter.ex:497-501`）在列表端点上无对应物。

### 2.2 存在专用端点 —— 但语义不满足 Plan E

```
GET /repos/{owner}/{repo}/pulls/{base}/{head}    "Get a pull request by base and head"
  200 → PullRequest（单个，非数组）
  404 → notFound
```

三次独立实测（Codeberg `forgejo/forgejo`，三个不同 head，各自都存在**当前 open** 的 PR）：

| base | head | 端点返回 | 该 pair 实际存在的 open PR |
|---|---|---|---|
| `forgejo` | `renovate/forgejo-webpack-5.x` | **#4484 `closed`** (2024-07-14) | #13674 (2026-07-29) |
| `forgejo` | `renovate/forgejo-katex-0.x` | **#6205 `closed`** (2024-12-09) | #13671 |
| `forgejo` | `renovate/forgejo-primer-octicons-19.x` | **#4370 `closed`** (2024-07-06) | #13670 |

`#4484` 与 `#13674` 经单独取回逐字段比对，`base.ref` / `head.ref` / `head.repo.full_name`
三者完全相同 —— 不是「pair 不同所以选了别的」，是**同一个 pair 下端点忽略 state 选了最老的那个**。

### 2.3 为什么不能用它

`github_adapter.ex:489-508` 的 reconcile 依赖三条属性，该端点各缺一条：

| Plan E 依赖 | GitHub 列表过滤 | Forgejo `/pulls/{base}/{head}` |
|---|---|---|
| 只匹配 **open**（§6.1 步骤 7 字面要求） | `state: "open"` | ❌ 无 state 参数，**返回 closed** |
| 零匹配 → 创建 | `{:ok, []}` | ✅ 404 可映射 |
| **多于一个 → fail closed**（§6.2 恢复原则） | `{:ok, [_,_\|_]}` → `:change_request_conflict` | ❌ 返回单个，**多重性被端点吞掉，信号结构性不可得** |

GitHub adapter 的注释明写：「a closed/merged PR with the same head+base does not
block creating a new one」。用该端点会**反过来**：一个早已关闭的同 pair PR 会被
当作本 run 的当前 change request 返回，且**没有任何错误** —— 静默错误，
比 fail closed 糟得多。

### 2.4 结论：改用列表 + 客户端精确匹配

```
GET /repos/{o}/{r}/pulls?state=open&page=N&limit=50   （分页至尽）
→ 客户端按 head.ref == deterministic_ref && base.ref == base 精确筛
→ 0 个 → 创建；恰好 1 个 → 规范化返回；≥2 个 → :change_request_conflict
```

三条属性全部保住。代价是**分页遍历所有 open PR**，而非一次带过滤的调用；
对 bot 自有仓库 open PR 数有界，可接受。需在设计文档写明这是**已知成本差异**，
并给分页设上限保护（超过 N 页仍未穷尽 → 失败而非截断）。

**建议 V1 不用 `/pulls/{base}/{head}`** —— 少一条需要单独验证的语义。

### 2.5 附带排除：带斜杠的 ref 可用

Forgejo 把 head 放在 **path segment**，而 `DeterministicRef.derive/2` 产出
`task/p4e/run-<24hex>` 这类带斜杠的名字（全仓生产形态 namespace 实测都含斜杠：
`feature/`、`task/p4b/`、`task/p4e/`、`task/live/`；另有 `"a"`、`""`、`"feature/../"`
等纯边界校验用例）。

实测**原始斜杠与 `%2F` 编码两种写法都返回 200 且结果一致**；目标实例上
`GET /branches/task/probe/run-dates01` 亦正确路由并给出精确 404。
**这条曾是最大的未知，已排除。**

---

## 3. 【已关闭】未知 #1 —— `POST /contents` 幂等性

全部跑在目标实例 `gagameow/ezagent-forgejo-test`，base = `103a5569…`。

### 3.1 `dates` 真的生效（地基成立）

传 `dates: {author, committer} = 2020-01-02T03:04:05Z` + 显式 `author`/`committer` Identity：

```
POST /contents → 201
  commit.sha = 64c9857471e1ea9d30295c90fc0e58085377fa2b
  parents    = [103a5569…]              ← 正是 base
GET /git/commits/64c98574…  （权威读回，非响应回显）
  author.date    = 2020-01-02T03:04:05Z | Ezagent Probe
  committer.date = 2020-01-02T03:04:05Z | Ezagent Probe
```

schema 声明与实现一致。**这是 §3.2 全部推理的地基，已实测，不是推断。**

### 3.2 commit sha 确定性成立（实证）

同 files / message / author / committer / dates、同 base，**只改 `new_branch` 名字**
再调一次：

```
第一次 sha = 64c9857471e1ea9d30295c90fc0e58085377fa2b
第二次 sha = 64c9857471e1ea9d30295c90fc0e58085377fa2b   ← 完全独立的第二次调用
```

**§6.1「重试产出同一个 commit sha」的前提在 Forgejo 上成立。**
交接文档 §2.3 的乐观判断得到证实 —— 但见 §3.3，它**不蕴含操作幂等**。

### 3.3 `POST /contents` 不幂等 —— 内容没变也会建空 commit

`ChangeFilesOptions` 无任何 parent / base_sha 字段（`branch` 是名不是 sha），
父提交 = 服务端执行那刻的分支头，隐式不可钉。实测后果：

| 场景 | 请求 | 结果 | 副作用 |
|---|---|---|---|
| 原样重发（`new_branch` 指向已存在分支） | 与首次逐字节相同 | **422** `branch already exists` | **无**，分支头未动 ✓ |
| `operation: create`，文件已存在 | — | **422** `repository file already exists` | 无 |
| `operation: update`，不带 `sha` | — | **422** `a SHA or commit ID must be provided` | 无 |
| **`operation: update` + 正确 sha + 内容逐字节相同** | — | **201** | ⚠️ **分支头 `64c98574` → `344f8c6e`** |

最后一行是关键。新 commit `344f8c6e` 的形状：

```
parents = [64c9857471e1…]          ← 叠在前一个之上
message / author.date / committer.date  与前一个完全相同
```

且两个 commit 的 tree 逐条目相同（用 `/git/trees?recursive=true` 实读，
**未用 `tree.sha` 字段** —— 见 §5 的数据质量瑕疵）：

```
64c98574 → README.md:cdb8d0e6  probe:b90a8adf  probe/a.txt:06dd187c
344f8c6e → README.md:cdb8d0e6  probe:b90a8adf  probe/a.txt:06dd187c
```

**同一棵树，两个 commit。这是一个纯空提交。**

结论：**`ChangeFileOperation.sha` 不是 no-op 守卫，是 CAS 令牌** ——
传当前 sha 会成功，并制造一个内容无变化的新 commit。任何「重试就重发写请求」
的 adapter 都会**每重试一次叠一个空 commit**。

### 3.4 因此：`:upsert` 无法直接映射，且必须 read-before-write

- Forgejo 没有 upsert 语义。`create` 与 `update` 是两个互斥操作，选哪个取决于
  文件当前是否存在，且 `update` 还必须带上该文件当前的 blob sha
  ⇒ **每个文件写前都要一次读**（或「先试 create、422 再读 sha 转 update」，
  同样是 ≥2 次往返）。
- 写分支前必须先读该分支：停在 base → 可写；已前进 → **不得重发**，
  须先判定是否本 run 产物。

### 3.5 有利的一面（均已实测，非仅 schema）

- **`POST /branches` 的 `old_ref_name` 收 commit sha** → 实测 201，
  分支头精确等于所给 sha。**§6.1 步骤 2 的 base 校验保得住**；
- **`POST /branches` 同名重建 → 409** `The branch already exists.`
  （注意与 `POST /contents` 的 `new_branch` 冲突码 **422** 不同 —— 两个端点
  两个码，映射表别写混）；
- **原样重发是 fail-closed 且零副作用**，比预想好：危险路径只有一条，
  即「分支已建、再往已存在分支写」；
- **GitHub 的窗口 1「commit 建了、ref 没推进」在 Forgejo 上不存在** ——
  `POST /contents` 一次调用同时建 commit 并推进分支，二者原子。
  取而代之的是「写成功、响应丢失」这一个窗口。

---

## 4. 对交接文档 §8.1（provenance 缺口）的影响 —— 订正本文前一版

本文 2026-07-29 首版（commit `fd690bcde`）在此处写过：

> commit 由服务端构造、父提交隐式，**sha 相等性不再是可依赖的 provenance 判据**，
> 缺口在 Forgejo 上**更严重**。

**该判断错误，据 §3.2 撤回。** commit sha 是 `(parent, tree, message, author,
committer, dates)` 的纯函数，实测可复现 —— sha 相等性**是**可依赖的判据。

修正后的实际状况：Forgejo 与 GitHub **处境相同，不是更差**。

- adapter 无法**本地计算**期望 sha（那要自己实现 Git 对象哈希），但它在重试时
  手上有全部输入，因此可以**逐字段比对**已前进分支的 head commit
  （`parent == base` ∧ message ∧ author/committer 的 name/email/date ∧ 文件内容）。
  由确定性，字段全等 ⟹ sha 必等，故字段比对是**充分**判据。
- 仍未关闭的是同一条老缺口：**ref 停在 base 时**没有任何 commit 可比对，
  分不清「自己上次留下的」与「外部 planted 的」。这与 GitHub 侧
  `github_adapter.ex` 记的 KNOWN LIMITATION 是同一条，不因 provider 而恶化。

设计文档应把它作为**继承自 GitHub 线的既有缺口**处理，与 §6.2.1 同一条轨，
不必为 Forgejo 单开议题。

---

## 5. 数据质量瑕疵（adapter 需绕开）

`GET /git/commits/{sha}` 回传的 `commit.tree.sha` **等于 commit 自身的 sha**，
显然不是 tree 对象的 sha。若 adapter 想用 tree sha 做内容比对，**该字段不可信**；
应改用 `GET /git/trees/{sha}?recursive=true` 实读条目
（本文 §3.3 的 tree 对比即如此取得）。

同样地，`POST /contents` 成功响应里 `files[].last_commit_sha` 观察到仍是**前一个**
commit 的 sha（写入后未刷新）。**分支头应以 `GET /branches/{branch}` 为准**，
不要信写响应里的这个字段。

---

## 6. 读路径补采（`list_checks` / `list_reviews`）

五个 adapter callback 里的两个读路径在 Forgejo 上模型不同，补采如下。

### 6.1 没有 Checks API，只有 commit status

Forgejo 无 GitHub Checks API 对应物，只有较老的 commit status 模型：

```
GET /repos/{o}/{r}/commits/{ref}/statuses   全量历史
GET /repos/{o}/{r}/commits/{ref}/status     合并（CombinedStatus）
```

同一个 head sha（Codeberg `forgejo/forgejo` PR #13674，head `d3a085ee`）实测：

| 端点 | 条数 | 不同 context 数 | 每 context 唯一？ |
|---|---|---|---|
| `/statuses` | **56** | 17 | **否** —— 同 context 最多重复 **7** 次 |
| `/status` | **17** | 17 | **是** |

`/statuses` 返回的是**重跑历史**。用它会让同一个 check 名字产出 7 条结论互相
矛盾的记录。**必须用 `/status` 合并端点。**

### 6.2 枚举取值只能采样，swagger 没有

`CommitStatusState` 与 `ReviewStateType` 在 swagger 里都是**无 `enum` 约束的
string**（go 侧类型未导出取值），只能从真实数据采。

- **`CommitStatusState` 采到：** `pending`、`success`、`failure`、`skipped`。
  （`error`、`warning` 未采到，属 Gitea 词表的合理外推，实施时须实测。）
- **`ReviewStateType` 采到：** `APPROVED`、`REQUEST_REVIEW`。
  （`REQUEST_CHANGES`、`COMMENT`、`PENDING` 未采到。）

### 6.3 reviews 里混着 review **请求**

`GET /pulls/{n}/reviews` 返回的条目里有 `state: "REQUEST_REVIEW"`
（Codeberg PR #13674、#13659 实采）—— 那是「**向某人请求了 review**」，
**不是一条已提交的 review**，不属于 `DomainGit.Review.state` 封闭词表的任何一个。

**adapter 必须过滤掉它**，否则「有人被请求 review」会被记成一条 review 事实。

另：`dismissed` 是与 `state` **并列的独立布尔字段**（实采 `dismissed=False`
与 `state=APPROVED` 同时出现），不是 state 的一个取值。映射时先看 `dismissed`
再看 `state` —— 写反会让被撤销的 approval 仍算作批准。

---

## 7. OAuth2 实证（2026-07-29 补，目标实例）

走了一次完整的授权码流程：web UI 注册应用 → 浏览器授权 → code 换 token → refresh。

### 7.1 已证成

| 项 | 结果 |
|---|---|
| 授权码 + **PKCE S256** | 支持 |
| `expires_in` | **3600（1 小时）** |
| `refresh_token` | **签发；`grant_type=refresh_token` 换新 token 时一并轮换**（返回新的 access + 新的 refresh） |
| `token_type` | `bearer` |
| 认证头 | **`Bearer` 与 `token` 两种写法都接受** —— 同一 OAuth token 打 `/user` 均 200 |
| token 响应是否回显 scope | **否** —— 拿不到「实际授予了什么」的回执 |

**对设计的影响：** access token 时效与 GitHub installation token 同级（都是 1 小时），
所以「短期凭证」这条在 Forgejo 上**保得住**——前提是走 OAuth 而非 PAT。
`Bearer`/`token` 都接受意味着 `ForgejoClient` 不必按凭证类型分支。

### 7.2 scope 行为

- **按类别强制，拒绝时点名缺哪个**，例如：
  `{"message":"token does not have at least one of required scope(s): [read:user]"}`；
- 词表形如 `<read|write>:<category>`（`repository` / `user` / `issue` …），
  **语法中无仓库选择器**；
- 注册 OAuth 应用（`POST /user/applications/oauth2`）需要 **`write:user`** ——
  该 scope 可修改帐号设置。因此「Ezagent 自助注册 OAuth 应用」不可取：
  为省一次手工注册而常驻一个可改帐号的凭证不划算，且调该 API 本身需要一个
  已存在的凭证（先有鸡先有蛋）。**租户管理员在 web UI 注册是唯一合理路径。**

### 7.3 per-repo 收窄拿不到 —— **已实证**

第一轮不成立：当时 OAuth token `GET /user/repos` 只返回 1 个仓库，但该帐号
本就只有 1 个，无法区分「作用域被收窄」与「帐号里就这一个」。PAT 对照组同样
不成立（PAT 只持 `repository` 档，缺 `read:user`，调 `/user/repos` 直接 403）。

**帐号新建第二个仓库后复测，坐实了**：

```
GET /user/repos  (Authorization: Bearer <同一个 OAuth token>)
→ 2 个
   gagameow/ezagent-forgejo-test   push=true   created 2026-07-29T16:14:03
   gagameow/test-2                 push=true   created 2026-07-29T18:02:32
```

**决定性的是时序**：`test-2` 创建于 18:02，晚于该 token 的签发时刻，token
仍然看得见它。所以授权**不是签发时刻的仓库快照，而是持续跟随帐号** ——
per-repo 收窄不存在，且新增仓库自动落入既有凭证的半径内。

刷新后的 access token（rotation 产物）返回同样结果。

~~未测的一点：`permissions.push: true` 是服务端对该 token 的权限声明，未做实际
写入验证。~~ —— **已补测（2026-07-30）**，见 §7.5。

### 7.5 `write:repository` 足够跑通写路径 —— 已实证（2026-07-30）

§7.1 当时只用 OAuth token 打过 `/user` 与仓库可见性，**没做实际写入**。而 token
响应不回显已授予 scope（§7.1），所以"scope 够不够"只能靠一次真实写反推 —— 没有
别的信号。缺口的危险形状是：授权成功、连接 active、读路径正常，**第一次开 PR 时
才失败**。

补测走的是**插件自己的代码路径**（`ForgejoOAuth.exchange_code/4` →
`ForgejoClient.post/5`），不是手搓 curl，所以顺带验证了此前只对 stub 测过的
OAuth 换取实现。

| 步骤 | 结果 |
|---|---|
| code 换 token | `:ok`，`expires_at` 正确算出（≈1h），refresh_token 已签发 |
| 读 `branches/main` | `:ok` |
| `POST /branches` 建分支 | `:ok` |
| `POST /contents` 写文件 | `:ok` ← 真正需要 `write:repository` 的一步 |
| `POST /pulls` 开 PR | `:ok`（PR #8） |

授权的 scope 集合就是插件 `@scopes` 里的 `["write:repository", "read:user"]`——
授权 URL 由 `ForgejoOAuth.authorize_url/3` 生成，所以请求的和验证的是同一组。

痕迹已清理：PR #8 关闭、探针分支删除（查询返回 404）。

**仍未覆盖**：refresh 轮换只在 §7.1 人工走过一次，自动化里仍是 stub。补它需要
一个可长期存放的 refresh token，属凭证管理决策。

### 7.4 操作坑：Cloudflare 按 User-Agent 拦截

`code.hyprial.com` 在 Cloudflare 后面。用 python `urllib` 打 token 端点得到：

```
403  Error 1010: Access denied — browser_signature_banned
"The site owner has blocked access based on your browser's signature."
```

请求**根本没到达 Forgejo**（所以授权码未被消费，换 curl 重打即成功）。
`curl` 一路正常。**探针一律用 curl，不要用 python 的 http 客户端。**
这条同样适用于将来的 live E2E：Req/Finch 的默认 UA 是否被拦需要实测。

---

## 8. 复现方式

```bash
# schema（无需凭证）
curl -sS https://code.hyprial.com/swagger.v1.json -o forgejo-swagger.json

# §2 的 PR 端点行为（无需凭证，需代理）
A=https://codeberg.org/api/v1/repos/forgejo/forgejo
curl -sS -x http://127.0.0.1:7890 "$A/pulls/forgejo/renovate/forgejo-webpack-5.x"   # → #4484 closed
curl -sS -x http://127.0.0.1:7890 "$A/pulls?state=open&limit=50"                     # → 含 #13674 open，同 pair

# §3 的实写探针（需 PAT + 代理 —— 见下方订正）
#   凭证：/home/huangjiajia/ezagent/forgejo-token.txt（已入 .git/info/exclude，不入库）
#   认证头是 "Authorization: token <TOKEN>"，不是 GitHub 的 Bearer
#
#   订正 2026-07-29：本文早前称目标实例"本机直连可达、不用代理"。错。shell 已
#   导出 https_proxy=http://127.0.0.1:7890 且 curl 静默遵循，那些"裸 curl 200"
#   其实都走了代理。curl --noproxy '*' 会 25s 超时。Req/Finch 不读该变量，
#   必须显式传 connect_options: [proxy: ...]（设计 §10.2.1）。
#   探针脚本与逐步结果见 session 记录；探针仓库残留状态：
#     main                     103a5569  （base，未动）
#     task/probe/run-dates01   344f8c6e  （首次提交 64c98574 + 一个空提交）
#     task/probe/run-dates02   64c98574  （确定性检验的第二次提交）
#     task/probe/pin01         103a5569  （sha 钉选检验）
```

**§2.2 待补：** 在目标实例上造两个同 base+head 的 PR（一 closed 一 open），
复核 `/pulls/{base}/{head}` 在 15.0.5 上是否同样返回 closed 的那个。
结论不变则 §2.4 直接落地；若 15.0.5 行为不同，§2.4 仍是安全选择，只是不再必需。

---

## 8. `/contents` 的 `type` 与 `sha` 语义（2026-07-30 实测）

第三轮 review 提出怀疑：`/contents` 可返回 `file`/`dir`/`symlink`/`submodule`，adapter
把任何字符串 `sha` 都当普通 blob sha 用，若非 blob 则内容比对恒假 → fail-closed 卡死。

**实测方法**：git push 一个 symlink（mode `120000`）与一个 gitlink（mode `160000`）到
探针仓库，再按 API 读回。（`POST /contents` 只能写普通文件、无法设 mode，所以必须走
git push。）

| path | `type` | `sha` | 是什么 | `content` |
|---|---|---|---|---|
| `link.md` | `symlink` | `42061c01a1…` | **标准 blob sha** —— 内容是目标路径字符串 `"README.md"`，本地 `sha1("blob 9\0README.md")` 逐字节一致 | `null`，另有 `target: "README.md"` |
| `sub` | `submodule` | `103a556951…` | **被指向的 commit sha，不是 blob sha** | `null` |
| `README.md` | `file` | `cdb8d0e600…` | 普通 blob sha | 填充 |

### 结论：怀疑一半被推翻，一半坐实

- **symlink 无害。** 它的 `sha` 仍是 blob sha，比较逻辑天然正确；我们写普通文件时它
  必然不等 → 正确判冲突。**不需要特例。**
- **submodule / dir 是真陷阱。** 返回 commit sha / tree sha，与 blob sha 同在 40 位 hex
  命名空间。危险方向不是"误判为相同"（那需要 SHA-1 碰撞级巧合），而是**恒不相同** →
  该路径被 submodule 占据时永远报 `:head_ref_conflict`，一个 fail-closed 死锁穿着
  并发冲突的外衣。

已按 `type` 显式判定，`submodule`/`dir` 归 `:unwritable_path_kind` →
`:invalid_file_change`（构造错误，重试与远端变化都不会让它成功）。**缺失 `type` 视为
file** —— 旧实例可能不返回该字段，缺失不构成"非 file"的证据。

同一个 `blob_sha/3` 也服务写路径（`file_operations/2` 读每个路径决定 create-vs-update），
所以首次执行同样受保护：往 submodule 上写普通文件原先会计划一个 `update`、把那个
commit sha 当 blob sha 传出去。

探针痕迹已清理（分支删除，查询 404）。

---

## 9. commit status 的字段与聚合语义（2026-07-30 实测）

用 `POST /repos/{o}/{r}/statuses/{sha}` 造真实状态后读组合端点。这些数据只能靠写权限
取得，静态审查拿不到。

### 9.1 单条状态的字段是 `status`，不是 `state`

| 层级 | 字段名 | 例值 |
|---|---|---|
| 组合响应顶层（rollup） | `state` | `"failure"` |
| `statuses[]` 单条 | **`status`** | `"success"` |

单条 status 的完整字段：`context` / `created_at` / `creator` / `description` / `id` /
**`status`** / `target_url` / `updated_at` / `url`。`Normalize.check/1` 读的正是
`status["status"]`，对。

### 9.2 组合端点按 context 去重，保留**最新**

造 5 条状态（`ci/test` 先 `failure` 后 `success`），组合端点返回 `total_count: 4`：

```
ci/build  success (id=1)
ci/lint   pending (id=3)
ci/flaky  error   (id=4)
ci/test   success (id=5)   ← 保留最新，不是最早
```

这实证了选组合端点而非 `/statuses` 历史端点的判断（设计 §9.2）：**重跑后修好的 check
会被正确读成成功**，不会卡在旧的 failure 上。历史端点同一 SHA 返回全部 5 条。

### 9.3 `warning` 被接受，且 rollup 保持 `warning`（不是 failure）

第四轮 review 怀疑 `warning -> :neutral` 会把 Forgejo 视为 failure 的状态降级，依据是
Gitea `commitstatus.Combine` 的文档。**在目标实例（15.0.5）上不成立**：

```
POST state=warning        → 201，回显 status="warning"
组合端点 rollup           → "warning"    ← 不是 "failure"
```

所以不存在"把 failure 降级为 neutral"的场景。另外上层
`observation_summary.ex` **不做阻塞判定**，只把 `status:conclusion` 原样计数成标签
（`"3 checks: completed:failed=1 completed:succeeded=2"`），`:neutral` 与 `:other` 都会
如实出现，不会被当作"无阻塞"放行。该怀疑不成立。

### 9.4 状态词表覆盖

实测接受并正确映射：`success` / `failure` / `pending` / `error` / `warning`。

