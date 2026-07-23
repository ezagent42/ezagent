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

  The `Ezagent.PluginCc.Provider` describes (ported from the retired
  cc-deepseek suite — full parity map in
  `docs/superpowers/specs/2026-07-17-cc-custom-backends-design.md` Appendix B)
  cover the shared facade directly: `profile_env/1` / `provider_env/1` per
  profile (both vendors), the fail-closed unknown/missing-key error shapes,
  `ensure_api_key/2`, `credential_status/1`, and the headless
  `sdk_sidecar_params/2` fail-closed defense line.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Provider
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

  # ── Provider: profile env assembly + fail-closed contract ───────────────
  # Ported from the retired cc-deepseek suite (Appendix B row 1) — these are
  # direct unit tests of the shared `Ezagent.PluginCc.Provider` facade, not
  # specific to either transport class, so they have no other home now that
  # cc_deepseek_backend_test.exs is gone.

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

    test "empty-string key counts as missing (parity with unset)" do
      System.put_env("DEEPSEEK_API_KEY", "")
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

    test "non-string provider → {:unknown_backend_profile, bad} (fail closed)" do
      assert {:error, {:unknown_backend_profile, 123}} =
               CcCustomAgent.validate(Map.put(@base, "provider", 123))
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

  # ── F3/#1460: config_schema opens the ad-hoc create lane to `provider` ────

  describe "config_schema/0 (F3)" do
    test "cc-custom: cc base fields + a required provider enum over the closed catalog" do
      schema = CcCustomAgent.config_schema()
      keys = Enum.map(schema, & &1.key)

      # cc base fields preserved (the schema is no longer a bare defdelegate).
      assert "model" in keys
      assert "effort" in keys
      assert "permission_mode" in keys
      assert "tools" in keys

      provider = Enum.find(schema, &(&1.key == "provider"))
      assert provider.type == :enum
      assert provider.required == true
      assert provider.options == Ezagent.PluginCc.ProviderCatalog.names()
    end

    test "cc-headless-custom: identical schema to the pty twin (F3 ad-hoc lane parity)" do
      assert CcHeadlessCustomAgent.config_schema() == CcCustomAgent.config_schema()
    end

    test "plain cc / cc-headless schemas carry NO provider key (closed-catalog boundary)" do
      refute "provider" in Enum.map(CcAgent.ConfigSchema.fields(), & &1.key)
      refute function_exported?(CcHeadlessAgent, :config_schema, 0)
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

    test "is a credentialled flavor (so the credential-status router probes it)" do
      assert Ezagent.Agent.CredentialAdapter.credentialled?(CcCustomAgent)
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

      previous_home = System.get_env("EZAGENT_HOME")
      previous_profile = System.get_env("EZAGENT_PROFILE")
      System.put_env("EZAGENT_HOME", bin_dir)
      System.put_env("EZAGENT_PROFILE", "cc-custom")

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
        if previous_home,
          do: System.put_env("EZAGENT_HOME", previous_home),
          else: System.delete_env("EZAGENT_HOME")

        if previous_profile,
          do: System.put_env("EZAGENT_PROFILE", previous_profile),
          else: System.delete_env("EZAGENT_PROFILE")

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
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_cu-pty-#{System.unique_integer([:positive])}"
        )

      _authority = install_test_authority!(uri, :agent)

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
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_cu-kimi-#{System.unique_integer([:positive])}"
        )

      _authority = install_test_authority!(uri, :agent)

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
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_plain-pty2-#{System.unique_integer([:positive])}"
        )

      _authority = install_test_authority!(uri, :agent)

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

      assert {:ok, %{template_class: CcHeadlessCustomAgent}} =
               Ezagent.AgentFlavorRegistry.lookup("cc-headless-custom")

      assert {:ok, EzagentPluginCc.CcHeadlessCustomBridgeAdapter} =
               Ezagent.AgentBridge.AdapterRegistry.lookup("cc-headless-custom")
    end

    test "template metadata: class name + cc-headless config_dir namespace" do
      assert CcHeadlessCustomAgent.template_name() == "cc_headless_custom.agent"

      assert CcHeadlessCustomAgent.config_dir_namespace() ==
               CcHeadlessAgent.config_dir_namespace()
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

    test "validate rejects unknown / anthropic / non-string providers (fail closed, drift guard vs pty)" do
      base = %{
        "class" => "cc_headless_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_cu-neg",
        "cwd" => "/tmp"
      }

      assert {:error, {:unknown_backend_profile, "bogus"}} =
               CcHeadlessCustomAgent.validate(Map.put(base, "provider", "bogus"))

      assert {:error, {:unknown_backend_profile, "anthropic"}} =
               CcHeadlessCustomAgent.validate(Map.put(base, "provider", "anthropic"))

      assert {:error, {:unknown_backend_profile, 123}} =
               CcHeadlessCustomAgent.validate(Map.put(base, "provider", 123))
    end

    test "validate rejects the wrong class" do
      tmpl = %{
        "class" => "cc_headless_custom.agent",
        "agent_uri" => "entity://team-alpha/agent/cch_cu-wrongclass",
        "cwd" => "/tmp",
        "provider" => "deepseek"
      }

      assert {:error, {:wrong_class, "cc_headless.agent"}} =
               CcHeadlessCustomAgent.validate(%{tmpl | "class" => "cc_headless.agent"})
    end

    test "template_data_extra/1 passes the content provider through (curl-pattern content seam)" do
      data = CcHeadlessCustomAgent.template_data_extra(%{provider: "kimi", model: "x"})
      assert data["provider"] == "kimi"
      assert data["model"] == "x"

      refute Map.has_key?(
               CcHeadlessCustomAgent.template_data_extra(%{model: "x"}),
               "provider"
             )
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

    test "credential adapter: no on-disk credential, no host login" do
      assert CcHeadlessCustomAgent.credential_relpaths() == []
      assert CcHeadlessCustomAgent.secret_relpaths() == []
      assert CcHeadlessCustomAgent.host_login_dir() == nil

      assert Ezagent.Agent.CredentialAdapter.host_login_source_dir(CcHeadlessCustomAgent) ==
               :none
    end

    test "is a credentialled flavor (so the credential-status router probes it)" do
      assert Ezagent.Agent.CredentialAdapter.credentialled?(CcHeadlessCustomAgent)
    end

    test "credential_status/2 is profile-driven via opts" do
      with_key()

      assert %{status: :authenticated} =
               CcHeadlessCustomAgent.credential_status(nil, backend_profile: "deepseek")

      without_key()

      assert %{status: :missing} =
               CcHeadlessCustomAgent.credential_status(nil, backend_profile: "deepseek")

      assert %{status: :unknown} = CcHeadlessCustomAgent.credential_status(nil, [])
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

    test "default anthropic headless path threads an empty cmd_env (no leak)" do
      with_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_plain")
      params = CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp"})
      assert params.cmd_env == %{}
    end

    test "cold restart resolves the headless custom flavor (both resolver paths)" do
      assert {:ok, "cc-headless-custom"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{
                   "flavor" => "cc-headless-custom",
                   "provider" => "deepseek",
                   "class" => "cc_headless_custom.agent",
                   "cwd" => "/tmp"
                 }
               })

      # belt-and-suspenders: even without the persisted "flavor" key, the
      # distinct template_name resolves the flavor via the class-name fallback.
      assert {:ok, "cc-headless-custom"} =
               Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(%{
                 respawn_template_data: %{
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

    test "headless custom adapter is in_process_sync (same as cc-headless)" do
      alias EzagentPluginCc.CcHeadlessCustomBridgeAdapter
      assert CcHeadlessCustomBridgeAdapter.flavor() == "cc-headless-custom"
      assert CcHeadlessCustomBridgeAdapter.transport_class() == :in_process_sync
    end
  end

  # ── Headless defense line: provider errors raise, never silent anthropic ──
  # Ported from the retired cc-deepseek suite (Appendix B) — exercises the
  # shared `CcHeadlessAgent.sdk_sidecar_params/2` fail-closed raise directly;
  # not specific to either custom-backend class.

  describe "headless provider_cmd_env fail-closed defense line" do
    test "raises on unknown profile (fail closed, no silent anthropic)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_bogus")

      assert_raise ArgumentError, ~r/unknown_backend_profile/, fn ->
        CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "bogus"})
      end
    end

    test "raises when the profile key is missing (fail closed)" do
      without_key()
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_nokey")

      assert_raise ArgumentError, ~r/backend_api_key_missing/, fn ->
        CcHeadlessAgent.sdk_sidecar_params(uri, %{"cwd" => "/tmp", "provider" => "deepseek"})
      end
    end
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://team-alpha")
end
