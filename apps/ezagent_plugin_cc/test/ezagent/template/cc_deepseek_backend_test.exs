defmodule Ezagent.PluginCc.Template.CcDeepseekBackendTest do
  @moduledoc """
  DeepSeek backend for the cc flavor (provider dimension) — pty + headless.

  Covers: the 8-var DeepSeek env block (key from `DEEPSEEK_API_KEY`), the
  provider dimension does NOT leak into the default anthropic cc path, both
  flavors are registered for both transports, the API-key credential contract
  (no OAuth / no host-login), the fail-fast launchability gate, and that the
  deepseek flavor identity survives a cold restart (respawn data → resolver).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Provider

  alias Ezagent.PluginCc.Template.{
    CcAgent,
    CcDeepseekAgent,
    CcHeadlessAgent,
    CcHeadlessDeepseekAgent
  }

  @key "sk-deepseek-test-abc123"

  setup do
    prev = System.get_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if prev,
        do: System.put_env("DEEPSEEK_API_KEY", prev),
        else: System.delete_env("DEEPSEEK_API_KEY")
    end)

    :ok
  end

  defp with_key, do: System.put_env("DEEPSEEK_API_KEY", @key)
  defp without_key, do: System.delete_env("DEEPSEEK_API_KEY")

  # ── Provider: profile env assembly + fail-closed contract ───────────────

  describe "Provider.profile_env/1 + provider_env/1" do
    test "deepseek profile assembles the documented 8-var block, token from its env var" do
      with_key()

      assert {:ok, env} = Provider.profile_env("deepseek")

      assert env == %{
               "ANTHROPIC_BASE_URL" => "https://api.deepseek.com/anthropic",
               "ANTHROPIC_AUTH_TOKEN" => @key,
               "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
               "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
               "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
               "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
               "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
               "CLAUDE_CODE_EFFORT_LEVEL" => "max"
             }
    end

    test "kimi profile assembles the documented 9-var block" do
      System.put_env("MOONSHOT_API_KEY", "sk-kimi-test-xyz")
      on_exit(fn -> System.delete_env("MOONSHOT_API_KEY") end)

      assert {:ok, env} = Provider.profile_env("kimi")
      assert map_size(env) == 9
      assert env["ANTHROPIC_BASE_URL"] == "https://api.moonshot.ai/anthropic"
      assert env["ANTHROPIC_AUTH_TOKEN"] == "sk-kimi-test-xyz"
      assert env["ANTHROPIC_MODEL"] == "kimi-k3"
      assert env["ENABLE_TOOL_SEARCH"] == "false"
      assert env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "1048576"
    end

    test "missing key → {:error, {:backend_api_key_missing, profile}}" do
      without_key()
      assert Provider.profile_env("deepseek") == {:error, {:backend_api_key_missing, "deepseek"}}
    end

    test "unknown profile → {:error, {:unknown_backend_profile, name}} (fail closed)" do
      assert Provider.profile_env("bogus") == {:error, {:unknown_backend_profile, "bogus"}}
    end

    test "provider_env/1: no key → {:ok, %{}}; explicit anthropic → {:ok, %{}}" do
      with_key()
      assert Provider.provider_env(%{}) == {:ok, %{}}
      assert Provider.provider_env(%{"provider" => "anthropic"}) == {:ok, %{}}
    end

    test "provider_env/1: known profile → block; unknown → fail closed (NEVER silent anthropic)" do
      with_key()
      assert {:ok, env} = Provider.provider_env(%{"provider" => "deepseek"})
      assert env["ANTHROPIC_AUTH_TOKEN"] == @key

      assert {:error, {:unknown_backend_profile, "bogus"}} =
               Provider.provider_env(%{"provider" => "bogus"})
    end

    test "ensure_api_key/2 gates on the profile's own env var" do
      without_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_x")

      assert {:error, {:backend_api_key_missing, "deepseek", ^uri}} =
               Provider.ensure_api_key("deepseek", uri)

      with_key()
      assert Provider.ensure_api_key("deepseek", uri) == :ok
    end

    test "credential_status/1 is per-profile; nil/unknown → :unknown (never an alarm)" do
      with_key()
      assert %{status: :authenticated} = Provider.credential_status("deepseek")
      without_key()
      assert %{status: :missing, detail: detail} = Provider.credential_status("deepseek")
      assert detail =~ "DEEPSEEK_API_KEY"
      assert %{status: :unknown} = Provider.credential_status(nil)
      assert %{status: :unknown} = Provider.credential_status("bogus")
    end
  end

  # ── Flavor registration (both transports) ───────────────────────────────

  describe "agent_flavors/0" do
    test "declares cc-deepseek (pty) + cc-headless-deepseek (headless)" do
      by = Map.new(EzagentPluginCc.Application.agent_flavors(), &{&1.flavor, &1})

      assert %{kind: Ezagent.Entity.Agent, template_class: CcDeepseekAgent} = by["cc-deepseek"]

      assert %{kind: Ezagent.Entity.Agent, template_class: CcHeadlessDeepseekAgent} =
               by["cc-headless-deepseek"]

      # headless reuses the cc-headless behavior set (unique reply action)
      assert is_function(by["cc-headless-deepseek"].instance_behaviors, 0)
    end

    test "the registry resolves each deepseek flavor → its template class" do
      assert {:ok, %{template_class: CcDeepseekAgent}} =
               Ezagent.AgentFlavorRegistry.lookup("cc-deepseek")

      assert {:ok, %{template_class: CcHeadlessDeepseekAgent}} =
               Ezagent.AgentFlavorRegistry.lookup("cc-headless-deepseek")
    end
  end

  describe "template metadata" do
    test "distinct class names + reuse cc/cc-headless config_dir namespaces" do
      assert CcDeepseekAgent.template_name() == "cc_deepseek.agent"
      assert CcHeadlessDeepseekAgent.template_name() == "cc_headless_deepseek.agent"
      assert CcDeepseekAgent.config_dir_namespace() == CcAgent.config_dir_namespace()

      assert CcHeadlessDeepseekAgent.config_dir_namespace() ==
               CcHeadlessAgent.config_dir_namespace()
    end

    test "template_data_extra bakes provider=deepseek and preserves cc fields" do
      data = CcDeepseekAgent.template_data_extra(%{model: "x", effort: "high"})
      assert data["provider"] == "deepseek"
      assert data["model"] == "x"
      assert data["effort"] == "high"
    end

    test "validate accepts the deepseek class + provider key, rejects cc.agent" do
      tmpl = %{
        "class" => "cc_deepseek.agent",
        "agent_uri" => "entity://team-alpha/agent/cc_ds-valid",
        "cwd" => "/tmp",
        "provider" => "deepseek"
      }

      assert CcDeepseekAgent.validate(tmpl) == :ok

      assert {:error, {:wrong_class, "cc.agent"}} =
               CcDeepseekAgent.validate(%{tmpl | "class" => "cc.agent"})
    end
  end

  # ── Credential contract: API key, NOT OAuth ─────────────────────────────

  describe "credential adapter (no OAuth / no host-login)" do
    test "declares zero on-disk credential files for both transports" do
      for tc <- [CcDeepseekAgent, CcHeadlessDeepseekAgent] do
        assert tc.credential_relpaths() == []
        assert tc.secret_relpaths() == []
        assert tc.host_login_dir() == nil
      end
    end

    test "is a credentialled flavor (so the credential-status router probes it)" do
      assert Ezagent.Agent.CredentialAdapter.credentialled?(CcDeepseekAgent)
      assert Ezagent.Agent.CredentialAdapter.credentialled?(CcHeadlessDeepseekAgent)
    end

    test "credential_status gates on DEEPSEEK_API_KEY, ignoring config_dir" do
      with_key()
      assert %{status: :authenticated} = CcDeepseekAgent.credential_status("/any/dir")
      assert %{status: :authenticated} = CcHeadlessDeepseekAgent.credential_status(nil)

      without_key()
      assert %{status: :missing} = CcDeepseekAgent.credential_status("/any/dir")
      assert %{status: :missing} = CcHeadlessDeepseekAgent.credential_status(nil)
    end

    test "the host-login-adopt seam no-ops (deepseek has no host login source)" do
      assert Ezagent.Agent.CredentialAdapter.host_login_source_dir(CcDeepseekAgent) == :none

      assert Ezagent.Agent.CredentialAdapter.host_login_source_dir(CcHeadlessDeepseekAgent) ==
               :none
    end
  end

  # ── Fail-fast launchability gate ────────────────────────────────────────

  describe "instantiate/3 fail-fast when the profile API key is missing" do
    test "pty flavor returns a clear :backend_api_key_missing (no opaque timeout)" do
      without_key()

      tmpl = %{
        "class" => "cc_deepseek.agent",
        "agent_uri" => "entity://team-alpha/agent/cc_ds-missing",
        "cwd" => "/tmp"
      }

      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcDeepseekAgent.instantiate("cc_deepseek.agent", tmpl, workspace_uri())
    end

    test "headless flavor returns a clear :backend_api_key_missing" do
      without_key()

      tmpl = %{
        "class" => "cc_headless_deepseek.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_ds-missing",
        "cwd" => "/tmp"
      }

      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcHeadlessDeepseekAgent.instantiate(
                 "cc_headless_deepseek.agent",
                 tmpl,
                 workspace_uri()
               )
    end
  end

  # ── Cold restart: the flavor identity survives ──────────────────────────

  describe "cold-restart flavor resolution" do
    test "respawn_template_data['flavor'] resolves back to the deepseek flavor" do
      pty = %{
        respawn_template_data: %{
          "flavor" => "cc-deepseek",
          "provider" => "deepseek",
          "class" => "cc_deepseek.agent",
          "cwd" => "/tmp"
        }
      }

      assert {:ok, "cc-deepseek"} = Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(pty)

      headless = %{
        respawn_template_data: %{
          "flavor" => "cc-headless-deepseek",
          "provider" => "deepseek",
          "class" => "cc_headless_deepseek.agent",
          "cwd" => "/tmp"
        }
      }

      assert {:ok, "cc-headless-deepseek"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(headless)
    end

    test "even without the persisted flavor key, the class name resolves the flavor" do
      # belt-and-suspenders: the distinct template_name is registered, so the
      # class-name fallback also recovers the deepseek flavor.
      assert {:ok, "cc-deepseek"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{"class" => "cc_deepseek.agent", "cwd" => "/tmp"}
               })

      assert {:ok, "cc-headless-deepseek"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{
                   "class" => "cc_headless_deepseek.agent",
                   "cwd" => "/tmp"
                 }
               })
    end
  end

  # ── PTY: the 8 vars actually land in the claude launch env (cmd_env) ────

  describe "pty launch env (build_claude_cmd/3)" do
    setup do
      # Mock `claude` on PATH: accepts the dev-channels probe (--help) and exits
      # 0 so `build_claude_cmd/3` resolves + probes it.
      bin_dir = Path.join(System.tmp_dir!(), "cc_ds_bin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin_dir)
      claude = Path.join(bin_dir, "claude")
      File.write!(claude, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(claude, 0o755)

      prev_path = System.get_env("PATH")
      System.put_env("PATH", bin_dir <> ":" <> (prev_path || ""))

      # Isolated per-agent config home (so the bridge .mcp.json write lands in a
      # tmp dir, not the operator home) + a tmp mcp dir + a tmp cwd.
      config_dir = Path.join(bin_dir, "config")
      cwd = Path.join(bin_dir, "cwd")
      File.mkdir_p!(config_dir)
      File.mkdir_p!(cwd)

      prev_mcp = Application.get_env(:ezagent_plugin_cc, :mcp_config_dir)
      Application.put_env(:ezagent_plugin_cc, :mcp_config_dir, Path.join(bin_dir, "mcp"))

      prev_ws = System.get_env("EZAGENT_BRIDGE_WS_URL")
      System.put_env("EZAGENT_BRIDGE_WS_URL", "ws://127.0.0.1:65535/agent_bridge/websocket")

      on_exit(fn ->
        if prev_path, do: System.put_env("PATH", prev_path), else: System.delete_env("PATH")

        if prev_ws,
          do: System.put_env("EZAGENT_BRIDGE_WS_URL", prev_ws),
          else: System.delete_env("EZAGENT_BRIDGE_WS_URL")

        if prev_mcp,
          do: Application.put_env(:ezagent_plugin_cc, :mcp_config_dir, prev_mcp),
          else: Application.delete_env(:ezagent_plugin_cc, :mcp_config_dir)

        File.rm_rf(bin_dir)
      end)

      {:ok, config_dir: config_dir, cwd: cwd}
    end

    @deepseek_keys ~w(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
                      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
                      ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
                      CLAUDE_CODE_EFFORT_LEVEL)

    test "deepseek provider injects all 8 vars into cmd_env", ctx do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_ds-pty")

      # `instantiate/3` injects both keys before the build path; mirror that.
      tmpl = %{
        "class" => "cc_deepseek.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir,
        "provider" => "deepseek",
        "flavor" => "cc-deepseek"
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)

      for k <- @deepseek_keys, do: assert(Map.has_key?(cmd_env, k), "missing #{k}")
      assert cmd_env["ANTHROPIC_AUTH_TOKEN"] == @key
      assert cmd_env["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic"

      # the esr-bridge sidecar must join the cc-deepseek topic (else the channel
      # rejects it on a topic-flavor mismatch and the agent goes mute).
      assert cmd_env["EZAGENT_BRIDGE_TOPIC"] ==
               "agent_bridge:cc-deepseek:" <> Ezagent.URI.stable_key(uri)
    end

    test "default anthropic cc path is UNCHANGED — no DeepSeek var leaks in", ctx do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_plain-pty")

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)

      for k <- @deepseek_keys, do: refute(Map.has_key?(cmd_env, k), "leaked #{k} into cc path")
      refute Map.has_key?(cmd_env, "EZAGENT_BRIDGE_TOPIC")
    end
  end

  # ── Bridge adapters (distinct flavor → distinct registered adapter) ─────

  describe "bridge adapters" do
    test "pty deepseek adapter serves cc-deepseek over the same subprocess_ws socket" do
      alias EzagentPluginCc.DeepseekBridgeAdapter
      assert DeepseekBridgeAdapter.flavor() == "cc-deepseek"
      assert DeepseekBridgeAdapter.transport_class() == :subprocess_ws
      assert DeepseekBridgeAdapter.socket_path() == "/agent_bridge"
      assert DeepseekBridgeAdapter.channel_topic_prefix() == "agent_bridge:cc-deepseek:"
    end

    test "headless deepseek adapter is in_process_sync (same as cc-headless)" do
      alias EzagentPluginCc.CcHeadlessDeepseekBridgeAdapter
      assert CcHeadlessDeepseekBridgeAdapter.flavor() == "cc-headless-deepseek"
      assert CcHeadlessDeepseekBridgeAdapter.transport_class() == :in_process_sync
    end

    test "AdapterRegistry resolves both deepseek flavors to their adapters" do
      assert {:ok, EzagentPluginCc.DeepseekBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-deepseek")

      assert {:ok, EzagentPluginCc.CcHeadlessDeepseekBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-headless-deepseek")
    end
  end

  # ── Headless: the 8 vars are threaded to the sidecar (cmd_env) ──────────

  describe "headless launch env (sdk_sidecar_params/2)" do
    test "deepseek provider threads all 8 vars as the sidecar cmd_env" do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_ds")

      params =
        CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "deepseek"})

      assert map_size(params.cmd_env) == 8
      assert params.cmd_env["ANTHROPIC_AUTH_TOKEN"] == @key
    end

    test "default anthropic headless path threads an empty cmd_env (no leak)" do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_plain")
      params = CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp"})
      assert params.cmd_env == %{}
    end
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://team-alpha")
end
