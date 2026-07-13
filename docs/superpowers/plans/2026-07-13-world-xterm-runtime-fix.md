# World PTY xterm runtime fix plan

**Goal:** Make the World PTY terminal load its own xterm runtime and stylesheet instead of relying on undeclared browser globals.

**Architecture:** Keep `PtyTerminalSurface` behavior unchanged while moving runtime ownership into `@ezagent/world`. Vite resolves and bundles the direct ESM imports and emits the imported xterm CSS with the World assets.

## Task 1: Lock the dependency boundary with a failing test

**Files:**

- Create: `apps/ezagent_plugin_world/test/ezagent/world/pty_terminal_runtime_contract_test.exs`
- Inspect: `apps/ezagent_plugin_world/assets/package.json`
- Inspect: `apps/ezagent_plugin_world/assets/src/components/PtyTerminal.tsx`

Add an ExUnit source contract that asserts package ownership, direct imports, CSS import, and absence of `window.Terminal`, `window.FitAddon`, and the old runtime error. Run the new test and capture its expected failure before implementation.

## Task 2: Give the World bundle direct runtime ownership

**Files:**

- Modify: `apps/ezagent_plugin_world/assets/package.json`
- Modify: `apps/ezagent_plugin_world/assets/pnpm-lock.yaml`
- Modify: `apps/ezagent_plugin_world/assets/package-lock.json`
- Modify: `apps/ezagent_plugin_world/assets/src/components/PtyTerminal.tsx`

Add versions matching the Web package, refresh both tracked lockfiles with the repository package manager policy, import the runtime and stylesheet, instantiate the imported classes, and remove global fallback code. Re-run the contract test for GREEN.

## Task 3: Verify the actual asset and browser behavior

Build the World assets. Inspect emitted JavaScript and CSS for the terminal runtime. Serve a disposable local fixture that mounts the production World bundle without defining xterm globals, then verify in a real browser that `.xterm` exists, the initial buffer is visible, and the old error is absent.

## Task 4: Verify and package the change

Run the focused World tests, frontend checks/build, and `mix precommit`. Review the complete diff and tracked files, ensure no generated assets or credentials are included, then create a Conventional Commit describing the runtime-ownership fix.
