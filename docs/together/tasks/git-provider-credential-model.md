# git-provider 凭据模型 —— V1 + 错误分类 + 五形态对比 → B2′ 拍板

- **id**: `git-provider-credential-model`
- **owner**: gaga
- **status**: done(收敛为 B2′ → `agent-ssh-credential-b2`)
- **历史**: started 2026-07-30 · est_done 2026-08-02 · actual 2026-08-03
- **关联**: PR #1643(Forgejo Git Provider V1, merged 07-30) · #1668(错误分类 :provider_response_unrecognized 拆出 :provider_unavailable, merged 08-03, 4359f4a6e) · #1677(五形态对比 + Plan A NO-GO 重核, merged 08-01) · 落地线: #1688(B2′)

## 目标

git-provider 的凭据模型定形: Forgejo Git Provider V1 落地后, 把不可读 provider 响应从
`:provider_unavailable` 拆出为 `:provider_response_unrecognized`(错误分类诚实化); 五种
凭据形态对比 + Plan A NO-GO 重核交付 Allen, 拍板走 **B2′**(User SSH 身份 + 物化进 agent,
私钥明文形态 APPROVED)。

## 验收

- [x] #1643 Forgejo Git Provider V1 入 main(evidence: merged 07-30)
- [x] #1668 错误分类拆入 main(evidence: 4359f4a6e)
- [x] #1677 五形态对比 + Plan A NO-GO 重核交付并入 main(evidence: merged 08-01)
- [x] B2′ 路线拍板(evidence: 08-02/03 决策) → 实现见 `agent-ssh-credential-b2`(#1688 merged)

## Handoff prompt

无 cc 派发 prompt —— gaga 自有轨道。五形态对比结论与 NO-GO 依据见 #1677 正文;
B2′ 实现/评审见 #1688; 撤销面 follow-up 见 `ssh-revoke-wipe`。
