defmodule EzagentPluginHello.Integration.HelloCredentialSourceTest do
  @moduledoc """
  #185 — the `DEEPSEEK_API_KEY` env → curl credential bridge, end to end on the
  real substrate (no live LLM: the proof point is the credential SLICE the cold
  reply reads, not an HTTP round-trip):

      CredentialBridge.ensure_deepseek_source (boot lane, env-gated)
        → workspace-shared curl credential source (cap-checked chokepoint)
        → App.ensure_app → hello.llm curl member cold-spawns
        → cascade resolves the source → key materialized into :api_keys

  plus the HARD ISOLATION guarantee (the platform owner's explicit #185
  constraint): a hello app in a DIFFERENT, un-bridged workspace resolves NO
  source and stays keyless — our key never leaks across workspaces.

  Fail-before: without the bridge seed the `llm` member's `:api_keys` slice is
  EMPTY (the pre-#185 bug — `{:no_api_key, "deepseek"}` at the visitor's first
  cold reply). The isolation test pins that baseline; the provisioned test is
  the same `ensure_app` with ONLY the bridge added.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.{GrantRow, WorkspaceSharedSource}
  alias Ezagent.Workspace
  alias EzagentPluginHello.{App, CredentialBridge, Members}

  @test_key "sk-test-hello-cred-bridge"

  setup do
    # Same role-seed rationale as `HelloPageE2ETest` (boot seeds land outside
    # this DataCase sandbox); the curl flavor must be boot-registered.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    # The bridge reads the env var at call time — pin a known test key and
    # restore whatever was there (config/test.exs installs a dummy).
    previous = System.get_env("DEEPSEEK_API_KEY")
    System.put_env("DEEPSEEK_API_KEY", @test_key)

    on_exit(fn ->
      if previous,
        do: System.put_env("DEEPSEEK_API_KEY", previous),
        else: System.delete_env("DEEPSEEK_API_KEY")
    end)

    :ok
  end

  test "provisioned path: env key bridged → hello llm curl member cold-spawns WITH deepseek" do
    ws = "hello-cred-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws, %{})

    # The boot lane (called directly here; at boot it runs from the plugin's
    # `credential_bridge_children/0` Task).
    assert {:ok, source_uri} = CredentialBridge.ensure_deepseek_source(ws)

    # …registered as THIS workspace's shared curl credential source…
    assert WorkspaceSharedSource.resolve("workspace://#{ws}", "curl") ==
             URI.to_string(source_uri)

    # …and the source agent itself carries the key (the vault the cascade
    # materializes from).
    assert source_uri == Ezagent.URI.entity(ws, :agent, CredentialBridge.source_agent_name())

    assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
             Ezagent.Kind.get_slice(source_uri, :api_keys)

    # A freshly seeded hello app cold-spawns its `llm` curl member…
    assert {:ok, session_uri, _front_desk} = App.ensure_app(ws, "main")
    assert {:ok, llm_uri} = Members.role_uri(session_uri, "llm")

    # …born-credentialed: the cascade resolved the workspace-shared source,
    # minted the grant, and materialized the key into the member's OWN slice.
    assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
             Ezagent.Kind.get_slice(llm_uri, :api_keys)

    assert %GrantRow{credential_source_uri: credential_source_uri} =
             GrantRow.get_for_agent(URI.to_string(llm_uri))

    assert credential_source_uri == URI.to_string(source_uri)

    # …and the exact read the curl bridge adapter performs at the visitor's
    # first cold reply (the durable snapshot slices — `BridgeAdapter.deliver/2`)
    # now yields the key instead of `{:no_api_key, "deepseek"}`.
    assert {:ok, %{state: state}} = Ezagent.SnapshotStore.latest(llm_uri)

    api_keys = Ezagent.Kind.normalize_slice_view(Map.get(state, :api_keys, %{}))
    assert get_in(api_keys, [:keys, "deepseek"]) == @test_key
  end

  test "bridge is idempotent (reseed-safe): re-run keeps the same source + pointer" do
    ws = "hello-cred-idem-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws, %{})

    assert {:ok, source_uri} = CredentialBridge.ensure_deepseek_source(ws)
    assert {:ok, ^source_uri} = CredentialBridge.ensure_deepseek_source(ws)

    assert WorkspaceSharedSource.resolve("workspace://#{ws}", "curl") ==
             URI.to_string(source_uri)

    assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
             Ezagent.Kind.get_slice(source_uri, :api_keys)
  end

  test "ISOLATION: a hello app in a DIFFERENT workspace stays keyless (no cross-workspace leak)" do
    bridged_ws = "hello-cred-a-#{System.unique_integer([:positive])}"
    plain_ws = "hello-cred-b-#{System.unique_integer([:positive])}"
    {:ok, _pid1} = Workspace.create(bridged_ws, %{})
    {:ok, _pid2} = Workspace.create(plain_ws, %{})

    # Bridge ONLY the first workspace.
    assert {:ok, bridged_source} = CredentialBridge.ensure_deepseek_source(bridged_ws)

    # A hello agent cold-spawned in the OTHER workspace…
    assert {:ok, plain_session, _front_desk} = App.ensure_app(plain_ws, "main")
    assert {:ok, plain_llm} = Members.role_uri(plain_session, "llm")

    # …resolves NO shared credential source of ours…
    assert WorkspaceSharedSource.resolve("workspace://#{plain_ws}", "curl") == nil

    # …mints NO grant to our source…
    assert GrantRow.get_for_agent(URI.to_string(plain_llm)) == nil

    # …and stays KEYLESS: the deepseek key does NOT leak across workspaces.
    assert {:ok, slice} = Ezagent.Kind.get_slice(plain_llm, :api_keys)
    keys = Map.get(slice, :keys, %{})
    assert Map.get(keys, "deepseek") in [nil, ""]

    # …while the bridged workspace's agent DID get it (same ensure_app; the
    # ONLY difference is the workspace-scoped bridge).
    assert {:ok, bridged_session, _} = App.ensure_app(bridged_ws, "main")
    assert {:ok, bridged_llm} = Members.role_uri(bridged_session, "llm")

    assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
             Ezagent.Kind.get_slice(bridged_llm, :api_keys)

    # Sanity: the source agent itself lives in the BRIDGED workspace only.
    assert Ezagent.Capability.workspace_of(bridged_source) ==
             Ezagent.URI.workspace(bridged_ws)
  end

  test "no DEEPSEEK_API_KEY in the env → deliberate no-op (keyless spawn stays the truth)" do
    System.delete_env("DEEPSEEK_API_KEY")
    ws = "hello-cred-noenv-#{System.unique_integer([:positive])}"

    assert {:ok, :no_env_key} = CredentialBridge.ensure_deepseek_source(ws)
    assert WorkspaceSharedSource.resolve("workspace://#{ws}", "curl") == nil
  end

  test "boot_enabled?/0 gates on BOTH the app config AND the env key" do
    previous_config = Application.get_env(:ezagent_plugin_hello, :credential_bridge_boot)

    on_exit(fn ->
      if is_nil(previous_config),
        do: Application.delete_env(:ezagent_plugin_hello, :credential_bridge_boot),
        else: Application.put_env(:ezagent_plugin_hello, :credential_bridge_boot, previous_config)
    end)

    # config/test.exs keeps the boot lane OFF even though a dummy key is
    # installed — test boots must never auto-wire a workspace.
    refute CredentialBridge.boot_enabled?()

    # With the lane enabled, the gate follows the env key alone.
    Application.put_env(:ezagent_plugin_hello, :credential_bridge_boot, true)
    assert CredentialBridge.boot_enabled?()

    System.delete_env("DEEPSEEK_API_KEY")
    refute CredentialBridge.boot_enabled?()
  end
end
