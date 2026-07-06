# kanban boot-publish 验收 E2E(2026-07-06,Allen 验收标准)

**结论一句话**:boot publish 本体 ✅(冷库零手动 seed → 下拉出现 kanban);建会话撞 **main 既有 bug ③**(`cc-headless-agents` ns 未注册 FsResolver,非本分支引入)→ 两个 agent 角色槽没 materialize;看板 tab 本分支不显示(#1199 world-views 才接)——view 注册/applies_to server 侧已证;kanban 功能本体(建板/建树/认领)经真 socket dispatch ✅。

## 环境

- 独立冷库 `POSTGRES_DB=ezagent_kanban_pub_e2e`(ecto.create+migrate,**零手动 seed**——admin 由 boot `repair_admin_user` 供给,`EZAGENT_ADMIN_PASSWORD=worlddev`;kanban 由 boot publish 自己发)
- 工具链 `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13`(注:本 worktree 裸 `mise exec` 会漏到 brew 1.19/OTP28,必须显式带版本)
- agent-browser 0.27.0 真 Chrome;分支 `feat/sw-kanban` @ `2fc132385`

## 步骤与判定

| 步 | 判定 | 证据 |
|---|---|---|
| 1 冷起 | ✅ boot publish 真 governance 流(open CR → cr-stage → cr-publish 移指针)自动发布 `socialware:kanban` scope=public,boot 日志 0 error | `00-boot-publish-log-excerpt.txt` |
| 2 登录 | ✅ admin/worlddev 直接可登录(boot 供给,没跑 set_password) | `01-login.png`(空 workspace,0 session——冷库实锤) |
| 3 下拉出现 kanban | ✅ New chat → Socialware 下拉 5 项含 **"Kanban 看板团队"**(截图为截图可见把 select 展开高亮,选项列表未动) | `02-dropdown-kanban.png` |
| 4 建会话 | 🟡 **部分**:session 行建出、definition 装上(views/roles/routing 全在 DB),但两个 `cc-headless` 角色槽 materialize 时爆 `config-dir resolution failed for resource://system/cc-headless-agents/…: :none` → **MEMBERS=1(只 Admin)、ROUTING=0** | `03-session-created.png` + 下方"gap ①" |
| 4b 看板 tab | 🟡 **预期内不显示**(本分支无 world-views 动态 tab,#1199 才接):tab 条只有 Chat/PTY。server 侧证据:`applicable_views/1` 含 `:kanban_board`(view 已注册+applies_to 本 session=true);`applicable_views/2(admin)` 被 cap gate 掉(见"gap ②") | `03-session-created.png`、`04-view-evidence.txt` |
| 5 kanban 功能活着 | ✅ `/plugins/kanban` 现为**只配置页**(建树/认领移进会话子视图=又是 #1199),故经**真 LiveView socket** push `world:dispatch`:`kanban.create`(board `entity://system/agent/e2e-board` 建出+20 个 Kanban caps 铸给 admin)→ `kanban.add_node`(n1 "e2e-root 建树验证" stage=positioning)→ `kanban.claim_node`(owner=admin status=claimed),快照落库验证 + world Authz Audit 页可见(红框行) | `05-board-works.png`、`05-board-works.txt` |

## gap 如实记录(都不是本分支 boot-publish 改动引入)

1. **cc-headless 角色 materialize 失败(main 既有 bug,已报 Allen)** — `Ezagent.Resource.FsResolver.Registry` 的静态 boot allowlist `@config_dir_namespaces ["cc","codex","codex-remote","py"]`(`apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex:386`)没有 `"cc-headless"`(`CcHeadlessAgent.config_dir_namespace/0` 返回它,cc_headless_agent.ex:18),latest main(bf5e03e94)同样没有。即 `docs/e2e/README.md` scenario-05 记过的 bug ③。**核心属 Allen 域,未私改。** 后果:kanban socialware 建会话时 pm/dev 两个角色槽爆炸,session 行留下但 0 agent 成员、relay-back 路由 0 条。等该 bug 修掉后同一条链应直通。
   - 控制组:同表单建 hello(纯配置无 cc-headless 角色)session 成功建出 → 排除 publish/install 机制本身。
2. **admin 的 `kanban_render` view cap 没铸** — `applicable_views/2(admin)` 把 `:kanban_board` gate 掉。install 在角色 materialize 处中断,疑为 cap mint 没走到(gap ① 的连带),没进一步定性;#1199 合并+gap ① 修掉后重验。
3. **看板 tab 不显示** = 任务预期内(#1199 world-views 动态 tab 在另一分支),非缺陷,server 侧 view 注册证据已给。

## 复现要点

- 二节点取证:server 节点非 distributed(无法 erpc),用同库第二 BEAM(`PORT=10099 mix run <script>`)读 DB-backed 状态——`installed_definitions`/快照 decode 忠实;ETS 态(cap store)结论已标"疑似"。
- LV socket 直推:`liveSocket.getViewByEl(el).channel.push('event',{type:'hook',event:'world:dispatch',value:{action,args}})` —— 与 React 岛 `pushEvent` 同一条真通道(main.tsx:235),非绕过。
