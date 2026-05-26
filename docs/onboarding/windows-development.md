# Developing ezagent on Windows

**TL;DR**: native Windows works for code reading, docs/review, and `mix format` (after a one-time MinGW install). It **does not** work for `mix test`, `mix phx.server`, or actually running cc-agents. For those, use **WSL2** (primary), a **VS Code Dev Container**, or a Linux/macOS box directly.

The blocker is `erlexec`, a POSIX-only Erlang library (uses `fork()` / `ptrace()` / SIGCHLD). It powers every subprocess in the system — PTY for cc-agent, Python sidecar, OS-process management. There's no port to Windows because the Windows kernel doesn't expose those APIs.

---

## What works on native Windows

After installing the toolchain below:

| Action | Status |
|---|---|
| Read / edit code in your IDE | ✓ |
| Commit docs / config / shell / JSON / YAML | ✓ (sub-step gate auto-skips non-Elixir) |
| `mix deps.get` | ✓ |
| `mix format --check-formatted` | ✓ |
| `mix compile` (partial — Elixir code only) | ✓ |
| Commit Elixir changes through the gate | ⚠️ format check passes, but `mix test` is part of the gate and won't start |
| `mix test` | ✗ erlexec port can't be built or started |
| `mix phx.server` / actual runtime | ✗ same reason |
| Run cc-agent / Python sidecar / PTY | ✗ same reason |

---

## Recommended setup

### Option 1 — WSL2 (recommended)

The smoothest path. Real Linux kernel, real `fork`, full ezagent functionality.

```powershell
# In an elevated PowerShell, one-time:
wsl --install -d Ubuntu

# Inside Ubuntu:
sudo apt update && sudo apt install -y build-essential erlang elixir git
git clone <ezagent-repo-url>
cd ezagent
mix deps.get
mix test    # should pass
```

VS Code's **WSL extension** gives you a native-feeling editor against the Linux filesystem. Keep the repo inside the WSL filesystem (e.g. `/home/<you>/ezagent`), not under `/mnt/c/...` — Linux NTFS performance is terrible for `mix deps.get`.

### Option 2 — Dev Container

If you have Docker Desktop, VS Code + Dev Containers extension can spin up an Elixir container automatically. The repo doesn't ship a `.devcontainer/` config yet — if you'd like one, contribute it (small JSON file).

### Option 3 — Native Linux / macOS

If you have a Linux or Mac box available, that's the lowest-friction path. The project's primary dev environment.

---

## Native Windows partial setup (docs / format / review)

Useful for: writing markdown docs, reviewing PRs, editing Elixir without running it, regenerating Excalidraw / Mermaid diagrams.

### 1. Install Erlang + Elixir

Either method works:

- **Chocolatey** (needs admin): `choco install elixir erlang`
- **Direct download**: erlang.org → Erlang/OTP installer, then elixir-lang.org → Windows installer

Verify:

```bash
erl -version
mix --version
```

### 2. Install MinGW-w64 GCC (no admin needed)

Several deps build C/C++ NIFs during `mix deps.get` — `bcrypt_elixir`, `exqlite`, `fine`. Their Makefiles call `cc` literally and need a Unix-style toolchain. The cleanest user-level install is via **winget**:

```bash
winget install --id=BrechtSanders.WinLibs.POSIX.UCRT --scope user --accept-source-agreements --accept-package-agreements
```

This puts gcc at `%LOCALAPPDATA%\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_..._x86_64\mingw64\bin\` and adds it to your User PATH.

**Alias `gcc.exe` as `cc.exe`** (the Makefiles call `cc`, not `gcc`):

```bash
WINLIBS_BIN="/c/Users/$USER/AppData/Local/Microsoft/WinGet/Packages/BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe/mingw64/bin"
cp "$WINLIBS_BIN/gcc.exe" "$WINLIBS_BIN/cc.exe"
```

If you're in Git Bash and the change isn't picked up, add it to `~/.bashrc`:

```bash
WINLIBS_BIN="/c/Users/$USER/AppData/Local/Microsoft/WinGet/Packages/BrechtSanders.WinLibs.POSIX.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe/mingw64/bin"
[ -d "$WINLIBS_BIN" ] && export PATH="$WINLIBS_BIN:$PATH"
```

Verify:

```bash
which cc gcc
cc --version    # should report MinGW-W64 x86_64-ucrt-posix
```

### 3. Install deps + verify format

```bash
cd /path/to/ezagent
mix deps.get                       # downloads + compiles NIFs (bcrypt_elixir et al.)
mix format --check-formatted       # should exit 0
```

### 4. What about the sub-step gate?

The pre-commit gate ([scripts/hooks/sub-step-gate.sh](../../scripts/hooks/sub-step-gate.sh)) runs three checks: `mix format`, `mix test`, `mix ezagent.check_invariants`. On Windows:

- `mix format` works after the MinGW install above
- `mix test` fails at `erlexec` app startup — no fix on native Windows
- `mix ezagent.check_invariants` should work, but **currently has 8 stale `apps/ezagent_core/lib/esr/...` paths from a pre-rename era** that cause `grep: no such file` errors. Tracked as a follow-up; fix when convenient.

The gate auto-skips when no `.ex/.exs/.heex` files are staged, so docs / shell / JSON / YAML / Dockerfile / lockfile commits go through cleanly. For Elixir commits on Windows, you'll need to either:

- Develop the change in WSL2 (recommended)
- Make the change on Windows, then run the gate in WSL2 before pushing

---

## FAQ

### Can erlexec be ported to Windows?

No, not in any practical sense. It's fundamentally about Unix process model semantics. A "Windows version" would need to be a rewrite using `CreateProcess` + Job Objects + Pseudo Console (ConPTY), with completely different semantics for things like `:exec.send/2`, signal forwarding, and process group management. ezagent uses enough of erlexec's PTY-specific features (PTY size, send-to-stdin, fork-from-parent) that a thin shim wouldn't suffice.

### Can I just stub erlexec on Windows?

In principle yes — write a fake `exec` module that returns no-op results — but you'd lose all the things the gate is designed to catch (PtyServer-related regressions, Python sidecar lifecycle, OS-process leak tests). You'd be running "tests" that don't exercise the parts of the system that actually need testing. Not recommended for any real contribution work.

### Why doesn't ezagent declare Linux/macOS as a requirement?

Historical: when the project started, no NIF deps were in the tree. The first NIF arrived around 2026-05-20 with the auth backend (`bcrypt_elixir`), and `erlexec` followed for the PTY/Python work. Pre-existing Windows contributors had a smoother experience that no one explicitly removed. This doc is the catch-up.

### My CI passes — does CI run on Windows?

The repo currently has **no `.github/workflows/`** — there is no CI. The sub-step gate (locally) and code review (manually) are the only mechanical checks. WSL2 / Linux / macOS dev environments run the gate cleanly; native Windows can run the format step only.
