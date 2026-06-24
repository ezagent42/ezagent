# 证据 · mindmap Miro 出站链路实测（增量 4 出站，2026-06-22）

> 分支 `feat/df-tech`。**真实输出，杜绝想象、不伪造绿。**

## 1 · API 契约探活（先探真 API 再写代码）

用真 token 对 Miro experimental 端点逐步探活，反推出确切 schema（迭代见会话）：
- 建板：`POST https://api.miro.com/v2/boards` body `{"name": "..."}` → 201 + `{"id": board_id}`
- 建节点：`POST /v2-experimental/boards/{board}/mindmap_nodes`
  body `{"data":{"nodeView":{"data":{"content":"文字"}}}}` → 201；**第一个自动成根**（`isRoot:true`）
- 建子节点：加 `{"parent":{"id":"<父miro_id>"}}` → 201，层级成立
- 读：`GET .../mindmap_nodes` → `{"data":[...]}`
- ⚠️ 该端点是 Miro 标注 experimental；`data.type`/`data.content` 等直觉写法均被拒，必须嵌套 `data.nodeView.data.content`。

## 2 · 端到端实测（ezagent 树 → 真 Miro 板）

脚本构造一棵 5 节点 ezagent 树（与 `get_tree` 同形）→ `EzagentPluginMindmap.Miro.Sync.push_tree/2` → 真推 Miro → GET 复核。

**真实输出**：
```
== 推 5 节点的树到 Miro，板名 ezagent-live-… ==
PUSH_OK board_id=uXjVHDSo-jM= 建了 5 个节点
VERIFY_GET 板上实有节点=5 其中根=1
```
树形：`ezagent产品树 →（定位、功能）→ 功能下（思维导图双向打通、节点认领）`。打开该 Miro 板可见渲染结果。

**结论**：ezagent 节点树 → Miro 板**出站链路打通**，节点数 + 根数 + 层级均正确，真实可行——非臆想。

## 3 · 单元测试（纯函数，无网络）

`EzagentPluginMindmap.Miro.Sync.tree_to_ops/1`（树→有序操作，根在前/父在子前/兄弟按 order）：3 个单测。
全套 mindmap：**22 tests, 0 failures**（markmap 7 + behavior 10 + sync 3 + roundtrip e2e 1 + persistence e2e 1）。

## 4 · PR gate（全绿）

| gate | 结果 |
|---|---|
| compile | 干净（含 `:ezagent_plugin_check`）|
| arch.scan set_effect_sites | 122/122 |
| doc.scan undocumented_public_defs | 374/392 |
| format | 我的文件 rc=0 |

## 5 · 实现

- `EzagentPluginMindmap.Miro`（`miro.ex`）：`:httpc` + `Jason`（对齐 feishu，无重依赖）；`read_creds`(读 `system://credentials/miro.yaml`)/`create_board`/`create_node`/`get_nodes`。
- `EzagentPluginMindmap.Miro.Sync`（`miro/sync.ex`）：`tree_to_ops/1`(纯) + `push_tree/2`(真推)。
- `mix.exs`：`extra_applications` 加 `:inets/:ssl/:crypto`，deps 加 `{:jason}`。

## 6 · 诚实推迟（增量 4 下半，未做）

- **入站（人在 Miro 改 → webhook → ezagent）**：需公网可达 URL + 身份绑定(Miro user↔ezagent) + CapBAC 复核 + 回声防护。本地起步做不了，明确推迟。
- **复用板 + 增量 diff**：当前每次 `push_tree` 建**新板**（证明链路）；复用同板 + 只推变化 + ez_id↔miro_id 持久化映射，是下一步。
- **ergonomic 触发**：现在经 `Sync.push_tree/2` 函数/脚本触发；做成 `mix ezagent.mindmap.miro.push <session>` 或 Behavior action 更顺手。
- **Miro 板成员/CapBAC 对齐**：权限模型（ezagent 权威 + 回滚）随入站一起做。
