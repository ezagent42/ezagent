# MFU 产品线 —— v0.15 landing package 续作(已迁独立 repo, ezagent board 跨 repo 跟踪)

- **id**: `mfu-v015`
- **owner**: ruihua
- **status**: wip(canonical home 已迁 Forgejo `Prototype/mfu`; ezagent board 继续跟踪)
- **历史**: started 2026-07-28 · est_done —（迁移后节奏在 Prototype/mfu 跟踪） · actual —
- **关联**: PR #1586(merged 2026-07-29) · **#1676(07-31: mfu-demo 移出本 repo —— canonical home 改为 Forgejo `Prototype/mfu`)** · Allen 08-03 裁定: MFU 与其他产品工作**仍是 ezagent 工作**, 代码在独立 repo 不改变归属, 本 board 继续以 ruihua 卡跟踪

- **repo**: Forgejo `Prototype/mfu`（经 #1676 迁出; 本 repo 不再持有 mfu-demo 代码）

## 目标
v0.15 落地包(living doc 在原 `mfu-demo/doc/tree/skill-tree.md` §8.1, 已随迁移进 Prototype/mfu)。

## 验收
- [x] 成长树修复包 + 技能/经验框架落地(evidence: #1586 merged 07-29; 纯 demo/docs/skill 无 core 改动)
- [x] #1618 协作卡牌阵列首个教学订单(evidence: merged 07-31 14:01 CST; 即 07-31 return `ruihua-mfu-multi-role-demo` 的 PR)
- [x] repo 迁移: mfu-demo 移出本 repo, canonical home = Forgejo Prototype/mfu(evidence: #1676 merged 07-31)
- [ ] 认证移出树：N-07/N-11 → 认证徽章架（公司页 + 个人页）
- [ ] 经验条 UI：两页上半区进度条（订单/打工/作品/人脉计数）
- [ ] 外部认证录入入口（D41）
- [ ] 目标 2：孵化器树 + 孵化器工作台（N-13 根 + grants 权限机制）

## Handoff prompt
> 在 Forgejo `Prototype/mfu` 继续 v0.15 landing package(本 repo 不再持有 mfu-demo
> 代码, 勿在 ezagent 内改 mfu-demo 路径)。四块续作, 每块独立 PR、纯 demo/docs/skill
> 无 core 改动 → 绿色通道(CI 绿即合, 无需 codex Cap 审):
> ① 认证移出树: N-07/N-11 → 认证徽章架(公司页 + 个人页);
> ② 经验条 UI: 两页上半区进度条(订单/打工/作品/人脉计数);
> ③ 外部认证录入入口(D41);
> ④ 目标 2: 孵化器树 + 孵化器工作台(N-13 根 + grants 权限机制)。
> 范围口径 = living doc(原 `mfu-demo/doc/tree/skill-tree.md` §8.1, 已随迁移进
> Prototype/mfu)。每块落地后在 ezagent board 本卡回勾并附 Prototype/mfu PR 链接 —
> ezagent board 按 Allen 08-03 裁定继续跨 repo 跟踪该产品线(不标"已离开/下线")。
