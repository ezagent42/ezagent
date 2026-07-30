# Socialware manifest release gate (#1642)

- **id**: `socialware-manifest-release-gate-1642`
- **owner**: zyli
- **status**: review
- **历史**: started 2026-07-30 · est_done 2026-07-30 · actual 2026-07-30
- **关联**: PR #1642

## 目标

当 socialware 的 deploy manifest 或 recipes 发生变更时，要求 PR 显式记录发布确认，并在 CI 输出受治理的运行节点导入命令，避免部署人员误以为重启会替换已存在的运行时 manifest。

## 验收

- [x] 修改 `manifest.yaml` 或 `recipes.yaml` 而未同步修改同包 `release.yaml` 时，PR gate 失败并给出导入命令。
- [x] 无关改动、以及带匹配 `release.yaml` 的模板改动通过 gate。
- [x] gate 接入既有 CI `gate` job，PR 不需要新增单独的必需检查。
- [ ] PR #1642 的 GitHub CI 全绿并完成评审。

## Handoff prompt

无正式 handoff prompt——该任务由本地 Hello 模板定义升级的发布缺口直接派生；范围固定为 PR #1642 的 CI release acknowledgement gate 与其回归脚本。
