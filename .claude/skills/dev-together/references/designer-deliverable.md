# Designer / non-code deliverable → PR

How a **non-code** deliverable (design demo, clickable prototype, mockups,
design doc, UX audit) enters the dev-together flow. Designers return work as
PRs like everyone else — but the machine-return-gate (green CI + rebase, see
[`return`](../commands/return.md)) does **not** apply, because there is nothing
for CI to compile/test. This is the substitute gate.

## Rules

1. **Never commit the raw archive.** If the work arrives as a `.zip`/`.tar`,
   **unpack it** and commit the actual files (HTML / images / PDF / CSS). A zip
   is an opaque blob — it can't be diffed, previewed, or reviewed.

2. **Place by type:**
   - **Product-design demo / prototype / mockups** → the demo's home in the app
     repo (e.g. `docs/website-demo/`). Overlay onto the existing location;
     don't fork a divergent copy.
   - **Reusable brand / design-system assets** (logos, tokens, component specs)
     → the separate `ezagent42/design-system` (`ezagent-design`) repo via its
     own PR + `design-sync`, **not** the app repo.

3. **Always add a dev-together return** at
   `docs/together/<date>/returns/<designer>-<topic>.md` so the deliverable is
   review-readable and becomes the designer's `latest_return`. It MUST:
   - say **what it demonstrates** and **how to view** it (e.g. "open
     `index-gallery.html`");
   - **embed screenshots** so a reviewer sees it without running it. Render
     static HTML to PNG with headless Chrome, e.g.:
     ```
     "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
       --headless=new --disable-gpu --hide-scrollbars --window-size=1440,1600 \
       --screenshot=<out>.png "file://<abs-path>/<page>.html"
     ```
     Commit the PNGs beside the return (`returns/<designer>-<topic>/*.png`);
   - give the **design rationale** + the **weekly goal** it serves + next steps.

4. **Keep binaries lean.** Screenshots as reasonably-sized PNG; interactive demo
   as HTML/CSS/JS. **Large binaries (video / huge images) do NOT go in the app
   repo** — put them in `ezagent-design` or link externally, and note it.

5. **Substitute gate (in place of green CI):** the demo **opens / renders
   correctly**, screenshots are embedded in the return, and the files are in the
   right home. That is the "gates green" for a non-code return.

6. **Attribution when the coordinator opens it on the designer's behalf**
   (designer handed over an archive rather than a PR): `Co-Authored-By:` the
   designer on the commit, the return doc `authored-by` them, and the PR body
   names them as the author. The designer can also open the PR themselves.

## Worked example

`#1372` — 陈瑞华 (ruihua) 官网飞轮 demo: archive unpacked → placed in
`docs/website-demo/` (new `index-gallery.html` + README) → return at
`docs/together/2026-07-13/returns/ruihua-flywheel-demo.md` with three embedded
screenshots rendered from the static HTML → merged docs-only. Follow that shape.
