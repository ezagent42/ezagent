defmodule EzagentCore.FrontendCIContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @main_ci_path Path.join(@repo_root, ".github/workflows/ci.yml")
  @frontend_ci_path Path.join(@repo_root, ".github/workflows/frontend-ci.yml")

  test "deterministic gate calls and waits for the reusable frontend workflow" do
    source = File.read!(@main_ci_path)

    assert source =~ "uses: ./.github/workflows/frontend-ci.yml"
    assert source =~ ~r/gate:\s+name: gate \(deterministic\)\s+needs: \[frontend\]/
    assert source =~ "mix world.e2e.fixtures --check"
    refute source =~ "pnpm --dir apps/ezagent_plugin_world/assets test:e2e"
  end

  # 2026-07-20: GitHub Actions billing was exhausted (GitHub-hosted runners
  # refused to start), so every GitHub-hosted job was migrated onto the
  # self-hosted macOS runner. This contract flipped from the ubuntu matrix to
  # the self-hosted mac one accordingly. The validated toolchain (Node 22 /
  # pnpm 10.23.0) stays pinned via setup-node + corepack; Playwright
  # `--with-deps` (Linux/apt-only) is dropped on macOS.
  test "frontend workflow owns the complete regression matrix on the self-hosted mac runner" do
    source = File.read!(@frontend_ci_path)

    for required <- [
          "workflow_call:",
          "workflow_dispatch:",
          "runs-on: [self-hosted, macOS, ARM64]",
          ~s(node-version: "22"),
          "pnpm@10.23.0",
          "apps/ezagent_web/assets",
          "apps/ezagent_plugin_world/assets",
          "apps/ezagent_plugin_hello/assets",
          ~s(pnpm --dir "$assets_dir" lint),
          ~s(pnpm --dir "$assets_dir" typecheck),
          ~s(pnpm --dir "$assets_dir" test),
          "playwright install chromium"
        ] do
      assert source =~ required, "frontend CI lost required contract: #{required}"
    end

    assert source =~
             ~r/^\s*run: pnpm --dir apps\/ezagent_plugin_world\/assets test:e2e\s*$/m

    # The Playwright install command must NOT carry `--with-deps` (Linux/apt-only)
    # on the mac runner. Scoped to the command form so the explanatory comment in
    # the workflow (which names the flag) does not trip this guard.
    refute source =~ "install --with-deps"
  end
end
