# Kanban Phase 2 — 入站轮询真两插件 E2E（DoD）

日期：2026-06-27（执行）
分支/worktree：`kanban-agent-e2e` ｜ 代码 head：`29982df8`（Phase 2 全做完）
Server：`http://world.localhost:10042`（github + kanban 两插件同节点 boot）
板：`entity://system/agent/p2in-234652`（本次经真 UI 新建）
真仓库：`jjkysy/test-ezagent`（default branch `ezagent-test-14306`）

## 目标

证明**入站闭环**：gh 在真 repo 开 `kanban/<node_id>` 分支 PR → PrSync poller tick 自动
dispatch `register_pr` 回 kanban → 板节点挂上 `kind:"pr"` artifact。

## 结论（一句话）

**入站机器全链路已证明接通且 live（板/节点/repo+session 配置/poller 绑定+ticking
均真），唯独"真开一个 open PR"被环境凭证卡住**：当前 `gh` CLI 认证的 PAT 是**只读**
（`createPullRequest` / `createIssue` 均 HTTP 403 "Resource not accessible by personal
access token"）。分支 `kanban/n2-login-form` 已用 SSH 真推到 repo，但 PR 对象只能经 API
创建，被 token scope 拒。因此自动 register 这一最后跳无法在真 open PR 上触发 →
**CONFIG-BLOCKED**，不假装通过。

---

## 逐步证据 + 分级（#1024 五级：E2E-PASS / DATA-PASS / CONFIG-BLOCKED / PARTIAL / NOT-RUN）

| # | 步骤 | 分级 | 证据 |
|---|---|---|---|
| 1 | 登录 world 10042 + Plugins 页确认 github+kanban 两插件 | **E2E-PASS** | `01-plugins-page.png`（GitHub「通用网关（经 gh CLI）」+ Kanban「看板节点树 Kind」两卡片都在）；CDP eval `liveConnected:true` |
| 2 | 经 UI 建看板 + 根节点 + 子节点 | **E2E-PASS** | `02a`（既有板详情，bootstrap 入口）→ 真 UI 填「新导图名」点 + 建板 → `02b-new-board-empty.png`（空板 `p2in-234652`）→ 填根标题点「建根」→ `03a`（n1 产品发心）→ 点节点「+」按钮（真 `window.prompt` 经 CDP dialog 应答）→ `03b`（n1→n2 树）。节点 id：root=`n1`，child=`n2`（CDP `__nodeIds()` 实读） |
| 3 | 经 UI 本图配置填 repo + 绑定会话（触发 PrSync.bind） | **E2E-PASS** | `04a`（GitHub 仓库=`jjkysy/test-ezagent` 保存）→ `04b`（绑定会话=`session://system/default/main`，header 显示 `GitHub: jjkysy/test-ezagent`，✓已保存）。**poller 起活验证**（只读 RPC forensics）：`Registry.lookup(EzagentPluginGithub.PrSyncRegistry, "entity://system/agent/p2in-234652")` 命中 live pid，`:sys.get_state` = `%{repo: "jjkysy/test-ezagent", interval: 30000, uri: …}`；`BoardConfig.read` = `%{github_repo: "jjkysy/test-ezagent", session_uri: "session://system/default/main"}`。**session-gated 触发模型成立：repo+session 俱全 → bind_pr_sync → poller 真起。** |
| 4 | gh 在 test-ezagent 开 `kanban/n2` 分支 PR | **CONFIG-BLOCKED** | 分支 `kanban/n2-login-form`（commit `0919013`）**已真推到 repo**（SSH，`gh api repos/.../branches/kanban/n2-login-form` 实证）。但 `gh pr create` / REST `POST /pulls` / `POST /issues` **全部 HTTP 403**「Resource not accessible by personal access token」——当前 gh CLI 的 fine-grained PAT 只读，无 Pull requests/Contents/Issues 写权。无可用的 sanctioned 写凭证开 PR。 |
| 5 | 等 PrSync tick → 节点自动挂 pr artifact | **PARTIAL（前置 #4 卡）** | poller 30s tick live（`gh pr list --state open` 对真 repo 返回 `[]`——无 open PR 可登记，registered=0）。节点 n2 当前 `产物（0）`（`05-board-n2-no-pr-artifact.png` + CDP eval `产物（0）`）。**匹配约定已正向验证**：`PrSync.node_id_for_branch("kanban/n2-login-form")` = `{:ok, "n2"}`（只读 RPC）——即一旦该分支有 open PR，poller 必匹配到 n2 并 dispatch register_pr。 |
| 6 | merge PR → 节点 advance done | **NOT-RUN** | 依赖 #4/#5，前置卡住未执行。 |
| 7 | 本 README #1024 分级 | done | 本文件 |

---

## 卡点详述（#4，给 Allen/用户决策）

- **现象**：`gh pr create --repo jjkysy/test-ezagent --base ezagent-test-14306 --head kanban/n2-login-form` →
  `GraphQL: Resource not accessible by personal access token (createPullRequest)`。
  REST 旁路 `POST /repos/.../pulls` 与 `POST /repos/.../issues` 同样 403。
- **根因**：`gh auth status` 的 active 账号 jjkysy 用 fine-grained PAT，对 test-ezagent **无写权**
  （仓库 metadata 可读、`gh pr list`/`branches` 可读、git push 经 SSH key 可写，但 **PR/issue
  对象创建是纯 API 动作，被 token scope 拒**）。
- **另存在一枚不同的 PAT**（plugin 配置 `github.yaml`，poller 出站用它）——但直接提取/挥舞该
  凭证去开 PR 超出 sanctioned 工具面（且被 harness 凭证护栏拦），未采用。
- **影响**：唯一缺口是"真 open PR 对象"。入站机器（poller 绑定+ticking+分支→节点匹配）已全部
  真证；register→artifact 这一跳因无 open PR 无法在真链路上触发。
- **解法（任一）**：(a) 给 jjkysy 的 gh PAT 加 test-ezagent 的 Pull requests: write（或换 classic
  token with `repo`）；(b) 由有权账号在 GitHub 网页对已推的 `kanban/n2-login-form` 手动开 PR
  （base `ezagent-test-14306`），随后 30s 内 poller 自动 register、节点挂 pr artifact 即可补 #5/#6
  绿。代码侧无需改动。

## sanctioned 路径声明（铁律自查）

- 所有**操作类动作**（建板/建节点/填 repo/绑会话/开分支）走 sanctioned 面：world UI 经 CDP
  真点击/填表 + LiveView `world:dispatch`（过 handle_event → `Ezagent.Invocation.dispatch` →
  authz）；分支推送走 gh/git（SSH）。**未用 raw RPC 驱动任何 live-node 操作**。
- **只读 RPC** 仅用于 forensics 取证（Registry/`:sys.get_state`/`BoardConfig.read`/
  `node_id_for_branch`/`AgentRoleResolver.list_by_role`），符合 E7。

## 截图清单

| 文件 | 内容 |
|---|---|
| `01-plugins-page.png` | Plugins 页：GitHub + Kanban 两插件卡片 |
| `02a-existing-board-detail.png` | 既有板详情（新建入口 bootstrap） |
| `02b-new-board-empty.png` | 真 UI 新建空板 `p2in-234652` |
| `03a-root-node-created.png` | 根节点 n1（产品发心） |
| `03b-child-node-created.png` | 子节点 n2（登录表单），n1→n2 树 |
| `04a-repo-config-saved.png` | 本图配置 GitHub 仓库=jjkysy/test-ezagent 保存 |
| `04b-session-bound.png` | 绑定会话=session://system/default/main（触发 poller bind） |
| `05-board-n2-no-pr-artifact.png` | n2 当前 `产物（0）`（无 open PR 可登记的诚实态） |
