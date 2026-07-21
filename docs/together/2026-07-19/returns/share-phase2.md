# Return: 分享二期(㉙ share_to_session dispatch + 规则8 request_edit)

- **returned_at**: 2026-07-20 00:05 (+08)

## DoD 对账

| 条目 | 状态 |
|---|---|
| ㉙ `kanban.share_to_session` dispatch(服务端 access gate + 物化分享消息 `hops: 0`) | ✔(白名单+handler+等价锁;e2e s01/s02) |
| 消息可见性 | 分享消息本体 `:external_visible, hops: 0`(`:internal` 被 chat 读面整体过滤、气泡无人可见——功能性取舍如实记);操作留痕走 `materialize_op` 的 `visibility: :internal, hops: 0`,两契约并行 |
| ErrorSignal 结构化错误、禁散文 | ✔(错误全走同步 :call → DISPATCH_ERR 字典,零散文物化;异步物化的 ErrorSignal 约束已立注释) |
| 规则8 `request_edit` → 板主人批准 → re-mount read→operate | ✔(`kanban.request_edit`/`kanban.approve_edit` + 申请/批准气泡 UI;`Mount.mount_for_person` person 自然键原地升级,仍 1 行;e2e s03-s06 + mount-rows-after.txt) |
| D4 不变量 3(升级点复查同 ws) | ✔(`ShareReceive.ws_policy(:operate,…)` 复查;跨 ws 申请人 `:cross_workspace_denied` 单测反例) |
| 授权反例 | ✔(:not_board_owner / :no_read_mount / :already_owner / :no_access,kanban_share2_test 全绿) |
| TDD | ✔(apps/ezagent_web/test/ezagent_web/socialware/kanban_share2_test.exs 新增全链测试;registry 等价锁 +3) |

## e2e 证据

`docs/e2e/2026-07-19/share-phase2/`(s01-s06 + mount-rows-after.txt + README)。

## 遗留

- 批准后对端 socket caps 不自动刷新(要刷新页面)——归 X1 推送环/membership `:notify` 半件(工单已记降级)。
- 申请气泡只物化进申请人当前会话,板主人不在同会话看不到(同上 X1 降级)。
- manifest `routing_rules` 未动(消息均 hops:0 零路由,无路由需求)。
