# kanban 全链路真 e2e — round 2(2026-07-06 晚)— 短回合策略,PTY 0 崩,板走到流程终点

**结论一句话**:分支 `feat/sw-kanban` @ `4e8f633b8`(rebase 到 main `49f0167f` 含 #1208)上,发布 cc 变体 → 建会话 → 两真 cc agent 认证 → relay 规则落库 → owner 建板 → **agent 真驱动建卡/认领/推进两档** → dev 真 push GitHub 分支 → `__done__` 内容协议 relay 回助手 → 助手 gh 服务端复核 sha → 两次 set_stage 推进,**全部真通**;**PTY-bug 崩溃 0 次**(上轮 6 连崩的绕法 = 短回合策略,见下)。唯一没做成的是**真 PR**:本机 gh fine-grained PAT 无 `createPullRequest` 权限(API 403)、https push 403(SSH push 可用)、Chrome 未登录 GitHub —— 环境凭证缺口,如实降级为"真分支 push + 服务端 sha 复核",**未伪造任何 URL**,`register_pr` 一步如实跳过。

> 上轮(kanban-full-loop/)阻断根因是 PtyServer 64KB buffer UTF-8 截断崩溃;本轮
> **没修 bug**(核心未动),纯靠把每条给 agent 的指令压成"一条命令 + 一行回复"
> 的极小颗粒回合(最长自主回合 43s),全程没接近崩溃窗口。

## 环境

- 独立冷库 `POSTGRES_DB=ezagent_kanban_loop_e2e_r2`(drop/create/migrate,零 seed;admin 由 boot `EZAGENT_ADMIN_PASSWORD=worlddev` 供给,登录邮箱 `admin@ezagent.chat`)
- 工具链 `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13`;server 起 distributed(`elixir --name ezagent_runtime@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) -S mix phx.server`,PORT=10042)
- agent-browser 真 Chrome;world 控制台在 `http://world.localhost:10042/`(host-scope `world.`,裸 localhost 是 404 页)
- creds:watcher 抢拷 `~/.claude/.credentials.json`(本轮撞竞态 miss 了,手动拷 + SIGTERM respawn 兜底,见 gap ⑤)

## 步骤与判定(agent 驱动程度逐条如实)

| 步 | 判定 | 驱动方 | 证据 |
|---|---|---|---|
| 1 冷起+登录 | ✅ 冷库 0 session,admin 登录 | operator | `01-login.png` |
| 2a 发布 cc 变体 | ✅ `manifest_attrs(name:"kanban-loop-r2",flavor:"cc")`→ManifestResolver→publish_or_upgrade 真 governance `{:ok,:published}` | operator(erpc) | `publish_variant.exs` |
| 2b 下拉建会话 | ✅ 下拉 6 项含本 run 变体(value=`kanban-loop-r2`);角色槽 `kanban-assistant · cc` | operator | `02-create-form-cc-variant.png` |
| 2c 两 agent materialize | ✅ `b68806c8…`=kanban-assistant、`d971bf44…`=dev-together(skills/ 目录证实);MEMBERS=3 全绿 | 平台 | `02-session-agents.png` |
| 2d creds+认证 | ✅(手动兜底)respawn 后双 PTY banner `Claude Max` | operator | `05-server-state-evidence.txt` |
| 2e relay 规则落库 | ✅ routing_rules 表:`text_contains "__done__"` → `$role:kanban-assistant` | 平台(install) | 同上 |
| 2f owner 建板 | ✅ 真 LV socket `world:dispatch kanban.create` → `entity://system/agent/loop-board-r2` + 20 caps 铸给 admin(协议 §a0) | operator | server log 14:40:58 |
| 3a D⑧ mention 重核验 | ✅ **49f0167f 上 D⑧ 仍成立**:裸名 `@kanban-assistant` → messages 行 `mentions: []`,45s 窗 0 投递;真键盘输入无 autocomplete 弹窗;成员显示名=uuid | operator 探针 | `03a-mention-probe.txt` + 3 张截图 |
| 3b 助手建卡 | ✅ **agent 真驱动**:全 URI mention 短指令 → 助手真跑命令并如实回错/回成果(3 个回合:CLI 语法报错→:unauthorized→claim n1+`add_node`→`{:ok,%{id:"n2"}}`) | **kanban-assistant** | `03b-assistant-created-card.png`、`03b-board-after-add.txt` |
| 4 dev 真 push | ✅ **agent 真驱动**:dev clone→分支→commit→push(https 403 如实报,SSH 重试成功)`e2e/kanban-loop-r2-1783351325` @ `5a0a4fee…` GitHub 服务端可见 | **dev-together** | `04-dev-branch-pushed.png`、`04-github-branch-real.png` |
| 4b 真 PR + register_pr | 🟥 **凭证缺口降级**:`gh pr create`/GraphQL/REST 均 403(fine-grained PAT 无 PR write;operator 亲测同样 403),Chrome 未登录 GitHub → **无真 PR、未伪造 URL、register_pr 跳过**(dev 曾试 register 垃圾串被 `:bad_pr_number` 正确拒掉) | —(环境) | `05-server-state-evidence.txt` |
| 5 `__done__` relay | ✅ **agent 真驱动**:dev 发 `__done__ card=n2 … sha=5a0a4fee… pr=none(…)`(**零 mention**,messages.mentions=[])→ 助手 PTY 收到 `← esr-bridge: __done__ …` = text_contains 规则命中;助手自主复核回合(43s 无崩):对上本地 sha、对"已 push"存疑、拒绝代发,如实说明 | **dev→规则→assistant** | `05-relay-log-excerpt.txt`、`05-relay-and-advance-chat.png` |
| 6 复核+推进两档 | ✅ **agent 真驱动**:助手 `gh api …/branches/… -q .commit.sha` 服务端复核 = `5a0a4fee…` 一致;档1 dev(n2 owner)`set_stage n2→metric`;档2 助手 claim n3 后 `set_stage n3→pain`(R1 阶段链约束下两档必须走 3 层链,见 gap ④) | **assistant+dev** | `06-final-tree.txt` |
| 7 清理 | ✅ 远端分支已删(`git push origin --delete`,GitHub 复核 0 残留);无 PR 需关;进程按 PID 点名 kill(见复跑指引) | operator | — |

板终态:`n1(root,positioning)→n2(登录表单,metric,dev)→n3(表单校验痛点,pain,assistant)`,9-stage 链完整。

## PTY 崩溃记录(核心指标)

- 全程 `child process exited` 仅 2 次 = 22:37:30 **手动 SIGTERM**(exit_status 36608=143<<8,为让 respawn 读到刚拷入的 creds),**非 PTY bug**。
- **PTY-bug 崩溃 0 次,0 次指令重发**。上轮 6 连崩同 bug 未修(核心未动),短回合策略(单指令=一条命令+一行回复;助手最长自主回合 43s)全程没积满 64KB buffer。

## 本轮新发现的 gap(全部如实,核心/domain 零私改)

1. **协议文档的 CLI 语法在本 build 不存在**:`kanban-team-collaboration.md` §d 教的 `mix ezagent agent add_node --agent=<board-uri> …` 被 CLI 拒 `unrecognized arguments` —— `EzagentCli.TreeBuilder.build/1` 只从全局 `Ezagent.BehaviorRegistry.list_all/0` 派生子命令(tree_builder.ex:23),而 kanban 动作是 per-instance recipe 行为(K5,kanban application.ex:272-279 注释),不进全局注册表;运行时实测 Agent kind 派生动作 35 个、0 个 kanban。**绕法(本轮用,协议注记自洽)**:`kanban-cli.sh`+`kanban_dispatch.exs` 代面脚本,复刻 `EzagentCli.Dispatch.run_action` 同一 invocation(身份=调用者自己的 `EZAGENT_USER_TOKEN`/`EZAGENT_ENTITY_URI` 经 `Ezagent.Entity.authenticate` 换 caps → `Ezagent.Invocation.dispatch`),CapBAC 不绕过——助手第一次跑就吃到真 `:unauthorized`,证明没有隐性提权。
2. **materialize 铸的 kanban caps instance 指错**:助手 22:28 被铸的 20 个 Kanban caps 的 `instance` = **助手自己的 URI**,不是板 URI(板 22:40 才由 owner 建出,materialize 时不存在)→ 助手首次 dispatch 板 `:unauthorized`。owner 用真 CLI `mix ezagent agent grant_cap --cap='{"instance":"<board-uri>",…}'` 逐个补发后通。**结构性问题:板后建于团队,"recipe 授了每个 kanban 动作"授不到具体板实例上。**
3. **D⑧ 复验(49f0167f 含 #1208)**:裸名 mention 仍 `mentions:[]` 静默不路由;composer autocomplete 真键盘不弹;成员显示名仍是 uuid。与上轮 gap ① 逐字一致,#1208 未改此行为。
4. **kanban 手办级 owner/阶段门实测**:根卡 admin-gated(`handle_add_node`:265);子卡要父卡 owner;`set_stage`/`update_node` 要节点 owner(:680);R1 链约束根卡永远锁 positioning(`stage_fits?`:425 根 parent_ok = 首段)且子卡 ≤ 父+1 → "推进两档"必须 3 层链(n2→metric、n3→pain)。这些都是设计内的门,但意味着**助手复核后无法推进 dev 认领的卡**(:forbidden),协议 §c "assistant advances the card" 与实现的 owner 门有张力,值得 Allen 裁决。
5. **creds watcher 竞态**:agent config dir 在 watcher 启动前 <5s 出现 → 被预登记当旧 dir 跳过,0 copy;手动拷 + SIGTERM respawn 兜底(banner 从 "Not logged in" 变 "Claude Max")。复跑要在**点建会话前**起 watcher(本轮 UI 第一次点击创建没发出去,重试间隔里 watcher 过期了)。
6. **建会话表单 agent-browser 原生 click 不触发**:`创建` 按钮 agent-browser click 两次无 LV 事件,JS `el.click()` 一发即中(React 合成事件与 CDP click 的差异);字段 fill 正常。
7. **会话内"看板" tab 点击后内容区不切换**(仍显示对话流,tab 高亮已变);`/plugins/kanban` 仍是配置页。板真态用 CLI `get_tree` 与 DB 快照取证。
8. **gh 凭证矩阵(本机现状)**:fine-grained PAT:repo read ✅ / contents write(https push)❌ / PR write ❌;SSH:push ✅;浏览器:未登录。上轮及 kanban Phase3 记忆里 `gh pr create` 可用,凭证已轮换/降权。**下轮复跑真 PR 需要先补一个带 PR write 的 token**。

## 复跑指引

```bash
# 1. 库 + server(worktree 根)
POSTGRES_DB=ezagent_kanban_loop_e2e_r2 mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix do ecto.drop, ecto.create, ecto.migrate
POSTGRES_DB=... EZAGENT_ADMIN_PASSWORD=worlddev PORT=10042 mise exec ... -- \
  elixir --name ezagent_runtime@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) -S mix phx.server
# 2. 登录 http://world.localhost:10042/ (admin@ezagent.chat/worlddev)
# 3. 发布变体: elixir --name probe@127.0.0.1 --cookie ... publish_variant.exs
# 4. 先起 creds_watcher.sh 再点建会话(gap ⑤);若 miss 手动拷 + kill claude 让 respawn
# 5. owner LV socket 建板 + grant_cap 补板实例 caps(gap ②)
# 6. 全 URI mention 短指令驱动两 agent(每条=一条命令+一行回复,gap ① 用 kanban-cli.sh)
# 7. 真 PR 需先换有 PR write 的 gh 凭证(gap ⑧)
# 清理:kill $(cat /tmp/kanban-loop-r2/server.pid);pkill -f 'cc-agents/system/<uuid>' 两个 claude;agent-browser close
```

代面脚本(`kanban-cli.sh`/`kanban_dispatch.exs`)、发布脚本、watcher 均随目录归档。token 均走环境变量,无任何 token 进提交物。
