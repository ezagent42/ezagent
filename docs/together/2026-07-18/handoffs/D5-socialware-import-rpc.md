# Handoff: D5 — socialware.import 分布式 RPC(infra,原 PR-D)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** an independent developer
> **Tracking:** 开工单 v2 终版 infra 清单 #6 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(记录型——D5「保持 boot-scan prod-only」Allen 已拍,RPC 是其配套 dev 正路)

## 0. Mission
dev 改 manifest 没有正路生效车道(boot-scan prod-only,config.exs:33;历史 workaround 是自标 TEMP 的 `.iex.exs` 手工 seed!+临时目录 scan_dir!,已删)。修 = `mix ezagent.socialware.import` 走分布式 Erlang RPC 在**运行节点内**执行(收编 workaround 的做法为正路)。

## 1. Required reading
1. Skill `ezagent-developer` + `ezagent-socialware`(seed 车道三层机制)。
2. `docs/together/2026-07-16/handoffs/allen-decisions.md` §D5。
3. `apps/ezagent_domain_session/lib/ezagent/socialware/manifest_yaml.ex`(import/export 唯二文件 IO 点)+ `manifest_seed.ex`(scan_dir!)。

## 2. Locked decisions
| # | Decision | Value |
|---|----------|-------|
| 1 | boot-scan 口径不动 | `socialware_manifest_boot_scan: config_env() in [:prod]`(config.exs:33)保持——**不改** |
| 2 | 车道 | CLI 已是分布式-RPC shell(ezagent_cli exec.ex);import 在运行节点内跑 parse→resolve→conformance→governed publish(`publish_or_upgrade`),与 boot-scan 同一条 governed 链 |
| 3 | 授权 | 走 `operator_admin_ctx`(manifest_yaml.ex:93-106)现姿势,不新开权限口 |

## 3. 现象/原因
- **现象**:dev 栈改 `priv/socialware_seed/kanban/manifest.yaml` 后无法生效(boot-scan 关),只能重启+手工 hack。
- **原因**:D5 拍定 prod-only 是对的(dev 不应 boot 扫);缺的是**显式 operator 动作**车道——mix task 在 CLI 节点跑时没有运行节点的 Repo/registry 上下文,须 RPC 到运行节点执行。

## 4. Plan
单 PR:`mix ezagent.socialware.import` 增强(或确认现 task 的执行位面)——经 CLI 分布式 RPC 在 server 节点调 import 链;dev/prod 同姿势。验证:dev 改 manifest → import → 界面即见新版。

## 5. Definition of Done
- [ ] dev 栈:改 manifest → `mix ezagent.socialware.import <dir>` → 零重启生效(E2E:import 输出 + world UI 见新 revision——真栈跑一遍)
- [ ] conformance 失败 → loud 错误(非静默);重复 import 幂等(`:exists`/`:upgraded` 语义与 publish_or_upgrade 一致,单测)
- [ ] config.exs:33 零改动(红线)
- [ ] All gates green + CI green + rebased on `main`

## 6. Discuss-first vs Deferred
**Discuss-first:** 无。**Deferred:** export 侧对称增强(有需要再提)。**Never deferred:** 红线(决策 1)。

## 7-9. Conflict / Merge / LOC
文件面:ezagent_cli task + domain_session import 链薄封装;与其他线零交集。独立分支 PR → `main`。~60-120 LOC。
