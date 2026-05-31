# Recording a browser demo (GIF/MP4) on this Mac for a PR

**Date:** 2026-05-31 · **Machine:** home / fresh dev Mac (macOS 12.7.6 Monterey) · **Context:** PoC phase-2 customer-chat (`poc/phase-2-customer-service`, PR #446). Demo recording was blocked during the PoC; this note root-causes every failed path and documents the one that works.

> GitHub note: `gh pr comment` **cannot upload images**. To put an image in a PR you must **commit the file** to the repo and reference its raw URL. So we need a committable file artifact (GIF / MP4 / PNG).

---

## TL;DR — use Playwright (browser-native capture)

```bash
# one command; bootstraps Playwright on first run, records, converts to GIF+MP4
DEMO_OUTDIR=docs/assets/demo scripts/demo/record-demo.sh
# -> docs/assets/demo/{demo.gif, demo.mp4, demo.webm, NN-*.png}
git add docs/assets/demo/demo.gif && git commit -m "demo: chat flow gif"
```

Playwright records the **browser's own compositor** (via CDP), so it:
- needs **no macOS Screen Recording (TCC) permission**,
- captures **only the page** (no wallpaper, no other windows, no privacy leakage),
- is **reproducible from the CLI** and drives `http://127.0.0.1:10142` directly.

Everything else on this machine is either broken or blocked (details below).

---

## Comparison of approaches (all tested 2026-05-31)

| # | Approach | Works here? | Committable artifact? | Needs Screen-Rec perm? | Notes |
|---|----------|:-----------:|:---------------------:|:----------------------:|-------|
| 1 | **Playwright** video + screenshots → ffmpeg GIF/MP4 | ✅ **yes** | ✅ webm/gif/mp4/png | ❌ no | **Recommended.** `scripts/demo/record-demo.sh`. Browser-native, reproducible. |
| 2 | `screencapture` **stills** burst → ffmpeg GIF | ⚠️ partial | ✅ png/gif | ✅ yes (see #5) | Works mechanically, but until the permission is *in effect* the frames are **wallpaper + menubar only** (app windows blanked). Whole-screen, not just the browser. |
| 3 | `screencapture -v` **native video** | ❌ fails | — | ✅ yes | `capture error 这项操作无法完成` on every variant — OS video pipeline unavailable until the host app is restarted post-grant. |
| 4 | **ffmpeg avfoundation** screen capture | ❌ broken | — | ✅ yes | Device negotiates pixel format then **hangs forever** (`Configuration of video device failed` / `NSKVONotifying_AVCaptureScreenInput not linked`). This Homebrew ffmpeg build can't grab the screen input. ffmpeg is still fine for **file conversion**. |
| 5 | Chrome `gif_creator` MCP (Claude-in-Chrome ext) | ❌ broken | (would be gif) | ❌ no | **Extension state bug in v1.0.74** — rejects every tab (see root cause). Not fixable from the caller. |
| 6 | `computer` screenshot `save_to_disk:true` | ❌ no local file | ❌ | ❌ no | Image goes **inline to the Claude UI** with an opaque `ss_…` id; **never written to the local working tree**. Can't be committed. |
| 7 | Registry "video-production" / `pr-demo` skills | n/a | — | — | None do **live web-app screen recording** (they're AI-video-gen or asciinema/terminal). Confirmed. |

---

## Root causes (so we don't re-investigate)

### #5 `gif_creator` — "Tab N is not in the MCP tab group" (the headline blocker)
The Claude-in-Chrome extension (v**1.0.74**, id `fcoeoabgfenejglbffodgkkbkcdhcgfn`) gates `gif_creator` like this (decompiled from `assets/mcpPermissions-*.js`):

```js
const n = (await chrome.tabs.get(tabId)).groupId ?? -1;          // tab's LIVE group id
if (ctx.sessionId === LOCAL) {
  let e = ctx.tabGroupId;                                         // expected id from request ctx
  if (e === undefined) e = (await chrome.storage.local.get('mcpTabGroupId')).mcpTabGroupId; // or persisted
  if (n !== e) return { error: "Tab … is not in the MCP tab group…" };
}
```

`tabs_context_mcp` instead calls `getOrCreateMcpTabContext()`, which **discovers/creates the live group dynamically** and returns it (e.g. `670499562`). The two never agree because **`ctx.tabGroupId` and `chrome.storage.local.mcpTabGroupId` are never populated** in this build/session — verified: the extension's `Local Extension Settings` LevelDB `.log` contains **no `mcpTabGroupId` write**. So `e` is `undefined`, `n !== undefined` is always true, and **every tab is rejected**.

Ruled out empirically (each tested and still rejected):
- the `chrome://newtab/` URL (navigated to a real `https://` URL — still rejected),
- the tab not being active/visible,
- a stale group — **destroyed the group and recreated it fresh** (`tabs_close_mcp` → `tabs_context_mcp createIfEmpty`) — still rejected,
- a missing permission — the manifest has `debugger`/`tabs`/`tabGroups`/`offscreen`/`downloads` (gif_creator records via the CDP `debugger`, not `tabCapture`/`desktopCapture`).

**Verdict:** extension-internal desync bug; not caller-fixable. Track an extension update; meanwhile use Playwright. (If a future build is installed, retest — the gate itself is fine once `mcpTabGroupId` is persisted.)

### #6 `computer save_to_disk` — no local file
Call returns `Successfully captured screenshot … ID: ss_57412jmvr` and renders the image **inline** in the conversation. A full-disk search (by id, by recent mtime across `~`, `/tmp`, `/private/tmp`, `/var/folders`, `~/Downloads`) finds **nothing**. The schema's "returns the saved path" refers to a path inside the Claude app sandbox/UI, **not** the agent's working tree. Cannot be used to commit images.

### #3 / #4 — OS-level screen capture is blocked, and the video pipeline is also broken
The decisive evidence: a `screencapture -x` still **succeeds** but the PNG shows only the **desktop wallpaper + menu bar (frontmost app "Claude")** — every application window is **blanked**. That is the exact signature of the capturing process **lacking an in-effect Screen Recording grant**. The permission was granted in System Settings, but **TCC grants only take effect after the granted app is fully quit and relaunched** — the running Claude app still has its pre-grant state. Same cause makes `screencapture -v` error out and (compounded by the broken AVFoundation build) makes ffmpeg hang.

**If you ever need whole-screen OS capture:** fully **quit and reopen the Claude app** after granting Screen Recording, then re-test `screencapture -x out.png`; the app windows should appear. Even then, prefer Playwright for browser demos (page-only, no privacy leak, reproducible). `screencapture -v` and ffmpeg-avfoundation remain unreliable on this box.

---

## Recommended workflow (details)

### A. Auto-drive the cinnox chat flow (fully scripted)
1. Start the PoC server (see `CLAUDE.local.md` → "poc-phase2 服务器"); confirm `http://127.0.0.1:10142` is up.
2. Record + convert in one go:
   ```bash
   cd ~/workspace/ezagent42/ezagent
   DEMO_OUTDIR=docs/assets/demo scripts/demo/record-demo.sh
   ```
   Defaults: `DEMO_URL=http://127.0.0.1:10142/chat/cinnox`, `DEMO_QUESTION="CINNOX 是做什么的?"`, waits up to 60s for the AI reply (`DEMO_REPLY_TIMEOUT_MS`), screenshots each beat.
3. Commit `docs/assets/demo/demo.gif` (or `demo.mp4`) and reference it in the PR body:
   ```markdown
   ![demo](https://raw.githubusercontent.com/<org>/<repo>/<branch>/docs/assets/demo/demo.gif)
   ```

If selectors differ from the defaults, edit the locators in `scripts/demo/record-demo.js` (it already falls back across `textarea / input / [contenteditable] / [role=textbox]` and Send-button vs Enter).

### B. Pages behind `/login` (operator console, soul-config) — auto-login built in
`/operator/*` and `/plugins/*` require auth. Set `DEMO_LOGIN=1` and the recorder logs in first
**in a throwaway context** (so the login screen is NOT in the video), then records the target:
```bash
# operator console (verified working)
DEMO_LOGIN=1 DEMO_URL=http://127.0.0.1:10142/operator/cinnox DEMO_SECONDS=15 \
  DEMO_OUTDIR=docs/assets/demo-operator scripts/demo/record-demo.sh
# soul config editor
DEMO_LOGIN=1 DEMO_URL=http://127.0.0.1:10142/plugins/customer-chat/cinnox/config DEMO_SECONDS=20 \
  DEMO_OUTDIR=docs/assets/demo-soul scripts/demo/record-demo.sh
```
Login env: `DEMO_USER` (default `entity://user/system/admin`), `DEMO_PASS` (default `ezagent-dev`),
`DEMO_LOGIN_URL` (default `<origin>/login`).

> ⚠️ **Gotcha:** the bare handle `admin` is **rejected** by `/login` on this build (the form just
> re-renders); you must use the **full URI `entity://user/system/admin`** — which is the recorder's
> default. (Verified via curl: `entity_uri=admin` → HTTP 200 stay-on-login; `entity://user/system/admin`
> → HTTP 302 → `/sessions`.)

Add `DEMO_HEADED=1` to any of the above to pop a real Chromium window and perform the steps by hand
(still browser-native, still no Screen-Recording permission) — login is already done for you.

### B2. Passive timed capture (no login)
```bash
DEMO_URL=http://127.0.0.1:10142/chat/cinnox DEMO_SECONDS=15 \
  DEMO_OUTDIR=docs/assets/demo-x scripts/demo/record-demo.sh
```

### Manual one-liners (if you don't want the wrapper)
```bash
# record (after `npm i playwright && npx playwright install chromium` in some dir)
node scripts/demo/record-demo.js
# webm -> high-quality gif
ffmpeg -y -i demo.webm -vf "fps=12,scale=720:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" demo.gif
# webm -> mp4 (h264, browser/PR friendly)
ffmpeg -y -i demo.webm -movflags +faststart -pix_fmt yuv420p demo.mp4
```

### Fallback: still-burst → GIF (only if Playwright is unavailable AND perm is in effect)
Quit/reopen the Claude app first so the Screen Recording grant takes effect, then:
```bash
mkdir -p /tmp/frames
for i in $(seq -w 1 12); do screencapture -x -t png /tmp/frames/f$i.png; sleep 0.3; done
ffmpeg -y -framerate 4 -pattern_type glob -i '/tmp/frames/f*.png' \
  -vf "scale=960:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" demo.gif
```
Captures the whole screen (other windows included) — last resort only.

---

## Machine facts (verified)
- `ffmpeg` 7.1.1 `/usr/local/bin/ffmpeg` — great for **conversion**, **broken** for avfoundation screen capture.
- `screencapture` `/usr/sbin/screencapture` — stills ok (subject to perm), `-v` video fails.
- `node` v24.4.1 (nvm), `npx` ok; Playwright not preinstalled (the wrapper installs it into `~/.cache/ezagent-demo-record`).
- No `gifski` / ImageMagick.
- Claude-in-Chrome extension v1.0.74 (older 1.0.70 also on disk).

## Deliverables added
- `scripts/demo/record-demo.js` — Playwright recorder (auto-drive cinnox chat, or timed passive).
- `scripts/demo/record-demo.sh` — self-bootstrapping wrapper → GIF + MP4 + PNGs.
- this note.
