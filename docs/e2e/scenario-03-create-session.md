# 场景 03(执行记录):创建 session + 加成员

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/09-session-create-lv](../scenarios/09-session-create-lv/scenario.zh_cn.md) |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~16:25 |
| **环境** | 分支 `feat/product-gaps-f9-f12` · commit `913e2ba0` · server `http://world.localhost:10042` |
| **前置 scenario** | scenario-01 ✅ + scenario-02 ✅(`zyli-echo-1` 可加) |

## 前置条件(当次实际)

- admin 已登录;workspace `workspace://system`
- scenario-02 已建 echo agent `entity://system/agent/zyli-echo-1`

## 角色

- **调用方**:admin(`entity://system/user/admin`)
- **目标**:`workspace://system`(`:create_session`)→ 新建 `session://system/default/zyli-test-1`;`:add_member` 加 `zyli-echo-1`

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | Sessions → New session,名 `zyli-test-1`,提交 | 跳到 **Conversation 详情页**,session 选择器显示 `/default/zyli-test-1`(URI `session://system/default/zyli-test-1`);transcript "No turns in this session yet" | [s03-step1-session-member-zyli](./evidence/scenario-03/s03-step1-session-member-zyli.png) | ✅ |
| 2 | Add member,选 `zyli-echo-1` | MEMBERS=**2**:`zyli-echo-1` [AGENT] **绿点在线** + `Admin` [USER] 绿点;ROUTING=0(默认 Always,无显式规则) | (同上截图) | ✅ |
| 3 | (observer)对照确认服务端 session + 成员 | Sessions 列表新增 `session://system/default/zyli-test-1`(Available);MEMBERS=2,zyli-echo-1+admin 均 `data-online="true"`;transcript "No turns yet";无 no_such_actor | [s03-step2-session-confirmed](./evidence/scenario-03/s03-step2-session-confirmed.png) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| session spawn,LV 重定向到 session 页 | ✅ 跳到 Conversation 详情,URI `session://system/default/zyli-test-1` | ✅ |
| `:add_member` 后 cap 授予(spawn-then-grant 原子,PR #419) | zyli-echo-1 加入即**绿点在线**,无 no_such_actor(老快照竞态未复现) | ✅ |

## 遗留 / bug

- 注意 world React 岛 form submit 被吞问题(记忆 `world_react_island_form_submit_swallowed`)—— 本次创建+加成员均正常,未触发。
- ✅ **正向信号**:`world-e2e-seed.md §3` 记录的 `create_session` 超时 + snapshot race → `no_such_actor` 老 blocker **本次未复现**(zyli-echo-1 绿点在线)。待 scenario-04 发消息进一步实证 send 不被吞。

## 证据清单

- `evidence/scenario-03/s03-step1-session-member-zyli.png` — zyli 视角:session 详情 + 成员名册(zyli-echo-1 在线)
- `evidence/scenario-03/s03-step2-session-confirmed.png` — observer 服务端对照(session Available + 成员在线)

## 备注

- **会话详情入口**(observer 发现):直接 `/admin/sessions/<uri>/zyli-test-1` 会 404;正确入口是 Sessions 列表行 "Open" → `/sessions?session=<encoded-uri>`。记入操作约定,避免后续 scenario 走错 URL。

## 交叉引用

- 设计场景:`docs/scenarios/09-session-create-lv`(PR #408 / #419)
