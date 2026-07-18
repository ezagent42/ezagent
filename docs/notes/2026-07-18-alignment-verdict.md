# 2026-07-18 对齐判定 —— main 新 landmark × 我方五分支(X/Y 方向验证)

> 背景:批次收口 rebase 前,逐个 main 新 landmark(#1457/#1451/#1452/#1453/#1449/#1440)
> 对照我方五个 PR 线,判「重叠(main 已做→收束改用 main 机制/删重复)/冲突(方向相抵→
> 改向适配)/独立(保留)」。有重叠/冲突的先改再 rebase。

## ① #1457 per-Kind signing authority × 我方全部 cap 签发点 —— **冲突→已改向适配**

#1457 把 Ed25519 签名权收进 per-Kind authority(target Kind 的 grant verifier 唯一签名点),
并**删除了 `{:rule, atom, uri}` / `{:genesis, uri}` 授权元组**——`Cap.issue/3` 与
`Identity.Grant` 的 authorization type 收敛为 `{:held_by, uri} | {:admin, uri}`。
同时 dispatch 要求 positive origin(`:authenticated_external | :trusted_internal`),
无 stamp 的 ambient fallback / 未签名 genesis wildcard 全部不再过验签。

我方逐签发点判定与适配:

| 签发点 | 原姿势 | 判定 | 适配 |
|---|---|---|---|
| ⑥ 建板 rule-authority(`BoardProvision.runtime_provision_ctx`,`{:rule, :socialware_runtime_provision, creator}`) | rule-tag 一次性 mint | **冲突** | 迁 `{:admin, admin_uri}` 具名系统 granter(同 main `anon_user.issue_born_with` 的迁移先例:没有人类 granter 的产品规则,由 canonical admin 作具名 extreme-case granter 经 workspace Kind 目标签名)。规则语义守卫(成员 + passive recipe)不变,仍 transient 不落库 |
| ⑤ installer view caps(`Installation.grant_installer_view_caps`,`{:rule, :socialware_install_views, installer}`) | rule-tag grant | **冲突** | 迁 Membership 同款:`TargetAuthority.ensure(granter, session)` + granter=installer(admin 走 `{:admin,…}` 其余 `{:held_by,…}`) |
| `Mount`/`CompositionCaps.mint_cap`(唯一 mint chokepoint) | `{:held_by, owner}` 自路径 | **重叠(main 已迁)** | rebase 自动采 main 版:`ensure_target_owner_authority/2` 落 per-Kind 授权后 issue,零我方改动 |
| Mount revoke(原注释称走 rule) | 代码已是 `{:held_by, granter}` | 仅注释 stale | 注释改述(#1457 后 revoke 不重跑 grant 授权) |
| `MemberBackfill`(kb-join-backfill 分支,`{:rule, :socialware_member_views, member}`) | rule-tag grant | **冲突** | 该分支 rebase 时同款迁移(granter = session owner,`grant_authorization/1` 家族)——见该分支 commit |
| 测试夹具(`admin_genesis_cap()` ambient wildcard / 无 origin dispatch) | 未签名 wildcard | **冲突** | 全部迁 `Ezagent.Test.CapHelper.signed_workspace_ctx!/signed_action_cap!` + `origin: :trusted_internal` |

「要不要登记 authority」结论:**要**。granter 首次对某 target Kind 签发前需
`Ezagent.Identity.TargetAuthority.ensure(granter, target_uri)`(main 的 Membership /
mint_cap 均如此);authority genesis 本身由 canonical-admin anchor 完成,业务层只管 ensure。

## ② #1453 reinstall_socialware(补物化) × #1462 MemberBackfill —— **正交,保留两者**

预判成立,边界写清:

- **#1453**(main):补的是**agent 角色物化**。对象 = install 时因**凭证缺失**被 skip 的
  role slot(durable skip 行);触发 = operator 手动 `mix ezagent.session.reinstall_socialware
  <session_uri>`(以 session owner 身份重跑幂等 install 管道);凭证轴。
- **#1462 MemberBackfill**(kb-join-backfill):补的是**人类成员钥匙**。对象 = join 已挂板
  会话的新成员(participation tier + declared-view render caps + 挂载表 `:operate` 行的
  person keys);触发 = 全部加人入口的 caller-side helper(红线:绝不在 handle_join 内同步发);
  cap 轴。
- 无重叠:一个管「角色 agent 没进成员表」,一个管「进了成员表的人没钥匙」。两者可同 session
  先后触发互不干扰(MemberBackfill 幂等,reinstall 后新物化角色是 agent 非 user,不走人类补发)。

## ③ #1451 G5 错误机制 × PR-K 错误码人话化 —— **独立保留,留收敛 TODO**

- **G5**:面向 **agent 执行错误**的注册型 triage 卡——`ErrorCode`(注册表:code/trigger/
  fix_path/fix_owner)→ `ErrorMatcher`(`{:error, reason}` 模式匹配)→ `ErrorRenderer`
  (按「当前用户能不能修」出 Layer 1/2/3 卡:可修给链接/不可修通知 fix_owner/未注册自动
  登记 issue)。
- **PR-K**:kanban dispatch 的**业务校验错误码**短提示(`last_dispatch_status "error:<code>"`
  → 前端 `DISPATCH_ERR` 字典人话 toast/红横幅,如 `root_exists`/`not_board_owner`)。
- 判定:**不收束**。kanban 业务错误没有 fix_path/fix_owner/issue 登记语义,是动作即时反馈,
  硬套 Layer1/2/3 卡是过度设计;G5 当前也不覆盖 LiveView dispatch-status 通道。
- TODO(不阻塞本批):若后续 kanban 出现「用户修不了需要找人」类错误(如凭证/配置类),
  应注册进 ErrorCode 表走 ErrorRenderer,不再扩 DISPATCH_ERR 字典。

## ④ #1440 自助开通 × ㉟(误选)⑭(邀请码面) —— **⑭ 销账;㉟ 不覆盖、维持原归属**

- **⑭ 邀请码管理面:已被 #1440 覆盖,销账**。`Ezagent.Workspace.Invites` ActionSet
  (`mint_invite/list_invites/revoke_invite`,CapBAC-checked)+ WorkspacePlugin 管理 UI +
  registration_requests 开放注册管道 + admin 注册设置。正合 ⑭ 改记(2026-07-16)的判定:
  邀请码模型、不给 `workspace.add_member` 补 UI。layering-debt ⑭ 条目标记「#1440 已落」。
- **㉟ builtin 'socialware' 概念名误选:#1440 不覆盖**(它是注册/开通面,不动建会话应用
  选择器)。㉟ 维持原判:表层命名归 zyli 向导 + Allen(builtin 命名),深层随 ㉜(D3)+㉛
  落地整体消失。不销账。

## ⑤ #1449 / #1452 顺带扫 —— **均独立,零改动**

- **#1449**:cc-custom provider-configurable completion backends 的 clarify-first 设计文档,
  纯 docs,与我方五线无交集。
- **#1452**:cc-headless MCP 落 main + CLI 身份 env + PTY parity——agent runtime 供给面。
  我方 kanban 线不触 cc-headless 运行时;它是 sw 侧功能面手检的最低闸门(memory 既有判定),
  非代码重叠。kb-dev-import-rpc(D5 manifest 导入正路)与其无关。

---

## 落地顺序(本批执行)

1. 本文档 + ①的主分支适配(BoardProvision/Installation/Mount 注释/测试夹具)commit 进
   feat/kanban-collab-round2(已 rebase 到 #1457 后的 main,套件绿)。
2. 其余五分支逐个 rebase:kb-join-backfill 按 ①表 MemberBackfill 行同款迁移;其余按
   「代码保我方语义 + 采 main 新 API」。
3. ⑭ 销账记录同步进 layering-debt 文档(该文档随分支走,不单独开 PR)。
