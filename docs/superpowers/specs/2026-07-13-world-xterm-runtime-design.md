# World PTY xterm runtime design

## Problem

The World React bundle renders `PtyTerminalSurface`, but the component only declares and reads `window.Terminal` and `window.FitAddon`. The host Web bundle imports xterm as ESM-local bindings and never publishes those constructors on `window`. Consequently the World component stops before constructing the terminal and displays `xterm runtime is not loaded.`.

The PTY server and event bridge are healthy; this repair is limited to frontend runtime ownership.

## Design

The World asset package will own every runtime dependency used by its terminal surface:

- add `xterm` and `xterm-addon-fit` to the World package dependencies, matching the versions already used by the Web assets;
- import `Terminal`, `FitAddon`, and `xterm/css/xterm.css` directly in `PtyTerminal.tsx`;
- remove the optional `window` declarations, runtime guard, and hand-written structural xterm types;
- retain the existing PTY input, resize, initial-buffer, server-event, and cleanup behavior.

This keeps the dynamically loaded World bundle self-contained and avoids a load-order contract with the host bundle.

## Verification and acceptance

The change is accepted when all of the following hold:

1. A regression test proves that the World package declares both dependencies, imports both constructors and the stylesheet, and no longer reads the xterm constructors from `window`.
2. The regression test is observed failing before the implementation and passing afterward.
3. The World Vite production build completes and emits xterm JavaScript and CSS.
4. A browser mounts a PTY World surface with no xterm global variables, shows an `.xterm` terminal, and renders an initial buffer without the previous error message.
5. Related World tests and `mix precommit` complete, or any unrelated pre-existing failures are recorded precisely.

No Canary deployment or configuration change is part of this repair. Deployment validation requires separate authorization.
