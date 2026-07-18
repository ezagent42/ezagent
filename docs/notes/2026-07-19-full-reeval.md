# 2026-07-19 全量重评 —— 五 PR 存废判定 + 问题清单对账

> 输入:main=a5dda0c30(含 #1457 per-Kind strict-verify / #1451+#1456 G5 / #1452 headless-MCP /
> #1453 凭证供给 / #1440 自助开通 / #1463 curl 错误测试跟修);四个 bootstrap 专项结论
> (CapBAC strict / agent 线四件全齐 / mount 永久机制半承载 / ErrorSignal 结构化错误);
> `2026-07-18-alignment-verdict.md`(五 landmark 对齐)+ `2026-07-18-work-order.md`(v2 切分)。
> 五个分支(本体 + 四 side)**均已本地 rebase 到 a5dda0c30**(merge-base 现查一致)。

---

## 一、五 PR 存废判定表

| PR | 分支 | 判定 | 理由与剩余动作 |
|---|---|---|---|
| **#1446 kanban 本体(PR-K)** | feat/kanban-collab-round2 | **保留照做** | #1457 适配已完成(278a42e51/335cca5a6:BoardProvision/Installation 迁 `{:admin,…}`/`{:held_by,…}`,夹具迁 `CapHelper.signed_*`,5 处 stale rule 注释改述);㊳㊴㊶+㊲kanban半+物化消息已落并有 e2e(36c0fa2ac)。**剩余**:㊵ 人本位 receive(`share_receive.ex:48` 现读仍 `@assistant_role` grantee,等 #1458 合)→ D3 `applies_to?` 翻转(`board_view.ex:51-61` 现读仍装板才 true,等 #1462 的 cap 半件合,顺序红线)→ 分享二期(㉙dispatch+规则8)。**新约束(bootstrap④)**:操作物化消息若日后物化失败/异步 agent 错误,必须走 `Ezagent.Agent.ErrorSignal.reply_body/1` 结构化通道,散文报错会绕过 world per-viewer 错误卡;同步 DISPATCH_ERR 字典维持(alignment ③ 判定不变)。收官轮 e2e 前 `mix ecto.reset`(存量 cap 全废) |
| **#1458 person-scope 挂载表** | feat/kb-mount-person-scope-handoff | **保留照做(降级权宜,迁移条款已自带)** | bootstrap③ 定论:永久机制**半承载**——`CompositionCaps.mint_cap/4` mint 面已能发人钥匙且 strict 兼容(composition_caps.ex:140,:341-347),但 `CompositionBinding` 强制 session+install provenance(composition_binding.ex:47-48,:95)**结构性装不下 person 行**——现在迁 = 无处可迁。本 PR 零 cap 机制改动(mint 同 chokepoint),与 #1457 无冲突。迁移条款:CompositionBinding 放宽 session 可空 + runtime provenance(Allen-gate)后 scope 列机械平移,挂 #1394。剩余:rebase 已毕,合并即解 ㊵ 前置 |
| **#1459 读面 handoff(docs)** | feat/kb-read-plane-handoff | **保留照做(等 Allen)** | main 三波 landmark 均不覆盖内部读面零 cap 判定(#1440 是进门面、G5 是错误面、#1457 是签发/验签面);**#1457 后论据反而更强**——写路已无条件 strict 验签,内部读面仍纯查表零判定,倒挂加剧,handoff 可补一句此对照。person-bound token(PR-C)仍以本 handoff 定性为前提 |
| **#1461 import RPC** | feat/kb-dev-import-rpc | **保留照做(撤销不成立)** | main 无任何 dev 导入正路(boot-scan 仍 prod-only,config.exs:33 未动);与 #1457 零交集(治理链 `publish_or_upgrade` 走 operator_admin_ctx,manifest_seed 不裸签 cap)。rebase 已毕,DoD 全勾,可直接推合 |
| **#1462 MemberBackfill(join 补发)** | feat/kb-join-backfill | **改向适配——已完成,保留** | 冲突点 = 原 `{:rule, :socialware_member_views, member}` tag,#1457 删除 rule 元组。**迁移已在分支上执行**(member_backfill.ex:14 现读:"granter = session owner,admin/held_by 二分,#1457";`:socialware_member_views` 字面 grep 零命中)。**不可撤销**:bootstrap③ 实证 main join 侧真空——composition 触发点只有物化/uninstall/离场 deactivate(session.ex:883),无 join-activate 对偶;`Mount.reconcile_session_mounts` 只按既有行重发不扩新成员。剩余:①收官 e2e 复跑前 `mix ecto.reset`;②给 Allen 的 Decision Log 请求**改口径**——不再是"补 rule tag 条目"(tag 已死),改为"入会补发授权口径(granter=session owner,caller-side)"备案 |

**一句话总账**:五 PR 零撤销。#1462 是唯一被 #1457 打中的,迁移已毕;#1458/#1462 都**不迁** CompositionBinding(结构性装不下,Allen-gate 放宽后再平移);#1459/#1461 原样;#1446 剩三件(㊵/D3翻转/分享二期)按序收。

---

## 二、全量问题清单对账(AUDIT ㉞项 + ㉟-㊷,共 41 计入项)

状态口径:✅已解决 / 🔶半解决(拆半:一半已落一半有归属)/ ❌未解决。

### ✅ 已解决(19)

| 项 | 结案方式 |
|---|---|
| ⑥⑦⑧⑨⑮⑲⑳㉓㉕㉖㉗㉚㉞ | 前两轮修复;⑥ 的 rule-authority 已按 #1457 迁 `{:admin,…}`(278a42e51),D2 追认拍板,永久收敛闭环(仅 Decision Log 条目待 Allen 记录,非代码) |
| ⑭ 邀请码面 | **main #1440 覆盖,销账**(`Workspace.Invites` + 管理 UI + registration_requests;旅程 e2e 归 zyli) |
| gap3/④ assistant 无工具 | **main #1452 关闭**(headless-MCP + CLI 身份 env);agent 线四件全齐(bootstrap②),sw 手检轮解锁 |
| ㊳㊴㊶ 前端三小 | 本体分支 ab23c5620,e2e 证据 36c0fa2ac |
| 债③ 分享业务在 controller | 7f32a44a8 搬 plugin |

### 🔶 半解决(14)

| 项 | 已落的一半 | 未落的一半 → 归属 |
|---|---|---|
| ⑤ 看板 tab 可见 | installer 半(上轮) | 成员 join 半 → **#1462**(已实现,待合) |
| ⑩ 凭证静默 skip | 供给面 **main #1453**(reinstall_socialware + skip 三分类落表) | UI 提示投影 → zyli #1443 |
| ⑪ dev 发布车道 | **#1461 已实现**(DoD 全勾) | 合并 |
| ⑯ 分享 ws 口径 | **D4 已拍**(只读放开+operate 隔离) | 守卫实现随 ㊵ → #1446 |
| ⑱ 深色主题 | kanban 半 | Conversation 层 → zyli |
| ㉑ 缺凭证横幅 | 上游 #1453 | 读侧投影 → zyli |
| ㉒ 建板自刷 | 推送环 kanban 半 | tab 深链 → zyli |
| ㉘ 操作广播 | kanban 半(:kanban_changed) | 基建半 → zyli |
| ㉙ 分享两选项 | 一期 UI ✅ | 二期 dispatch → #1446 分享二期 |
| ㉜ tab 恒显 | **D3 拍板 + cap 半件已落 #1462** | `applies_to?` 翻转 → #1446(等 #1462 合,顺序红线) |
| ㉝ 链接气泡 | unfurl 一期 ✅ | 点击挂载落点 → #1446 ㊵/二期(与 error_card 渲染点合并语义:互不吞,alignment ③) |
| ㊲ 附件 forbidden | kanban 半(点击现签 045c9fed3 + 物化消息 481e6f3cb) | 通用半 person-bound token → PR-C(以 #1459 过 Allen 为前提) |
| 债② kanban 住 world | 可搬半 ✅(d5655c715) | UI 注册机制 → D6 缓,#1394 |
| 债① BoardProvision 住 domain | 默认值半步 ✅ | 本体搬迁 → D6 缓,#1394 |

### ❌ 未解决(8)

| 项 | 归属 | 需不需要新 PR |
|---|---|---|
| ⑫ 向导按钮折叠 / ⑬ 骨架屏 / ⑰ 成员推送 / ㉛ 装 sw 面 / ㊱ 删 session UI | zyli #1443(实施 0 进展) | **不新开,催**(handoff 已 MERGED) |
| ㉟ builtin 命名 | 表层 zyli 向导+Allen 命名;深层随 ㉜ 两半合龙自然消失 | 不新开 |
| ㊵ 人本位 receive | #1446 内(唯一前置 #1458 已备好) | 不新开 |
| ㊷ create_session deadline | provision-deadline handoff(world caller 一行 `deadline_ms: 30_000`,conversation_actions.ex:349) | **需要:一个一行小 infra PR**(或并入最近 infra 批);泛化提案仍只记 Allen 线 |

**对账数字**:41 计入项(㉔被㉕取代不计)= ✅19 / 🔶14 / ❌8。上轮 AUDIT 口径(✅19🔨8⏸5📋2+半类)以来的净变化:main 侧收走 3 项(⑭#1440、gap3#1452、⑩上游#1453),决策侧 D1-D6 全拍清零 ⏸ 类,我方四 side PR 把 ⑤㉜⑪ 推到待合位。

---

## 三、新开工建议(优先级序)

1. **推合四 side PR**(全部已 rebase a5dda0c30):#1461(零依赖,直合)→ #1458(㊵ 唯一前置)→ #1462(合前收官 e2e 复跑一轮,**先 `mix ecto.reset`**;Decision Log 请求改为"补发授权口径备案")→ #1459 催 Allen 定性。
2. **#1446 收尾三连**(严格顺序):㊵ 人本位 receive(等 #1458 合)→ `applies_to?` 翻转(等 #1462 合)→ 分享二期;全程守 ErrorSignal 新约束(散文错误禁入会话物化);收官换最终全功能 e2e 轮(PR 收口收敛证据规矩)。
3. **㊷ 一行小修**独立落(provision-deadline)。
4. **sw 手检轮**(#1452 已合 = 最低闸门达成):五功能面 × 每步截图;fresh 环境凭证前置可走 #1453 `reinstall_socialware` 正路;顺核 `kanban-cli.sh` cookie 路径硬编码。
5. **方向变化备忘**:①任何新 mint 点二分口径固定——无人 granter 走 `{:admin, admin_uri}`(board_provision.ex:171,:188 范本),有人 granter `{:held_by,…}`+首签前 `TargetAuthority.ensure`;②#1458/#1462 折入永久机制的唯一触发 = Allen 放宽 CompositionBinding(session 可空+runtime provenance),届时表/触发点平移、mint 路不动;③kanban 未来"用户修不了"类错误注册进 G5 ErrorCode 表,不再扩 DISPATCH_ERR。
