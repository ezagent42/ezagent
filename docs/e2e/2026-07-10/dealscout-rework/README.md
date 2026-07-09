# dealscout rework 段5 — 真浏览器全流程 e2e 证据（2026-07-10）

取代 2026-07-07 的两套旧证据（`dealscout-discover` / `dealscout-refresh-v2`，
段4 已把它们证的 ALT/手工 mount/fake generator 假点全部删掉）。证明本分支
改版后的 dealscout 全流程真实走通：

```
发布(deploy-seed 车道) → 安装(world 新建会话×socialware 向导，requires 递归带 orchestrator)
      → 会话发现流(@discover 真键盘 mention → py sandbox 真爬 HN → 回复自带 __dealscout_update__)
      → crawl_now/search 真 dispatch(线索逐条入会话 + {:set,:items} 入 :crawler slice)
      → 「线索」view(registry 声明的 LeadsView tab + internal render 真数据)
      → 页面自动重建(crawl_now 直呼腿 → publish_page → Turn/Surface committed)
      → 匿名公开页(/socialware/external 零 cookie 看到 committed 真数据表格页)
```

## 流程与证据索引

| # | 步骤 | 证据 | 结果 |
|---|---|---|---|
| 00 | 环境：ecto.reset + world_e2e_seed + `mix phx.server`（后台，PID 精确管理，最终 fix build PID 15442）+ `_health` 200 | `00-env-and-health.txt` | ✅ |
| 01 | world 登录（admin@ezagent.chat / $ADMIN_PW，见 docs/guide/world-e2e-seed.md） | `01a-login-page.png` `01b-logged-in-sessions.png` | ✅ |
| 02 | **发布**：server 节点内 `SocialwareSeed.seed!`（dealscout 包 → `$EZAGENT_HOME/default/socialware/dealscout`，与分支 manifest byte-identical）+ `ManifestSeed.scan_dir!` → `dealscout (deploy) → published`；DB `socialware_config_pointers` 落 `socialware:dealscout` | `02-publish-deploy-lane.txt` `dealscout_publish_e2e.exs` | ✅ |
| 03 | **安装**：新建会话「应用」下拉出现 *DealScout*（manifest 描述原文）→ 向导展示 discover（dealscout-discover × py）/ page（crawler-page × native）两 role 槽 → 创建 `session://system/socialware-install-dealscout/dealscout-rework-e2e`：4 成员（discover/page/orchestrator + Admin，全绿在线）、已装 Socialware=2（DealScout + **Orchestrator——D5 requires 递归安装实证**）、routing_rules 落 dealscout-update 规则（DB 与 YAML 逐字一致） | `03a`–`03e` 截图 | ✅（UI 有已知 5s create_session 超时红条 #1279 同类，后台创建成功，见 Blockers 1） |
| 04 | **会话发现流**：真键盘 `@dis` → autocomplete listbox → 插入 mention → 发送 `data-last-dispatch=ok` → **py sandbox 真爬 HN Algolia**，回复 5 条当日真实线索 + `__dealscout_update__` 信号；`routing_traces` 铁证：mention 命中 rule 1 → discover，带信号回复命中 rule 2 → page。admin `crawler.crawl_now` / `crawler.search` 真 dispatch（CapBAC 走 token 身份）各注入 20 条真线索入会话 + `:crawler` slice（erpc 探针印证 20→41→43 条留存） | `04a`–`04d` 截图 `04e-crawl-dispatch-slice-routing.txt` `dealscout_dispatch.exs` | ✅ |
| 05 | **「线索」view**：view-switcher 出现「线索」tab（`SessionViewRegistry` 声明→world 通用消费，零 world 改动）；点击后 `session.view.switch` dispatch ok、tab 高亮，但主区未切换渲染（Conversation.tsx 无非 chat mode 渲染腿——kanban rework 同一既有缺口，非本分支回归，见 Blockers 3）→ 用 view 的 internal render 可达路径证明：erpc 调 `LeadsView.render/1`（HEEx→HTML，35KB）渲出 41 条真实线索卡片列 | `05a-leads-tab-clicked.png` `05b-leadsview-internal-render.png`（同名 .html 为 erpc 渲染原件，Tailwind CDN 仅为截图包壳） | ⚠️ PASS-with-gaps（tab/switch 真、渲染腿是既有缺口，internal render 真数据实证） |
| 06 | **公开页**：crawl_now 直呼腿自动触发 `publish_page` → PagePublisher 驱动 turn.open/compose/settle → committed settlement（~9s，零操作员干预）；**匿名**（全新 context，`document.cookie.length==0`）访问 `/socialware/external?session_uri=<enc>` 看到 committed 真数据表格页（41 条），再跑一轮 crawl_now 自动重建后刷新 → 43 条（新增为当日真实 HN 新条目） | `06a-anon-external-page.png` `06b-anon-page-after-auto-crawl-rebuild.png` `06c-auto-publish-and-fixes.txt` | ✅（经两处段4 bug 修复，见下） |

## 段5 e2e 揪出并当场修掉的两个段4 bug（详见 06c）

1. **自动发布腿必跳**：注入 burst 后 session Kind 消化 send/snapshot 期间
   `get_slice` 5s 超时，`items_for` fail-safe 把读失败折叠成空 → 静默 skip。
   修：`CrawlerRender.items_result/1`（可辨别读）+ `PagePublisher` 读失败
   有界重试（10×3s）、耗尽 fail-loud。回归单测 3 条。
2. **公开页 "Unsupported node: page"**：`render_tree/1` 用了已退役的 hello
   page-builder 词表（page/section），外部 SPA 现行 renderer 是 shadcn
   catalog。修：emit Stack/Heading/Text/Table + rows 按 columns 对齐 cell
   数组。断言同步。

修后 `mix test apps/ezagent_plugin_crawler/test` 92/92 绿（umbrella root）。

## 真 / 绕开标注（如实）

- **真**：HN Algolia 爬取（discover sandbox 内 + Crawler Fetch 两条腿都真连
  公网）；mention autocomplete 真键盘；dispatch/CapBAC/routing/审计全真；
  匿名页零 cookie 新 context。
- **cc 无关**：D1 后 discover 是 py 车道，不吃 cc OAuth 401（本轮 e2e 全程
  无 cc 依赖）。
- **绕开（平台缺口，不修）**：
  - #1201 ② routing receive → native page 成员投递死（`AgentBridge deliver
    dropped ... :no_sandbox_respawn_state` 原文见 04e）。生产腿 = crawl_now
    直呼 / 成员显式 publish_page（本证据集实证）；chat 信号腿保留为声明式痕迹。
  - discover 回复触发的 rule 2 命中同样止步于此投递（04e ③）——即
    "@discover → 页面自动重建"链的最后一跳待 #1201 ② 修复回切。

## Blockers / 既有缺口（均非本分支回归，不在本 PR 修）

1. **create_session 5s dispatch 超时红条**（docs/guide/world-e2e-seed.md §3
   已知）：py 物化慢，UI 报 `{:create_session_exit, {:timeout, ...}}`，后台
   创建成功（成员/规则/快照齐全），刷新即见。
2. **会话内子视图切换主区不渲染**：`session.view.switch` ok、tab 高亮、
   `active_view` 更新，但 `Conversation.tsx` 只有 chat 渲染分支（LeadsView
   mode="external" 无 iframe 腿；hello 有 TEMPORARY 专属侧栏）。kanban rework
   README Blocker 3 同源，候选 issue。
3. **会话「高级规则」面板计 0**：`ConversationData.list_session_routing_rules`
   只显示 session-wrapped matcher，dealscout-update 是 manifest 装的
   rule_set 规则（DB 在、路由真命中），UI 面板不展示。展示层缺口，候选 issue。
4. **dev 关 boot scan**（prod-only，设计如此）：发布用 erpc 在 server 节点
   显式驱动同一晚扫描车道；scan 目录用只含 dealscout 的 symlink 目录（避开
   autoservice recipe 缺失 fail-loud——kanban 段4 同一注记）。

## 复现要点 / 环境坑（学费）

- 按 `docs/guide/world-e2e-seed.md`（PG → reset/seed → seed-then-start）；
  发布照 `02` + `dealscout_publish_e2e.exs`；dispatch 照
  `dealscout_dispatch.exs`（token 自铸不入库）。
- **runtime cookie 覆盖**：boot 时 `Ezagent.Runtime.ensure_cookie!` 用
  `$EZAGENT_HOME/default/runtime/cookie` 覆盖命令行 `--cookie`——erpc 一律读
  该文件，否则 `Invalid challenge reply`。
- **server 重启后 headless Chrome 会瘸**：旧 agent-browser 实例的 LV WS 升级
  持续失败 → 静默降级 longpoll → join 超时 → `phx-server-error` 循环，页面
  永远骨架屏。**重启 agent-browser（close --all + 新 session）即愈**——先例
  没记过，记在这。
- vite 孤儿照旧：`pkill -f "vite --host 0.0.0.0 --port 5173"`（world 的
  watcher 起不来会 `:watcher_command_error` 静默循环，React 岛挂不上）。
- React 受控 input 用 native setter；`var name=` 在 eval 顶层会撞 `window.name`
  （字符串强转）——换变量名。
