# Return ack → @黄佳佳：cc-headless 已合并 main

> 这是对 PR #931（cc-headless 真实现）的 lead 验收回复，供 @林懿伦 转发给 @黄佳佳。

## ✅ cc-headless 已合并 main（#931 → `2c5bb208`）

走的 dev-together push→close 流程：return 记入 `docs/together/2026-06-24/returns/`，进 `stack.md`，rebase 最新 main 干净，过 close-gate 后合并。验收：
- `mix precommit` EXIT=0（全 suite 0 failures，grep 确认）+ `check_invariants` EXIT=0 + 45 arch tests 0 failures。
- **codex 对 core/domain 改动做了对抗式 review**：路由正确性（cc/codex/curl/echo 不被误路由）、cap 守、slice 归属、single-spawn-entry —— **全部 sound**。👍 receive/delivery 只对 `"cc-headless"` 映射 `:cc_headless_sync_result`、其它 flavor 仍走 `:sync_result`，没有重复投递/丢失；behavior superset 只把 cc-headless 加进声明集，老 flavor 不会误拾。

## ⚠️ 两点（登记进 review，未来注意）

**1.（已由 lead 在合并时修掉）arch 基线 cap 方向反了**：你把 `spawn_registry_call_sites`/`_modules` cap **调高**到 43/38，但实际计数其实**降到** 41/36——因为 cc-headless 模板改用了 `Ezagent.Kind.spawn/2`（不再走 SpawnRegistry），SDK sidecar 用 `DynamicSupervisor.start_child`（属 sidecar allowlist，不计入这个数）。我已把 cap **ratchet 到实际 41/36**（cap 调高会"掩盖"未来 2 个回归）。**以后注意**：cap 只在真新增债时调高，且方向要跟实际计数一致；减少了就 ratchet 下来。

**2.（待 @林懿伦 拍板，非 bug）protocol-api 去掉了前缀解析**：`openai_chat_plug` 从 `cc_`/`codex_`/`curl_` 前缀推 flavor → 改成 `UriQuery.resolve(:flavor)`。这**符合**"flavor 是存储属性、不从名字前缀解析"的架构方向（赞）。副作用：**未预配置**的非-echo protocol 目标（光有 cc_ 前缀、没存 flavor）现在会 spawn 失败而不是自动建。这是有意收紧，不是 bug；但若有外部客户端依赖前缀魔法，需要 @林懿伦 决定要不要补一条"目标 agent 自动预配置"路径。

## 下一步（你今天下午的 track）

`feat/agent-config-backend` —— agent 配置**后端完整性**（完整 config cascade 可读 + 每 key 经 `apply_config_delta` 可写 + console 需要的后端函数齐全 + 后端测试逐项证明）。这是 @戴明 #84 前端能调的契约。**开工前先和 @戴明 对齐前后端接口契约**。详见你的 handoff：`docs/together/2026-06-24/handoffs/gaga-cc-headless-and-agent-config-handoff.md`。

辛苦！cc-headless 干得漂亮。
