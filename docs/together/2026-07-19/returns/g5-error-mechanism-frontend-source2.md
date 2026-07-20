# G5 error mechanism frontend · source-2 rebase return

> **PR:** https://github.com/ezagent42/ezagent/pull/1450
> **Branch:** `feat/g5-error-mechanism-frontend`
> **returned_at:** 2026-07-19 +0800

## Rebase

- 分支已 rebase 到最新 `origin/main`，包含 #1457 的 per-Kind signing authority
  和 #1456 的 G5 source-2 生产链路。
- rebase 前本地与远程均停在 `3f06e5cff`；rebase 后分支相对 main 为
  `0 behind / 11 ahead`。

## 两类错误来源

- **source-1:** 同步 `last_dispatch_status = "error:..."`，由 #1450 的
  WorldApp 右上角 toast 展示。
- **source-2:** Agent 异步回复中的结构化 `ErrorSignal`。服务端
  `ErrorCards.enrich/3` 生成 per-viewer `messages[].error_card`，React
  `Conversation` 在对应消息气泡内渲染 Layer 1/2/3 卡片，并保留持久化消息正文。

rebase 后 main 的同步 `dispatch_error` 内嵌卡会与 #1450 toast 重复显示；
`main.tsx` 现在只屏蔽传给 Conversation 的同步卡，不会移除
`messages[].error_card`。因此 source-1 只显示 toast，source-2 仍显示消息卡。

## 回归覆盖

新增 `Conversation.error-card.test.tsx`，验证异步 Agent 消息同时呈现：

1. 持久化错误正文；
2. source-2 的结构化错误标题和影响；
3. Layer 2 Founder 提醒按钮；
4. `data-world-message-error-card` 验收标记。
