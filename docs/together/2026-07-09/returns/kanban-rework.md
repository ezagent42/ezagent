# Return — kanban 改版（world 注册表化 + socialware 纯化 + 收官清理 + e2e 重做）

> **Task:** socialware-rework 四任务线 T2（0709 拍板）· **Branch:** `feat/sw-kanban-rework`（org）· **PR:** #1298
> **Dev:** agent（jjkysy 席位）· **returned_at:** 2026-07-09 · **deadline_status:** on_time

## 做了什么（四段）
①world 去 kanban 硬编码：新增 `Ezagent.World.PluginPageRegistry`，6 处硬编码（routes/navigation/slot_registry/world_live 动作串+state 子句/main.tsx case/manifest）全部改查注册表，fail-closed；②socialware 纯化：溶解 `EzagentPluginKanban.Demo`（Decision #156——socialware=config-only carries zero code），manifest YAML 唯一真相源，relay marker 契约锁配置化三方互锁；③收官清理：删 40 件旧证据 + 5 份活文档对齐现状；④e2e 重做：真浏览器全流程新证据集（`docs/e2e/2026-07-09/kanban-rework/`，24 件）。

## DoD reconciliation
| # | DoD | status | proof |
|---|---|---|---|
| 1 | 6 处硬编码→注册表，行为零变化 | met | world 套件 179/0 零断言改动（唯一例外 slot_mount_gate 静态 lint 学新准入路径，更严）；20 动作白名单双重等价锁 |
| 2 | fail-closed（未注册 key/route/action 拒绝） | met | 注册表测试 12/0 含负例；前端 default throw 保持 |
| 3 | Demo 溶解、插件零 socialware 专属模块 | met | grep apps/+.claude/skills 零命中；kanban 套件 85/0；契约锁 manifest 权威三方互锁（relay-signal-check 实跑 OK） |
| 4 | 旧证据/过期文档清理 | met | 删 40 件证据 + 5 份活文档对齐；一致性 grep 清零；docs/together 台账未动 |
| 5 | e2e 全流程真浏览器证据 | met | 发布 published→UI 安装→注册表路由 index+detail→板动作 3 种 ok+持久化→relay routing_traces 铁证+from_role 双负路径；每步截图 18 png；cc 真脑 OAuth 401 如实标注（路由/送达/审计全真） |
| 6 | 全套 gate | met | arch.scan exit 0（socialware 两 gate 0/0）；**uri_query.scan 0**（CI 抓过一次 tenant_derivation——切段实现改回锚定正则后修复）；compile/format 干净 |
| 7 | 机器返还闸 | met | #1298 full-suite pass（修复后）；base=main 3eaceeabf |

**Method friction:** ①段1 自测漏了 `uri_query.scan`（不在官方五连里）被 CI 抓到——**world/URI 面的自测清单必须显式加 uri_query.scan**（0709 plan §6 原话，这次真踩了）；②agent 正在用的 worktree 不能并发 rebase 它的分支（静默失败+误 push 一次，靠 #1292 合入后 rebase 消化噪音）；③scanner 的 tenant_derivation 是词法规则（任何 String.split "/"），路由匹配要用正则形态。

**候选 issue（e2e 带回，非本分支回归）：** world New Agent 表单 native role 字段静默丢失（`agent_create.ex:84` 只读 atom key）；会话内「看板」子视图切换不生效（Conversation.tsx 无 mode 渲染腿）；create_session 5s UI 超时（已知）。

## Merge request
#1298 四段完整，独立可合。后续：dealscout 迁移+改版（T3，等本任务稳定）复用同套路（注册表条目+Demo 溶解）。world 页面完全自包含（React/data-builder 出 world）仍是独立架构 follow-up（#1267 两轨前提已对齐）。
