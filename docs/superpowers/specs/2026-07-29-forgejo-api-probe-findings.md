# Forgejo API 实证结论 —— Plan E 移植的可行性边界

> **日期：** 2026-07-29 · **前置：** `docs/superpowers/handoffs/2026-07-29-forgejo-provider-handoff.md`
> **状态：** 关闭交接文档 §3 的未知 #2；未知 #1 收敛为「API 形状已判定、待实写确认」
> **本文是后续 Forgejo 设计文档的 §2 素材，不是设计文档本身。**

---

## 0. 一句话

交接文档 §2.3 的判断「§6.1 确定性 commit 保得住，已确认没问题」**需要订正**：
`dates` 让 commit **内容**确定，但 `POST /contents` **没有 parent 钉选**，
所以**操作本身不幂等**。而 §3 未知 #2（PR 精确过滤）现已实证关闭，
**答案是「有专用端点，但它不能用」** —— 用了会静默返回已关闭的旧 PR。

---

## 1. 证据来源与可信度

| 来源 | 版本 | 用途 | 凭证 |
|---|---|---|---|
| `code.hyprial.com/swagger.v1.json` | `15.0.5+gitea-1.22.0` | schema / 端点存在性 | 无需（公开可读，828KB） |
| `codeberg.org` 活体 API | `16.0.0-dev-626+gitea-1.22.0` | **行为**实证（匿名读公开仓库） | 无需 |

**口径说明：** 行为实证跑在 Codeberg 而非目标实例 —— 目标实例
`GET /api/v1/version` 返回 403，匿名打不了。两者同为 `gitea-1.22.0` 基座，
但**大版本不同（16.0.0-dev vs 15.0.5）**。下列行为结论在拿到目标实例 token 后
应各复跑一次；端点存在性结论直接来自目标实例自己的 swagger，无此风险。

---

## 2. 【已关闭】未知 #2 —— PR 的 find-or-create 语义

### 2.1 列表端点没有 head/base 过滤

目标实例 swagger，`GET /repos/{owner}/{repo}/pulls` 的全部 query 参数：

```
state, sort, milestone, labels, poster, page, limit
```

**没有 `head`，没有 `base`。** GitHub 的
`?head=owner:ref&base=main&state=open`（`github_adapter.ex:497-501`）在列表端点上
无对应物。

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

**顺带确认（原本担心会一票否决）：路径段可以承载带斜杠的 ref。**
`/pulls/forgejo/renovate/forgejo-webpack-5.x`（原始斜杠）与 `%2F` 编码两种写法
都返回 200 且结果一致。`DeterministicRef.derive/2` 产出的 `task/p4e/run-<24hex>`
这类形状**不会因为路由而不可用** —— 全仓生产形态的 namespace 实测值都含斜杠
（`feature/`、`task/p4b/`、`task/p4e/`、`task/live/`；另有 `"a"`、`""`、`"feature/../"`
等纯边界校验用例），这一条曾是最大的未知，已排除。

### 2.3 为什么不能用它

`github_adapter.ex:489-508` 的 reconcile 依赖三条属性，该端点各缺一条：

| Plan E 依赖 | GitHub 列表过滤 | Forgejo `/pulls/{base}/{head}` |
|---|---|---|
| 只匹配 **open**（§6.1 步骤 7 字面要求） | `state: "open"` | ❌ 无 state 参数，**返回 closed** |
| 零匹配 → 创建 | `{:ok, []}` | ✅ 404 可映射 |
| **多于一个 → fail closed**（§6.2 恢复原则） | `{:ok, [_,_\|_]}` → `:change_request_conflict` | ❌ 返回单个，**多重性被端点吞掉，信号结构性不可得** |

GitHub adapter 的注释明写：「a closed/merged PR with the same head+base does not
block creating a new one」。用该端点会**反过来**：一个早已关闭的同 pair PR 会被
当作本 run 的当前 change request 返回，且**没有任何错误** —— 这是静默错误，
不是失败，比 fail closed 糟得多。

### 2.4 结论：改用列表 + 客户端精确匹配

```
GET /repos/{o}/{r}/pulls?state=open&page=N&limit=50   （分页至尽）
→ 客户端按 head.ref == deterministic_ref && base.ref == base 精确筛
→ 0 个 → 创建；恰好 1 个 → 规范化返回；≥2 个 → :change_request_conflict
```

三条属性全部保住，与 GitHub 路径语义一致。代价是**分页遍历所有 open PR**，
而非一次带过滤的调用。对 bot 自有仓库 open PR 数有界，可接受；
需要在设计文档里写明这是**已知的成本差异**，并给出上限保护
（超过 N 页仍未穷尽 → 失败而非截断，见交接文档 §6.3「别从截断的操作下结论」）。

`/pulls/{base}/{head}` **可作为快路径**，但其结果必须经 state 复核，
且不能用作「不存在」的判据（它的 404 语义未验：是「无任何 PR」还是别的）。
**建议 V1 不用它** —— 少一条需要单独验证的语义。

---

## 3. 【收敛未闭】未知 #1 —— `POST /contents` 幂等性

### 3.1 API 形状已判定：不幂等

`ChangeFilesOptions` 的全部字段：

```
author, branch, committer, dates, files, message, new_branch, signoff
```

**没有任何 parent / base_sha 字段。** `branch` 是分支**名**，不是 sha。
因此 commit 的父提交 = 「服务端执行那一刻该分支的头」，隐式且不可钉选。

推论：`dates + author + committer + message + files` 全部固定 ⇒ commit **内容**确定；
但父提交不固定 ⇒
- 分支停在 base 时重试 → 父 = base → **同一个 sha**（幂等）；
- 上一次已成功但 receipt 丢失（分支已前进）时重试 → 父 = 上次的 commit →
  **不同 sha，且叠一个新 commit 上去**（不幂等）。

这与 GitHub 的窗口 1 是**同一个问题的不同形状**。GitHub 靠 blob/tree/commit 内容寻址
+ 显式 parent + non-force ref update 天然消解；Forgejo 消解不了，**必须靠 read-before-write**：
调 `POST /contents` 前先读 deterministic 分支，判定它停在 base（可写）还是已前进
（须先确认是本 run 的产物，然后跳过写）。

### 3.2 订正交接文档 §2.3

交接文档写「`dates` 存在 → §6.1 的确定性 commit 保得住 —— 这是当时最担心会崩掉
整个设计的一条，**已确认没问题**」。

**订正为：** 确定性 commit **sha 可复现**这一条保住了（`dates` 确实给了 GitHub
显式 author/committer date 的等价物）；但**「重试幂等」不是 sha 可复现的推论**，
它在 GitHub 上额外依赖「parent 显式指定」，而 Forgejo 不提供该能力。
设计文档必须把这两件事分开写，否则会照抄一个不成立的前提。

### 3.3 有利的一面（同样来自 schema，未实测）

- `CreateBranchRepoOption.old_ref_name` = 「Name of the old branch/tag/**commit** to
  create from」→ **建分支可精确钉在 expected base sha**，§6.1 步骤 2 的 base 校验保得住；
- `POST /branches` 的 **409 = 「branch with the same name already exists」** —— 干净无歧义的
  存在信号，比 GitHub 的 422 好（GitHub adapter 为消歧 422 专门写了一段，
  `github_adapter.ex:226-268`）；
- `ChangeFileOperation.sha` = 「SHA for the file that already exists, required for
  update or delete」→ **每文件的乐观并发令牌**，可作为二次防线；
- `FilesResponse.commit` 回传结果 commit → 可落 provenance；
- `POST /contents` 一次调用同时建 commit 并推进分支（`new_branch` 还能顺带建分支）
  ⇒ **GitHub 的窗口 1「commit 建了、ref 没推进」在 Forgejo 上不存在**，
  取而代之的是「写成功、响应丢失」这一个窗口。

### 3.4 仍需实写确认的（要一个能写的 token）

1. 分支已前进时重复 `POST /contents`（同 files/message/dates）→ 叠新 commit？报错？
2. `:upsert` 映射：文件已存在时用 `operation: "create"` → 422/409？
   用 `"update"` 缺 `sha` → 拒绝？（决定 upsert 要不要先读文件 sha）
3. `new_branch` 指向已存在分支 → 409 还是静默复用？
4. `dates` 是否真的进入 commit 对象（swagger 声明 ≠ 实现生效）—— 这条是 §3.1
   全部推理的地基，**必须实测**，不能只信 schema。

---

## 4. 对交接文档 §8.1（ref-at-base provenance 缺口）的影响

**在 Forgejo 上更严重。** GitHub 侧至少可以用「commit sha 是内容的纯函数」
做一次弱比对；Forgejo 侧 commit 由服务端构造、父提交隐式，
**sha 相等性不再是可依赖的 provenance 判据**。

因此 §6.2.1 说的「需要一个有判别力的事实（例如本 run 创建 ref 时它指向的 sha）」
在 Forgejo 线上**不是可选优化，而是接近必需** —— read-before-write 的
「已前进的分支是不是我的」这一问，没有该事实就答不了。

设计文档应把它作为**显式议题**提出，而不是继承 GitHub 侧「已知未关闭」的默认。

---

## 5. 复现方式

```bash
# schema（无需凭证）
curl -sS https://code.hyprial.com/swagger.v1.json -o forgejo-swagger.json

# 行为（无需凭证，需代理）
A=https://codeberg.org/api/v1/repos/forgejo/forgejo
curl -sS -x http://127.0.0.1:7890 "$A/pulls/forgejo/renovate/forgejo-webpack-5.x"   # → #4484 closed
curl -sS -x http://127.0.0.1:7890 "$A/pulls?state=open&limit=50"                     # → 其中含 #13674 open，同 pair
```
