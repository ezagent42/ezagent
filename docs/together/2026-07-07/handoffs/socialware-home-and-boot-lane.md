# Handoff — socialware 的"家"与 boot seed 车道的分层问题（给 Allen）

> **From**: jjkysy · **Date**: 2026-07-07 · **基线**: main `dcabf617`（含 #1213）
> 起因：把 kanban-team / dealscout 两个 Definition 迁上 #1213 的 YAML 车道时撞到的一个归属问题。**不阻塞任何在途 PR**，是给 registry follow-up 的设计输入。

## 一句话

**socialware 是 plugin 的上层建筑，不归属任何 plugin**——plugin 作者交付能力（代码/view/recipe/action），平台用户交付 socialware（一个 YAML，家在 registry）。像包管理器：应用依赖库，但应用不放在库的文件夹里。今天的 boot seed 车道和我们 flagship 的放置方式，都还是"socialware 住在某个 app 里"的过渡形态。

## 鸡和蛋，其实不是环

"没有 plugin，socialware 起不来"是**单向依赖**，标准解=声明+检查，平台已有一半：

- manifest 的 `uses: [...]` 就是依赖声明，`ManifestResolver.ensure_plugins_installed` 按 PluginRegistry 核验、缺了 fail-closed（我们 rename 时实测：`uses` 留旧 slug 直接 resolve 拒绝）——✅ 已通
- **运行时导入天然无时序问题**：`mix ezagent.socialware.import` 跑在活节点上，所有 plugin 已启动——用户造 socialware 的正门是安全的——✅ 已通
- 唯一有时序问题的是 **boot 扫描车道**，病根正是归属混淆（见下）

## 今天车道的两个断（file:line）

`ManifestSeed.scan_boot_manifests!`（`manifest_seed.ex:21-23`）：
1. **位置**：只扫 `:ezagent_domain_session` 自己的 priv——"部署级 seed 目录"被放进了一个 domain app 的源码树里；
2. **时序**：跑在 domain_session 启动时（umbrella 启动序列中段），**早于所有 plugin**——任何引用 plugin 注册物（view/recipe）的 manifest 在这里 resolve 必炸，且是 raise 炸整个 boot。autoservice 能走通只因它的引用全在 domain 侧。

**我们 flagship 的过渡放置**（#1190/#1191 现状，如实报备）：YAML 放各自 plugin 的 `priv/socialware/<名>/`，plugin 自己 boot 时跑薄加载器（同一条 parse→resolve→check_candidate→publish_or_upgrade 链，只是入口时机在 plugin 启动后）。这符合 #1169"首个 flagship 随插件出厂"的规矩、是**出厂预装示例**——但如果把"扫描扩展到每个 plugin 的 priv"定为正门，会把"socialware 归 plugin"进一步焊死，方向不对。

## 提案：三个"家" + 一个"晚扫描"

| socialware 的家 | 谁放的 | 怎么进系统 |
|---|---|---|
| **registry（ConfigStore）** | 平台用户 | import / world 编辑器 / 会话"发布为模板"——**主车道，已通** |
| **部署级 seed 目录**（不在任何 app 源码树内，如 `$EZAGENT_HOME/socialware/`） | 运维 | boot **最后阶段**统一扫（全部 app 已起，`uses` 门把关） |
| plugin priv 里的示例 | plugin 作者 | 出厂预装/starter，同样由晚扫描收编（或显式 import）——收编后我们两个薄加载器归零删除 |

三条全走同一治理链。两个配套细节：
- **扫描时机**挪到全部 app 启动完成之后（如 web app 的 after_boot、或专门的 post-start phase）——时序问题整体消失；
- **错误形态分层**：manifest 内容坏（parse/conformance）→ fail-loud 炸 boot 是对的（部署错误就该拦住）；**缺 plugin** → 应给可读的"uses 未满足：需要 crawler，未安装"而不是 resolve 深处的名字解析失败。

## 对在途工作的影响

无。#1190/#1191 维持现状（出厂预装形态，moduledoc 已注明车道扩展后可再缩）；车道落地后各自一个 commit 完成迁移（挪文件+删加载器）。
