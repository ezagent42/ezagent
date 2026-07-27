# hello live E2E + Kanban fusion evidence

Date: 2026-07-14 (Asia/Shanghai)

## Product surface proved

- Public entry: `http://127.0.0.1:10042/hello/fusion`
- Session: `session://system/hello/fusion` (the current
  `:ezagent_web, :hello_workspace` short-link configuration).
- The short-link uses the external Surface feed, so it renders the committed
  JSON-render product page rather than the chat-only message projection.
- The real browser found `#hello-product-entry`, `#hello-task-cta`,
  `#hello-coupling-boundary`, and the single `#hello-prompt-form` composer.
- An anonymous instruction submits through the real CSRF-protected
  `/hello/delegate` form, redirects through password login and the PAT delivery
  page, then resumes exactly once.
- The resumed request created the canonical Kanban board
  `entity://system/agent/hello-kanban`, node `n1`, with status `unassigned` and a
  normalized `hello_source` artifact referring back to the Hello session.
- The Hello receipt projects the real status as `待派` and links to the real
  World Kanban product page containing the same node.
- This remains a loose-coupled task reference/copy. It does not claim #1360
  Layer B mounting, and Hello does not become a second Kanban data owner.
- World `styles.css` was not touched.

## Screenshots

1. [Recording-ready product entry](01-anonymous-entry.png) — the real website
   Surface, Hello product card, primary CTA, coupling boundary, and persistent
   composer.
2. [Anonymous task filled](02-anonymous-task.png) — the instruction is ready for
   the login continuation.
3. [Login continuation](03-login-continuation.png) — the real password login
   screen reached from the Hello form.
4. [Truthful delegation receipt](04-delegation-result.png) — authenticated return
   to Hello with the real board URI, node id, task title, `待派`, and Kanban link.
5. [Real Kanban node](05-kanban-node.png) — World Kanban showing node `n1`, raw
   `unassigned` status, and its Hello source artifact.

The evidence browser used a user-installed Noto CJK font so Chinese copy is
legible. No repository font or World stylesheet was changed for the screenshots.

## DeepSeek boundary

The runtime was started with `HELLO_LLM_BACKEND=deepseek`. The existing curl-agent
`BridgeAdapter` reaches `https://api.deepseek.com/chat/completions` through the
local Erlang `:httpc` proxy profile. The only local DeepSeek credential in `.env`
is rejected by DeepSeek with HTTP 401 `authentication_error`, so a successful
real-model generation/PATCH is not claimed from this machine.

No stub, shell-curl response, or fabricated JSON spec is presented as the live
DeepSeek proof. Deterministic tests cover `Spec.validate`, render/PATCH,
concierge read-only, catalog parity, continuation, and Kanban delegation. The
recording-ready entry/continuation/Kanban product flow above is fully live.

## Companion transcript

See [transcript.txt](transcript.txt). Secrets, PAT values, cookies, CSRF values,
and browser tokens are intentionally omitted.
