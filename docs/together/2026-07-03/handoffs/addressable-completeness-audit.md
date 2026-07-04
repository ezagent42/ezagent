# Handoff: 可寻址单位完备性审计——发布/发现/安装/数据分离/自举回路

> **Date:** 2026-07-03（2026-07-04 更新）· **From:** jjkysy (FP5) · **To:** Allen (lead)
> **Base:** upstream/main `de4f40a5`（全部 file:line 对代码实读核实；本轮更新的 file:line 对 `de4f40a5`）
> **Status:** research handoff（4 路并行读码审计的汇总，不改代码）
> **方法:** 以下述公理为标尺，对 12 类可寻址单位逐个体检五列：寻址 / 发布 / 发现 / 安装迁移 / 开发使用分离。
>
> **更新说明:** 本文原 base 为 `622b10e0`，彼时标注了"发布+发现两列系统性断裂"等缺口。现 main = `de4f40a5`，**#1164 socialware manifest track（author→publish→discover→install→use 全链）+ #1150/#1155 安全修 已落地**，闭合了本审计标的多项缺口。本次更新逐项区分"已闭合（标 PR）"与"仍缺（保留）"，不 over-claim。

---

## 0. 公理（审计的标尺）

ezagent 的立身之本：**一切皆 URI 可寻址**。交互基本单位是 **session（微型操作系统/沙箱）**——用户在里面加载 plugin、创建 agent、拉人。系统要成立，session 里长出来的任何东西（agent、template/app、编辑过的 plugin、页面、数据）都应该能走完一条链：

```
有地址 → 发布（定版可复用）→ 被人发现 → 装进别人的 session → 使用（以用户身份写运行时数据，与开发态分离）
```

这条链跑通，session 的不断建立/复制 + 单位的迁移/发现/安装就能让系统功能滚雪球——**自举开发**。本审计回答：这条链今天每一段的真实成色。

## 1. 完备性矩阵（12 单位 × 5 列总表）

✅ 完备 · ⚠️ 半（机制在但有缺口）· ❌ 无 · ▫️ 刻意除外（设计如此）

| 单位 | 寻址 | 发布 | 发现 | 安装/迁移 | 开发/使用分离 | 最短板一句话 |
|---|---|---|---|---|---|---|
| **user** | ✅ `entity://<ws>/user/<名>` | ❌ | ⚠️ 管理面 | ⚠️ 可跨 ws 成员、不可迁移 | ✅（身份即锚点） | 单安装公民，无跨安装身份 |
| **agent** | ✅ `entity://<ws>/agent/<名>` | ❌ 实例无发布 | ⚠️ 管理面 | ⚠️ 全是"按数据重建"，带记忆迁移无 | ✅ | 实例=钉死出生 ws 的一次性物件 |
| **recipe** | ⚠️ `recipe:<名>` 刻意非 URI | ⚠️ 仅 system seed 路 | ❌ 无 list | ✅ materialize 即设计本意 | ✅ 最干净 | **能装不能逛**（无 list/无租户 publish 入口） |
| **flavor** | ▫️ 刻意无地址 | ▫️ 只随代码 | ⚠️ 无目录 | ▫️ =装 plugin | ✅ | 刻意除外（引擎=运行时的一部分） |
| **session** | ✅ `session://` 三段 | ⚠️ 仅匿名只读面 | ✅ **listing 已加 ws 隔离（#1150/#1155）** | ⚠️ fork_config 同 ws / 本体无 export | ✅ | 跨租户枚举泄漏已修，本体 export 仍缺 |
| **SessionTemplate** | ✅ content-addressed `@<hash>` | ⚠️ save_template_as 已 merge 但只写本 ws | ⚠️ 只列本 ws | ✅ fork 完备（跨 ws 结构性堵死） | ✅ 历史绝不入模板 | 分发面止步单 workspace |
| **Definition** | ✅ `socialware:<名>` | ✅ **socialware 级 CR 治理发布（#1164）** + 声明式包通道仍封死 | ✅ **`DefinitionRegistry.list/1`（#1164）** | ✅ **按 ref 装别人发布的（#1164）** + 运行时热加装仍缺 | ⚠️ hello 漏 views 键铸空 cap | 治理+发现+安装已闭合，剩声明式打包 |
| **workspace** | ✅ `workspace://<名>` | ❌ by design | ✅ 治理正确 | ⚠️ 无整体导出/复制 | ⚠️ 配置与运行态同界内混装 | 配置只能靠 system 单向 fallback 流动 |
| **plugin** | ⚠️ slug 非 URI | ⚠️ 包格式在、**打包工具不存在** | ✅ list_all | ⚠️ 装/卸/换全链有 e2e，但 seed 只认 :recipe | ✅ | 分发格式齐，产出工具缺位 |
| **ActionSet** | ⚠️ 模块 atom、无版本轴 | ❌ 只随 plugin | ✅ registry | ✅/⚠️ 活实例不自动跟升级 | ✅ | 地址与代码部署绑死 |
| **view/surface** | ✅/⚠️ 版本化完备但依附 session | ✅ publish_policy 完整 | ✅ 注册表+统一 cap 门 | ✅/⚠️ 随 Definition 迁移 | ✅ | 四类里最完备；版本非一等对象 |
| **运行时数据** | ❌ **element 级全军覆没** | —（不该发布，原则一贯✅） | — | ▫️ 刻意不迁移（无反例） | ✅ 三态划分干净 | 消息=裸 UUID、slice/版本/节点无 URI |

> **#1164 闭合小记（Definition/socialware 行）:** 发布走 socialware 级 CR 治理流 `config_governance/socialware.ex`（`open_cr:41 → stage_definition:60 → publish_cr:81`，不再裸 `write_definition`）；发现有 `DefinitionRegistry.list/1`（`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:109`）；安装有 `world/socialware_install.ex prepare_create_template:27`（按 ref 装、校验 definition 对 caller workspace visible/installable `:16-17`）。**flavor 也从"forward-declare/被丢弃"落地**：`Definition.agents` 每个 agent 条目的 agent_spec 现携带 `%{recipe,role_name,flavor}`（`definition.ex:35`），`new/1` 读+校验（`:245-249`），materialize 走 `definition_agents.ex:101 flavor_of`——注意 flavor 是 per-agent 字段、非 Definition 顶层字段。**W0 安全实锤已修**：session listing 跨租户泄漏由 #1150（home_live tenant isolation）+ #1155（agents.delete 跨 ws 枚举）闭合。

## 2. 系统性结论（按列看）

**寻址列：基本达标，唯 element 级空白。** Kind 实例六 scheme 权威齐整；recipe/Definition 是刻意的结构化 subject（T1 拍的）。但**"对话中的 element 可被寻址"今天只对 uploads 文件成立**：`message://` scheme 已被 PR#149 明确删除（消息是裸 UUID，`uri.ex:136-137`）、snapshot slice 无 URI、Surface 版本/kanban 节点只是 action 参数。URI 的 **sub-resource 位是设计好保留未用的扩展点**（`uri.ex:73-74`，4 段即 raise）——公理的这半句是"留了位没建"。

**发布+发现两列：socialware track 已由 #1164 闭合，剩两块真缺口。** 原审计（base `622b10e0`）最大发现是"12 单位无一同时具备可发布+可枚举发现"。#1164 socialware manifest track 落地后，**Definition/socialware 这条链已通**：
- **发布**：走 socialware 级 CR 治理流（`config_governance/socialware.ex` `open_cr:41 → stage_definition:60 → publish_cr:81`），不再裸 `write_definition` 落 system 公共区——治理真空已补；
- **发现**：`DefinitionRegistry.list/1`（`definition_registry.ex:109`）提供 workspace 维度 listing，"出现在可选列表"成立；
- **安装**：`world/socialware_install.ex prepare_create_template:27` 支持按 ref 装别人发布的 socialware，且校验 definition 对 caller workspace visible/installable（`:16-17`）。

剩下的**两块真缺口**：
- **声明式打包仍缺**：`PluginPackage.Manifest` 仍拒 `:socialware` seed_ref（只认 `:recipe`，`manifest.ex:54-56`），且 Plugin 契约无 `definitions/0` callback——socialware **打不进可分发插件包的 manifest**，只能 imperative seed（`App.ensure_app`）或 governance publish；
- **element 级寻址仍缺**：消息/slice/版本无 URI（见寻址列），"分享一条消息/一个页面版本"的一等句柄尚未兑现。

其余单位（recipe 无 list、template 只写本 ws、session 唯一公开态是匿名只读）不在 #1164 范围内，仍如原判。

**安装/迁移列：创建期同 ws 内闭环，三个边界清晰。** 创建期链路完整且优雅（installs 解析 fail-closed、agents 自动 materialize 幂等）。断口：运行时不能给活 session 热加装单个 Definition（唯一运行时通道是整模板 migration 且不重算 behavior 集，`migration.ex:12-38`）；跨 workspace 一切复制 fail-closed；运行时数据无 sanctioned 导出（kb 只能手拷 sqlite）。

**开发/使用分离列：全系统最健康的一列。** 数据三态（开发态 ConfigObject+指针 / 安装态 install 钉版本 / 使用态 slice+messages+uploads+sqlite）划分真实、写入各有 chokepoint、"运行时数据不迁移"原则一贯无反例；隔离=统一 CapBAC 面（step 5.5 + cross_workspace fail-closed + caller-authority 窄化 grant），无旁路。两个精确边界：隔离粒度到 per-session/per-ws，**无 per-user 粒度**（同 session 两成员写同一 board 不分"谁的数据"，只有 actor 标记）；**匿名使用者零受限写路径**（read-only by construction，连投票先例都没有——"外部人使用"的写半边是空的）。

## 3. 自举回路体检（agent 写码 → 装回系统）

| 段 | 状态 | 断点 |
|---|---|---|
| a) agent 产出 artifact | ⚠️ | cc 有 per-agent sandbox 能写；但产物只是 host 文件，**无 URI、系统看不见**（违反公理） |
| b) artifact → 包 | ❌ **最短板** | `mix ezagent.plugin.package` 只活在 docstring（`manifest.ex:214`）；全仓唯一打包实现是 kb 的测试支撑（`test/support/plugin_pkg/builder.ex`） |
| c) 热装进运行时 | ⚠️ | 机制完备（install/unload/swap + 真 e2e `plugin_package_codex_gate_test.exs:59`）；但 install **刻意非 dispatch 操作**（`ezagent.plugin.install.ex:5-10`，agent 无合法触发路径）+ mix task 不跨节点（无 :rpc，`:123`）+ seed 只认 :recipe |
| d) 装完被活 session 用 | ⚠️ | 新建实例立即可用（e2e 证）；活实例要 mount——机制完备（`mount_detach.ex`）但**零 production 调用方** |

**判定：离自举差的不是机制是工具**——打包 task、cap 门控的 install 入口、socialware 热装解禁，三样补上回路即通。"埋好管道零调用方"是反复出现的模式（snapshot_live_session / mount_detach / from_plugin 皆如此）。

## 4. 补齐计划（分波，PR-sized）

> 前提事实：Definition 的发布通道方向已定为 **ConfigObject + CR 治理线**（#1147 修正，非 plugin manifest 线）。本计划按此排布；plugin 包只管代码+recipe 分发。

| 波 | 内容 | 层 | 依赖 |
|---|---|---|---|
| ~~**W0 安全前置**~~ ✅ **已落地（#1150/#1155）** | ① session listing 跨租户泄漏 → #1150 home_live tenant isolation 修；② agents.delete 跨 ws 枚举 → #1155 修。原计划的两项安全前置均已闭合，无需再动 | domain_session + web | — |
| **W1 发布/发现通道** ✅ **#1164 已落大部分** | 已落地（#1164）：Definition 发布走 socialware 级 CR 治理（`config_governance/socialware.ex publish_cr:81`）；`DefinitionRegistry.list/1`（`definition_registry.ex:109`）listing；按 ref 安装（`socialware_install.ex prepare_create_template:27`，校验 visible/installable）。**仍剩：声明式打包**——`PluginPackage.Manifest` 拒 `:socialware` seed_ref（`manifest.ex:54-56`）+ 无 `definitions/0` callback，socialware 打不进可分发插件包，只能 imperative seed 或 governance publish | domain_session (+ core manifest) | — |
| **W2 自举工具** | `mix ezagent.plugin.package` 打包 task（`from_plugin` 已在只缺产品化，`manifest.ex:219-236`）；cap 门控的 install 入口（dispatch 化或 :rpc 通道，安全模型 discuss-first）；agent artifact 挂 `resource://`（sandbox 产物可寻址） | core | 独立 |
| **W3 element 寻址（公理补全，长线）** | 启用 URI sub-resource 保留位（`uri.ex:73-74`）：消息/Surface 版本/board 节点的一等句柄；"分享一条消息/一个页面版本"的产品面 | core(uri) | 独立 |
| **W4 远期** | 干净的 per-user use-session（concierge 方向 #1146——今天匿名直接 join 发布 session，非每人独立 session）、跨 workspace 只读引用、运行时数据 sanctioned 导出、匿名受限写（投票类 cap+滥用防护）、跨安装身份（联邦） | 多层 | W1-W3 |

## 5. Discuss-first（给 Allen）

1. ~~**W0 两项安全前置**~~ ✅ **已落地（#1150/#1155）**——session listing 跨租户泄漏 + agents.delete 跨 ws 枚举均已修，此项无需再议。
2. **发布/发现的治理形态**——#1164 已定调：发布走 socialware 级 CR 治理（PUBLIC scope admin-gated），发现走 `DefinitionRegistry.list/1`。**仍待拍的是声明式打包**：要不要放开 `PluginPackage.Manifest` 收 `:socialware` seed_ref（+ 加 `definitions/0` callback），让 socialware 能打进可分发插件包；还是坚持"包只管代码+recipe、socialware 只走 governance publish"。
3. **install 的安全模型**：它今天"刻意非 dispatch"有理由（改 BEAM code path），自举要求给 agent 一条门控通路——cap 门控 dispatch 化 vs 保持 operator-only + 人审批队列，需要你定调。
4. **element 寻址（W3）是否立项**：sub-resource 位是当年留的扩展点，"对话中的 element 可被寻址"这半句公理要不要在这个周期兑现。
5. **per-user use-session（concierge #1146）是否立项**：今天匿名访客直接 join 已发布 session（共享），非每人独立 use-session；"外部人以自己身份用"的干净形态要不要走 concierge。
