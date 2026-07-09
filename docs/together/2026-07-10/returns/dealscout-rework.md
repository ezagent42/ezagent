# Return — dealscout 改版（迁移+改版一个任务：真实组合 socialware / 真页面 / 四旅程划分）

> **Task:** socialware-rework 四任务线 T3（0709 拍板；0710 重启为完整任务，取代已关的 #1264/#1191）
> **Branch:** `feat/sw-dealscout-rework`（org）· **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-10 · **deadline_status:** on_time

## 做了什么（迁移基底 + 五段改版）
基底带入 #1264 的部署级 seed 迁移（manifest 入 socialware_seed、gate 归零）。改版五段：①纪律收编（溶解 `EzagentPluginCrawler.Demo`、`__dealscout_update__` 契约锁反转为 manifest 权威、15/15 对齐）②数据真化（L2 措辞诚实化——不再拿 HN 冒充投融资线索；删"抓完即丢"的 Poller 周期腿与 no-op RetentionSweeper/pin_batch）③角色真化（discover 槽 cc-headless→py script-carrying recipe，被 @ 后 sandbox 真爬 HN 检索源、回复自带信号；`requires:[orchestrator]`）④页面立起（`CrawlerRender`+`LeadsView` 照 kanban 模具、真数据 `:crawler` slice、`PagePublisher` 走 Surface 版本树零 LLM 自动发布、删 ALT+fake generator+crawler→hello dep）⑤真浏览器 e2e 22 件证据 + 文档收官（e2e 当场揪出并修掉段4 两个真 bug：发布读有界重试、渲染词表 shadcn 对齐）。

## DoD reconciliation（对用户四条拍板目标）
| # | 目标 | status | proof |
|---|---|---|---|
| 1 | 功能不变 | met | 发现→线索→页面全流程保持；假腿删除如实文档化（无后台周期抓取） |
| 2 | 真实组合 socialware 能力 | met | 一切编排 = manifest 纯配置（uses/requires/roles/routing/views/legends）；插件零 socialware 专属模块（grep 清零）；requires 递归安装实证（e2e 装出 Orchestrator） |
| 3 | 真页面非假数据 | met | e2e：匿名零 cookie 在 `/socialware/external` 看到 41 条**当日真实爬取**线索 committed 页；crawl_now→~9s 零操作员自动重建；`page_tree == view_tree` 单一投影源；fake generator/ALT/LLM 依赖全删 |
| 4 | 四旅程划分（P6/#155/#156） | met | plugin=generic 机制（crawler/render/publisher 零业务语义）；socialware=纯 YAML；部署=deploy-seed 车道（e2e 实走 published）；终端用户=UI 安装→会话→公开页（e2e 实走） |
| 5 | 全套 gate | met | crawler 90+/0、conformance 15×5、arch/uri_query/lifecycle exit 0、compile/format 干净；set_effect 两次实测校准（133→131→135，注释记录） |
| 6 | 机器返还闸 | pending CI | rebase 到 main 2df027f58；PR full-suite 跑中 |

**自主决策 D1-D10**（用户休息期间取的默认，spec §2 全记录，可推翻）——最关键三条：D1 discover 换 py 绕平台 gap⑥；D2 自造结构化 view 消 LLM/fake/手工 mount 三假点；D4 措辞诚实化优先于接新源。

**平台缺口（绕开未修，Allen 裁决权）**：①py 车道无"chat→dispatch action"中继（Domain.Python V1 设计如此）；②native receive 投递死（#1201②，routing 规则保留为声明痕迹，e2e 有日志原文）；③匿名面尚无 external_render 消费者（#1199 anon caps 已在场）；④会话子视图主区渲染缺腿（#1291 类）。候选 follow-up：真商业源选型+token（产品决策）、curl-llm 大脑槽、@discover→页面自动重建最后一跳（等②修）。

**Method friction**：①e2e 是真正的段4 验收官——两个 bug（fail-safe 折叠成静默 skip、渲染词表过期）单测全绿但真栈才现形，"注入 burst 下的读超时"这类只有真环境有；②`--onto` 基点连续两次选错的教训：重排前先 `git log` 画清楚要保/要甩的段，不动手猜；③runtime cookie 覆盖命令行 cookie、server 重启后旧 headless Chrome WS 静默降级假死（重启 agent-browser 即愈）——已写进 e2e README。

## Merge request
独立 PR。建议排在 #1298（kanban）后合（同一改版套路家族，review 心智连续）；与 #1292/#1293 零冲突面。
