# Hello live E2E + Kanban fusion proof

This directory records the 2026-07-15 product-surface proof for the Hello live
loop and the existing Hello-to-Kanban delegation contract. The run used the
real `deepseek` provider with model `deepseek-chat`; it did not use a model
stub. Credentials and the single-use login token are intentionally omitted.

## Proven journey

1. An authenticated visitor opened `/hello/fusion-live-0715` and asked Hello
   to generate a coffee-shop landing page.
2. The live curl-LLM member called DeepSeek and returned a json-render spec.
   `EzagentPluginHello.Spec.validate/1` accepted the exported live spec.
3. The customer renderer displayed the generated 152-node page.
4. A second prompt edited the existing surface: `Brew & Bean` became
   `山岚咖啡`, and `立即预订` became `预约座位`. The surface hash changed while
   the node count remained 152.
5. Concierge answered the Sunday-hours question from the current page. The
   persisted answer was `周日营业时间为9:00 - 18:00。`; the surface hash did
   not change.
6. A fresh anonymous browser could see the same public 152-node surface and
   was offered login, rather than anonymous Kanban mutation authority.
7. The authenticated Hello delegation created a real Kanban node and returned
   a bounded receipt. The matching node was then opened in World Kanban.
8. The backend catalog contained exactly 36 components. All 13 component types
   used by the live spec belong to that catalog.

This is the planned loose-coupling increment. Cross-session sharing,
bidirectional synchronization, Hello-side task editing, and #1360 Layer B are
not claimed here.

## Evidence index

- `01-deepseek-generated-page.png` — first live DeepSeek-generated page.
- `02-deepseek-patch-page.png` — existing page after the second prompt/edit.
- `03-concierge-read-only.png` — page after the concierge turn; transcript
  records the persisted answer and unchanged hash.
- `04-anonymous-public-view.png` — logged-out visitor sees the public page and
  a login-gated Kanban action.
- `05-kanban-receipt.png` — Hello receipt for real node `n7`, state `待派`.
- `06-world-kanban-node.png` — the same task selected on the World board.
- `hello-live-deepseek-kanban.webm` — 31.44-second, 1440x900, 25 fps product
  walkthrough. The one-time login token region is visually blurred.
- `transcript.txt` — timestamps, prompts, hashes, validation, read-only check,
  anonymous result, catalog result, and delegation identifiers.

## Stable identifiers

- Session route: `/hello/fusion-live-0715`
- LLM member: `entity://system/agent/fa5dbfe7-2f7c-4710-bb23-e3e0522eb805`
- Kanban board: `entity://system/agent/hello-kanban`
- Kanban node: `n7`

No API key or login token is stored in this directory.
