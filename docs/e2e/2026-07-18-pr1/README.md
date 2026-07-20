# D1 join 补发 e2e 证据(2026-07-18,双账号真 UI,PORT=10052)

**分支**:`feat/kb-join-backfill`(base = main `d533a5d73`)。**修的现象**:新成员进已挂看板的会话,看不到「看板」tab、没有本会话已挂板的钥匙(layering-debt ⑤⑧)。**修法**:`Ezagent.Socialware.MemberBackfill.backfill/2` —— 唯一 caller-side confirmed 补发供给点,接到全部加人入口。

**环境**:本 wt 起 dev server(节点 `ezagent_r1@127.0.0.1`,PORT=10052,共享 dev 库 `ezagent_pg_compat_dev`,seeds 同 2026-07-16 e2e);账号 owner@test.local(A)/ viewer@test.local(B1,跨 ws)/ editor@test.local(B2,同 ws;**注意其 profile display_name 历史设置成了 "viewer"**,截图右上角显示 viewer 实为 editor)。agent-browser 会话 pr1a/pr1b。

## 流程一:A 邀请跨 ws 成员 viewer(add-site = world `session.invite` → conversation_actions 拉人路)

| # | 证据 | 验证点 |
|---|---|---|
| a01/a02 | A 登录 + world home | 环境真 UI |
| a03/a04 | A 建 kanban 会话 pr1-room(native flavor)+ **A 见「看板」tab** | 创建期 owner 走 materializer join → backfill(main 上无 installer view-cap 路,A 的 tab 本身就是 D1 效果) |
| a05 | A 打开 Test-Kanban(已挂板 test-0716 operate + test-0717 **read** 行) | 补发数据源 |
| before-mounts-test-kanban.txt | 挂载表 4 行,**viewer 零行** | before |
| a06 | A 邀请 viewer(`session.invite`,同 add-site;UI picker 只列本 ws 候选,跨 ws URI 走同一 dispatch 通道) | 拉人入口 |
| after-mounts-test-kanban.txt | **+1 行:test-0716 × viewer × operate**;**test-0717(read 行)没有扩散** | ② mount 钥匙补发 + read 不扩散 |
| b01/b02 | B1 登录后自己的 home / 打开会话时 tab 尚未出现 | before |
| b03 | **B1 打开会话即见「看板」tab(零刷新、零管理员操作)** | ① view-cap 补发过 `authorize_view` gate |
| b04 | B1 tab 内板列表 = **只有 test-0716**(person-scoped:read 行的 test-0717 不在) | 人本位口径 |

**已知边界(非 D1)**:B1 读板内容撞 `:cross_workspace_denied`(invocations 实录)——跨 ws 内容读是 **D4 workspace 口径** 决策空间;D1 的钥匙已铸(cap_granted via_absorb 实录)。

## 流程二:A 邀请同 ws 成员 editor(无跨 ws 墙,全链可见)

| # | 证据 | 验证点 |
|---|---|---|
| before-mounts-owner-room.txt | Owner-Room 挂载表:只有 owner × r08-board × operate | before |
| b05 | editor 登录 home | before |
| a07 + after-mounts-owner-room.txt | A 邀请 editor → **+1 行:r08-board × editor × operate**(冷板 mint ~17s,`Mount.provision` 30s deadline 内) | ② 钥匙补发 |
| b06 | **editor 打开会话即见「看板」tab** | ① view-cap 补发 |
| b07 | editor tab 内 r08-board 列表+画布渲染(get_tree 走新钥匙) | 读通 |
| editor-capbac-granted-invocations.txt | editor 对 r08-board 的 `get_tree`/`add_node` dispatch **authz=granted**(CapBAC 用 D1 铸的钥匙放行) | 钥匙有效性(chokepoint 实录) |

**已知边界(非 D1)**:`add_node` 在 CapBAC granted 后被 kanban handler 按 main 的旧 ACL 拒(`根节点 = admin-only`,`加子 = 父节点 owner-only`,kanban.ex:265-272)——成员可写要等 PR-K 落协作模型(H1 自动认领),与钥匙补发正交。

## 单测(member_backfill_test.exs,6/6 绿)

补发本体(view cap granted_by=member + operate 行 + person keys granter=板主 #154)/ 幂等(重复调用 cap 不翻倍、行数不变)/ `:read` 行不扩散 / 单行失败不牵连+永不 raise / anon 只拿 participation tier / agent 整体 no-op。

## 复现

```bash
docker start ezagent-pg-compat-audit-postgres
mise exec -- mix ecto.migrate
export EZAGENT_SIGNING_SEED_V1=... EZAGENT_PAT_PEPPER_V1=...   # 同组 seeds
PORT=10052 WORLD_VITE_PORT=5252 mise exec -- elixir --name ezagent_r1@127.0.0.1 -S mix phx.server
# dev 前端骨架屏偶发(已知 ⑬):多刷新/重开浏览器恢复
```
