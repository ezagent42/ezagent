defmodule EzagentPluginHello.Integration.HelloCredentialSourceTest do
  @moduledoc """
  #185 — the `DEEPSEEK_API_KEY` env → curl credential bridge, end to end on the
  real substrate (no live LLM: the proof point is the credential SLICE the cold
  reply reads, not an HTTP round-trip).

  ## Two clearly separated planes (#185 codex review)

    * The **production entry point** `CredentialBridge.ensure_deepseek_source/0`
      is ZERO-ARITY: it reads `DEEPSEEK_API_KEY` and mints admin authority, so
      its destination is the single deploy-config home workspace
      (`EzagentPluginHello.home_workspace/0`, default `"ezagent"`) — never a
      caller-supplied one (#185's caller-redirect hole stays closed).
      The `"prod entry"` tests below drive it against the REAL cap-checked
      chokepoint and assert it lands in the home workspace only.

    * The **cascade + isolation behavior** for OTHER workspaces is proven with a
      test-only fixture `seed_shared_source/2` that takes an EXPLICIT key +
      workspace, NEVER reads the production env, and NEVER mints production admin
      authority (it writes the durable source snapshot + the `WorkspaceSharedSource`
      pointer directly — the sanctioned direct-setup pattern the sibling
      `curl_cascade_activation_test` / `workspace_shared_credential_source_test`
      use). The cascade resolves a directly-seeded source via
      `Ezagent.SnapshotStore.latest/1` (the `curl.agent` Template's snapshot
      fallback), so `App.ensure_app` materializes the key into the hello `llm`
      member exactly as it would from the prod path.

  HARD ISOLATION (the platform owner's explicit #185 constraint): a hello app in
  a DIFFERENT, un-bridged workspace resolves NO source and stays keyless — our
  key never leaks across workspaces.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.{GrantRow, WorkspaceSharedSource}
  alias Ezagent.Workspace
  alias EzagentCore.Repo
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

    :ok
  end

  # --- production entry point (zero-arity, env-gated, deploy-config home ws) ---

  describe "production entry ensure_deepseek_source/0" do
    setup do
      previous = System.get_env("DEEPSEEK_API_KEY")
      System.put_env("DEEPSEEK_API_KEY", @test_key)

      home = CredentialBridge.destination_workspace()

      # Stale-Kind hygiene: sibling tests in this BEAM create the SAME home
      # workspace + source-agent names; their DB rows roll back with the
      # sandbox but the live Kind processes (and the signed caps/keys in their
      # state) survive, surfacing as `:invalid_cap_signature`/`:not_found` in
      # the cap-checked chokepoint below. Terminate them so the create is a
      # FRESH spawn consistent with this transaction.
      terminate(Ezagent.URI.entity(home, :agent, CredentialBridge.source_agent_name()))
      terminate(Ezagent.URI.workspace(home))

      # This isolated test boundary registers no `"workspace"` SpawnRegistry fn
      # (full boot does), so the bridge's cap-checked chokepoint dispatch —
      # `issue_for_action` → `ensure_started(workspace://<home>)` — can only
      # resolve a workspace Kind that is ALREADY live. Create the home
      # workspace (persist + spawn, the way the boot `Workspace.Loader`
      # arranges in prod). Idempotent.
      case Workspace.create(home, %{}) do
        {:ok, _pid} -> :ok
        {:error, :workspace_exists} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      on_exit(fn ->
        if previous,
          do: System.put_env("DEEPSEEK_API_KEY", previous),
          else: System.delete_env("DEEPSEEK_API_KEY")

        # The prod path spawns the singleton home-workspace source live;
        # terminate it so its process cannot bleed into other tests (its DB
        # rows are already rolled back by the sandbox).
        terminate(Ezagent.URI.entity(home, :agent, CredentialBridge.source_agent_name()))
      end)

      {:ok, home: home}
    end

    test "is ZERO-ARITY — no workspace parameter to redirect the env key" do
      # The env-reading + admin-minting path exposes NO way to point it at an
      # arbitrary workspace (the #185 isolation hole codex flagged). This is
      # the PRESERVED #185 invariant: the destination moved from a compile-time
      # `"system"` literal to the deploy-config home workspace (hello-A), but
      # it remains non-caller-redirectable.
      assert function_exported?(CredentialBridge, :ensure_deepseek_source, 0)
      refute function_exported?(CredentialBridge, :ensure_deepseek_source, 1)
    end

    test "seeds the configured home workspace through the real cap-checked chokepoint (idempotent)",
         %{home: home} do
      # No workspace argument — the destination is the deploy-config constant.
      assert {:ok, source_uri} = CredentialBridge.ensure_deepseek_source()
      # …idempotent (reseed-safe): a re-run keeps the same source + pointer.
      assert {:ok, ^source_uri} = CredentialBridge.ensure_deepseek_source()

      # …lands in the home workspace ONLY…
      assert source_uri ==
               Ezagent.URI.entity(home, :agent, CredentialBridge.source_agent_name())

      # …registered as the home workspace's shared curl source through the REAL
      # chokepoint…
      assert WorkspaceSharedSource.resolve("workspace://#{home}", "curl") ==
               URI.to_string(source_uri)

      # …and the live source agent (spawned by the prod path) carries the key.
      assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
               Ezagent.Kind.read(source_uri, :api_keys, spawn: :never)
    end
  end

  test "no DEEPSEEK_API_KEY in the env → deliberate no-op (keyless spawn stays the truth)" do
    previous = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")
    on_exit(fn -> if previous, do: System.put_env("DEEPSEEK_API_KEY", previous) end)

    assert {:ok, :no_env_key} = CredentialBridge.ensure_deepseek_source()

    assert WorkspaceSharedSource.resolve(
             "workspace://#{CredentialBridge.destination_workspace()}",
             "curl"
           ) == nil
  end

  test "boot_enabled?/0 gates on BOTH the app config AND the env key" do
    previous_config = Application.get_env(:ezagent_plugin_hello, :credential_bridge_boot)
    previous_key = System.get_env("DEEPSEEK_API_KEY")
    System.put_env("DEEPSEEK_API_KEY", @test_key)

    on_exit(fn ->
      if is_nil(previous_config),
        do: Application.delete_env(:ezagent_plugin_hello, :credential_bridge_boot),
        else: Application.put_env(:ezagent_plugin_hello, :credential_bridge_boot, previous_config)

      if previous_key,
        do: System.put_env("DEEPSEEK_API_KEY", previous_key),
        else: System.delete_env("DEEPSEEK_API_KEY")
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

  # --- cascade materialization in ARBITRARY workspaces (test-only fixture) -----

  test "provisioned path: a seeded workspace's hello llm curl member cold-spawns WITH deepseek" do
    ws = "hello-cred-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws, %{})

    source_uri = seed_shared_source(ws, @test_key)

    # …registered as THIS workspace's shared curl credential source…
    assert WorkspaceSharedSource.resolve("workspace://#{ws}", "curl") ==
             URI.to_string(source_uri)

    # A freshly seeded hello app cold-spawns its `llm` curl member…
    assert {:ok, session_uri, _front_desk} = App.ensure_app(ws, "main")
    assert {:ok, llm_uri} = Members.role_uri(session_uri, "llm")

    # …born-credentialed: the cascade resolved the workspace-shared source,
    # minted the grant, and materialized the key into the member's OWN slice.
    assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
             Ezagent.Kind.read(llm_uri, :api_keys, spawn: :never)

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

  test "ISOLATION: a hello app in a DIFFERENT workspace stays keyless (no cross-workspace leak)" do
    bridged_ws = "hello-cred-a-#{System.unique_integer([:positive])}"
    plain_ws = "hello-cred-b-#{System.unique_integer([:positive])}"
    {:ok, _pid1} = Workspace.create(bridged_ws, %{})
    {:ok, _pid2} = Workspace.create(plain_ws, %{})

    # Seed ONLY the first workspace (explicit key, no env, no admin).
    bridged_source = seed_shared_source(bridged_ws, @test_key)

    # A hello agent cold-spawned in the OTHER workspace…
    assert {:ok, plain_session, _front_desk} = App.ensure_app(plain_ws, "main")
    assert {:ok, plain_llm} = Members.role_uri(plain_session, "llm")

    # …resolves NO shared credential source of ours…
    assert WorkspaceSharedSource.resolve("workspace://#{plain_ws}", "curl") == nil

    # …mints NO grant to our source…
    assert GrantRow.get_for_agent(URI.to_string(plain_llm)) == nil

    # …and stays KEYLESS: the deepseek key does NOT leak across workspaces.
    assert {:ok, slice} = Ezagent.Kind.read(plain_llm, :api_keys, spawn: :never)
    keys = Map.get(slice, :keys, %{})
    assert Map.get(keys, "deepseek") in [nil, ""]

    # …while the bridged workspace's agent DID get it (same ensure_app; the
    # ONLY difference is the workspace-scoped seed).
    assert {:ok, bridged_session, _} = App.ensure_app(bridged_ws, "main")
    assert {:ok, bridged_llm} = Members.role_uri(bridged_session, "llm")

    assert {:ok, %{keys: %{"deepseek" => @test_key}}} =
             Ezagent.Kind.read(bridged_llm, :api_keys, spawn: :never)

    # Sanity: the source lives in the BRIDGED workspace only.
    assert Ezagent.Capability.workspace_of(bridged_source) ==
             Ezagent.URI.workspace(bridged_ws)
  end

  # --- test-only fixture -------------------------------------------------------
  #
  # Seed an ARBITRARY workspace's shared curl credential source WITHOUT the
  # production bridge. Deliberately (#185 codex review):
  #   * takes an EXPLICIT key — never reads `DEEPSEEK_API_KEY`;
  #   * mints NO production admin authority — it writes the durable state
  #     directly (the source snapshot + the `WorkspaceSharedSource` pointer),
  #     the same direct-setup pattern the sibling credential tests use.
  # The `curl.agent` cascade reads the source's `:api_keys` from
  # `SnapshotStore.latest/1` (its documented snapshot fallback), so a
  # directly-seeded source materializes into the hello `llm` member exactly as
  # the prod path's live source would.
  defp seed_shared_source(ws, key) do
    source_uri = Ezagent.URI.entity(ws, :agent, CredentialBridge.source_agent_name())
    source_str = URI.to_string(source_uri)

    :ok = Ezagent.AgentFlavorAttributes.put(source_uri, "curl")

    {:ok, _} =
      Ezagent.SnapshotStore.write(
        source_str,
        %{api_keys: %{keys: %{"deepseek" => key}}},
        kind_type: :agent
      )

    {:ok, _} =
      %{
        workspace_uri: "workspace://#{ws}",
        flavor: "curl",
        source_uri: source_str,
        set_by: "entity://#{ws}/user/cred-seeder"
      }
      |> WorkspaceSharedSource.changeset()
      |> Repo.insert()

    source_uri
  end

  defp terminate(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      _ -> :ok
    end
  end
end
