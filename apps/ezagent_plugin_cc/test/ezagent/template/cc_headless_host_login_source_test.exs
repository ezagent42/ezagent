defmodule Ezagent.PluginCc.Template.CcHeadlessHostLoginSourceTest do
  # async: false — mutates the process-GLOBAL `CLAUDE_CONFIG_DIR` env var, which
  # `host_login_dir/0` reads. Isolated from the async cc_headless_agent_test suite.
  use ExUnit.Case, async: false

  alias Ezagent.Agent.CredentialAdapter
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.PluginCc.Template.CcHeadlessAgent

  # #1309 regression. The deterministic blocker behind "@orchestrator never
  # replies": a materialized cc-headless agent booted into an EMPTY config home
  # (401 "Not logged in") because it never inherited the host claude login.
  #
  # Root cause: `CredentialAdapter.host_login_source_dir/1` gates on
  # `function_exported?(mod, :host_login_dir, 0)`. cc-headless delegated the whole
  # credential interface to cc BUT omitted `host_login_dir/0` (an OPTIONAL
  # callback → no compiler warning), so the gate resolved to `:none`, #1209's
  # `HostLoginAdopt.ensure_installer_source` chain silently no-oped, and
  # `.credentials.json` never reached the agent's config dir.
  #
  # This test FAILS on origin/main (source resolves `:none`) and PASSES with the
  # `host_login_dir/0` delegate added — i.e. it is the invariant #1309 violated.
  describe "CredentialAdapter.host_login_source_dir/1 — host-login parity cc vs cc-headless (#1309)" do
    setup do
      host_dir = Path.join(System.tmp_dir!(), "ezagent-1309-host-login-#{System.unique_integer([:positive])}")
      File.mkdir_p!(host_dir)
      # A present secret is REQUIRED for the dir to be a usable source (a host home
      # with no secret is "not logged in" — the gate rejects it).
      File.write!(Path.join(host_dir, ".credentials.json"), ~s({"claudeAiOauth":{"accessToken":"t"}}))

      prev = System.get_env("CLAUDE_CONFIG_DIR")
      System.put_env("CLAUDE_CONFIG_DIR", host_dir)

      on_exit(fn ->
        if prev, do: System.put_env("CLAUDE_CONFIG_DIR", prev), else: System.delete_env("CLAUDE_CONFIG_DIR")
        File.rm_rf!(host_dir)
      end)

      %{host_dir: host_dir}
    end

    test "cc-headless resolves the same USABLE host-login source as cc (no longer :none)", %{
      host_dir: host_dir
    } do
      # Baseline: cc has always worked.
      assert {:ok, ^host_dir} = CredentialAdapter.host_login_source_dir(CcAgent)

      # #1309: cc-headless must now resolve the SAME dir — not `:none`.
      assert {:ok, ^host_dir} = CredentialAdapter.host_login_source_dir(CcHeadlessAgent)

      assert CredentialAdapter.host_login_source_dir(CcHeadlessAgent) ==
               CredentialAdapter.host_login_source_dir(CcAgent)
    end

    test "the source is dropped for BOTH flavors when the host home has no secret", %{
      host_dir: host_dir
    } do
      File.rm!(Path.join(host_dir, ".credentials.json"))

      # Parity in the negative direction too: an unusable host home is `:none` for
      # both — the delegate inherits cc's secret-presence gate, it doesn't bypass it.
      assert CredentialAdapter.host_login_source_dir(CcAgent) == :none
      assert CredentialAdapter.host_login_source_dir(CcHeadlessAgent) == :none
    end
  end
end
