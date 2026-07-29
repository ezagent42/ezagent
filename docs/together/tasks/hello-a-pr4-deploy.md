# hello 官网部署迁移（hello-A PR-4）

- **id**: `hello-a-pr4-deploy`
- **owner**: Allen 轨道
- **status**: planned(被 #189 阻塞)
- **历史**: started 2026-07-28 · est_done 2026-07-29 · actual —
- **关联**: 承接 hello-A 系列 PR-1~3（去硬编码）的 PR-4；无独立 PR 号（部署执行，非代码 PR）

- **依赖**: `189-identity-cutover` 完成 → main 全绿 → canary 自动放行

## 目标
去硬编码后的官网（hello template）迁移落到部署环境，走 canary→beta→stable 五步流程。

## 验收
- [ ] 5 步部署迁移（canary→beta→stable）执行
- [ ] 前置条件：每个部署节点须先有真实非管理员创始人用户 + `add_member`（不能用 admin
      账号代替真实用户验收）

## Handoff prompt

> hello 官网（去硬编码后，即 hello-A PR-1~3 已完成的产出）的部署迁移，走标准
> canary→beta→stable 五步流程（deploy 流维护在独立仓库，见
> `docs/agent-orchestration.md` 里对 deploy 拆分的说明；具体步骤参照该仓库的
> 部署 runbook，不在本任务重复）。
>
> **硬前置**：本任务**被 #189 阻塞**——canary 环境当前 HELD，要等 `189-identity-cutover`
> 完成、main full-suite 真绿、canary 自动放行之后才能执行部署。不要在 #189 解阻前尝试
> 手动绕过部署闸。
>
> 部署验收标准是**功能验收**而非「进程起来了」：每个环境（canary/beta/stable）都要
> 先用 `bin/ezagent rpc` 之类的正式写入路径创建一个真实的非管理员创始人用户并
> `add_member`，再用这个真实用户走一遍 hello 官网核心路径，确认去硬编码后的内容
> 正确渲染、无残留写死数据。不要用 admin 账号代替真实用户做验收（admin 视角会掩盖
> 权限相关的硬编码残留）。
