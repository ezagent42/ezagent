defmodule Ezagent.PluginCc.Template.CcCustomBackendTest do
  @moduledoc """
  The `"cc-custom"` flavor (PTY transport) — ONE flavor for every custom
  backend, with the backend selected by the REQUIRED `"provider"` template-data
  key naming a closed `ProviderCatalog` profile (fail-closed validation:
  absent / unknown / `"anthropic"` all reject).

  Covers: flavor + adapter registration, the fail-closed `validate/1` profile
  contract, `template_data_extra/1` passing the content `provider` through
  (never injecting one), the profile-driven credential adapter (no OAuth / no
  host-login), the fail-fast launchability gate, cold-restart flavor
  re-resolution, the per-profile PTY launch env (+ no leak into the default
  anthropic cc path), and the bridge adapter shape.

  The `"cc-headless-custom"` describe covers the headless transport twin:
  registration with the `cc_headless_behaviors` instance set, the same
  fail-closed profile contract on the `"cc_headless_custom.agent"` class, the
  profile env block threaded as the SDK sidecar `cmd_env`, cold-restart flavor
  re-resolution, and the `sync_result_action` reply-route clause.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.{CcAgent, CcCustomAgent, CcHeadlessAgent, CcHeadlessCustomAgent}

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

  # ── Registration ─────────────────────────────────────────────────────────

  describe "registration" do
    test "agent_flavors/0 declares cc-custom → CcCustomAgent + adapter" do
      by = Map.new(EzagentPluginCc.Application.agent_flavors(), &{&1.flavor, &1})
      assert %{kind: Ezagent.Entity.Agent, template_class: CcCustomAgent} = by["cc-custom"]

      assert {:ok, %{template_class: CcCustomAgent}} =
               Ezagent.AgentFlavorRegistry.lookup("cc-custom")

      assert {:ok, EzagentPluginCc.CcCustomBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-custom")
    end

    test "template metadata: class name + cc config_dir namespace" do
      assert CcCustomAgent.template_name() == "cc_custom.agent"
      assert CcCustomAgent.config_dir_namespace() == CcAgent.config_dir_namespace()
    end
  end

  # ── validate/1: the fail-closed profile contract ─────────────────────────

  describe "validate/1 — fail-closed profile contract" do
    @base %{
      "class" => "cc_custom.agent",
      "agent_uri" => "entity://team-alpha/agent/cc_cu-valid",
      "cwd" => "/tmp"
    }

    test "accepts a catalog profile" do
      assert CcCustomAgent.validate(Map.put(@base, "provider", "deepseek")) == :ok
      assert CcCustomAgent.validate(Map.put(@base, "provider", "kimi")) == :ok
    end

    test "missing provider → :missing_backend_profile" do
      assert CcCustomAgent.validate(@base) == {:error, :missing_backend_profile}
    end

    test "unknown provider → {:unknown_backend_profile, name} (anthropic is NOT a profile)" do
      assert {:error, {:unknown_backend_profile, "bogus"}} =
               CcCustomAgent.validate(Map.put(@base, "provider", "bogus"))

      assert {:error, {:unknown_backend_profile, "anthropic"}} =
               CcCustomAgent.validate(Map.put(@base, "provider", "anthropic"))
    end

    test "rejects the wrong class" do
      tmpl = Map.put(@base, "provider", "deepseek")

      assert {:error, {:wrong_class, "cc.agent"}} =
               CcCustomAgent.validate(%{tmpl | "class" => "cc.agent"})
    end
  end

  # ── template_data_extra/1: pass-through, never inject ────────────────────

  describe "template_data_extra/1" do
    test "passes the content provider through (curl-pattern content seam)" do
      data = CcCustomAgent.template_data_extra(%{provider: "kimi", model: "x"})
      assert data["provider"] == "kimi"
      assert data["model"] == "x"
    end

    test "no provider in content → key absent (validate fails it later, fail closed)" do
      refute Map.has_key?(CcCustomAgent.template_data_extra(%{model: "x"}), "provider")
    end
  end

  # ── Credential contract: profile-driven, no OAuth / no host-login ────────

  describe "credential adapter" do
    test "no on-disk credential, no host login" do
      assert CcCustomAgent.credential_relpaths() == []
      assert CcCustomAgent.secret_relpaths() == []
      assert CcCustomAgent.host_login_dir() == nil
      assert Ezagent.Agent.CredentialAdapter.host_login_source_dir(CcCustomAgent) == :none
    end

    test "credential_status/2 is profile-driven via opts" do
      with_key()

      assert %{status: :authenticated} =
               CcCustomAgent.credential_status(nil, backend_profile: "deepseek")

      without_key()

      assert %{status: :missing} =
               CcCustomAgent.credential_status(nil, backend_profile: "deepseek")

      assert %{status: :unknown} = CcCustomAgent.credential_status(nil, [])
    end
  end

  # ── Fail-fast launchability gate ─────────────────────────────────────────

  describe "instantiate/3" do
    test "missing key → {:backend_api_key_missing, profile, uri} before any spawn" do
      without_key()

      tmpl = %{
        "class" => "cc_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cc_cu-missing",
        "cwd" => "/tmp",
        "provider" => "deepseek"
      }

      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcCustomAgent.instantiate("cc_custom.agent", tmpl, workspace_uri())
    end
  end

  # ── Cold restart: flavor + persisted profile re-resolve ──────────────────

  describe "cold restart" do
    test "respawn flavor + persisted profile re-resolve (both resolver paths)" do
      sandbox = %{
        respawn_template_data: %{
          "flavor" => "cc-custom",
          "provider" => "kimi",
          "class" => "cc_custom.agent",
          "cwd" => "/tmp"
        }
      }

      assert {:ok, "cc-custom"} = Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(sandbox)

      assert {:ok, "cc-custom"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{"class" => "cc_custom.agent", "cwd" => "/tmp"}
               })
    end
  end

  # ── PTY: the profile block lands in the claude launch env (cmd_env) ──────

  describe "pty launch env (build_claude_cmd/3)" do
    setup do
      # Mock `claude` on PATH: accepts the dev-channels probe (--help) and exits
      # 0 so `build_claude_cmd/3` resolves + probes it.
      bin_dir = Path.join(System.tmp_dir!(), "cc_cu_bin_#{System.unique_integer([:positive])}")
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

    test "deepseek profile injects its block + the cc-custom bridge topic", ctx do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_cu-pty")

      tmpl = %{
        "class" => "cc_custom.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir,
        "provider" => "deepseek",
        "flavor" => "cc-custom"
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)
      assert cmd_env["ANTHROPIC_AUTH_TOKEN"] == @key
      assert cmd_env["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic"

      assert cmd_env["EZAGENT_BRIDGE_TOPIC"] ==
               "agent_bridge:cc-custom:" <> Ezagent.URI.stable_key(uri)
    end

    test "kimi profile injects its 9-var block (MOONSHOT_API_KEY)", ctx do
      System.put_env("MOONSHOT_API_KEY", "sk-kimi-test-xyz")
      on_exit(fn -> System.delete_env("MOONSHOT_API_KEY") end)
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_cu-kimi")

      tmpl = %{
        "class" => "cc_custom.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir,
        "provider" => "kimi",
        "flavor" => "cc-custom"
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)

      assert map_size(Map.take(cmd_env, ~w(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
                  ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
                  ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL ENABLE_TOOL_SEARCH
                  CLAUDE_CODE_AUTO_COMPACT_WINDOW))) == 9

      assert cmd_env["ANTHROPIC_MODEL"] == "kimi-k3"
    end

    @catalog_keys ~w(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
                     ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL
                     ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
                     CLAUDE_CODE_EFFORT_LEVEL ENABLE_TOOL_SEARCH
                     CLAUDE_CODE_AUTO_COMPACT_WINDOW)

    test "default anthropic cc path UNCHANGED (no catalog var leaks)", ctx do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_plain-pty2")

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => ctx.cwd,
        "agent_config_dir" => ctx.config_dir
      }

      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(uri, ctx.cwd, tmpl)

      for k <- @catalog_keys, do: refute(Map.has_key?(cmd_env, k), "leaked #{k} into cc path")
      refute Map.has_key?(cmd_env, "EZAGENT_BRIDGE_TOPIC")
    end
  end

  # ── Bridge adapter ───────────────────────────────────────────────────────

  describe "bridge adapter" do
    test "serves cc-custom over the shared subprocess_ws socket" do
      alias EzagentPluginCc.CcCustomBridgeAdapter
      assert CcCustomBridgeAdapter.flavor() == "cc-custom"
      assert CcCustomBridgeAdapter.transport_class() == :subprocess_ws
      assert CcCustomBridgeAdapter.socket_path() == "/agent_bridge"
      assert CcCustomBridgeAdapter.channel_topic_prefix() == "agent_bridge:cc-custom:"
    end
  end

  # ── cc-headless-custom: the headless transport twin ──────────────────────

  describe "cc-headless-custom" do
    test "registered with the cc-headless behavior set" do
      by = Map.new(EzagentPluginCc.Application.agent_flavors(), &{&1.flavor, &1})

      assert %{kind: Ezagent.Entity.Agent, template_class: CcHeadlessCustomAgent} =
               by["cc-headless-custom"]

      assert is_function(by["cc-headless-custom"].instance_behaviors, 0)

      assert {:ok, EzagentPluginCc.CcHeadlessCustomBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-headless-custom")
    end

    test "validate requires a catalog profile (same contract as pty)" do
      base = %{
        "class" => "cc_headless_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_cu",
        "cwd" => "/tmp"
      }

      assert CcHeadlessCustomAgent.validate(base) == {:error, :missing_backend_profile}
      assert CcHeadlessCustomAgent.validate(Map.put(base, "provider", "kimi")) == :ok
    end

    test "instantiate fail-fast on missing key" do
      without_key()

      tmpl = %{
        "class" => "cc_headless_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_cu-missing",
        "cwd" => "/tmp",
        "provider" => "deepseek"
      }

      assert {:error, {:backend_api_key_missing, "deepseek", %URI{}}} =
               CcHeadlessCustomAgent.instantiate(
                 "cc_headless_custom.agent",
                 tmpl,
                 workspace_uri()
               )
    end

    test "headless sidecar params thread the profile block (both vendors)" do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_cu")

      params =
        CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "deepseek"})

      assert map_size(params.cmd_env) == 8
      assert params.cmd_env["ANTHROPIC_AUTH_TOKEN"] == @key

      System.put_env("MOONSHOT_API_KEY", "sk-kimi-test-xyz")
      on_exit(fn -> System.delete_env("MOONSHOT_API_KEY") end)

      params2 = CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "kimi"})
      assert map_size(params2.cmd_env) == 9
      assert params2.cmd_env["ANTHROPIC_BASE_URL"] == "https://api.moonshot.ai/anthropic"
    end

    test "cold restart resolves the headless custom flavor" do
      assert {:ok, "cc-headless-custom"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{
                   "flavor" => "cc-headless-custom",
                   "provider" => "deepseek",
                   "class" => "cc_headless_custom.agent",
                   "cwd" => "/tmp"
                 }
               })
    end

    test "sync_result_action routes cc-headless-custom replies to :cc_headless_sync_result" do
      # The clause under test is private (`Agent.Receive.sync_result_action/1`);
      # the public delivery path (`Agent.Delivery.deliver_agent_receive/2` →
      # the {:sync, flavor, result} branch) requires a live SDK sidecar, so no
      # clean unit seam exists — assert the clause via a source check instead.
      receive_ex =
        Path.join([
          __DIR__,
          "..",
          "..",
          "..",
          "..",
          "ezagent_domain_agent",
          "lib",
          "ezagent",
          "behavior",
          "agent",
          "receive.ex"
        ])

      src = File.read!(receive_ex)

      assert src =~
               ~s|sync_result_action("cc-headless-custom"), do: :cc_headless_sync_result|
    end
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://team-alpha")
end
