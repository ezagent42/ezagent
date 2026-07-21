# Return: ㊵ 人本位 receive

> 注:本件所验行为已被 2026-07-20 `docs/e2e/2026-07-20/final-round/`(全六面收官轮)取代,此 return 仅留作台账。

- **returned_at**: 2026-07-19 22:05 (+08)
- **commit**: 4d9356319(rebased origin/main d0f851232 后首件)

## DoD 对账

| 条目 | 状态 |
|---|---|
| 钥匙发给点击者本人(`Mount.mount_for_person` person-scope 行) | ✔(单测 + mount-rows.txt 3 行 person/read) |
| 板出现在点击者自己的 kanban tab(ws∪cap 派生枚举) | ✔(in-app 原地切 tab + 深链 /plugins/kanban) |
| 不发生 session 跳转 | ✔(气泡点击 URL 前后不变;controller 302 改深链) |
| 读/写按点击者与板的关系判(gate check) | ✔(读成 s07 / 写 missing_cap s08) |
| SessionReads 授权门不回退裸 get_slice | ✔(成员读整段删除;红线备案 moduledoc,㉙ 复用时必须走 SessionReads) |
| assistant 解析整段删除 + ws_policy 单守卫(D4) | ✔ |
| TDD:plugin e2e 重写 + controller/world_data/registry 测试全绿 | ✔ |

## e2e 证据

`docs/e2e/2026-07-19/40-person-receive/`(s01-s09 + mount-rows.txt + README)。

## 遗留(非本件面,README 发现①-④详述)

- **D4 跨 ws read 放开的 core 半件**:runtime step 5.6 workspace isolation 把跨 ws 合法 read cap dispatch 拦死(`:cross_workspace_denied`),plugin 侧 ws_policy 已放行——需 Allen 拍 core 落点(同 ws 分享全链绿,业务主场景不受影响)。
- 向导装 socialware 撞 `write_session_templates`(普通 founder 无此 cap)且 UI 吞错;建板后 socket caps 陈旧 → 首写 `:invalid_cap_signature`;invite join `:missing_cap`。
