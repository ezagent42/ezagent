# kanban 全链路真 e2e(2026-07-06)— 前半真通,agent 回合被 main PTY bug 硬阻断

**结论一句话**:发布 cc 变体→下拉建会话→两个真 cc agent materialize+手动 creds 认证→owner 建板→relay-back 规则落库,**这一段全部真通**;但 kanban-assistant 的 claude 侧车 **6 连崩**于 main 既有 PtyServer bug(buffer 裸字节截断 + `~r/\s+/u` regex 对 invalid UTF-8 raise),**0 次 kanban dispatch 成功**,填卡→派活→真 PR→relay→推进 无法继续。**未 stub、未伪造任何一步**;真 PR 未开(dev 从未跑到),故无 PR URL、无需清理远端分支。

> 手动 creds 过渡方式声明:cc agent 认证 = watcher 脚本抢在 claude 启动前把宿主
> `~/.claude/.credentials.json` 拷进 materialize 出的 config dir(S6 已验证方式)。
> A² 落地后 rebase 重跑零手动版。

## 环境

- 独立冷库 `POSTGRES_DB=ezagent_kanban_loop_e2e`(ecto drop/create/migrate,零 seed;admin 由 boot `EZAGENT_ADMIN_PASSWORD=worlddev` 供给)
- 工具链 `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13`;分支 `feat/sw-kanban`(与 origin/main `bf5e03e94` 同基线)
- agent-browser 真 Chrome;server 起为 `ezagent_runtime@127.0.0.1`(distributed,CLI/erpc 可达)

## 步骤与判定

| 步 | 判定 | 证据 |
|---|---|---|
| 1 冷起+登录 | ✅ 冷库 0 session,admin/worlddev 登录 | `01-login.png` |
| 2a 发布 cc 变体 | ✅ `ManifestResolver.resolve(Demo.manifest_attrs(name: "kanban-loop-e2e", flavor: "cc"))` + `Governance.publish_or_upgrade` 经真 governance(open CR→stage→publish 移指针)→ `{:ok, :published}`,零代码改动 | server log CR `4ebd91f1`,content_hash `a15b4fa6…` |
| 2b 下拉建会话 | ✅ 下拉 5 项含 kanban(boot 发布)与 kanban-loop-e2e(本 run 变体);选后角色槽卡片显示 `kanban-assistant · cc` | `02-create-form-cc-variant.png` |
| 2c 两 agent materialize | ✅ 两角色槽在新 uuid URI 真 spawn:`122b9333…`=kanban-assistant、`f6ddf2d5…`=dev-together(config dir 的 skills/ 证实);UI MEMBERS=3 全绿 | `02-session-agents.png` |
| 2d 手动 creds+认证 | ✅ watcher 在 claude 启动前拷入 `.credentials.json`(18:39:58 / 18:40:02);PTY banner 显示 `Claude Max`(已认证);spawn_plan T7d 注入 `EZAGENT_USER_TOKEN`/`EZAGENT_ENTITY_URI`(/proc environ 实测) | `05-server-state-evidence.txt` |
| 2e relay-back 规则 | ✅ Definition 安装进 RuleStore:`text_contains "__done__"` → `$role:kanban-assistant` | `05-server-state-evidence.txt` |
| 2f owner 建板 | ✅ Admin 经真 LV socket `world:dispatch` `kanban.create` → `entity://system/agent/loop-board`(协议 §a0:板本就是 owner 建,不是助手建) | `05-server-state-evidence.txt` |
| 3 填写内容(助手建卡) | 🟥 **阻断**:助手 claude 侧车 6 连崩(见下),0 次 `action=kanban.*` dispatch;板 tree 空如实保留 | `03-chat-blocked-no-agent-reply.png`、`04-pty-crash-forensics.txt` |
| 4-7 派活/真 PR/relay/推进 | ⛔ 未到达(依赖步 3);**没有开任何真 PR** | — |

## 阻断 bug(main 既有,非本分支引入;核心/domain 未私改)

**PtyServer invalid-UTF8 crash loop** — `apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex`:

1. `trim_buffer_only`:buffer >64KB 时 `binary_part(buf, size-16K, 16K)` 裸字节切片,可切在多字节 UTF-8 码点中间(claude TUI 大量 3 字节 box-art `─`=`e2 94 80`);
2. `matches?/normalize_ws`(:787-795):`String.replace(s, ~r/\s+/u, " ")` 对 invalid UTF-8 buffer raise `ArgumentError`(`:re.run` 层);
3. 每个 stdout chunk 都跑 `scan_auth_observers`(:669)/`scan_auto_prompts`;`auth_observers`(cc spawn_plan 的 credential_auth_observers,盯认证失败字样)正常运行时**永不 fire**,regex 永远在跑;
4. → GenServer 死 → supervisor respawn claude → **进行中的回合整个丢失**。活跃回合(spinner 动画)几分钟就积满 64KB,等于任何长回合必死。本 run:6 连崩(86312→13287→15606→15674→18308→19589→…),首崩发生在助手真思考干活 ~6 分钟时(它正 grep kanban 插件代码)。旁证:Logger formatter 也被割裂码点打爆(`bad return value … [<<226,148>>,…]`)。
   - 修复方向(供 Allen 定夺,一行级):`normalize_ws` 换非 unicode 模式/先 scrub,或 trim 对齐码点边界。main HEAD `bf5e03e94` 的 server.ex 同样存在。
   - **尝试过的 runtime 缓解**:`:sys.replace_state` 清空两个 PTY 的 observers 列表 —— 被权限分类器拒绝(未绕过);公开 facade `Pty.start` 重启也无法去掉 default auto_prompts(init 无条件前置),无 sanctioned 缓解路径。

## 其他如实记录的 gap(本 run 实测)

1. **@mention 解析不认 role-slot agent 的角色名**:role-slot agent 的 display_name=uuid(`EntityPresenter`),`@kanban-assistant` 裸名既不匹配 URI 段(uuid)也不匹配 display_name → `mentions: []` 静默不路由(world `conversation_data.ex` `resolve_member_name`);composer 的 autocomplete listbox 在真键盘输入下也没弹出。**workaround(本 run 用)**:`@entity://system/agent/<uuid>` 全 URI mention 100% 解析。
2. **建会话 UI 5s dispatch timeout vs cc materialize 实际 ~3 分钟**:UI 红字"创建会话失败 {:create_session_exit, {:timeout, …5000}}",但后台 materialize 实际完成,刷新后 session 正常——误导 operator。
3. **lib.sh `ab_fill_react` 不支持 textarea**(HTMLInputElement setter 对 textarea Illegal invocation)——本 run 用 HTMLTextAreaElement setter 变体;可回补 lib.sh。
4. 每个角色 materialize 出的 cc config dir 无 `.credentials.json`(已知,A² 前手动拷)。

## 引导程度(如实)

- 全部消息都是 operator(Admin)在真 chat 里发的;**助手 0 次成功回合**,所以谈不上"自主/引导比例"——发过 4 轮指令(含"只跑这一条 bash"的极简版),每轮都死于 PTY 崩溃,没有任何一轮跑到 `mix ezagent`。
- 板由 owner 建出符合协议 §a0(kanban-team-collaboration.md:板永远 owner 建,助手只 dispatch 驱动)。

## 复跑指引

PTY bug 修掉(或授权 runtime 缓解)后,从"给助手发一条含全 URI mention 的建卡指令"继续即可,后续步骤(dev 真 gh PR → register_pr → `__done__` relay → gh pr view 验证 → set_stage 两档)的通路件(路由规则/caps/CLI 身份)本 run 已全部验证在位。
