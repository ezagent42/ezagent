# Agent SSH 凭据 B2′ —— User SSH 身份 + 物化进 agent (#1688)

- **id**: `agent-ssh-credential-b2`
- **owner**: gaga
- **status**: done
- **历史**: started 2026-08-01 · est_done 2026-08-03 · actual 2026-08-03
- **关联**: PR #1688(merged 08-03, 8ad5d3795) · 前置: `git-provider-credential-model`(#1677 五形态对比 → Plan A NO-GO → B2′ 拍板) · follow-up: `ssh-revoke-wipe`(撤销即擦除, codex, 按序跟上)
- **branch**: `feat/agent-ssh-credential`

## 目标

git 凭据模型 B2′ 形态落地: agent 持有 **User SSH 身份**并物化进 agent(私钥明文形态,
Allen 08-03 APPROVED), 使 agent 能以用户身份对 Forgejo 做 git 操作 —— 服务 agent 开发
自举主线(平台能被用来开发 agent)。

## 验收

- [x] B2′ 实现 + PR open(evidence: `feat/agent-ssh-credential`)
- [x] 私钥明文形态决策: Allen APPROVED(evidence: 08-03 拍板)
- [x] cc 评审通过 → rebase main → gate+merge(evidence: merged 08-03, 8ad5d3795)
- [ ] 撤销即擦除 follow-up(`ssh-revoke-wipe`, codex)按序合入 —— wipe 未合前, agent 物化凭据存在撤销不即擦除窗口

## Handoff prompt

> B2′ 已入 main(#1688, 8ad5d3795)。剩余动作 = 收口验证 + follow-up 跟入:
>
> (1) 在含 #1688 的 main 上核对: agent 物化 User SSH 身份后能以用户身份对 Forgejo
> 完成 git 操作(clone/push 冒烟), 私钥明文形态与 #1677 五形态对比结论 + Allen
> 08-03 APPROVED 口径一致。
> (2) 推动 `ssh-revoke-wipe`(gaga 轨道, codex 执行)评审合入 —— wipe 未合前,
> agent 物化凭据存在撤销不即擦除窗口; 该窗口随 follow-up 合入关闭, 届时回勾
> 本 task 验收第 4 条。
