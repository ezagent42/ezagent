defmodule Ezagent.PluginCc.Template.CcHeadlessCliIdentityTest do
  @moduledoc """
  Task A (#1323 落 main, handoff 2026-07-16 gaga-agent-runtime §3) — the
  cc-headless sidecar's process env must carry the SAME CLI-identity credential
  a PTY role-agent gets (`SpawnPlan.maybe_put_cli_identity_env/3`, Phase 3 ③
  T7d), or a headless role-agent (e.g. the kanban-assistant) cannot drive the
  ezagent CLI as itself: its recipe operates the board via
  `scripts/kanban-cli.sh` (Bash + `EZAGENT_USER_TOKEN` dispatch — the recipe
  explicitly says there are NO MCP kanban tools), so without this env every
  board action fails CLOSED ("CLI calls require authentication").

  Pins the seam at `CcHeadlessAgent.sdk_sidecar_params/2 → :cmd_env`, which the
  sidecar exports as `EZAGENT_CC_SDK_ENV` and the Python worker applies as the
  Claude Code SDK subprocess `env=` — inherited by every Bash tool child.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcHeadlessAgent

  defp uniq, do: System.unique_integer([:positive])

  defp agent_uri do
    uri = Ezagent.URI.agent("team-alpha", "kanban-assistant-#{uniq()}")
    _authority = install_test_authority!(uri, :agent)
    uri
  end

  defp tmpl(role) do
    base = %{"class" => "cc_headless.agent", "cwd" => System.tmp_dir!()}

    case role do
      :__omit__ -> base
      r -> Map.put(base, "role", r)
    end
  end

  describe "sdk_sidecar_params/2 — role-agent cmd_env carries the CLI bearer token" do
    test "role template injects EZAGENT_USER_TOKEN that resolves as the agent" do
      uri = agent_uri()

      params = CcHeadlessAgent.sdk_sidecar_params(uri, tmpl("kanban-assistant"))

      token = params.cmd_env["EZAGENT_USER_TOKEN"]
      assert is_binary(token) and token != ""

      # Resolves through the SAME authentication path the CLI uses, AS the agent.
      assert {:ok, ^uri} = Ezagent.Authentication.authenticate(token)
    end

    test "role-less template gets no CLI token (provider env only, no change)" do
      params = CcHeadlessAgent.sdk_sidecar_params(agent_uri(), tmpl(:__omit__))

      refute Map.has_key?(params.cmd_env, "EZAGENT_USER_TOKEN")
    end
  end
end
