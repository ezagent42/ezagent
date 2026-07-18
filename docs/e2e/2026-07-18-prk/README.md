# PR-K 小修真 UI e2e（2026-07-18，agent-browser --session prk）

- 环境：worktree kanban-progress-board @ `feat/kanban-collab-round2`，dev server localhost:10042（docker pg 55432），world UI http://world.localhost:10042，账号 owner@test.local。
- 现场：Owner-Room2 会话 → 看板 tab → test-0716 板 → 节点「dfsa」（本人认领）。
- 每张截图逐张 Read 自审后写结论；服务端证据（server log / psql / 下载文件）附文末。

## 结论表

| 项 | 验证点 | 截图 | 结论 |
|---|---|---|---|
| ㊶ tab 自适配 | 画布区随窗口高度伸缩（原 h-[560px] 固定高改 flex-1 min-h-0），左栏在区内自滚 | e01-tab-adapt-tall.png（1280×900）/ e02-tab-adapt-short.png（1280×620） | **过**：900 高时看板区（侧栏+画布）填满到窗口底；620 高时整区收缩适配、侧栏内部滚动，页面无纵向溢出 |
| ㊴ 单表单窗（新建） | 「添加→链接」不再两连 prompt，弹一个小表单窗（名称+URL 同窗） | e03-link-form-modal.png | **过**：「添加链接产物」modal，名称/URL 两输入框 + 取消/保存（名称空时保存禁用） |
| ㊴ 单表单窗（编辑） | 每条链接产物有「编辑」，点开回填原值，改完保存生效 | e04-link-form-edit-prefill.png | **过**：「编辑链接产物」回填 名称=e2e链接 / URL=https://example.com/prk/1；改 URL 为 …/prk/2-edited 保存后，DOM href 变为 `https://example.com/prk/2-edited`（eval 证据） |
| ㊳ 链接直开 | 填**裸域名** `example.com/prk/1` → 存储侧补 https://；「打开」原样新窗开，不拼 localhost base | e05-link-opened-external.png | **过**：保存后 href=`https://example.com/prk/1`（eval 证据）；点「打开」新 tab 真开到外网 Example Domain 页（tab list：`[t2] example.com/prk/1 - https://example.com/prk/1`），无 localhost 前缀 |
| ㊲ 附件点击现签（kanban 半） | file 附件「打开」= dispatch `kanban.download_artifact` 点击现签 fresh token → 触发下载（根治渲染预签 300s 过期） | e06-attach-download-row.png | **过**：上传 prk-附件测试.txt 挂节点（产物2）；点「打开」→ server log 见 `kanban.download_artifact` dispatch（点击时刻现签）→ 浏览器真下载成功，内容与上传原文件逐字一致（文末）。grantee 绑定（person-bound）等 infra-C 合后补 |
| 操作物化消息 | kanban 写操作以操作者身份物化 `visibility: :internal, hops: 0` 消息进会话（attach 带附件引用），普通 chat 读面不显示 | e07-chat-internal-owner-view.png | **过（带 infra 残留，见下）**：psql 证 4 条物化消息全部 `internal / hops=0 / sender=entity://…/user/owner`（挂产物/移除产物/挂附件，中文摘要带板名+节点名）；`recent_visible_in_session` 过滤 internal（单测 world_actions_materialize_test (b)）。截图为 **owner 视角** chat——owner 持 admin 位 `read_unfiltered` cap，读面不过滤属设计内 |

## 物化消息的 infra 残留（如实记，PR-K 拒收范围）

1. **live 推送不分 visibility**：`session.ex` `send_success` 的 `{:notify …, {:chat_message, …}}` 对 internal 消息也广播，`world_live.ex:173` 的 `handle_info({:chat_message, …})` 无 visibility 过滤直接 push 进转写——普通成员**开着页面时**会实时看到一条物化消息（刷新后按 visible 读面消失）。两处都是 domain/world 共享文件（PR-K 铁律拒收），随工单 §五「内部会话页读史零判定」族记 Allen。
2. **owner/admin 读史全可读**：持 `read_unfiltered` 形 cap 的读面（本轮截图视角）能看到 internal 留痕——即工单 §五已挂账的「observer 全可读」遗留，非本轮引入。

## 服务端证据

下载文件（与上传原文件逐字一致）：

```
$ cat /tmp/prk-downloaded.txt
prk e2e attachment content Sat Jul 18 14:02:06 CST 2026
```

server log（点击时刻的现签 dispatch）：

```
Parameters: %{"action" => "kanban.download_artifact", "args" => %{"id" => "n3", "kanban_uri" => "entity://owner-c9f54a/agent/test-0716", "ref" => "prk-附件测试.txt"}}
```

psql（物化消息真身）：

```
 visibility | hops |              sender              |                    text
------------+------+----------------------------------+--------------------------------------------
 internal   |    0 | entity://owner-c9f54a/user/owner | 【看板·test-0716】在节点「dfsa」挂了产物「e2e链接」
 internal   |    0 | entity://owner-c9f54a/user/owner | 【看板·test-0716】移除了节点「dfsa」的产物「e2e链接」
 internal   |    0 | entity://owner-c9f54a/user/owner | 【看板·test-0716】在节点「dfsa」挂了产物「e2e链接」
 internal   |    0 | entity://owner-c9f54a/user/owner | 【看板·test-0716】在节点「dfsa」挂了产物「prk-附件测试.txt」
(4 rows)
```
