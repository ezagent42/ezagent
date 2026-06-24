# 片6 实现 spec：GithubSync 纯出站连接器

> 写于 2026-06-23。研究员视角，全部 file:line 实证。
> 真相源 = ezagent mindmap domain；GitHub = 纯出站投影 + 轮询伪入站。
> 形态判定已定（见 `2026-06-23-github-outbound-and-attachment-interaction.md` §结论）：
> **GitHub 走 Miro 式纯出站连接器**——不开 inbound webhook、不碰 ezagent_web 路由、不碰 external_mirror 域、不碰 core。

---

## 0. 设计基线（照搬对象一览）

| 新建 | 照搬现有 | 现有 file:line |
|---|---|---|
| `EzagentPluginGithub.Github`（REST client） | `EzagentPluginMindmap.Miro` | `miro.ex:1-201`（`:httpc`+`Jason`，`read_creds/write_creds`，`{:body_format,:binary}` 防中文乱码 `miro.ex:143`） |
| `EzagentPluginGithub.Github.Sync`（纯函数） | `EzagentPluginMindmap.Miro.Sync` | `miro/sync.ex:1-167`（`render_content`、纯函数、可单测无网络） |
| `EzagentPluginGithub.GithubSync`（GenServer 三件套） | `EzagentPluginMindmap.MiroSync` | `miro_sync.ex:1-185`（Registry+DynamicSupervisor、`bind/sync_now/sync_or_bind/teardown`、tick 轮询、系统身份 dispatch `miro_sync.ex:171-184`） |
| `EzagentPluginGithub.Application` | `EzagentPluginMindmap.Application` | `application.ex:1-66`（`use Application`+`use Ezagent.Plugin`、`children/0` 起 Registry+Supervisor） |
| world `mindmap.sync_github` 子句 | world `mindmap.sync_miro` 子句 | `mindmap_actions.ex:82-83,116-136`（dispatch→`MiroSync.sync_or_bind`→`push_event("world:state")`） |
| world `mindmap.save_github_creds` 子句 | world `mindmap.save_miro_creds` 子句 | `mindmap_actions.ex:85-87,140-160`（admin-gated→`Miro.write_creds`） |

**与 Miro 的本质差异（不能纯照搬的 3 点）**：
1. **不建"板"，建 issue**：Miro 是"整棵树镜像成一块板"（全删全建 `miro/sync.ex:110-115`）；GitHub 是"**单个节点出站成一个 issue**"（命令式单次，不是状态镜像）。所以 GithubSync 的绑定单位是 **node→issue**，不是 tree→board。
2. **轮询拉的是 PR/CI 状态，不是节点新增**：Miro `detect_inbound` 吸纳"人在 Miro 新加的节点"回写 ezagent（`miro/sync.ex:147`）；GitHub 轮询拉的是**已挂 PR artifact 的 PR 状态**（open/merged/closed + CI 评价），**只更新节点 artifact 字段**，不 add 新节点（github-outbound spec §3 line 72）。
3. **多一件事：post CI 评价评论**（片5）：在 PR 上 post 非阻塞评论（D2=软提示，不卡合并）。Miro 无对应物。

---

## 1. 完整文件清单

新建 OTP app：`apps/ezagent_plugin_github/`

```
apps/ezagent_plugin_github/
├── mix.exs                                            # 照 mindmap mix.exs：{:ezagent_core, in_umbrella}, {:jason}
│                                                       #   env: [ezagent_plugin: EzagentPluginGithub.Application]
│                                                       #   compilers: ++ [:ezagent_plugin_check]
├── lib/
│   └── ezagent_plugin_github/
│       ├── application.ex                              # use Application + use Ezagent.Plugin（轻插件：无 kinds/behaviors）
│       ├── github.ex                                  # REST client（仿 miro.ex）
│       ├── github/
│       │   └── sync.ex                                # 纯函数：节点→issue payload / PR 状态→artifact patch / CI 评价→comment body
│       └── github_sync.ex                             # GenServer 三件套（建 issue / 轮询 PR / post CI 评论）
└── test/
    └── ezagent_plugin_github/
        ├── github/
        │   └── sync_test.exs                          # 纯函数单测（无网络）
        └── github_sync_test.exs                       # GenServer 单测（Github mock）

根 mix.exs:23 releases 列表 + 加一行：  ezagent_plugin_github: :permanent  （照 miro 之于 mindmap，在 :ezagent_plugin_world 前后）
```

改动的现有文件（最小侵入）：

```
mix.exs:38-47                                          # releases.applications 加 ezagent_plugin_github: :permanent
apps/ezagent_plugin_world/lib/ezagent/world/mindmap_actions.ex
  - handle_dispatch 加 "mindmap.sync_github" 子句（仿 :82）
  - handle_dispatch 加 "mindmap.save_github_creds" 子句（仿 :85）
  - 私有 sync_github/2（仿 sync_miro/2 :116-136）
  - 私有 save_github_creds/3（仿 save_miro_creds/3 :140-160）
apps/ezagent_plugin_world/lib/ezagent/world/mindmap_data.ex
  - 加 github_status/0（仿 miro_status/0 :37，读 read_creds 判 configured?）
```

**注意 world/mix.exs 不需改 deps**——`mindmap_actions.ex:119` 已证 world 跨 app 调 `EzagentPluginMindmap.MiroSync` 而 world/mix.exs deps 里**没列 mindmap**（umbrella release 全编译，runtime 跨 app 调）。GithubSync 同理，只需进 release 列表。

**绝不碰**：`apps/ezagent_web/lib/ezagent_web/router.ex`（不开 inbound）、`apps/ezagent_domain_external_mirror/*`（不复用 EM 域）、`apps/ezagent_core/*`。

---

## 2. 关键函数签名

### 2.1 `EzagentPluginGithub.Github`（REST client，仿 miro.ex）

凭证 `system://credentials/github.yaml`（仿 `miro.ex:29` 的 `Ezagent.System.FsResolver.read_yaml(Ezagent.URI.system("credentials", "github.yaml"))`）。字段：`token`（PAT/fine-grained，必填）、`repo`（`owner/name`，默认仓，可选）。

```elixir
@api "https://api.github.com"

@spec read_creds() :: {:ok, %{token: String.t(), repo: String.t() | nil}} | {:error, term()}
@spec write_creds(%{required(:token)=>String.t(), optional(:repo)=>String.t()|nil}) :: :ok | {:error, term()}
#   ↑ 仿 miro.ex:51-69：FsResolver.path! → File.write → File.chmod 0o600

# --- issue 出站 ---
@spec create_issue(token::String.t(), repo::String.t(), title::String.t(), body::String.t()) ::
        {:ok, %{number: integer(), url: String.t()}} | {:error, term()}
#   POST /repos/{repo}/issues  body %{title, body} → 拿 %{"number","html_url"}

# --- PR 状态轮询拉回 ---
@spec get_pull(token::String.t(), repo::String.t(), number::integer()) ::
        {:ok, %{state: String.t(), merged: boolean(), head_sha: String.t()}} | {:error, term()}
#   GET /repos/{repo}/pulls/{n} → %{"state"(open/closed),"merged_at","head"=>%{"sha"}}
@spec get_pull_files(token::String.t(), repo::String.t(), number::integer()) ::
        {:ok, [%{filename: String.t(), status: String.t(), patch: String.t()|nil}]} | {:error, term()}
#   GET /repos/{repo}/pulls/{n}/files（分页，v1 取首页 per_page=100）

# --- CI 评价 post（片5，D2=软提示）---
@spec post_issue_comment(token::String.t(), repo::String.t(), number::integer(), body::String.t()) ::
        {:ok, %{id: integer()}} | {:error, term()}
#   POST /repos/{repo}/issues/{n}/comments（PR=issue，evaluation 评论走这条；不卡合并）

# :httpc helpers（**逐字照搬 miro.ex:143-196**）：
#   @http_opts [{:body_format, :binary}]  # 防中文 UTF-8 双重编码（miro.ex:142 注释）
#   auth_headers/1：[{~c"Authorization", 'Bearer '<>token}, {~c"Accept", 'application/vnd.github+json'},
#                    {~c"User-Agent", 'ezagent'}]  ← GitHub 强制要 User-Agent，否则 403（与 Miro 唯一 header 差异）
#   GitHub 建 issue 成功码是 201；评论 201；GET 200（与 miro post/get 的 code in [200,201] 一致）
```

### 2.2 `EzagentPluginGithub.Github.Sync`（纯函数，仿 miro/sync.ex）

```elixir
# 节点 → issue payload（仿 miro/sync.ex:52 render_content：status图标+[stage]+title+@owner+metrics+artifacts）
@spec node_to_issue(node :: map()) :: %{title: String.t(), body: String.t()}
#   title = node.title；body = markdown（stage/owner/status/metrics 渲染成正文，artifacts 渲染成链接列表）

# PR 状态 → 节点 artifact 字段补丁（纯对比，决定要不要回写）
@type pr_state :: %{state: String.t(), merged: boolean(), head_sha: String.t()}
@spec pr_status_to_patch(pr_state(), current_artifact :: map()) ::
        {:changed, ci_status :: String.t()} | :unchanged
#   merged→"merged" / closed&!merged→"closed" / open→"open"；与 artifact 现存 ci_status 不同才 :changed

# CI 评价（片5）：节点判据 + PR diff → 软提示评论正文。**纯函数、可单测**。
@spec evaluate_ci(node :: map(), files :: [map()]) :: %{verdict :: :pass|:warn, comment :: String.t()}
#   v1 判据示例（领域逻辑，data 全在 ezagent 真相源）：
#     - node.stage==:pr 但 changed files 为空 → :warn
#     - node.status!=:done 时 PR 已 open → 提示「节点未标 done」
#   verdict 只决定评论措辞，**绝不产 failure status**（D2=软，github-outbound spec line 68）
```

### 2.3 `EzagentPluginGithub.GithubSync`（GenServer 三件套，仿 miro_sync.ex）

绑定单位 = **node（mindmap_uri + node_id）**，不是 tree。Registry key = `"{mindmap_uri}#{node_id}"`。

```elixir
use GenServer
@registry   EzagentPluginGithub.GithubSyncRegistry        # 仿 miro_sync.ex:24
@supervisor EzagentPluginGithub.GithubSyncSupervisor      # 仿 miro_sync.ex:25
@default_interval 60_000                                   # CI 状态秒级延迟可接受（github-outbound spec line 73）

# 件1：建 issue 出站（命令式单次）。world「出站到 GitHub」按钮调这个。
#   建好后回挂 artifact：dispatch mindmap.attach_artifact %{tool:"github",kind:"issue",ref:"#N",url}
#   （仿 miro_sync.ex:171-181 的系统身份 do_dispatch；effect 见 mindmap_actions.ex:53 attach_artifact）
@spec create_issue_for_node(mindmap_uri :: URI.t(), node_id :: String.t()) ::
        {:ok, %{number: integer(), url: String.t()}} | {:error, term()}

# 件2：轮询 PR 状态拉回（tick）。绑定后周期 GET PR → pr_status_to_patch → 变了就
#   dispatch set_metric/attach_artifact 更新节点 ci_status（P14，系统身份）。
@spec bind_pr(mindmap_uri :: URI.t(), node_id :: String.t(), pr_number :: integer(), keyword()) ::
        DynamicSupervisor.on_start_child()        # 仿 miro_sync.ex:37 bind
@spec sync_now(ref :: pid() | {URI.t(), String.t()}) :: {:ok, map()} | {:error, term()}  # 仿 :47

# 件3：post CI 评价评论（片5）。tick 内或手动：evaluate_ci → post_issue_comment。
@spec post_ci_evaluation(mindmap_uri :: URI.t(), node_id :: String.t(), pr_number :: integer()) ::
        {:ok, %{comment_id: integer()}} | {:error, term()}

@spec unbind(ref) :: :ok | {:error, term()}      # 仿 miro_sync.ex:44/teardown：停轮询（GitHub 不删 issue/PR——非破坏）

# 系统身份 dispatch（**逐字照搬 miro_sync.ex:171-184**）：
#   sys_caller = Ezagent.URI.user(:system, :admin)；sys_caps = admin_genesis_cap
#   target = Ezagent.URI.with_action(mindmap_uri, :mindmap, action)  ← sanctioned 构造
#   Ezagent.Invocation.dispatch(%Ezagent.Invocation{target, mode: :call, args, ctx})
```

**读节点真相源**：GithubSync 经系统身份 dispatch `mindmap.get_tree`（仿 `miro_sync.ex:161-166` read_tree），从 tree 取目标 node。**不直接读 mindmap 内部 state**（P14：Kind 间只能 dispatch）。

---

## 3. world 侧改动（仿 sync_miro）

```elixir
# mindmap_actions.ex 加（仿 :82-83）
def handle_dispatch(socket, "mindmap.sync_github", %{"mindmap_uri"=>u, "id"=>id}),
  do: sync_github(socket, u, id)
def handle_dispatch(socket, "mindmap.save_github_creds", %{"token"=>t}=a) when is_binary(t),
  do: save_github_creds(socket, t, Map.get(a, "repo", ""))

# sync_github/3（仿 sync_miro/2 :116-136）：
#   EzagentPluginGithub.GithubSync.create_issue_for_node(uri, id)
#   {:ok,%{number:n,url:url}} → attach artifact + push_event("world:state", %{"github_issue_url"=>url,...})
#   GithubSync 内部已 dispatch attach_artifact，world 这里 re-read 树推回（仿 push_tree :245）

# save_github_creds/3（仿 save_miro_creds/3 :140-160）：
#   admin-gated（Ezagent.Identity.admin?(current_entity_uri)）→ Github.write_creds(%{token:t,repo:r})
#   → push_event("world:state", %{"github"=>MindmapData.github_status(),...})
```

凭证配置 UI（plugin 页，仿 Miro）：复用 mindmap config_surface `/plugins/mindmap`（`application.ex:62`），前端 `Mindmap.tsx` 配置区加 GitHub token/repo 输入 + 「保存」按钮 → `onDispatch("mindmap.save_github_creds", {token, repo})`。**前端不在本 spec 范围（片6 是后端连接器）**，仅留 dispatch 契约。

---

## 4. 单元测试点（httpc 可 mock）

### `github/sync_test.exs`（纯函数，无网络，仿 `test/miro/sync_test.exs`）
- `node_to_issue/1`：title 取 node.title；body 含 `[stage]`/`@owner`/status/metrics；空 metrics/artifacts 不渲染空段。
- `node_to_issue/1`：title 含 `<`、中文 → body markdown 正确（无 HTML escape 误伤，GitHub 用 markdown 非 HTML）。
- `pr_status_to_patch/2`：merged_at 非空 → `{:changed,"merged"}`；state=open & 现存 ci_status="open" → `:unchanged`；closed&!merged → `{:changed,"closed"}`。
- `evaluate_ci/2`：stage=:pr & files=[] → `:warn` + 评论含提示；status!=:done & PR open → 评论含「未标 done」；正常 → `:pass`。

### `github_sync_test.exs`（GenServer，mock Github REST）
- mock 手法：把 `Github` 的 httpc 出口抽成可注入（或用 `:meck`/test 配置 base_url 指向 bypass）。**建议**：`Github` 模块 `@api` 改成 `Application.get_env(:ezagent_plugin_github, :api_base, "https://api.github.com")`，测试用 `Bypass` 起本地 stub（与 ezagent 现有 httpc mock 惯例对齐——确认 feishu/miro 测试是否已有 Bypass dep，无则纯函数层测，GenServer 编排层用 mock module 注入）。
- 件1 `create_issue_for_node`：mock `create_issue` 返回 `#42` → 断言发了 `mindmap.attach_artifact` dispatch（用 test 收 dispatch 的 caller_inbox）+ 返回 url。
- 件2 `bind_pr`+`sync_now`：mock `get_pull` 返回 merged → 断言 dispatch 更新节点 ci_status="merged"；返回 unchanged → 无 dispatch。
- 件3 `post_ci_evaluation`：mock `get_pull_files` + `post_issue_comment` → 断言按 `evaluate_ci` verdict post 了评论，**断言绝不调任何 status/check API（D2 软）**。
- `read_creds` 缺失：`create_issue_for_node` 返回 `{:error, :github_token_missing}`（仿 miro `:miro_access_token_missing` `miro.ex:34`），不 silent。

### `github_test.exs`（REST client，Bypass）
- `create_issue`：201 + body 含 number/html_url → `{:ok,%{number,url}}`；422 → `{:error,{:http_status,422,_}}`。
- `auth_headers`：含 `User-Agent`（缺则 GitHub 403，必测）。
- `{:body_format,:binary}`：中文 title issue body 不乱码（仿 miro 防双编码 `miro.ex:142`）。

---

## 5. 网页 e2e 验收点

仿 `apps/ezagent_plugin_mindmap/test/e2e/miro_live_test.exs`，新建 `github_live_test.exs`（或扩 mindmap world e2e）。**真 GitHub e2e 需真 token**（放 `system://credentials/github.yaml`，CI 用测试仓）：

1. **凭证保存**：admin 登录 `/plugins/mindmap` → 填 GitHub token+repo → 保存 → `world:state` 回 `github.configured==true`；非 admin 保存 → `last_dispatch_status=="error:unauthorized"`（仿 `mindmap_actions.ex:142`）。
2. **建 issue 出站闭环**：节点面板「出站到 GitHub」→ `mindmap.sync_github` → 真建 issue（测试仓出现新 issue）→ 节点 artifact 多出 `%{tool:"github",kind:"issue",ref:"#N",url}` → `world:state` 回 `github_issue_url`。
3. **PR 状态轮询回填**：手动把测试仓 PR merge → 等一个 interval（或 `sync_now`）→ 节点 ci_status 变 "merged"（re-read 树断言）。**真相源恒 ezagent**：GitHub 端无对应回删 ezagent 节点的路径。
4. **CI 评价软提示**：绑一个 stage=:pr 但空 diff 的 PR → `post_ci_evaluation` → 测试仓该 PR 出现一条评论（含 warn 文字）→ **PR 仍可合并**（无 failing status check，断言 GitHub PR mergeable_state 不被 ezagent 改）。
5. **凭证缺失降级**：删 github.yaml → 「出站到 GitHub」→ `last_dispatch_status=="error:github_token_missing"`，不崩、不 silent。

---

## 6. 待定决策（需 Allen 拍板）

1. **偏离 PRD 的 GitHub 双向插件设计**（conflict-ci-datamodel spec §2.2-2.3 已点出）：PRD `05:93`/`01:68`/`03:183` 把 GitHub 设计成飞书式「出站 EM + 入站 webhook→dispatch」双向。本 spec 走**纯出站轮询**，不开 inbound。需 Allen 确认：把「CI 评价」(纯出站轮询)与「状态镜像/PR 合并闭环」(PRD 的 EM push + webhook)拆成两条机制，v1 只做前者。
2. **ci_status 挂哪**：挂 artifact 的新字段（`%{tool,kind,ref,url,ci_status}`，要扩 `behavior/mindmap.ex:18` artifact schema）还是挂 node.metrics？建议挂 artifact（PR 状态属于该 PR artifact 的属性），但扩 schema 要碰 mindmap Behavior——需确认是否在片6 范围内还是片5。
3. **轮询绑定的持久化**：MiroSync 的 bind 是内存态（重启丢，`miro_sync.ex` 无持久化）。GithubSync 的 node→pr 绑定同样内存态 v1 可接受？还是要把 pr_number 也作为节点 artifact 持久化、重启后从树 rehydrate 轮询器？建议 v1 内存态（对齐 Miro），rehydrate 后置。
4. **Bypass/mock 依赖**：确认 umbrella 是否已有 `Bypass`/`:meck` 做 httpc 测试（feishu/miro 当前似乎只测纯函数层）。若无，GenServer 层用「Github 行为注入」(传 module/fun)而非引新 dep。

---

## 7. 对抗审查（2026-06-23，逐条对真实代码核实）

总判：**架构形态（纯出站连接器、零碰 core/web/EM、系统身份 dispatch、body_format binary）成立且贴合**，但 spec 多处 file:line 失准、且踩到 mindmap 自身的 release 缺口与 artifact append 不去重坑。落地前 6 处必改，3 处必决。

### A. 必改（阻塞）

1. **artifact append 不去重 → 件2 轮询每 tick 累积重复 artifact = 快照膨胀（最严重，spec 未点出）**。
   `behavior/mindmap.ex:361-362` `handle_attach_artifact` 是**无条件 `artifacts ++ [..]`**，无 ref 去重（对比 `handle_set_metric:374-380` 按 name 去重）。spec §2.3 件2 说「变了就 dispatch attach_artifact 更新 ci_status」——每次 PR 状态变都 attach 一条新 artifact，N 次轮询 = N 条 issue artifact 堆进节点快照（真相源），无上限。**必改**：件2 回写 ci_status 不能走 attach_artifact，要么走 `set_metric`（已天然去重 by name），要么先 detach_artifact(ref) 再 attach，要么扩 Behavior 加 upsert_artifact。spec §6-#2 把它当「待定」，实际是阻塞 bug。

2. **`ci_status` 字段会被 `normalize_artifact` 直接丢弃**。
   `behavior/mindmap.ex:505-515` `normalize_artifact` 白名单只取 `tool/kind/ref/url/content`，**不存 `ci_status`**。所以 spec §2.3 注释「dispatch attach_artifact %{...ci_status}」写进去也读不回来——必须先改片5 Behavior schema（`behavior/mindmap.ex:18` 的 `artifacts: [%{tool,kind,ref,url}]` + `normalize_artifact`）。这把 spec「不碰片5」的边界打破了，§6-#2 必须升级为「片6 依赖片5 先扩 schema」的硬前置，否则件2 是 silent no-op（违反 CLAUDE.md「不要 silent 失败」）。

3. **`mindmap` 自己根本不在 release `applications` 列表里 → spec 的照搬锚点不存在**。
   `mix.exs:25-46` releases 列了 17 个 app，**没有 `ezagent_plugin_mindmap`**（grep `mindmap` 在 mix.exs 零命中）。spec §1 line 50「照 miro 之于 mindmap，在 :ezagent_plugin_world 前后」引用了一个**不存在的 release 条目**。而且 mindmap 不是任何 app 的 dep（`grep ezagent_plugin_mindmap apps/*/mix.exs` 只命中自己）——意味着 world→MiroSync 跨 app 调**只在 `iex -S mix`/test（umbrella 全编译）下成立，release 里 mindmap 压根没 boot**。spec §1「umbrella runtime 跨 app 调已被 world→MiroSync 引用证实」这条「证实」是假的（dev 模式证实 ≠ release 证实）。**必改**：(a) github app 进 release 列表是对的；(b) 但要同时把 mindmap 补进 release（否则 GithubSync 依赖 mindmap dispatch 的 get_tree 在 release 里无 target），并把 world/github 对这两个 plugin 模块的跨 app 调用**显式声明为 dep 或在 release 里 listed**——这是 P14 dispatch 能落地的前提。建议把 mindmap+github 都补进 releases 并标注此前 mindmap 漏列。

4. **world creds 子句 key 用错**。spec §3 line 175 写 `mindmap.save_github_creds %{"token"=>t}`，但真实 `save_miro_creds` 子句用的是 `"access_token"`（`mindmap_actions.ex:85`），且 `write_creds` 也匹配 `%{access_token: ...}`（`miro.ex:51`）。github spec §2.1 line 81 又把 creds 字段定为 `token`。**必改**：统一字段名（建议 github 用 `token` 自洽，但前端 dispatch payload key、world 子句 pattern、`Github.write_creds` 三处必须一致），别照抄 miro 的 `access_token` 又混用 `token`。

5. **spec 说「GithubSync 内部已 dispatch attach_artifact，world re-read 推回」与真实 sync_miro 不符**。
   `mindmap_actions.ex:116-136` `sync_miro` **不 attach 任何 artifact**，它只拿 `sync_or_bind` 返回的 `board_id` → push `miro_board_url`，re-read 走的是 `push_tree`（节点动作路径 `act/4:107`），**不是** sync_miro 路径。spec §3 line 181「仿 push_tree :245」的行号也对不上（`push_tree` 在文件内，非 :245；本次只读到 170 行已确认 sync_miro 无 attach）。**必改**：明确件1 的 attach 责任归属——是 GithubSync GenServer 内 do_dispatch attach（像 miro_sync `do_dispatch`），还是 world 层 attach；二选一，别两处都写「已 attach」导致重复（又叠加坑 #1）。

6. **file:line 全面对账**。多处锚点偏移，落地照搬会贴错位置：`auth_headers` 真实在 `miro.ex:194-196`（spec line 103-106 写 `:143-196`）；`{:body_format,:binary}` 注释在 `miro.ex:141-143`（spec line 14 写 `:143` 尚可，但 §2.1 line 104 写 `miro.ex:142` 注释 OK）；系统身份 dispatch 真实在 `miro_sync.ex:171-184`（spec 正确）；`read_tree` 在 `miro_sync.ex:161-166`（spec 正确）。**必改**：把所有「逐字照搬 miro.ex:X」的行号按本节核实值更新，尤其 auth_headers。

### B. 必决（需 Allen，spec §6 已列但定性需升级）

- §6-#1 纯出站偏离 PRD `05:93` 双向设计：**确认 v1 只做出站轮询**。形态本身过 gate（不碰 web router/EM/core，符合「GitHub 纯出站」已定决策），但与 PRD 文档冲突需 Allen 背书，否则后续片会按 PRD 双向重写本片。
- §6-#2 升级为 A-2/A-1：**ci_status 落点 + schema 扩展属于片5 还是片6**，必须先定，否则件2 写不进真相源。
- §6-#4 测试依赖：umbrella **当前无 Bypass/meck**（`grep bypass/:meck apps/*/mix.exs` 仅命中注释，无 dep），miro/feishu 只测纯函数层。GenServer 层走「module 注入」不引新 dep，与现状对齐——**建议直接定为注入，不留「待定」**。

### C. 守住的不变式（核实通过，无需改）

- **P14 单一真相源**：GithubSync 经系统身份 `Ezagent.Invocation.dispatch` 读 get_tree / 写节点，不直读 mindmap state；GitHub 端无回删 ezagent 路径——✓ 守真相源（前提是坑 #1/#2 修好让回写真生效，否则是「dispatch 了但没落地」的伪真相源）。
- **per-node CapBAC/R1**：件1/件2/件3 都是受信后台系统身份（`URI.user(:system,:admin)` + `admin_genesis_cap`，对齐 `miro_sync.ex:183-184`），不绕过 Behavior 内 CapBAC；world 凭证保存 admin-gated（`Identity.admin?` 存在于 `identity.ex:159`）——✓ 未破坏。
- **uri_query.scan**：dispatch target 用 `Ezagent.URI.with_action/3`（`uri.ex:379` 存在）而非裸 `?action=`——✓ 过 raw-URI gate。
- **arch.scan oversized**：gate 是 baseline-manifest 棘轮（`arch_baseline_manifest.exs`，>1000 LOC 计数 cap=4），新 app 文件只要各自 <1000 行不触发；github 三件套照 miro（miro.ex 201 / miro_sync.ex 185 / miro/sync.ex 167）量级，远低于 1000——✓ 不触发，但**写完务必 `wc -l` 核对**。
- **doc.scan undocumented**：gate 要求每个 public `def`/`defmodule` 有 `@doc`/`@moduledoc`（`ezagent.doc.scan.ex`）。miro 三件套的 public def 多数有 `@doc` 或 `@doc false`——github 照搬时**每个 public def 必须带 `@doc`/`@doc false`，每模块带 `@moduledoc`**，否则增量计数过 baseline 报红。spec 未提醒，落地时注意。

### D. 其它埋坑（非阻塞但记一笔）

- **两 BEAM/formatter**：creds 写文件用手拼 YAML 字符串（`miro.ex:54-56`），github token 含 `/`、`+` 等需确认不破 YAML（PAT 一般安全，fine-grained token 含下划线/数字也安全）；body_format binary 已防中文乱码——OK。formatter 对新 app 无特殊风险。
- **件2 内存态 bind 重启丢（§6-#3）**：对齐 miro 内存态可接受，但 miro 是「重建自愈」（板还在，重 bind 即可），github PR 轮询重启后**没有自动 rehydrate**，PR merge 信号会漏（节点 ci_status 永远停在重启前值）。v1 接受需显式写进降级说明，别当「对齐 miro 就没问题」。
- **轮询无幂等/无 DLQ**：件2 tick 失败（GitHub 5xx/限流）目前只能靠下一 tick，spec 未写失败可观测性（telemetry/last_error）。对齐 miro `sync` 的 `{err, state}` 静默吞同样的坑，但 github 是「拉状态」语义，漏一次 merge 信号无人知——建议至少 telemetry 出口（CLAUDE.md「这里失败了谁会知道」）。
