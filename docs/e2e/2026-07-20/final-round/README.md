# 收官全功能 e2e 轮（2026-07-20，真 UI agent-browser，同 ws 边界）

**环境**：worktree kanban-progress-board @ `feat/kanban-collab-round2`，rebased **origin/main fe2906431（#1471 person-bound DownloadToken 双 serve 路 + kanban-403）**；fresh dev DB（`ecto.reset`）；kanban 经 `mix ezagent.socialware.import_remote`（D5 RPC 治理路）发布；dev server 命名节点 `ezagent_runtime@127.0.0.1` :10042，world UI `http://world.localhost:10042`；前端为 `pnpm build` 产物（`/assets/world/main.js`，已含 ㊲ 清算后的直链下载 UI）。

**账号**（fresh，全部同 ws `kanban-e2e`，invite code 注册）：
- **owner**@test.local（A，板主人）——operator 前门补发模板三 cap（`write_session_templates` 等，07-19 发现① 同款，仍在）。
- **editor**@test.local（B）——invite 注册即入 ws（07-19 发现④ join `:missing_cap` **未复现**，零 operator 补挂）。
- **member**@test.local（C）——面⑥ 新成员。

## 六面结论

| 面 | 结论 | 证据 |
|---|---|---|
| ① 建板→加卡列 | ✅ | s01 向导（kanban 应用+双 role 槽 native）/ s02 建板自动进操作面 / s03 根+两子卡（stage 定位列，status doing） |
| ② 人本位分享（只读+写拒） | ✅ | s07 B 开分享深链 → 302 落 `/plugins/kanban/<board>`，flash「看板已加入你的看板页（只读）」，树全可读；s12 B **自己会话的看板 tab** 列出并渲染 final-roadmap；s08 B 写（加子）→ 红条结构化 `操作失败：missing_cap`，树仍可读 |
| ③ request_edit→批准→B 可写 | ✅ | s12 申请编辑（会话上下文）→ s13 A 侧物化申请气泡「批准编辑」→ 批准后 mount 行 editor **person-scope operate**（mount-rows-after-approve.txt SoT）→ s14 B 加子成功（@editor 节点入树） |
| ④ share_to_session 物化消息 | ✅ | s06 A 点「分享到会话」→ chat 物化【看板分享】气泡（服务端 messages 表有行）；s11 B 入会后同气泡可见（「加入我的看板」按钮） |
| ⑤ 附件（#1471 解锁面，重点） | ✅ | s04 A 传 final-spec.txt 挂节点；A 打开 → 200；s15 B 点「打开」（渲染期预签 person-bound href）→ **200** + `content-disposition: attachment`；**token-binding-proof.txt**：B 的 token `grantee=entity://kanban-e2e/user/editor`，A 重放同 token → **403**（caller≠grantee 拒）——serve 端 grantee match 取代 message-participation 复查 = kanban-403 根修实证 |
| ⑥ D3 新成员入会 | ✅ | A 邀 C 入会（MemberBackfill 路）→ erpc 实测 C 即持 `{KanbanRender,:kanban_render}`（本会话 instance）；s16 C 开会话：看板 tab 恒显、板列表/树渲染成功（只读，操作被 claim 文案+cap 门控） |

## 本轮清算验证面（#1471 对齐轮）

- ㊲「点击现签」权宜已整体删除（后端 dispatch/前端 effect/registry 白名单字面/fixture），下载 UI 回归 main 正路：**渲染期预签 person-bound href 直链下载**——s15/token-binding-proof 即该路径的活证。
- `WorldData.mint_download(url, grantee: caller)`（债② 搬移文件里 main #1471 的 grantee 绑定原样保留）为每个读板者本人签 token；A/B 各自 href 各自绑定。

## e2e 挖出的发现（如实记）

1. **`WorldUploadsController.authorize_attach` 空 ctx caps 被 #1457 strict 拒**（`:missing_cap`）：#1457 后 runtime 不再 ambient 装载 caller durable caps，该控制器仍 `caps: MapSet.new()` dispatch —— main 侧漏迁移点，合法 attach 持有者传附件必败。本轮按 strict 模型补：server 侧（LiveAuth 同款 `Ezagent.EntityCaps.load/1`）装载 presenter caps 呈交，授权仍全在 Kind chokepoint。修后上传即通（s04）。
2. **板深链页 request_edit 无会话上下文** → 结构化 `error:no_session_context`（fail-closed，非静默）：申请编辑目前只在会话内看板 tab 可用；深链页按钮存在但必失败，UX 待补（归 share 二期 follow-up）。
3. **建板后 socket caps 陈旧**（07-19 发现③ 复现）：`kanban.create` 成功后首个写 dispatch `invalid_cap_signature`，刷新即好——create 路缺 refresh_caps 小修仍待做。
4. **会话创建 UI 报 `{:create_session_exit, {:timeout,...}}` 但会话实际物化成功**（冷启动慢 + 5s GenServer call；ff8d44b44 修过 Mount.provision 30s deadline，创建链还有别的 5s 点）。刷新后会话在列、功能完好。
5. 07-19 发现④（invite 注册 join `:missing_cap`）**未复现**——invite 注册即成 ws member。

## 已删旧证据

按收口规矩，本轮取代 07-19 三个子轮（40-person-receive / d3-tab-always / share-phase2）的截图证据，已随本 commit 删除（returns/handoffs 不动）。
