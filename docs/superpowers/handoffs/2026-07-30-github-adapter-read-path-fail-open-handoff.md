# GitHub adapter 读路径 fail-open — 交接

**来源**：Forgejo Provider V1（PR #1643）第四轮对抗性 review。审 Forgejo 读路径时发现
GitHub adapter 有**同族且更严重**的缺陷。属另一 owner 的代码，当时未改。

**gaga 2026-07-30 决定**：计一笔，Forgejo PR 处理完就接着做。

---

## 缺陷

`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`

```elixir
defp map_review_state(state) when is_binary(state) do
  case String.upcase(state) do
    "APPROVED" -> :approved
    "CHANGES_REQUESTED" -> :changes_requested
    "COMMENTED" -> :commented
    "DISMISSED" -> :dismissed
    _ -> :commented              # ← 未知 state 编造成"评论"
  end
end

defp map_review_state(_), do: :commented   # ← 字段缺失/非字符串 同样编造

defp map_check_status(_), do: :completed          # ← 未知状态编造成"已完成"
defp map_check_conclusion(_), do: :other
```

### 为什么这比"静默丢弃"更危险

Forgejo 侧原本是丢弃（已修）。丢弃至少让**计数变少**，可能被察觉。

**编造成 `:commented` 则把一条 `CHANGES_REQUESTED` 变成"有人评论了、无阻塞"** —— 上层
`observation_summary` 按标签计数，得到的事实是"1 条评论"，人类明确要求修改的事件不仅
消失，还被替换成一个无害的事件。

`map_check_status(_) -> :completed` 同理：一个仍在运行的 check 若状态字符串是未知值，
会被报成"已完成"，配合 `map_check_conclusion(_) -> :other` 读起来就是"跑完了、结论未知"，
而不是"还在跑"。

### 具体失败场景

provider 返回一条 `APPROVED`（正常）+ 一条 `CHANGES_REQUESTED` 但 `state` 字段因版本
漂移改名或缺失 → adapter 输出 `[:approved, :commented]` → 上层记为
`2 reviews: approved=1 commented=1` → 任何据此推进的自动化都会在人类明确反对的情况下
放行。

---

## Forgejo 侧已确立的修法（可直接照搬）

见 PR #1643 的 `normalize.ex`。核心是**把三件事分开**：

| 情形 | 正确答案 | 理由 |
|---|---|---|
| 有意过滤（`REQUEST_REVIEW` / `PENDING`） | `{:ok, []}` | 它们不是已提交的 review |
| 未知**值**（`state: "TELEPORTED"`） | 拒绝整次读取 | 不猜相邻状态，也不静默丢 |
| 形状不对（字段缺失 / 非字符串） | 拒绝整次读取 | "找不到状态" ≠ "状态我们没映射" |

关键区分：`:other` 的意思是"**这个状态我们没有映射**"，不是"**我们找不到状态**"。前者
是诚实汇报，后者是解析失败，必须拒绝。

同一原则也适用于 checks：Forgejo 侧要求 `status` 字段必须是 binary，缺失即拒绝（因为
`CommitStatus.status` 与 `CombinedStatus.state` 是同一 Go 类型的两个 JSON 名 —— 正是
版本升级最可能改名的那类字段）。

---

## 范围建议

1. `map_review_state/1` — 未知值与形状不对都改为让 `list_reviews/3` 整体失败
2. `map_check_status/1` — `_ -> :completed` 是编造，未知状态应拒绝
3. `map_check_conclusion/1` — 未知**值**保留 `:other` 是对的；但要确认 `nil` 与"字段
   缺失"是否被正确区分
4. 检查 GitHub 侧是否有同族的"catch-all 返回空结果"（Forgejo 侧的 `checks(%{})` 就是
   这样：缺 `statuses` 键被伪造成"没有 checks"）

**同时必查测试**：Forgejo 侧有两条测试**把 fail-open 钉死了**（断言未知 state 返回
`{:ok, []}`），测试名还叫 "dropped rather than guessed"。GitHub 侧很可能有对应的测试
在钉 `:commented`，修实现前要先确认测试断言的是哪一边。

---

## 上下文：为什么 review 契约不受影响

同一轮裁决确认 **DomainGit `Review` 是历史事件流**（不是当前有效 gate），所以
`official`/`stale` 这类"是否计入批准数"的字段不读是正确的。

本交接的缺陷与那条裁决**无关** —— 它不是"少读了字段"，而是**把读不懂的东西编造成一个
具体的、无害的状态**。历史事件流的契约同样要求汇报的事件是真实发生过的。

---

## 验证方式

照 Forgejo 侧：先写会失败的测试（混合列表 —— 一条正常 + 一条形状不对），确认它红；
修实现；再变异验证（把修复改回去，确认测试变红）。

GitHub 侧有 live E2E（`apps/ezagent_plugin_git_workflow/test/e2e/github_live_*.exs`），
但注意它需要 GitHub App 凭证。
