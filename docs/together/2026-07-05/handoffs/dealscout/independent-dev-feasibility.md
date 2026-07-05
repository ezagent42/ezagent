# 独立开发者可行性：只写自己的文件、零改已有代码，能不能定义 agent / 开发 plugin / 开发 socialware

> **Date:** 2026-07-03 · **Base:** upstream/main `622b10e0`（file:line 实读核实）
> **判定标准:** "只写自己的文件" = 只允许**新增**文件（新 plugin OTP app / 新 .ex 模块 / 新 seed 脚本），**禁止编辑任何现存 .ex/.exs/config**——包括往某个 registry 的 `roles/0` 塞一项、往 `builtin_definitions` 加一条、改 `application.ex` children、改 `config/*.exs`。这才是"独立扩展"的真门槛。

---

## 0. 一句话结论

**在 dev/test 和运行时热装两种模式下，三条路都能"只写自己文件"走通注册层**——因为 plugin 的声明式契约（9 个回调 + 框架替你写所有 registry）就是为此设计的。**三道真门槛**：prod release 的 `mix.exs` 逐一枚举、入站 HTTP webhook 在 `router.ex` 硬编码、纯数据上传 socialware 未接线。前两道 dev/热装绕得过，第三道是唯一"写代码也救不了、必须等平台补"的门。

## 1. 核心机制（三条路共用）

一个 plugin = 一个 OTP app，`Application.start/2` 只调 `Ezagent.Plugin.boot(__MODULE__)`（`apps/ezagent_core/lib/ezagent/plugin.ex:417`）。`boot/1` 读 9 个声明回调（`roles/0 / behaviors/0 / agent_flavors/0 / adapters/0 / template_classes/0 / routing_tables/0 / resource_types/0 / children/0 / after_boot/0`），**框架替作者做所有 `*Registry` 写入**（`plugin.ex:441-528`）——作者永远不碰 registry API。所以"声明即自动注册"这层，三条路都成立。

**真正门槛只有一个问题**：`apps/` 里放一个新 app，它能不能在不改中央清单的前提下被启动？分三种运行态：

| 运行态 | 新 app 启动方式 | 改中央代码? |
|---|---|---|
| **dev / test** | umbrella 语义（根 `mix.exs:6` `apps_path: "apps"`）自动把每个 `apps/` 子 app 当依赖，从根跑全部自动启动 | ✅ 零改 |
| **prod release** | 根 `mix.exs:36-60` `releases:` 块**逐一枚举**，注释明写"每个 runnable app 必须显式列否则静默不启动" | ❌ 必改 |
| **runtime 热装** | `mix ezagent.plugin.install` → `PluginPackage.install/1`（`plugin_package.ex:88-96` `:code.add_paths` + `:application.load` + `ensure_all_started`），装进运行中的 BEAM，无需重启、无需改源 | ✅ 连 mix.exs 都不改 |

**热装路径是平台已经设计好的"独立扩展"正道**——写好 plugin → build → install，Kind/Behavior/recipe 全部可达。

## 2. 中央清单实体清单（"门槛"的实体）

| # | 清单 | file:line | 何时挡路 | 通用绕过 |
|---|---|---|---|---|
| 1 | 根 `mix.exs` `releases:` | `mix.exs:36-60` | **仅 prod release** | dev/test/热装绕过 |
| 2 | `ezagent_web/router.ex` 入站路由 | feishu `:260`、protocol_api `:263` | 新 plugin 要**新入站 webhook 路径**时 | `/plugin-assets/:slug/*`（`:198`）+ `/socialware/*` 公开面**通用不用改** |
| 3 | `DefinitionRegistry.builtin_definitions/0` | `definition_registry.ex:109` | 只放系统默认 chat/socialware | 新 socialware 不进这里，走 `seed_definition_if_absent` |
| 4 | manifest `seed_refs` 只认 `:recipe` | `manifest.ex:174-178` | 热装包想带 socialware Definition | 无（第三道门，见 §3 路3） |
| 5 | `config/*.exs` | — | 只有 plugin 自有 key | 新 plugin 加自己的 key = 自己文件，不挡 |

## 3. 三条路逐个判定

### 路 1 · 定义一个 agent（recipe + flavor）
- recipe：新 plugin 声明 `roles/0` → `RoleSeedHook.seed_roles`（`plugin.ex:482`）→ RecipeRegistry；唯一依赖 ezagent_core。
- flavor：`agent_flavors/0` → `FlavorPublishHook`（`plugin.ex:473`）。
- **判定**：dev/test ✅ 零改、热装 ✅ 零改、prod ❌ 要进 releases。唯一 ❌ 场景 = 给**已有** plugin 加 recipe（要改它的 roles/0）——开新 plugin app 就避开。

### 路 2 · 开发一个 plugin（ActionSet + 外部 HTTP + 自定义 token）
- ActionSet/adapter：`behaviors/0`/`adapters/0` 自动注册（`plugin.ex:447,501`），action 立即可 dispatch。
- 外部 HTTP：自己模块里 `:httpc` + Jason（范式 kanban `github.ex:98-121`），纯自有代码 ✅。
- 自定义 token：kanban idiom = `write_creds` 写 `system://credentials/<x>.yaml`（`github.ex:20,41`）——**token 是文件系统运行时数据，用户在 chat/UI 配路径通** ✅；更正规是 domain_identity 的 credential cascade。
- **判定**：注册+HTTP出站+token 全自己文件（dev/热装 ✅），prod ❌，**新入站 webhook → 改 router.ex ❌**（除非复用通用 ingress）。

### 路 3 · 开发一个 socialware（Definition + views + agents）
> **官方规范口径**（`docs/guide/socialware-authoring-interim.md` #1153）：socialware = **零代码纯 Definition 数据**，只引用 plugin 的模块。三条纪律：代码全进 plugin / Definition 是 DATA（12 字段）/ 经 DefinitionRegistry 持久化。**caps 只来自 recipe，Definition 从不放 requested_caps**（struct 无此字段 `definition.ex:12-23`）；agents 照 `%{recipe, role_name, flavor}` 写但 flavor 当下被 `new/1` 丢弃（forward-declare）。
- Definition 进系统：运行时 API `seed_definition_if_absent`（`definition_registry.ex:61`）。**hello 是活证据——它从自己的 `app.ex:62` 调它、自注册 PageView、走通用 `/socialware/*`，没改任何中央清单** ✅。
- views 复用：Definition.views 引 ActionSet 模块。复用 `Ezagent.ActionSet.HelloRender` = 跨 plugin 引用（用不改）✅ 但要 depend hello；更常规是自己写 render ActionSet 经自己 `behaviors/0` 注册。
- **纯数据（不写代码）提交 Definition：今天不通** ❌——① 热装 seed_refs 拒 `:socialware`（`manifest.ex:174-178`）；② plugin 契约**无 `definitions/0` 回调**（`plugin.ex:246-257` 回调全集里没有）。#1147 明确 publish 原语已在（ConfigStore CR 治理），但**统一 app-package 上传**排期在官网之后。**第三方今天必须写 plugin 代码 seed，不能纯上传数据。**
- **判定**：新 plugin app + seed 自己 Definition + 注册自己 render（dev/热装 ✅），纯数据上传 ❌ 未接线，prod ❌。

## 4. 综合矩阵

| | dev/test 零改 | 热装零改 | prod release | 入站 HTTP 路由 | 纯数据(不写码) |
|---|---|---|---|---|---|
| 路1 recipe/flavor | ✅ | ✅ | ❌ releases | 不涉及 | ❌ 无 definitions/0 数据通道 |
| 路2 plugin+HTTP+token | ✅ | ✅ | ❌ releases | ❌ 改 router（除非复用通用 ingress） | 出站/token=数据✅；插件本体=代码 |
| 路3 socialware | ✅（写码 seed） | ✅（但 seed_refs 拒 :socialware，只能 after_boot 自 seed） | ❌ releases | 走通用 /socialware/*，无需改 | ❌ 未接线（排期官网后）|

## 5. 理想态缺口（对应可寻址完备性审计 PR #1148 的波）

1. **Plugin 自动发现（prod）**——去掉 `mix.exs` releases 逐一枚举，自动 glob `apps/`。消灭清单 #1，prod 与 dev/热装一致。
2. **通用 plugin HTTP ingress 声明**——一个入站路由回调，router.ex 不用为每个 plugin 手改。消灭清单 #2。→ 对应 PR#1148 W2。
3. **`definitions/0` 契约回调 + manifest seed_refs 支持 `:socialware`**——让 socialware Definition 像 recipe 一样随契约/热装自动进系统，不用手搓 `ensure_app`。→ W1。
4. **纯数据 Definition 上传**（`config://<ws>/app/` + ConfigStore CR publish）——第三方把 Definition 当数据零代码提交，socialware "应用商店"终局。→ W1/W3。

**总结**：三条路今天在 dev/test 和热装下都能"只写自己文件"走通；prod 的 mix.exs 枚举和入站路由硬编码是两道真门槛（对 dealscout 这种"新 plugin + 通用公开面"的组合，dev/热装完全够用）；纯数据 socialware 上传是唯一等平台补的缺口。
