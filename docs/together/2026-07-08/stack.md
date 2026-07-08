# dev-together 合并栈 + close 对账 · 2026-07-08

> lead close 对账：把 07-08 plan §3 的 6 条 track 与实际落地（returns/ + 已合 PR + 草稿件）逐条对齐，
> 诚实标注每人闭环状态。数据窗口 `merged:2026-07-08`（GMT+9）。

## 一、按 track 收口（plan §3 → 实际）

| track（plan §3） | 负责 | 计划 DoD | 实际落地 | 状态 |
|---|---|---|---|---|
| stable 重新部署 + socialware load/create/delete + M3 requires + M2 default-template + seed 三态契约 + CI reflow 闸 + nightly 自动触发 + playground | allenwoods（lead） | 主目标：stable 上验证 socialware 全生命周期 | **基础设施 + 韧性全量交付**：nightly 自动部署 #1241、seed 三态契约 #1242、模板名解析 #1244、canary 上线、部署能力探针、GLOSSARY 四层词 #1253、namespace 闸 #1255、skill-distribution 设计 #1251 + 实现 SPEC #1254 + P1-P3（→ integration 分支）、韧性弧 #1252/#1257/#1259/#1261/#1263。**但 socialware 生命周期验证本身未完成**——stable 一接触即暴露一串生产问题，当日转向加固（见 review §2 转向）。 | **部分 / 转向**：基础设施 + 加固交付；生命周期验证结转 07-09 |
| 官网全流程 + hello 路径可达 | zhaomaota97 | 全体成员可回复网站操作 + hello 路径可达 | #1243 四合一合入（curl-agent LLM 委托 + `/hello` 路径路由 + rulings + orchestrator→front-desk）。**但线上 golive hello session 是 #1243 之前的旧 Definition 实例（stale）**——需重建，结转 07-09（todo.md 已登记）。 | **代码交付**；官网 session 重建结转 |
| ezagent-in-ezagent 自举审计（dogfooding） | gagameow | 三面 works/breaks/gaps 报告 | #1247 审计草稿（evidence artifact，保持 open）：**Track A ✔**（产品内 agent 写仓库文件；隐患：默认 cwd 落在 main checkout）· **Track B ✔**（可编译 plugin 骨架）· **Track C ✗**（socialware 编写/安装未起步，@mention 派发 `:unauthorized`）。另开 #1256 agent×flavor 设计草稿（保持 open，明日续）。 | **审计交付**（works/breaks/gaps 齐）；Track C 失败 = 明日头号；继续 |
| deploy-seed 车道 | jjkysy | 部署级 seed 车道合入 | #1231/#1233/#1246 三 PR 栈 + #1248 kanban 迁车道，**全部合入 main**。取代跨-fork #1190（同库重开）；#1236 收编入 #1246。 | **全量交付** |
| socialware 安装/卸载 E2E 脚本化 + UI 校验 | zyli-developer | E2E 脚本化 + 干净移除证据 | #1245 socialware 卸载 UI 合入。**但浏览器路径的卸载面板始终未渲染绿**（`[data-world-socialware-uninstall-panel]: 0`）——本地 py-agent 冷启动超时挡住（与 #1259 修的冷 provision 同类）；只到后端安装 + 成员面板截图。 | **已合但 DoD 部分**：浏览器卸载演示未绿；follow-up 结转 07-09 |
| 探索式玩法测试 | ruihuachen-designer | 非正式发现清单 | 探索日，无 PR 交付（计划内即如此）；发现走 Feishu。 | **无 PR 交付（计划内）** |

## 二、returns/ 全量对账（不遗漏任一文件）

| return 文件 | 映射 PR | returned_at | deadline_status | 入栈处置 |
|---|---|---|---|---|
| `socialware-deploy-seed-stack.md` | #1231/#1233(/#1236) 栈总述 | 2026-07-08 02:04 +0800 | on_time | 栈总述；被下列分条 return 细化 |
| `socialware-deploy-seed-mechanism.md` | #1231（栈①） | 2026-07-08 09:14 +0800 | on_time | 已合 main |
| `socialware-deploy-seed-hello.md` | #1233（栈②） | 2026-07-08 09:14 +0800 | on_time | 已合 main |
| `kanban-deploy-seed-migration.md` | #1248（取代 #1190） | 2026-07-08 17:19 +0800 | on_time | 已合 main |
| `socialware-uninstall-ui-agent-browser.md` | #1245 | 2026-07-08（席位 agent） | on_time | 已合 main；DoD 部分（浏览器卸载演示未绿）→ follow-up 结转 |

> 注：各 return 头部标 `deadline_status: on_time`，其"机器返还闸"列多标 `partial`（full-suite 当时 pending），
> 后续 full-suite 转绿并已合入 main——close 确认为 met。
>
> **无 return 文件但已落地的 track**（从 PR / 草稿件对账，非遗漏）：allenwoods lead 线（24 PR 中的绝大多数）、
> zhaomaota97 #1243、gagameow #1247/#1256 草稿、ruihua 探索（Feishu 发现）。lead 线当日 context 高度集中、
> 直接走 PR 未逐一填 return——记为流程债（见 review §method-deltas）。

## 三、close 处置汇总

- **合入 main（本工作日产品 + 流程，25 个）**：#1229 #1231 #1233 #1235 #1237 #1238 #1240 #1241 #1242 #1243 #1244 #1245 #1246 #1248 #1249 #1250 #1251 #1252 #1253 #1254 #1255 #1257 #1259 #1261 #1263（深夜 main-green 收尾，按 GMT+9 归本工作日）。
- **合入 integration/skill-distribution（非 main，验收进行中）**：#1258（P1）· #1260（P2）· #1262（P3）——`[P123-DONE]` 已盖章（~00:40），机械验收已绿（全局 gate + spec §4 全部 7 个测试文件 29/0，26 文件 diff 含 runbook）；余下 diff review + 对抗评审（今晨）→ jjkysy 定夺是否进 main（结转 07-09）。
- **保持 open（有意，非事故）**：#1247（dogfooding 审计草稿，evidence artifact）· #1256（agent×flavor 设计草稿，明日续）。
- **superseded**：#1190（跨-fork）→ #1248（同库重开）；#1236 → 收编入 #1246。
- **关闭 issue**：#1226（deploy-seed 决策）· #878 · #879 · #1227（seed 单源收口）。
- **延后（plan §5 登记）**：git-filter-repo 历史重写——需 dev 窗口冻结，本日不执行（非偏离）。

## 四、gate 说明

本日工作已通过各自 PR 的 `precommit + check_invariants` 分支保护闸合入 main；两处例外须诚实登记：
① #1261 是 #1248×#1255 合并顺序碰撞（重命名 `Agent.RecipeResolver`）导致 main 短暂红后的热修复（review §2 事故 D）；
② #1257 遗留 4 条 `uri_string_key` scan 违规致 full-suite 深夜短暂红，#1263 收尾恢复绿（review §2 事故 E——当晚两次
过早合并，教训 = 验证看每个 check 的最终结论而非数量，修复类 PR 自测清单加 `uri_query.scan`）。close 为确认，而非首次检查。
