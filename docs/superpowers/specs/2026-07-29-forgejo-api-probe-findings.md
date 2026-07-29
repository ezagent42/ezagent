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

## 6. 复现方式

```bash
# schema（无需凭证）
curl -sS https://code.hyprial.com/swagger.v1.json -o forgejo-swagger.json

# §2 的 PR 端点行为（无需凭证，需代理）
A=https://codeberg.org/api/v1/repos/forgejo/forgejo
curl -sS -x http://127.0.0.1:7890 "$A/pulls/forgejo/renovate/forgejo-webpack-5.x"   # → #4484 closed
curl -sS -x http://127.0.0.1:7890 "$A/pulls?state=open&limit=50"                     # → 含 #13674 open，同 pair

# §3 的实写探针（需 PAT，本机直连不用代理）
#   凭证：/home/huangjiajia/ezagent/forgejo-token.txt（已入 .git/info/exclude，不入库）
#   认证头是 "Authorization: token <TOKEN>"，不是 GitHub 的 Bearer
#   探针脚本与逐步结果见 session 记录；探针仓库残留状态：
#     main                     103a5569  （base，未动）
#     task/probe/run-dates01   344f8c6e  （首次提交 64c98574 + 一个空提交）
#     task/probe/run-dates02   64c98574  （确定性检验的第二次提交）
#     task/probe/pin01         103a5569  （sha 钉选检验）
```

**§2.2 待补：** 在目标实例上造两个同 base+head 的 PR（一 closed 一 open），
复核 `/pulls/{base}/{head}` 在 15.0.5 上是否同样返回 closed 的那个。
结论不变则 §2.4 直接落地；若 15.0.5 行为不同，§2.4 仍是安全选择，只是不再必需。
