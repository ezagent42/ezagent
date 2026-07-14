# hello live E2E + Kanban fusion evidence

Date: 2026-07-14 (Asia/Shanghai)

## Product surface proved

- Public entry: `http://127.0.0.1:10042/hello/fusion`
- Session: `session://demo/hello/fusion`
- Anonymous viewers receive the real public-view page and the stable
  `#hello-prompt-form` entry.
- An anonymous instruction submits through the real CSRF-protected
  `/hello/delegate` form, redirects through login, and resumes exactly once.
- The resumed request created the real canonical Kanban board
  `entity://demo/agent/hello-kanban`, node `n1`, with a normalized
  `hello_source` artifact referring back to the hello session and page URL.
- This is a loose-coupled task copy. It does not claim #1360 Layer B mounting.
- World `styles.css` was not touched.

## Screenshots

1. [Anonymous hello entry](01-anonymous-entry.png) — public page plus the
   anonymous instruction form.
2. [Anonymous task filled](02-anonymous-task.png) — instruction ready for the
   login continuation.
3. [Login continuation](03-login-continuation.png) — real login screen reached
   from the hello form.
4. [Returned hello page](04-delegation-result.png) — continuation returned to
   the public hello product surface after dispatch.

## DeepSeek boundary

The real runtime was started with `HELLO_LLM_BACKEND=deepseek`. The existing
curl-agent `BridgeAdapter` reached `https://api.deepseek.com/chat/completions`
through the local Erlang `:httpc` proxy profile, proving that the prior transport
timeout is resolved. The only local DeepSeek credential in `.env` was rejected
by DeepSeek with HTTP 401 `authentication_error` on 2026-07-14, so a successful
real-model generation/PATCH cannot honestly be claimed from this machine.

No stub, shell-curl response, or fabricated JSON spec is presented as the live
DeepSeek proof. Deterministic tests cover the validated render/PATCH/concierge
contracts while this external credential remains invalid.

## Companion transcript

See [transcript.txt](transcript.txt). Secrets, cookies, CSRF values, browser
tokens, and PATs are intentionally omitted.
