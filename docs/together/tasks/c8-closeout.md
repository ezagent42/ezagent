# C8 收口：A2 census-freeze → cross-track reconcile → 双分支合 main

- **id**: `c8-closeout`
- **owner**: Allen 轨道
- **status**: planned(暂缓至 #189 落地)
- **历史**: started 2026-07-28 · est_done 2026-07-29 · actual —
- **关联**: 依赖 `c8-pid-closure-obtain`（obtain 侧, feat/v5-pid-closure）+ `c8-mailbox-seal`
  （use 侧, feat/v5-use-side-mailbox）两个任务都先收口

- **依赖**: #189 一次合入 main（避免与身份平面并发改 use 侧 mailbox/pid 面返工）

## 目标
关闭 C8，actor-isolation 全链（C0–C8）落 main——结构主线的最后一步：census-freeze
冻结当前 pid 使用面清点，做 obtain 侧 × use 侧的跨分支对账，最终两个分支一起合入。

## 验收
- [ ] A2 census-freeze（pid-surface 冻结清点）通过：全仓扫描确认除 allowlist 外无域代码
      裸 pid 使用
- [ ] obtain 侧 × use 侧 cross-track reconcile 完成（两分支同期都改了 Kind 寻址/写路，
      需要确认没有互相踩踏、合并顺序有定论）
- [ ] `feat/v5-pid-closure` + `feat/v5-use-side-mailbox` 两分支合入 main
- [ ] 合入后 `mix gate.arch` + `mix ezagent.uri_query.scan` 在 main 上仍 0 违规

## Handoff prompt

> C8 收口是 actor-isolation（C0–C8 全链）结构主线的最后一步，**暂缓至 #189 身份平面
> cutover 落 main 之后启动**（避免两条线并发改 use 侧 mailbox/pid 面互相返工——07-28 板
> 的教训是 C8 use 侧曾被误判为「EM-authz」而与 #189 纠缠，已在 `c8-mailbox-seal` 卡订正
> 为纯 mailbox 封口）。
>
> #189 落地后，SCOPE：
> 1. **A2 census-freeze** — 对整个域代码跑一次 pid-surface 冻结清点：枚举所有仍然
>    持有/传递 Kind 原始 pid 的调用点，确认除了 `TargetAuthority` 的 framework-verb
>    allowlist 之外没有遗漏。这是「收口前最后一次全量核对」，不是增量检查。
> 2. **cross-track reconcile** — `feat/v5-pid-closure`（obtain 侧，URI-native 寻址）与
>    `feat/v5-use-side-mailbox`（use 侧，sealed mailbox）在 07-26～07-27 期间同期改了
>    Kind 寻址/写路相关代码；rebase 到彼时最新 main 后，人工对账两分支改动是否有语义
>    冲突（不是 git 冲突，是设计层面：obtain 侧收窄了寻址方式，use 侧收窄了写入方式，
>    两者组合后行为要仍然自洽）。
> 3. **合并** — 对账通过后，确定合并顺序（哪个分支先 rebase 到含另一个分支改动的 main），
>    两分支依次合入。
>
> DONE 判定：合入后 main 上 `mix gate.arch` 0 failures，`mix ezagent.uri_query.scan`
> 0 violations，且这两个闸值本身已经是「域代码零裸 pid」的可复算证明。
