# 证据 · mindmap 增量3 节点数据模型（2026-06-22）

> 分支 `feat/df-tech`（基于 a6fa6db3）。按 dev-together handoff 标准；真实输出、杜绝想象。
> 设计 `docs/superpowers/specs/2026-06-22-mindmap-node-model-design.md`。

## DoD（可演示产物）— CapBAC per-node 经真实 dispatch 生效 ✅
`apps/ezagent_plugin_mindmap/test/e2e/capbac_test.exs`：真 spawn Mindmap Kind，经
`Ezagent.Invocation.dispatch/1` 跑：
1. admin 建根 + 功能点节点；
2. **alice**（持非通配 `cap(:mindmap, Behavior.Mindmap, :any)`）`claim_node` → owner=alice、status=:claimed；
3. **bob**（同样持 mindmap cap、实例级授权通过，但**非 owner 非 admin**）`set_status` → **`{:error, :forbidden}`**（handler 的 per-node 闸拒掉）；
4. **alice（owner）** `set_status :doing` + `attach_artifact`(github PR) → 通过；
5. `get_tree` 复核 owner/status/artifacts 都对。

→ 证明"**admin + 节点 owner**"经**真实 dispatch + ezagent CapBAC**生效（bob 有实例 cap 但被节点级拒）。授权机制由 skill-1 常驻 agent 查证：`ctx.caps` 内联具体 cap 精确匹配即过（`runtime.ex:405/539`、`capability/match.ex`），per-node 在 handler 用 `ctx.caller`/`ctx.caps` 判。

## 测试（27，0 失败）
markmap 7 + behavior 14（含认领/状态/挂载/指标/授权/不变式 `owner==nil⟺unassigned`）+ sync 3 + e2e 3（roundtrip / persistence / **capbac**）。

## 全 gate（handoff 标准全集）✅
| gate | 结果 |
|---|---|
| compile + `:ezagent_plugin_check` | ✓ |
| arch.scan set_effect_sites | **122/122**（所有写走单一 `commit/1`，14 动作不增站点）|
| doc.scan undocumented_public_defs | 374/392 |
| **uri_query.scan** | ✓ no violations |
| check_invariants(+lifecycle) | ✓ |
| format | ✓ |

## 范围（本轮 = mindmap + Miro 打通）
- 节点数据模型 + per-node CapBAC：✅ 本增量。
- Miro 出站：`Miro.Sync` 只读 `title/parent_id/order`，新字段不破坏 → 打通保持。把 status/owner 映射成 Miro 颜色/tag = 增量4下半（deferred）。
- **后续工具链（github CI / ops 自动化 / Miro 入站轮询）= 待讨论的几个插件，经 dispatch 接入（架构已支持，零耦合）**——本轮不做。

## 合规
- 纯 plugin，只改 `apps/ezagent_plugin_mindmap/`（不碰 world/core 逻辑）。
- per-node 授权采"CapBAC 管实例级 + handler 管行级"——已核实 `data_owner/1` 是 per-instance（`behavior.ex:223`），故 per-node 必在 handler，是 ezagent 行级授权常规方式（非 hack），仍实现用户定的"admin + 节点 owner"。
