# df-prd 自举开发流程 → mindmap 插件 实现 spec

> 把 `docs/discuss/df-prd/07-定版-自举开发流程-10分钟.md` 钦定的「真相源接力链」（9 棒，交接即 gate，spec 卡 Gherkin 一物三用，不达标 drop）映射到现有 `apps/ezagent_plugin_mindmap/`（resource Kind + per-node CapBAC）和 `apps/ezagent_plugin_world/lib/ezagent/world/mindmap_*.ex`（动作/读模型 + react-flow 视觉树）。
>
> **现状基线**：mindmap 是数据资源 Kind（`apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/mindmap.ex:15` `pattern: :resource`，`{:snapshot, :on_change}`），节点形状已含 `parent_id/title/order/stage/owner/status/artifacts/metrics`（`apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:13-20`），动作 = add/rename/move/remove/set_stage/claim/unclaim/set_status/attach_artifact/detach_artifact/set_metric/get_tree/export_markmap/import_markmap。per-node 授权 `owner_or_admin?` 已经在 handler 内如实判（`behavior/mindmap.ex:427`），world 层 dispatch 带登录者身份不放水（`world/mindmap_actions.ex:94-112`）。
>
> **本 spec 的差额**：现有 stage 枚举是 `purpose/value/module/feature/dev/ops`（6 个，behavior `:31` + data `:14`），**与产品的 9 棒接力链不一致**，要换；gate 语义、attachment 分类、插入校验、CI gate、agent 自动编辑、drop 反哺这 6 块现有代码**没有**，要加。
>
> 真相源引用：产品流程 = `07-定版`；spec 卡模板 = `04-spec与用户旅程.md:42-65`；drop/北极星 = `06-产品闭环与有效性评估.md:35,93-102`；节点字段语义 = `03-思维导图.md`。

---

## 1. 9 个固定阶段（替换现有 6 阶段 stage 枚举）

产品的接力链是 9 棒（`07-定版` §一 + demo `NODES` 数组 `07-demo-接力链-多角色视角.html:204-232`）。把它定为 mindmap 的 `stage` 枚举，**顺序固定、语义如下**：

| 序 | stage atom | 中文名 | 这一棒的真相源（交付物）| 默认认领角色 |
|---|---|---|---|---|
| 1 | `:positioning` | 战略/定位 | **一页定位稿**（价值主张为主，PR/FAQ·交易公式作附件）| 产品负责人 |
| 2 | `:metric` | 验证/运营 | **北极星指标**（这个定位对应的"成功度量"+ drop 阈值；实测末尾回收）| 运营 |
| 3 | `:pain` | 痛点 | **排序后的痛点清单**（机会树，每个痛点指向北极星）| 产品 |
| 4 | `:anchor` | 用户锚定 | **岗位↔认领层映射表**（决定后面谁认领）| 产品负责人 |
| 5 | `:ux` | 体验主张 | **主界面线框/原型**（四条 UX 承诺落地）| 产品 + 设计 |
| 6 | `:feature` | 功能/模块 | **功能 spec 卡**（用户故事+Gherkin+ICE+价值卡+挂钩牌，一物三用）| 产品 + 研发 |
| 7 | `:issue` | issue | **issue 本身**（含范围/不做/验收用例）| 研发 |
| 8 | `:test` | 测试 | **对应 Gherkin 的测试套件**（必须全绿才交 PR）| 研发 |
| 9 | `:pr` | PR | **合并后的 PR**（上线触发实测回收 → 回 §2 对照阈值）| 研发 |

**改动点**：
- `apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:31` `@stages` → `[:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr]`
- `apps/ezagent_plugin_world/lib/ezagent/world/mindmap_data.ex:14` `@stages ~w(...)` 同步改成 9 个（顺序必须一致，前端按这个顺序画泳道/接力链）。
- `enrich_parsed/1`（`behavior/mindmap.ex:398`）默认 stage `:feature` 保留（markmap 导入只有拓扑，落最常见的功能棒）。
- `set_stage` 已有，自然支持改阶段；新枚举生效后 `parse_enum` 自动校验。

> **stage 是分类轴、不是权限边界**（`behavior/mindmap.ex` moduledoc 已写明）。9 棒只是给节点贴"它在接力链哪一棒"的标签 + 驱动插入校验（§5）和 gate（§2），不改 CapBAC（权限永远是 admin + node owner）。

> **待定 D1**：stage 是固定 9 枚举，还是允许每个 mindmap 实例自定义阶段集？产品文档钦定固定 9 棒（这是流程纪律本身），建议**硬编码 9 枚举**。若以后要做成「通用流程引擎」则需 Allen 定是否参数化。

---

## 2. gate 语义：每棒交接的「上一棒合格」判据 + status 流转

### 2.1 gate 判据（来自 demo `GATES` 数组 `07-demo:235-244`，逐棒钦定）

每个 `stage[i] → stage[i+1]` 的交接 = 一道 gate，上一棒真相源没过自己的验收，下游不放行：

| gate | pass 判据（合格）| fail（打回）| 能否自动判 |
|---|---|---|---|
| 1→2 positioning→metric | 价值主张明确 + PR/FAQ·交易公式齐（attachment 齐）| 打回重写定位稿 | 半自动：查 attachment 存在性可自动，"明确"需人工 |
| 2→3 metric→pain | 北极星指标可量化、对齐定位（metric 有 name/target/unit）| 重定北极星 | 半自动：metric 字段齐可自动 |
| 3→4 pain→anchor | 痛点按优先级打分排序 + 每个痛点能撬动北极星（每个 pain 节点挂 ICE/挂钩牌）| 补打分/对齐北极星 | 半自动 |
| 4→5 anchor→ux | 零教育成本评估通过 + 每个岗位映射到认领层（映射表 attachment 齐）| 重做用户锚定 | 人工 |
| 5→6 ux→feature | 主界面线框/原型成形 + 四条 UX 承诺落地（原型 attachment 存在）| 重做体验主张 | 半自动：attachment 存在性 |
| 6→7 feature→issue | **功能 spec 卡的 Gherkin 验收用例写全**（spec 卡 attachment 有 ≥1 条 Given/When/Then）| spec 卡没写验收 → 不许开 issue | **可自动**：parse spec 卡 Gherkin 块 |
| 7→8 issue→test | issue 范围/不做明确 + 携带 spec 卡 Gherkin（issue attachment 有 github url + 引用 spec 卡 ref）| 补全 issue | **可自动**：查 issue artifact + 引用链 |
| 8→9 test→pr | 测试套件可跑且对应 Gherkin、**必须全绿**（test artifact 有 CI 绿结果）| 测试不绿 → 不许提 PR/不许合 | **可自动**：读 test artifact 的 status=green |

### 2.2 status 流转（现有 4 态，无须改）

现有 `status: :unassigned | :claimed | :doing | :done`（`behavior/mindmap.ex:17`），不变式 `owner==nil ⟺ status==:unassigned`（`:24`）。映射到产品的「待认领→认领→进行→交接合格」：

```
:unassigned（待分配/待认领）
   --claim_node-->        :claimed（已认领，owner=caller）
   --set_status doing-->  :doing（进行中）
   --set_status done-->   :done（交接合格 = 本棒真相源过 gate）
   --unclaim_node-->      :unassigned（退领）
```

**钦定**：`:done` 的语义 = **"本棒真相源已过 §2.1 gate"**，不是单纯"做完"。即 `set_status(done)` 应在 gate 校验通过后才允许。

**改动点（新动作或 set_status 增强）**：
- 方案 A（最小改动，推荐 MVP）：保留 `set_status` 自由置 `:done`，gate 校验**独立成一个只读动作** `check_gate`（见 §6），UI/CI 调它判，不阻塞人手动改 status。
- 方案 B（强约束）：`set_status(done)` 内嵌 gate 校验，未过 gate 返回 `{:error, :gate_not_passed}`。

> **待定 D2（关键架构决策，找 Allen/用户定）**：gate 是「软提示」（A：人可强推 done，CI 另判）还是「硬闸」（B：done 必须过 gate）？产品 demo 的措辞是"上一件不合格不放行"（偏硬闸），但**自动判 gate 只对 6→9 这几棒可行**（1→5 多是人工判"明确/成形"）。建议：6→9 用硬闸（可自动判的棒），1→5 用软提示（attachment 齐全性自动查 + 人工确认）。这个混合策略需 Allen 拍板。

---

## 3. 节点模型：每阶段挂什么 attachment + 数据/出站分离

### 3.1 复用现有 `artifacts` + `metrics`，不新建字段

现有节点已有两个挂载槽（`behavior/mindmap.ex:18-19`）：
- `artifacts: [%{tool, kind, ref, url}]` —— 挂任意工具产物（`normalize_artifact/1` `:458`）
- `metrics: [%{name, target, current, unit}]` —— 挂指标（`normalize_metric/1` `:462`，按 name upsert）

**每棒挂什么 artifact（用 `tool`/`kind` 区分类型）**：

| stage | artifact.kind | artifact.tool（出站目标）| 备注 |
|---|---|---|---|
| 1 positioning | `:positioning_doc` / `:prfaq` | `feishu`(docx) / `miro`(根节点)| 一页定位稿 + PR/FAQ |
| 2 metric | （用 `metrics` 字段，不用 artifact）| 落 ezagent 库 | 北极星 name/target/unit + drop 阈值放 `metrics` |
| 3 pain | `:pain_card` | `feishu`(bitable) / `xmind`/`miro`(机会树)| 多张痛点卡 + ICE 分 |
| 4 anchor | `:role_map` | `feishu`(bitable)| 岗位↔层映射表 |
| 5 ux | `:wireframe` | `excalidraw`/`lovable`/`zeplin`| 线框/原型 |
| 6 feature | `:spec_card`（**核心，带 Gherkin**）| `feishu`(docx) / `markmap`| spec 卡正文（用户故事+Gherkin+ICE+价值卡+挂钩牌）|
| 7 issue | `:issue` | `github`(REST/GraphQL)| issue url + number |
| 8 test | `:test_suite` | `ci`/`github`| 测试结果 status(green/red) + 覆盖映射 |
| 9 pr | `:pr` | `github`| PR url + merged 状态 |

### 3.2 数据 vs 出站分离（对齐 mindmap 现有 Miro 模式）

mindmap 已经把「数据真相」和「出站镜像」分开（`world/mindmap_actions.ex:116` `sync_miro` 一键推；MiroSync 是插件自有 GenServer，不复用锁死的 external_mirror 域 —— memory `df-tech` 已记）：

- **数据真相落 ezagent 库**：节点树（含 artifacts ref/url、metrics）随 `{:set, :tree, ...}` effect 落核心 KindSnapshot（`mindmap.ex:33` `{:snapshot, :on_change}`），冷启动 rehydrate。**这是真相源**。
- **出站到外部工具**：
  - **Miro**：现成 `mindmap.sync_miro`（`MiroSync.sync_or_bind` `world/mindmap_actions.ex:119`），整张图镜成 Miro 板。
  - **GitHub（issue/PR）**：spec 卡的 `03-思维导图.md:178` 钦定走 external_mirror 出站 adapter（抄 feishu）+ 入站 webhook 走 `Ezagent.Invocation.dispatch/1`（P14 铁律）。**但 memory 提示插件自有同步、不复用 EM 域**——建议 GitHub 也走 mindmap 插件自有的 GithubSync GenServer，与 MiroSync 对称。
  - **飞书**：现成 feishu plugin 出站（`03-思维导图.md:186`）。
- **入站回挂**（github webhook → 更新节点）：webhook 进来 → `Ezagent.Invocation.dispatch/1` 打 `mindmap.attach_artifact` / `mindmap.set_status`（issue 合并 → 对应 issue 节点 status→done）。**入站永远走 dispatch，不许 PubSub.broadcast 到 inbound topic（P14）**。

**改动点**：
- artifact 的 `kind` 现在是自由字符串，建议加一个**校验白名单**（上表的 kind），让 attach 时能按 stage 校验 kind 合法性（gate §2.1 6→9 要靠 kind 找 spec_card/issue/test/pr）。
- 新增 GithubSync GenServer（插件内，对称 MiroSync）+ 入站 webhook 端点（Phoenix transport adapter，dispatch 进来）。**这是第二大自研块**（`03-思维导图.md:178`）。

> **待定 D3**：GitHub 出入站走「插件自有 GithubSync」（对称 MiroSync，memory 偏好）还是「external_mirror 域的 push/pull adapter」（`03/04` 文档原话）？两个文档源不一致。建议**插件自有**（与 Miro 对称、EM 域锁死 session 语义），但需 Allen 确认。

---

## 4. claim / 权限：对齐现有 per-node CapBAC（基本无改动）

产品要求「任何人可编辑/claim，claim 后只 owner 编辑，admin 增删」—— **现有代码已经完全这样实现**：

- **任何持 mindmap 实例 cap 的人可 claim 未分配节点**：`handle_claim_node`（`behavior/mindmap.ex:270`）只拒 `already_claimed`，未分配谁都能领。
- **claim 后只 owner（或 admin）编辑**：`owner_or_admin?(ctx, node)`（`:427`）= `admin?(ctx) or node.owner == caller`。所有写动作经 `update_node`（`:407`）统一查。验证见 `test/e2e/capbac_test.exs`（非 owner 非 admin 持 cap 仍被 handler 拒）。
- **admin 增删**：建根 = admin（`:187`）；删节点 = owner_or_admin（`:247`）；import_markmap 覆盖 = admin（`:363`）。
- **两层 cap**：实例级 cap（`data_owner: :no_owner` `:171`，per-instance 收口，dispatch 边界查）+ per-node owner（handler 内查）。world 层带登录者 `current_entity_uri`/`current_caps` 不放水（`world/mindmap_actions.ex:229-235`）。

**唯一可能的差额**：产品说"任何人可编辑"——现状是"任何持 mindmap cap 的人"。若要真正「任何登录者（含匿名旁观）可编辑未认领节点」，需放宽实例 cap 授予（给所有 workspace member 发 mindmap cap）。**这是授予策略，不是 behavior 改动**。建议保持现状（持 cap 才能动），匿名旁观者只读（对齐 socialware public_view）。

> **无新决策**：§4 现状即满足产品需求，仅需在 seed/membership 时给 member 发 mindmap 实例 cap。

---

## 5. 插入规则：阶段顺序固定，每阶段可多节点，单调不回插

产品规则（`07-定版` §一 + 用户口述）：**阶段顺序固定**；**每阶段可多节点形成大图**；**"产品→issue 的图中间可插产品节点，但 issue 后不能插产品节点"** —— 即沿接力链方向，**子节点的 stage 不能早于（小于）其在链上的位置**。

### 5.1 确切校验规则

定义 `stage_index(s)` = 该 stage 在 9 枚举里的序号（1..9）。

**规则 R1（add_node / move_node 时校验）**：新节点/被移动节点的 `stage_index` **必须 ≥ 父节点的 `stage_index`**。
- 现有 `handle_add_node`（`:200`）新节点 stage 默认继承父节点 stage（`stage = nodes[parent_id].stage`）—— 默认就满足 R1。
- 但 `set_stage` 可事后改 stage，move_node 可换父 —— **这两处要加 R1 校验**：
  - `set_stage(id, s)`：若 `stage_index(s) < stage_index(parent.stage)` → `{:error, :stage_before_parent}`。同时若该节点有子节点，新 stage 不能晚于任一子节点 stage（否则子树违反 R1）→ `{:error, :stage_after_child}`。
  - `move_node(id, new_parent)`：若 `stage_index(node.stage) < stage_index(new_parent.stage)` → `{:error, :stage_before_parent}`。
- **直觉对照产品话术**："产品(feature)→issue 之间可插 feature 节点"= 在 feature 父下加 feature 子，`stage_index` 相等，R1 通过；"issue 后不能插 feature"= 在 issue 父下加 feature 子，`feature_index(6) < issue_index(7)`，R1 拒。

**规则 R2（每阶段多节点）**：同一 stage 下可挂任意多个兄弟节点（现状已支持，order 递增 `:199`）。无须改。

**规则 R3（根节点）**：根 = `:positioning`（现 add_node 建根默认 `:purpose` `:200`，**改成 `:positioning`**）。

**改动点**：
- `behavior/mindmap.ex` 加 `stage_index/1` helper + R1 校验，注入 `handle_set_stage`（`:258`）和 `handle_move_node`（`:214`）。
- `handle_add_node` 建根默认 stage 从 `:purpose` 改 `:positioning`（`:200`）。

> **待定 D4（边界语义，建议自定但可问用户）**：R1 用 `≥`（子可与父同棒，允许 feature 下挂 feature）。是否允许"跳棒"（positioning 直接挂 pr 子）？R1 的 `≥` 允许跳跃。产品要的是"不回插"，跳跃前进应允许 → `≥` 正确。确认即可。

---

## 6. CI gate：PR 提交时拿「PR 前的节点+attachment」当 github 判据

产品（`07-定版` §三.3 + `06`）：PR 必须**只动该功能 spec 卡范围内的东西，超范围一律砍**；reviewer 过 gate 清单逐条勾（含"测试是否覆盖 spec 卡每条 Gherkin"）。

### 6.1 实现路径

mindmap 是真相源 → CI/github action 需要一个**只读接口**把"这个 PR 对应的 feature 子树（spec 卡 Gherkin + issue + test）"读出来当判据。

**新增只读动作 `check_gate`（mindmap Behavior）**：
```
action :check_gate, args: %{id: :string}, returns: %{passed: :boolean, reasons: :list}, modes: [:call]
# 给定一个节点 id，沿接力链校验它到上游每一棒的 gate（§2.1），返回是否全过 + 不过原因
```
- 对 PR 节点（stage `:pr`）调 `check_gate`：回溯它的祖先链（test→issue→feature），逐棒查 §2.1 的可自动判据（feature 有 spec_card 且 Gherkin 非空、issue artifact 存在、test artifact status=green）。
- **超范围检测**：PR 的 artifact 里记 changed files；feature spec 卡里记 scope（可挂在 spec_card artifact 的 metadata）。`check_gate` 比对 PR changed files ⊆ spec 卡声明范围 → 超出则 `passed: false, reason: :out_of_scope`。

**github action 怎么读**：
- 方式 1（推荐）：mindmap 插件暴露一个 **HTTP 只读 endpoint**（Phoenix route，如 `GET /api/mindmap/gate?node=<id>`），内部 dispatch `check_gate`，返回 JSON。github action 用 PR body 里的节点 ref 调它，非绿则 fail check。
- 方式 2：github action 直接 dispatch（需 ezagent 在 CI 网络可达 + cap）。MVP 用方式 1。

**改动点**：
- behavior 加 `check_gate` 只读动作 + gate 校验逻辑（复用 §2.1 表，先做可自动判的 6→9）。
- 加 Phoenix 只读 endpoint（`:ezagent_web_mindmap` 或挂 world 路由）。
- spec_card artifact 增加结构化 `gherkin: [...]` + `scope: [glob]` 字段（attach 时校验）。

> **待定 D5**：CI gate 的「超范围」判据需要 spec 卡声明 scope（文件 glob）。产品文档没给 scope 的确切格式。建议 spec_card artifact 带 `scope: ["apps/foo/**"]`，PR artifact 带 `changed_files: [...]`，`check_gate` 做子集判定。格式待用户确认。

---

## 7. agent 自动编辑 mindmap：cc agent 身份 + dispatch mindmap 动作

产品（`03-思维导图.md` §5.3 + §6.2）：每人一个 agent 盯节点；进一步要一个 **cc agent 自己编辑这张 mindmap**。

### 7.1 路径（无新机制，组合现有）

- **agent 身份**：spawn 一个 `entity://<ws>/agent/<name>`（`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex`），给它发 mindmap 实例 cap（`Ezagent.Capability.cap(:mindmap, Ezagent.Behavior.Mindmap, :any)`），并让它 claim 自己负责的节点（claim 后成 owner，能改）。
- **agent dispatch mindmap 动作**：agent 的 ctx.caller = 它的 entity URI，caps 含 mindmap cap。它走标准 `Ezagent.Invocation.dispatch/1`（与 world 层 `act/4` `world/mindmap_actions.ex:99` 完全相同的路径），target = `Ezagent.URI.with_action(mindmap_uri, :mindmap, action)`。**per-node CapBAC 对 agent 一视同仁**（agent 是 node.owner 才能改它认领的节点），无需特例。
- **cc flavor**：agent 用 cc flavor 时，给它一个 MCP tool / system prompt 描述 mindmap 的 14 个动作（add_node/claim/set_status/attach_artifact/...），它自然能调。MVP 先 curl flavor 验证"能读自己节点 + 能 set_status/attach"（`03:144`）。

### 7.2 典型自动流（三位一体兜底，`03:141`）

agent 监测自己 owner 的 feature 节点 → 发现缺 issue 子节点 → 自动 `add_node(parent=feature, stage=issue)` + `attach_artifact(github issue url)` → set_status。或：盯到 PR 合并 webhook → `set_status(pr_node, done)`。

**改动点**：
- 无 behavior 改动（dispatch 路径现成）。
- 需要：(a) seed 一个 agent + 发 cap 的脚本；(b) 给 cc flavor 配 mindmap 动作的 tool 描述/system prompt；(c) 一个让 agent 周期性"看自己节点"的触发器（定时 dispatch get_tree filter by owner）。
- **per-owner 读**：现有 `get_tree` 返回整树，前端过滤。agent 场景建议加一个只读便利动作 `my_nodes`（args 空，按 ctx.caller filter owner），减少 agent 处理负担。可选。

> **无新架构决策**：agent 自动编辑完全复用现有 dispatch + CapBAC + agent 域，是组合而非新机制。仅工程量（flavor 配置 + 触发器）。

---

## 8. drop 闭环：指标不达标砍子树 + 反哺痛点

产品（`07-定版` §三.4 + demo `DROP_SUBTREE=[6,7,8,9]`, `DROP_FEEDBACK_TO=3` `07-demo:271-272`）：PR 上线后实测指标回收，窗口内未达北极星阈值（如小红书帖 7 天阅读 <500）→ **砍掉该功能子树（feature→issue→test→pr）的节点/分支，反哺回 pain 重选痛点**。

### 8.1 映射到现有动作

- **回收实测指标**：metric 采集器（PostHog/Umami/Metabase，`07-定版` §二·补）把实测拉回 → dispatch `mindmap.set_metric(id, %{name, current, target, unit})`（现成 `:331`，按 name upsert `current`）。落在该 feature/metric 节点上。
- **判 drop**：新增只读 `check_drop`（或扩 `check_gate`）：某 metric 节点 `current < target`（或文档说的窗口阈值）→ 标记该子树待 drop。
- **砍子树**：现成 `remove_node`（`:240` 级联删整个 subtree，`subtree_ids/2` `:489`）。对 feature 节点调 `remove_node` 即砍掉 feature→issue→test→pr 整条（它们是 feature 的后代）。**只 owner/admin 能删**（CapBAC 不变）。
- **反哺痛点**：drop 时**自动在对应 pain 节点下加一个回溯节点**记录"这个 feature 因 X 指标未达被砍，重选痛点"——dispatch `add_node(parent=对应pain节点, title="drop反哺: ...")` + `attach_artifact`（drop 报告）。"对应 pain 节点"= 该 feature 子树往上回溯到的 pain 祖先（沿 parent_id 找 stage==:pain 的祖先）。

**改动点**：
- 新增只读 `check_drop`（metric current vs target 比对，返回待 drop 的 feature 子树根 id 列表）。
- drop 动作 = 组合 `remove_node`（砍）+ `add_node`（反哺 pain）。可做成一个便利动作 `drop_subtree(id)` 在 behavior 内原子完成两步，或在 world/agent 层编排两次 dispatch。**建议 behavior 内 `drop_subtree` 原子动作**（避免砍了没反哺的中间态）。
- 反哺找 pain 祖先 = 复用 `ancestors/2`（`:481`）filter stage==:pain。

> **待定 D6（小，建议自定）**：drop 阈值判定窗口（"7 天阅读<500"里的 7 天窗口）放哪？建议 metric 字段扩 `%{name, target, current, unit, window_days}`，`check_drop` 读 window。或简化为只比 current<target（窗口由采集器负责）。建议简化版 MVP。

---

## 分片实现建议（每片 e2e 验收点 + 标注待定）

> 现状基线已经做完「节点模型 + per-node CapBAC + Miro 出站 + markmap + react-flow 视觉树」（df-tech worktree）。以下是把它对齐 9 棒产品流程的增量分片，**按依赖排序**。

### 片 1 · 9 阶段枚举对齐（地基，P0，无待定）
改 `@stages`（behavior `:31` + data `:14`）为 9 枚举 + 建根默认 `:positioning`。
- **e2e**：新建 mindmap，根节点 stage=positioning；`set_stage` 9 个枚举都能设、非法值拒；前端接力链按 9 棒顺序渲染。改 `test/behavior/mindmap_test.exs` 的 stage 断言。

### 片 2 · 插入校验 R1（P0，依赖片1，待定 D4 仅需确认）
加 `stage_index/1` + R1 校验注入 `set_stage`/`move_node`，建根默认改。
- **e2e**：feature 父下加 feature 子（通过）；issue 父下加 feature 子（拒 `:stage_before_parent`）；move 一个 pr 节点到 feature 父下（拒）。

### 片 3 · attachment 分类 + kind 白名单（P0，依赖片1，待定 D3 不阻塞本片）
artifact `kind` 白名单（§3.1 表）+ attach 时按 stage 校验 kind；spec_card artifact 加结构化 `gherkin`/`scope` 字段。
- **e2e**：feature 节点 attach `kind: :spec_card` 带 gherkin（通过）；issue 节点 attach `kind: :spec_card`（拒，kind 不属于该 stage）；metric 落 `metrics` 字段而非 artifact。

### 片 4 · gate 校验 + check_gate 只读动作（P1，依赖片1+3，**待定 D2 需 Allen 先定软/硬闸**）
实现 §2.1 的可自动判 gate（6→9）+ `check_gate` 动作 + `:done` 语义。
- **e2e**：feature 节点无 Gherkin → `check_gate` returns passed=false reason=gherkin_empty；补 Gherkin → passed=true；test 节点 artifact status=red → 8→9 gate fail。

### 片 5 · CI gate endpoint（P1，依赖片4，待定 D5 scope 格式）
Phoenix 只读 endpoint `GET /api/mindmap/gate?node=<id>` → dispatch check_gate → JSON；超范围检测（PR changed_files ⊆ spec scope）。
- **e2e**：curl endpoint 拿到 pr 节点 gate JSON；PR changed_files 超出 spec scope → passed=false out_of_scope；mock github action 调它非绿则 fail。

### 片 6 · GitHub 出入站（P1，第二大自研，**待定 D3 需 Allen 定 插件自有 vs EM 域**）
GithubSync GenServer（出站 issue/PR，对称 MiroSync）+ 入站 webhook → dispatch（P14）。
- **e2e**：issue 节点 set_status → 推 github issue；github PR merged webhook → dispatch set_status(pr_node, done)（入站走 dispatch 不走 PubSub）。

### 片 7 · agent 自动编辑（P2，依赖片1-3，无新决策）
seed agent + 发 mindmap cap + cc flavor tool 描述 + 周期触发器 + 可选 `my_nodes` 只读动作。
- **e2e**：curl flavor agent claim 一个节点 → set_status → attach_artifact，全程经 dispatch + per-node CapBAC（agent 是 owner 才能改）；agent 答"我认领节点进度如何"。

### 片 8 · drop 闭环（P2，依赖片1+3+6，待定 D6 小）
`check_drop` + `drop_subtree(id)` 原子动作（remove_node 砍 + add_node 反哺 pain 祖先）。
- **e2e**：feature 节点 metric current<target → check_drop 标待 drop；drop_subtree → 整条 feature→issue→test→pr 被级联删 + 对应 pain 节点下出现"drop 反哺"子节点。

---

## 待定决策汇总（找 Allen / 用户拍板）

| # | 决策 | 建议 | 阻塞哪片 |
|---|---|---|---|
| **D2** | gate 软提示 vs 硬闸 | 6→9 可自动判的用硬闸，1→5 用软提示+人工确认 | 片 4/5（**最关键**）|
| **D3** | GitHub 出入站走 插件自有 GithubSync vs external_mirror 域 | 插件自有（对称 Miro，EM 域 session 语义锁死）| 片 6 |
| **D5** | CI gate「超范围」的 spec scope 声明格式 | spec_card artifact 带 `scope:[glob]`，PR 带 `changed_files`，做子集判 | 片 5 |
| D1 | stage 固定 9 枚举 vs 实例自定义 | 固定 9（流程纪律本身）| 片 1 |
| D4 | 插入 R1 用 `≥`（允许跳棒前进）| 是，`≥` 满足"不回插" | 片 2 |
| D6 | drop 窗口（7 天）放 metric 字段 vs 采集器 | MVP 简化为 current<target，窗口归采集器 | 片 8 |

> 其余（片 1/2/3/7）是纯工程映射、无新架构决策，可直接开工。**建议先做 D2**（决定 gate 是不是硬闸，影响片 4-5 整个 CI 闸的形态），再排片。
