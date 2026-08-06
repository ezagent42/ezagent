defmodule EzagentPluginHello.ReusableLlmAgentTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias EzagentPluginHello.{App, ReusableLlmAgent}

  @hello_recipe "hello.llm"
  @credential_apps [
    :ezagent_plugin_cc,
    :ezagent_plugin_codex,
    :ezagent_plugin_curl_agent,
    :ezagent_plugin_py
  ]

  setup do
    Enum.each(@credential_apps, fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)

    suffix = System.unique_integer([:positive])
    ws_name = "hello-reusable-#{suffix}"
    {:ok, _} = Ezagent.Workspace.create(ws_name, %{})
    workspace_uri = Ezagent.URI.workspace(ws_name)
    owner = confirmed_user(ws_name, "owner")
    stranger = confirmed_user(ws_name, "stranger")
    config_root = Path.join(System.tmp_dir!(), "hello-reusable-credentials-#{suffix}")
    File.mkdir_p!(config_root)

    previous_deepseek = System.get_env("DEEPSEEK_API_KEY")
    previous_moonshot = System.get_env("MOONSHOT_API_KEY")
    System.put_env("DEEPSEEK_API_KEY", "test-only-deepseek-key")
    System.put_env("MOONSHOT_API_KEY", "test-only-moonshot-key")

    on_exit(fn ->
      restore_env("DEEPSEEK_API_KEY", previous_deepseek)
      restore_env("MOONSHOT_API_KEY", previous_moonshot)
      File.rm_rf!(config_root)
    end)

    %{
      workspace_uri: workspace_uri,
      ws_name: ws_name,
      owner: owner,
      stranger: stranger,
      config_root: config_root
    }
  end

  test "lists every supported Hello LLM flavor when its exact reusable agent is eligible", ctx do
    assert App.llm_flavors() ==
             ~w(curl cc-headless cc-headless-custom cc codex codex-remote py)

    Enum.each(App.llm_flavors(), fn flavor ->
      agent =
        seed_candidate(ctx, flavor,
          credential_status: :authenticated,
          provider_profile: "deepseek"
        )

      assert {:ok, candidates} =
               ReusableLlmAgent.list(ctx.owner, ctx.workspace_uri, flavor)

      assert %{
               agent_uri: ^agent,
               flavor: ^flavor,
               credential_status: status
             } = Enum.find(candidates, &(&1.agent_uri == agent))

      expected_status = if flavor == "py", do: :n_a, else: :authenticated
      assert status == expected_status
    end)
  end

  test "accepts authenticated, expiring, and credentialless candidates", ctx do
    authenticated = seed_candidate(ctx, "cc", credential_status: :authenticated)
    expiring = seed_candidate(ctx, "cc", credential_status: :expiring)
    credentialless = seed_candidate(ctx, "py")

    assert {:ok, %{credential_status: :authenticated}} =
             ReusableLlmAgent.validate(
               ctx.owner,
               ctx.workspace_uri,
               "cc",
               authenticated
             )

    assert {:ok, %{credential_status: :expiring}} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "cc", expiring)

    assert {:ok, %{credential_status: :n_a}} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "py", credentialless)
  end

  test "rejects missing, expired, and unknown credential states", ctx do
    Enum.each([:missing, :expired, :unknown], fn status ->
      agent = seed_candidate(ctx, "cc", credential_status: status)

      assert {:error, {:ineligible_credential_status, ^status}} =
               ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "cc", agent)
    end)
  end

  test "requires caller Manage authority for both list and validate", ctx do
    agent = seed_candidate(ctx, "py")

    assert {:ok, []} =
             ReusableLlmAgent.list(ctx.stranger, ctx.workspace_uri, "py")

    assert {:error, :unauthorized} =
             ReusableLlmAgent.validate(ctx.stranger, ctx.workspace_uri, "py", agent)
  end

  test "accepts an agent without hello.llm recipe when flavor and credentials match", ctx do
    wrong_recipe = seed_candidate(ctx, "py", recipe: "other.recipe")
    wrong_flavor = seed_candidate(ctx, "codex", credential_status: :authenticated)

    assert {:ok, %{flavor: "py", credential_status: :n_a}} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "py", wrong_recipe)

    assert {:ok, candidates} = ReusableLlmAgent.list(ctx.owner, ctx.workspace_uri, "py")
    assert Enum.any?(candidates, &(&1.agent_uri == wrong_recipe))

    assert {:error, {:flavor_mismatch, "codex"}} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "py", wrong_flavor)
  end

  test "accepts any provider profile when the flavor and credentials match", ctx do
    wrong_curl =
      seed_candidate(ctx, "curl",
        credential_status: :authenticated,
        provider_profile: "kimi"
      )

    wrong_cc =
      seed_candidate(ctx, "cc-headless-custom",
        credential_status: :authenticated,
        provider_profile: "kimi"
      )

    assert {:ok, %{flavor: "curl", provider_profile: "kimi"}} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "curl", wrong_curl)

    assert {:ok, %{flavor: "cc-headless-custom", provider_profile: "kimi"}} =
             ReusableLlmAgent.validate(
               ctx.owner,
               ctx.workspace_uri,
               "cc-headless-custom",
               wrong_cc
             )
  end

  test "rejects stale and cross-workspace URIs without leaking them in list results", ctx do
    stale = Ezagent.URI.agent(ctx.ws_name, "stale-#{System.unique_integer([:positive])}")

    other_ws_name = "hello-reusable-other-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.create(other_ws_name, %{})

    other_ctx = %{
      ctx
      | workspace_uri: Ezagent.URI.workspace(other_ws_name),
        ws_name: other_ws_name
    }

    cross_workspace = seed_candidate(other_ctx, "py")

    assert {:error, :not_found} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "py", stale)

    assert {:error, :not_found} =
             ReusableLlmAgent.validate(ctx.owner, ctx.workspace_uri, "py", cross_workspace)

    assert {:ok, candidates} = ReusableLlmAgent.list(ctx.owner, ctx.workspace_uri, "py")
    refute Enum.any?(candidates, &(&1.agent_uri == cross_workspace))
  end

  test "rejects a canonical non-Agent URI with a typed error", ctx do
    wrong_kind = Ezagent.URI.system(:routing, :default)

    assert {:error, :invalid_agent_uri} =
             ReusableLlmAgent.validate(
               ctx.owner,
               ctx.workspace_uri,
               "py",
               wrong_kind
             )
  end

  test "rejects unsupported flavors before scanning candidate state", ctx do
    assert {:error, {:unsupported_flavor, "native"}} =
             ReusableLlmAgent.list(ctx.owner, ctx.workspace_uri, "native")

    assert {:error, {:unsupported_flavor, "native"}} =
             ReusableLlmAgent.validate(
               ctx.owner,
               ctx.workspace_uri,
               "native",
               Ezagent.URI.agent(ctx.ws_name, "irrelevant")
             )
  end

  defp seed_candidate(ctx, flavor, opts \\ []) do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.agent(ctx.ws_name, "#{flavor}-#{suffix}")
    recipe = Keyword.get(opts, :recipe, @hello_recipe)
    status = Keyword.get(opts, :credential_status, :authenticated)
    profile = Keyword.get(opts, :provider_profile, "deepseek")
    config_dir = Path.join(ctx.config_root, "#{flavor}-#{suffix}")
    File.mkdir_p!(config_dir)
    put_file_credentials(config_dir, flavor, status)

    sandbox = %{
      recipe: recipe,
      config_dir_path: config_dir,
      respawn_template_data: %{"flavor" => flavor, "provider" => profile}
    }

    state =
      %{sandbox: %{state: sandbox}}
      |> maybe_put_curl_state(flavor, profile, status)

    start_and_cold_stop_managed_agent(ctx.owner, agent_uri)

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(agent_uri, state,
               kind_type: :agent,
               version: 0,
               workspace_uri: URI.to_string(ctx.workspace_uri)
             )

    agent_uri
  end

  defp maybe_put_curl_state(state, "curl", profile, status) do
    keys = if status == :authenticated, do: %{profile => "test-only-key"}, else: %{}

    state
    |> Map.put(:curl_agent, %{state: %{flavor: "curl", provider: profile}})
    |> Map.put(:api_keys, %{state: %{keys: keys}})
  end

  defp maybe_put_curl_state(state, _flavor, _profile, _status), do: state

  defp put_file_credentials(config_dir, flavor, status)
       when flavor in ["cc", "cc-headless"] do
    path = Path.join(config_dir, ".credentials.json")
    now_ms = System.system_time(:millisecond)

    case status do
      :authenticated ->
        File.write!(
          path,
          Jason.encode!(%{"claudeAiOauth" => %{"expiresAt" => now_ms + 3_600_000}})
        )

      :expiring ->
        File.write!(
          path,
          Jason.encode!(%{"claudeAiOauth" => %{"expiresAt" => now_ms + 45_000}})
        )

      :expired ->
        File.write!(
          path,
          Jason.encode!(%{"claudeAiOauth" => %{"expiresAt" => now_ms - 3_600_000}})
        )

      :unknown ->
        File.write!(path, "not-json")

      :missing ->
        :ok
    end
  end

  defp put_file_credentials(config_dir, flavor, status)
       when flavor in ["codex", "codex-remote"] do
    path = Path.join(config_dir, "auth.json")

    case status do
      :authenticated ->
        File.write!(path, Jason.encode!(%{"tokens" => %{"access_token" => "test"}}))

      :unknown ->
        File.write!(path, "not-json")

      :missing ->
        :ok
    end
  end

  defp put_file_credentials(_config_dir, _flavor, _status), do: :ok

  defp confirmed_user(ws_name, prefix) do
    uri =
      Ezagent.URI.new!("entity://#{ws_name}/user/#{prefix}-#{System.unique_integer([:positive])}")

    {:ok, _} = Ezagent.Users.create(uri, "pw-not-secret", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp grant_manage(owner, agent_uri) do
    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        agent_uri,
        Capability.workspace_of(agent_uri),
        owner
      )

    assert :ok =
             Ezagent.Identity.Grant.grant_cap_via_router(
               owner,
               cap,
               {:admin, Ezagent.Entity.User.admin_uri()},
               :sync
             )
  end

  defp start_and_cold_stop_managed_agent(owner, agent_uri) do
    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: agent_uri,
               behaviors: Ezagent.Entity.Agent.base_behaviors(),
               initial_caps: MapSet.new()
             })

    assert :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, Capability.workspace_of(agent_uri))
    grant_manage(owner, agent_uri)
    assert {:ok, pid} = Ezagent.KindRegistry.lookup(agent_uri)
    assert :ok = DynamicSupervisor.terminate_child(Ezagent.Entity.Agent.supervisor(), pid)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(agent_uri) == :error end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
