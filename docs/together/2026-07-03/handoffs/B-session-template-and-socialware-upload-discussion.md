# Handoff B — SessionTemplate 改动 + socialware 上传/发布机制 讨论

> **修订 (2026-07-03)**：本文档初版**指错了层** —— 把 `PluginPackage.Manifest`
> (`manifest.json`) 当成了 socialware 的上传机制。**那是插件（OTP 代码包）那一层**。
> socialware/app 的上传发布**已有 spec (#1125) + 已落 publish 原语 (#1042)**，走的是
> **ConfigObject + CR-governance + public_view**，不是 plugin manifest。本版已更正。

- **类型**: `clarify_first`（研究 / 设计讨论，**不写实现代码**）。产出 = 对齐文档 + build 切片 + DoD。
- **建议 owner**: gaga 或熟悉 socialware/ConfigStore 的 dev（可与 lead + jjkysy grill）。
- **必读**: skill `ezagent-socialware`、`ezagent-developer`；**先读 #1125 全系列**
  `docs/together/2026-07-01/handoffs/app-socialware/{1..4}.md + README`（这是本主题的**权威 spec**）。
- **一句话目标**: 对齐「**新的 SessionTemplate 机制**」和「**socialware/app 的上传/发布机制**」。
  关键认知修正：**机制不是"没打通",而是"socialware 那条已通、统一 app-package 抽象还没建 ——
  且 #1125 已经把怎么建写死了"**。讨论 = #1125 spec vs 现状差距 + 未定的 open question。

---

## 权威 spec：#1125 已经定义了这套机制（先读它）

`docs/together/2026-07-01/handoffs/app-socialware/`（1 平台使用全流程 / 2 现有概念代码实情 /
3 应有关系+差距 / 4 实现路径）。核心结论：

- **app package = 拟建的上位单元**，一份声明 = 一个 typed ConfigObject at
  `config://<ws>/<kind>/<名>`，**7 字段**：`uses:[plugin]` / `agents:[recipe(+可选 AgentManifest)]` /
  `data:[slice+schema]` / `views:{embedded,public}` / `public_face:CapBAC` /
  `lifecycle:{install/publish/compose}` / `routing:`（接力规则，realized 在 session 层）。
- **socialware = app package 的"公开交付 facet"**（只读投影 + gated 动作），**不是**上位单元（Locked decision #1）。
- 实现路径分两段：**本周硬目标 = 官网上线（不被基座阻塞）**；**官网上线后 = 基座收口**
  （步 1 manifest schema spec / 步 2 泛化 installs / 步 3 统一发布接口 / 步 4 view 统一 / 步 5 conformance gate），
  拿官网 + kanban 当两个 conformance example。

---

## 现状（代码已核对，origin/main）—— 哪些已建、哪些还没

**✅ 已建（"发布一个 socialware"这条今天就能走）**
- **socialware = ConfigObject**：`config://<ws>/socialware/<名>`,经 `DefinitionRegistry`
  (`.../socialware/definition_registry.ex:29`) 寻址。
- **发布原语 = ConfigStore CR governance**（#1042,`apps/ezagent_domain_identity/lib/ezagent/behavior/config_governance.ex`）：
  `open_cr → stage_item → preview_cr → publish_cr`（+ rollback）。**publish = flip 指针 → 触发既有
  sandbox 物化**;发布 cap 就是 config-edit cap,无独立 publisher/reviewer 券,dispatch 到 subject agent。
- **公开面**：`public_view`（`.../socialware/public_view.ex` 匿名门 + `web_anon_access?/1`）+
  `ExternalFeed`（只读投影/feed）。`installation.ex:193 publish_policy/1`（`:auto`）。
- **装配**：`SessionTemplate.installs` 引用 socialware definition 装进会话
  （`installation.ex` `@default_installs ["chat"]` / `resolved_template_installs/2`）。
- **发布单元胖化**：T2 (#1140) 给 socialware `Definition` 加了 `agents:[{recipe,role_name}]` + `views`。

**🚧 已 spec（#1125）未建 —— 这才是要讨论/要建的**
- 统一 **app package** 7 字段声明（`git grep AppPackage / config://…/app/` = 空,已核实）。
- `installs` 仍是 **socialware-only**（`@default_installs ["chat"]` / "Default socialware refs"）,
  未泛化到 app-package（#1125 步 2）。
- `config://<ws>/app/<名>` 寻址**不存在**（只有 `socialware/<名>`）。
- 无单一"发布 app"动作（发布 = 通用 CR-governance 原语 + public_view 拼,#1125 步 3 要收成一个动作）。

---

## 重点：要讨论 / 要拍的问题（多数是 #1125 里 Allen 该落笔的 open question）

1. **OQ-1 可寻址（#1125 步 1②,仍开着）**：app package 用**新开 `config://<ws>/app/<名>`**,
   还是**复用/泛化 `socialware/<名>`**?这决定 installs 泛化和寻址怎么落。

2. **本周要不要动基座?** #1125 明说基座排在**官网上线之后**、且"**不能阻塞官网上线**"。
   那今天关于"上传发布"的讨论,是**只对齐认知**(现状 socialware 那条已够官网上线),
   还是要**现在就启动步 1-3**?（lead 拍优先级。）

3. **`package.yaml` 这个说法**：代码里 socialware 发布**不是 yaml/manifest 文件**,是
   **ConfigObject + CR-governance**。若产品上确实想要"上传一个包文件"式体验,那是**新增
   的导入形态**(文件 → 解析成 ConfigObject → CR 发布),要不要做、跟 `PluginPackage.Manifest`
   (插件代码包,`uses` 层)怎么分工 —— 这是要拍的。

4. **SessionTemplate 近期改动对齐**：T1(role→recipe)、fork(#1139)、SPEC #324(无静默 default)
   之后,SessionTemplate 当前完整形状 + 对建会话调用方的影响,团队要不要统一对齐一遍。

5. **官网这条具体怎么发布**：现状是 `HELLO_DEMO_SEED=1` boot 种子 + `/socialware/chat?session_uri=…`
   （见 #1125 文档 1 Step 3 例 B）。官网上线要的"发布"= 复用 public_view 公开面即可,
   还是要等统一"发布 app"动作?

---

## 交付物（clarify 阶段,不写实现）

一份对齐文档：
- 用 #1125 的概念地图 + 本文的"已建/未建"清单,画出 **SessionTemplate → socialware Definition →
  ConfigStore/CR-governance 发布 → public_view 公开面** 的真实链路,并标出 app-package 抽象的缺口;
- 逐条回答上面 5 个问题,尤其 **OQ-1 寻址** 和 **本周要不要动基座**(给 lead 拍);
- 若要启动基座,把 #1125 步 1-3 落成可执行 build 切片(每片一句话 + 落点文件),标已建/待建;
- DoD(用户层:发布一个 socialware → 拿到公开地址 + 身份寻址 → 建会话能装能跑,附 E2E 证明计划)。

**明确不做**：不写实现代码；不与官网上线抢道（基座是官网之后的事,除非 lead 另拍）。

---

## 怎么快速看现状（命令）

```bash
# 权威 spec（先读）
git show origin/main:docs/together/2026-07-01/handoffs/app-socialware/1-platform-usage-flow.md
git show origin/main:docs/together/2026-07-01/handoffs/app-socialware/4-implementation-path.md
# 发布原语（CR governance）
git show origin/main:apps/ezagent_domain_identity/lib/ezagent/behavior/config_governance.ex | sed -n '1,100p'
# socialware = ConfigObject + 装配 + 公开面
git show origin/main:apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex | sed -n '1,60p'
git show origin/main:apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex | sed -n '1,40p'
# 确认 app-package 抽象还没建
git grep -nE "config://[^\"]*app/|AppPackage" origin/main -- 'apps/**/*.ex'   # 预期：空
# 对照：插件代码包 manifest（另一层,别混）
git show origin/main:apps/ezagent_core/lib/ezagent/plugin_package/manifest.ex | sed -n '51,66p'
```
