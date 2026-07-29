> **Task:** share-A2-1 — Capability 可见性派生 `Cap.Visibility.caps_toward/2`
> **Branch:** `feat/socialware-share-a2-visibility`
> **PR:** https://github.com/ezagent42/ezagent/pull/1596
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 09:15 +0800
> **deadline:** 2026-07-28 (Group A 推进)
> **deadline_status:** on_time

## 做了什么
URI 授权分享统一(#1583 §7.7)可见性正向件。additive,纯 core,零业务文件。

- `Ezagent.Cap.Visibility.caps_toward(caps, behavior) :: [URI.t()]` —— 给一个 cap 集派生"指向某 behavior 的具体 target 实例集"(去重、排除 :any 通配)= "我能看到这类的哪些"。纯函数,不碰授权(chokepoint 仍 `Cap.authorize`)。
- 泛化 kanban 私有的 per-board `holds_board_cap?` / caller_caps 过滤,让 workspace/session/kanban 停止各自重造。**A2-1 只建通用函数 + 单测,不迁 4 处 bespoke 消费者**(碰业务层 → Group B)。

## A2 拆分说明
A2 原计划 caps_toward + grantees_of。grantees_of(反向索引:表 + cap-store 写钩 + generation 过滤)是 invariant 敏感重块,拆为 **A2-2**(排到 A4-2 前,与其唯一消费者 :members 一起验证)。本 PR = **A2-1 caps_toward** 单独。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | caps_toward 纯函数:混合 behavior 只挑对的 + 去重 + 排除 :any + MapSet/空集 | met | `cap/visibility_test.exs` 4 test |
| 2 | 零 kanban / 零业务文件（纯 core） | met | git diff 仅 `capability.ex`(未改)+ `cap/visibility.ex` + 测试 |
| 3 | full suite CI 绿 + Loop C | met | CI run 见下(rebase 后重跑) |

**Method friction:** (a) 新 worktree 里 `mix format` 编译慢老超时 → 前两次提交了未格式化文件、CI format 闸红。教训:**push 前必须后台跑完 format + 本地 `format --check-formatted`**(已改流程,A3 起遵守)。(b) 把 `caps_toward` 加进 `Capability` 撞 `oversized_modules` def-count 闸(28→29)→ 改放专属 `Cap.Visibility`。教训:加公共函数别塞进有 def-count 上限的模块,给专属模块。这两条 friction 值得 lead 在 review 提炼成常规检查。

## 分支 + gate 状态
- Branch rebased onto `main` @ (见 commit,rebase 到当前 main)。
- CI:见下方 rebase 后重跑 URL。之前一次 red = `frontend regression gate` 下载 `actions/setup-node` 网络超时(**CI 基础设施 flake,非代码**;同 sha 另 2 run 绿)。
- 本地:visibility 4 单测 + oversized + doc_coverage(20/0)+ format clean。

## Merge request
PR #1596,Group A 独立件(与 A1/A3 并行)。建议 lead 待 CI 绿后并入。

## 遗留 / 开放决策
无 deferred。A2-2 grantees_of + 4 处 bespoke 可见性消费者迁移 = 后续。
