# Round 1 — dispatch 驱动全闭环（27/27 全绿）

跑法：`/tmp 下 eval.sh scenario-v2.exs`（erpc → 活节点的授权 API：`Workspace.create_agent` + `Router.dispatch`）。多次复跑稳定 27/27（偶发 5s dispatch 超时是已知 kernel perf-bug，retry 即过）。

## 实测结果（board-mgr-7810 实例）

| 步 | 结果 |
|---|---|
| create_board_mgr（kanban-manager × native agent） | ✓ `entity://system/agent/board-mgr-7810` |
| 9 阶段接力链 add_node + set_stage ×9（positioning→metric→pain→anchor→ux→feature→issue→test→pr） | ✓ 全过（相邻棒校验 stage_fits 通过） |
| create_worker（第二个 agent） | ✓ `entity://system/agent/worker-feat-7810` |
| worker claim_node(feature) | ✓ `feature_owner = entity://system/agent/worker-feat-7810`（**agent 拥有节点**） |
| set_status doing→done | ✓ `feature_status = :done` |
| set_board_config（github jjkysy/test-ezagent） | ✓ |
| register_pr(issue, "1") | ✓ 节点挂 `%{tool:github, kind:pr, ref:"#1", url:".../pull/1"}` |
| export_markmap | ✓ 完整 9 级树 `# 定位…\n## 指标…\n### 痛点…\n…\n######### PR…` |
| get_tree / get_slice | ✓ 板持久化在 Entity.Agent `:kanban` snapshot |

**ok_steps: 27 / total_steps: 27**

## 证明

kanban-as-role 在合并后的 main 上端到端工作：双 agent（board + worker，均 entity://agent）、
9 阶段接力链、**agent 认领并拥有节点**（per-node CapBAC）、status 流转、github PR artifact、
markmap 投影、板=snapshot 持久（重启后 list_by_role 仍枚举得到）。
