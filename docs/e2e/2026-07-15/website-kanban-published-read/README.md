# Website Hello → Kanban published-read browser proof

This companion records the real browser path added by PR #1425:

1. An anonymous visitor opens `/hello/fusion` and enters a task through the
   website's Hello product entry.
2. The login continuation resumes the original request after authentication.
3. Hello creates a real task on the canonical Kanban board and renders an
   explicit publication receipt: the source board URI, node id, revision `r1`,
   and the boundary “访客接收后只读；修改仍由原 Kanban 管理”.
4. The signed receive reference is claimed by a second session. World confirms
   “看板已加入你的工作区（只读）” and exposes that session's Kanban tab.

Evidence:

- `hello-kanban-published-read.webm` — complete browser recording.
- `01-hello-product-entry.png` — public website product entry and delegation.
- `02-published-read-receipt.png` — Hello publication receipt (`r1`).
- `03-session2-readonly-received.png` — Session 2 readonly receipt and Kanban tab.
- `transcript.txt` — redacted step transcript and machine-checked companion.

The browser recording does not display credentials, the one-time PAT, the
signed board token, a signing seed, or a provider key. The PAT delivery HTML is
redacted before Chromium renders it, and the signed receive URL is navigated
programmatically so it is not exposed in the captured browser chrome.

Authorization is not inferred from UI decoration. The integration companion
`apps/ezagent_web/test/ezagent_web/controllers/socialware/kanban_share_controller_test.exs`
asserts that Session 2 can `get_tree`, cannot `add_node`, and repeated receipt
converges to one Mount row for the same board URI.

