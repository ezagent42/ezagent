# 剩余片实施总纲（片4 gate / 片5 CI / 片6 GithubSync / 片8 drop）

> 写于 2026-06-23。worktree `df-tech`。综合 4 份 impl spec：
> `2026-06-23-impl-gate.md`(片4) / `impl-ci.md`(片5) / `impl-github.md`(片6) / `impl-drop.md`(片8)。
> 锁定前提（全片共享，不再重开）：**D2 = 全软提示**——gate/CI 只「标记+评价」永不硬拦；
> **CI 内容 inline 存 ezagent**（`artifact.content`，8KB cap `behavior/mindmap.ex:503`）；
> **GitHub 纯出站轮询**（不开 inbound、不碰 web router / external_mirror 域 / core）。

---

## ① 依赖序（哪片先做）

```
片8(drop)   ──┐  独立，可任意时刻并行（只碰 mindmap.ex + mindmap_actions，无跨片依赖）
              │
片4(gate)   ──┤  独立，纯 behavior 只读动作 + 前端徽章
              │
片5(CI)     ──┤  纯函数评价模块，但产物 schema 依赖见下 ⚠
              │
片6(Github) ──┘  ★依赖片5★：GithubSync 调片5 check_pr_gate 出评论；
                  且依赖 mindmap 先扩 artifact schema 存 ci_status
```

**钉死的顺序结论**：

1. **片8 与片4 完全独立**，可最先做或并行。两者都只在 `mindmap.ex` 加一个动作 + 改 `mindmap_actions.ex` 加一条子句，互不重叠（片4 加 `check_gate` 只读、片8 加 `drop_subtree` 写）。
2. **片4(gate) 先于 片5(CI)，但不是硬依赖**——两者评价判据高度重叠（都查 spec_card content 的 Gherkin、都查 status）。片4 是「单节点派生评价（前端徽章）」，片5 是「PR 节点跨祖先链 + scope/Gherkin 覆盖（出 PR 评论）」。**建议片4 先落，片5 复用片4 钉死的 artifact `kind` string 词表与 Gherkin 正则**，避免两套判据漂移。若片5 先做也能跑，但 kind 词表必须先统一（见 §3）。
3. **片6 依赖片5**：impl-github §2.2 `evaluate_ci` 与 §6-#2 明确 GithubSync tick 调片5 的 `check_pr_gate` post 评论。**且 片6 反向打破「不碰片5」边界**——impl-github 对抗审查 A-2 指出 `ci_status` 字段会被 `normalize_artifact`(`mindmap.ex:505-515` 白名单 `tool/kind/ref/url/content`)直接丢弃，**必须先在 mindmap Behavior 扩 artifact schema** 才能让片6 件2 回写真生效。所以真实依赖链是：**mindmap schema 扩展（片5 范畴）→ 片5 评价函数 → 片6 出站连接器**。

**推荐落地序：片8 ≈ 片4（并行）→ 片5（含 schema 扩展）→ 片6。**

---

## ② 每片网页 e2e 验收点（复用 full3.mjs 模式）

现有 `docs/superpowers/evidence/assets/full3.mjs` 已确立黄金模式：playwright-core + 真 chrome、`admin@ezagent.chat/worlddev` 登录、**复用已有 session**（进 `/sessions` 点第一个 `Open`，避开 create+reload 的 flaky）、`page.on('dialog')` 按 prompt 文案分支应答。每片新增一段，复用同一 session、同一 dialog 处理器：

- **片4 gate**（impl-gate §6 F1-F3）：选无 Gherkin 的 feature 节点 → NodePanel 出 ⚠ + reason「缺 spec_card / Gherkin 为空」、卡片黄徽章；「加内容」挂 `Given/When/Then` content → 徽章变绿 ✓ reason 消失；手动置 `status=done` 但 gate=warn → 卡片红边高亮但**操作成功不报错**（软提示铁证）。full3.mjs 的 dialog 已会应答 `Given 用户登录 When 点提交 Then 跳转`，可直接复用。
- **片5 CI**（impl-ci §6 read-model 侧 + 出站评论由片6 验）：纯函数无前端往返，e2e 主要是 NodePanel 上 pr 节点的 ci 徽章（绿 3/3 / 黄 1-2 / 灰 0）。复用 session 建 pr 节点 + spec_card(带 scope+Gherkin) + pr artifact(changed_files) → 断言徽章 score。
- **片6 Github**（impl-github §5，**需真 token** 放 `system://credentials/github.yaml` + 测试仓）：admin `/plugins/mindmap` 填 token+repo 保存 → `github.configured==true`；节点「出站到 GitHub」→ 真建 issue + 节点多出 `kind:"issue"` artifact；PR merge 后等一 interval/`sync_now` → `ci_status` 变 merged；空 diff PR → post warn 评论但 **PR 仍可合并**；删 creds → `error:github_token_missing` 不 silent。
- **片8 drop**（impl-drop §6）：admin dispatch `mindmap.drop_subtree` → `last_dispatch_status=="ok"`、re-read tree 不含子树、pain 节点带 `drop_record`；非 owner 非 admin → `error:forbidden` 树不变；drop 后 Kind 重启子树不复现（持久化）；`metric{target:3,current:1}` 节点 read_tree `metric_breached==true`。

**flaky 规避（全片）**：一律复用已有 session（不 create）；多 prompt 用 `dialog` message 内容分支；node 选中用 `.react-flow__node`，面板等 `aside:has-text("节点属性")`。

---

## ③ 跨片共享文件冲突点（协调）

四片都改这三个文件，**串行合并 / 加子句不删行**：

| 文件 | 片4 | 片5 | 片6 | 片8 | 冲突性质 |
|---|---|---|---|---|---|
| `behavior/mindmap.ex` | 加 `action(:check_gate)`+handler+6 判定基元 | **扩 artifact schema 存 ci_status** + `normalize_artifact` 白名单加字段 | 依赖片5 schema（不直接改） | 加 `action(:drop_subtree)`+handler | 三片各加一个 action 宏 + handler。`required_caps/0`(`:150` list) 四处都要加项。**`normalize_artifact`(`:505-515`) 是片5/片6 的高危共享点**——加 `ci_status` 字段影响所有 artifact 读路径。 |
| `mindmap_actions.ex` | 加 `mindmap.check_gate` 子句（路 B，可选） | 改 read model 给 pr 节点附 ci 摘要 | 加 `sync_github`+`save_github_creds` 子句 | 加 `drop_subtree` 子句 | 都在 `:89` catch-all(`handle_dispatch(_,_,_)`)**之前**插子句，互不删行。注意片6 creds 字段名 `token` vs miro 的 `access_token`（impl-github A-4 必改：前端 payload / 子句 pattern / `write_creds` 三处一致）。 |
| `Mindmap.tsx` / `MindmapCanvas.tsx` | gate 徽章 + `gateVerdict()` 导出 + NodePanel reason 列表 | pr 节点 ci 徽章（绿/黄/灰 by score） | GitHub token/repo 配置区 + 「出站」按钮 | metric 红标 + 「砍子树」按钮 + 原因输入框 | **NodePanel 是四片都改的热点**。徽章/按钮各占一块，建议每片加独立子组件（`<GateBadge>`/`<CiBadge>`/`<DropButton>`），别挤进同一 JSX 块。片4 `gateVerdict` 与片5 ci 判据共享 kind 词表/Gherkin 正则，前端这份要对齐后端。 |
| `mindmap_data.ex` | 路 A 不改；路 B 不改 | 加 pr 节点 `ci` 摘要字段 | 加 `github_status/0` | （可选）加 `metric_breached?` + `jsonable_node` 加布尔 | `jsonable_node/1`(`:149`) 是共享整形点，片5/片8 都往里加字段——**加字段兼容、删/改字段才破**，注意前端不依赖旧字段集。 |

**协调建议**：合并序按 §1（片8/片4 → 片5 → 片6）。每片在 `required_caps/0`、`jsonable_node/1`、NodePanel 三处用「加项不删项」，rebase 冲突仅在这三处人工 resolve。

---

## ④ 汇总待定架构决策（标找谁）

### ★最关键（必须 Allen 拍板，否则阻塞 / 返工）★

- **★ D-CI-1（模块归属，阻塞片5/片6）**：`MindmapCi` 放 world 还是下沉 `EzagentPluginMindmap.Ci`？impl-ci 对抗审查 M3 证据偏向**下沉 mindmap**（`ezagent_plugin_github` 当前不存在、`world/mix.exs` 不含 mindmap dep，留 world 会形成 github→world 脏依赖）。spec 正文 §4/§5 自相矛盾，**开工前必落定**否则文件清单是错的。→ **找 Allen**。
- **★ D-github-1（纯出站偏离 PRD，阻塞片6）**：PRD(`05:93`/`01:68`/`03:183`) 把 GitHub 设计成飞书式「出站 EM + 入站 webhook」双向；本片走纯出站轮询。需 Allen 背书「v1 只做出站」，否则后续片会按 PRD 双向重写。→ **找 Allen**。
- **★ ci_status 落点 + schema 扩展归片5 还是片6（阻塞片6 件2）**：impl-github A-1/A-2 指出 `attach_artifact` 无去重(`mindmap.ex:361`)会每 tick 累积重复 artifact = 快照膨胀；且 `ci_status` 被 `normalize_artifact` 丢弃。**必须先定：扩 schema + 回写走 `upsert`/`set_metric`/`detach+attach` 哪条**。这是真 bug 不是「待定」。→ **找 Allen（涉及 Behavior schema 改动）**。

### 实现细节（开工就地定，不阻塞，可工程师自决）

- D-gate-1：`:test` 绿/红编码 → 约定 `%{kind:"test_suite", ref:"green"|"red"}`。
- D-gate-2：前端徽章路 A（本地算）vs 路 B（dispatch 权威）→ **建议 MVP 仅路 A**（impl-gate 必改2：`act/4` 丢 result payload，路 B 需新写子句，降级路 A 绕开）。
- D-gate-3：pr 棒回溯按 parent 链 vs 按 feature 子树 → 建议 feature 子树。
- D-CI-2/D-CI-3：scope `scope:` 行 / Gherkin 块 / test `covers:` 行的 content 格式 → 用 impl-ci §2 轻量约定；**parser 实现强依赖此格式锁定**，开工前须从「待定」升「已定」。
- D-drop-3/D-drop-4：miss pain 祖先静默仍删 / 反哺绕 pain owner 检查 → impl-drop 对抗审查已核实成立。
- 片6 测试 mock：umbrella **无 Bypass/:meck** → GenServer 层用「module 注入」不引新 dep（impl-github B 建议直接定，不留待定）。

### 全片共享必改（非决策，是落地红线）

- **doc.scan ratchet**：每个新 public `def`（`handle_check_gate`/`check_pr_gate`/`handle_drop_subtree`）必带 `@doc false`，否则 CI 红（四片对抗审查均点名）。
- **string-key 边界（片5 M1）**：`read_tree` 产物是 string-key/string-value JSON，`check_pr_gate` 解构 atom-key 会恒静默 false（dead gate，违 CLAUDE.md「不 silent 失败」）——必须二选一写死。
- **artifact kind 是 string（片4 必改1）**：判定基元写 `kind==:spec_card`(atom) 永远 false；现有 UI 挂 `"spec"` 不是 `"spec_card"`——统一 UI 与判据 kind 词表。

---

## ⑤ 每片预估改动规模

| 片 | behavior/mindmap.ex | mindmap_actions.ex | 前端 tsx | 新模块/新文件 | 单测 | e2e | 总量级 |
|---|---|---|---|---|---|---|---|
| **片4 gate** | +60~80 LOC（action+handler+6 判定基元） | +0~8（路 B 可选） | +50（gateVerdict 导出 + 2 处徽章） | — | 10 点 | E1-E3 + F1-F3 | **中（~150 LOC）** |
| **片5 CI** | +~20（扩 artifact schema + normalize 白名单） | +少量（read model ci 摘要） | +30（ci 徽章） | `mindmap_ci.ex` ~150 LOC | ~12 点纯函数 | read-model 侧 | **中（~200 LOC）** |
| **片6 Github** | 依赖片5（不直接改，除 schema 已由片5 改） | +~40（2 子句+2 私有 fn） | +配置区（契约留口，非本片） | 整个新 OTP app `ezagent_plugin_github/`：github.ex(~200)+sync.ex(~167)+github_sync.ex(~185)+application.ex+mix.exs，照搬 miro 三件套 | 3 文件单测 | §5 真 token 5 点 | **大（~600 LOC + 新 app + release 列表改）** |
| **片8 drop** | +~50（action+handler+2 私有 fn） | +2（一条子句） | +30（红标+drop 按钮+原因框） | — | 11 点 | §6 5 点 | **小~中（~90 LOC）** |

> 片6 最大（新建 OTP app + 改根 `mix.exs` release 列表，impl-github A-3 还要补 mindmap 自己进 release——当前 mindmap 漏列，release 里压根没 boot）。片8 最小最独立。

---

## 返回摘要

**依赖序**：片8(drop)、片4(gate) 互相独立可并行最先做 → 片5(CI，含 mindmap artifact schema 扩展) → 片6(GithubSync，调片5 评价 + 依赖片5 扩的 schema 回写 ci_status)。

**每片一句话**：片4=在 `:done` 上叠只读 `check_gate` 派生评价 + 前端 pass/warn 徽章（软提示，不拦 status）；片5=纯函数 `check_pr_gate` 沿祖先链算 上游done/scope子集/Gherkin覆盖 三判据出 markdown 评语；片6=照搬 Miro 三件套的纯出站连接器，建 issue + 轮询 PR 状态回填 + post 软提示评论，不开 inbound；片8=`drop_subtree` 级联删子树 + 最近 pain 祖先记一笔反哺，人工触发、不自动。

**最关键待定决策（均找 Allen）**：① D-CI-1 `MindmapCi` 模块归属（证据偏向下沉 mindmap，否则 github→world 脏依赖，正文自相矛盾，开工前必定）；② D-github-1 GitHub 纯出站 vs PRD 双向（需背书 v1 只出站）；③ ci_status 落点 + artifact schema 扩展归属（`attach_artifact` 无去重 + `normalize_artifact` 丢字段是真 bug，必先定 upsert 路径）。三者都涉及 Behavior schema / 跨 app 依赖方向，工程师不能自决。
