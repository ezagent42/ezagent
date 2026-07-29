# C8 obtain 侧 — URI-native 寻址（域代码零裸 pid）

- **id**: `c8-pid-closure-obtain`
- **owner**: Allen 轨道
- **status**: planned(暂缓至 #189 落地)
- **历史**: started 2026-07-26 · est_done 2026-07-29 · actual —
- **关联**: branch feat/v5-pid-closure @ 19bfc7761(已推送待合) · 无 PR 号(直推分支)

- **branch**: `feat/v5-pid-closure`
- **依赖**: use 侧 c8-mailbox-seal 完成 → cross-track reconcile → 一起合 main；C8 收口本身暂缓至 #189 落地

## 目标
Kind 只经 URI 寻址，域代码不再获取 raw Kind pid——C8 定式「delete-the-holes」pid-纪律
（#200 决策）的 obtain 半程：删掉裸 pid 通路本身，而非在通路上加检查。

## 验收
- [x] A1a/b/c + Chunks 1–4 完成：域代码 `KindRegistry.lookup` 烧毁、`TargetAuthority` 进
      scanner framework-verb allowlist、AST 级 enumerator gate 落地
      （evidence: `genserver_to_pid=0` · domain-lookup gate=0 · 19bfc7761 已推送）
- [ ] 与 use 侧分支（`feat/v5-use-side-mailbox`）cross-track reconcile 后合入 main

## Handoff prompt

> C8 obtain-side pid-closure：域代码 (apps/ezagent_domain 及各 socialware/kanban 插件) 里
> 任何直接持有/传递 Kind 的原始 pid（GenServer/`Process` handle）都必须消灭，改为只经
> URI（`kind://...`）寻址，由 `KindRegistry`/`TargetAuthority` 在边界处一次性解析。
>
> SCOPE：
> 1. **A1a/b/c** — 枚举域代码里所有 `KindRegistry.lookup/1`（或等价直接拿 pid 的调用）的
>    调用点；域代码本体一律烧毁改走 URI 寻址；仅框架层（scanner 已 allowlist 的
>    `TargetAuthority` verb 集合）保留裸 pid 特权。
> 2. **Chunks 1–4** — 按子系统分批清（数量以枚举结果为准，不预设具体文件名）。
> 3. **AST 级 enumerator gate** — 新增/复用静态扫描 gate，把「域代码裸 pid」变成可复算的
>    数字闸值：`genserver_to_pid` 调用计数 = 0，`domain-lookup` gate = 0。gate 必须能在
>    CI 里跑（非人工巡检）。
>
> DONE 判定：两个闸值都=0，且 AST gate 已提交进静态检查套件（不是本地脚本）。
>
> 完成后 **不要**单独合 main——与 use 侧 `feat/v5-use-side-mailbox`（task `c8-mailbox-seal`）
> 做 cross-track reconcile（同期都改 Kind 寻址/写路，需要对账合并顺序），再走 `c8-closeout`
> 任务的 A2 census-freeze 一并收口。
