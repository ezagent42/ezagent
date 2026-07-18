defmodule Ezagent.PluginCurlAgent.CurlCascadeActivationTest do
  use Ezagent.LifecycleCase, async: false

  alias Ezagent.Credential.{GrantCap, GrantRow, UserDefaultSource, WorkspaceSharedSource}
  alias Ezagent.Entity.Agent
  alias Ezagent.Invocation
  alias Ezagent.PluginCurlAgent.Template
  alias EzagentCore.Repo

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")
  @owner_uri Ezagent.URI.new!("entity://team-alpha/user/alice")

  setup do
    register_curl_dispatch()
    :ok
  end

  test "curl Template materializes the selected source provider key into the target api_keys slice" do
    source_uri = agent_uri("curl-source")
    target_uri = agent_uri("curl-target")

    spawn_curl_source!(source_uri, "deepseek", "sk-source-key")

    assert {:ok, _grant} =
             GrantRow.insert(%{
               agent_uri: URI.to_string(target_uri),
               credential_source_uri: URI.to_string(source_uri),
               approved_by: URI.to_string(@owner_uri),
               approved_scope: URI.to_string(source_uri),
               version: 1
             })

    assert {:ok, [^target_uri], %{fresh?: true}} =
             Template.instantiate(
               Template.template_name(),
               curl_template_data(target_uri, source_uri),
               @workspace_uri
             )

    wait_for(fn -> Ezagent.ReadyGate.status(target_uri) == :ready end)

    assert {:ok, %{keys: %{"deepseek" => "sk-source-key"}}} =
             Ezagent.Kind.get_slice(target_uri, :api_keys)

    Ezagent.Kind.terminate(source_uri)
    Ezagent.Kind.terminate(target_uri)
  end

  test "curl Template fails loud when the selected source lacks the provider key" do
    source_uri = agent_uri("curl-empty-source")
    target_uri = agent_uri("curl-target-missing")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: source_uri,
        behaviors: Ezagent.Entity.Agent.curl_behaviors()
      })

    wait_for(fn -> Ezagent.ReadyGate.status(source_uri) == :ready end)

    assert {:ok, _grant} =
             GrantRow.insert(%{
               agent_uri: URI.to_string(target_uri),
               credential_source_uri: URI.to_string(source_uri),
               approved_by: URI.to_string(@owner_uri),
               approved_scope: URI.to_string(source_uri),
               version: 1
             })

    assert {:error, {:cascade_api_key_missing, "deepseek", ^source_uri}} =
             Template.instantiate(
               Template.template_name(),
               curl_template_data(target_uri, source_uri),
               @workspace_uri
             )

    Ezagent.Kind.terminate(source_uri)
  end

  test "domain create chokepoint resolves workspace-shared curl source and materializes its key" do
    source_uri = agent_uri("curl-ws-shared-source")
    target_uri = agent_uri("curl-ws-shared-target")
    admin_uri = Ezagent.URI.new!("entity://team-alpha/user/admin")

    spawn_curl_source!(source_uri, "deepseek", "sk-workspace-key")

    assert {:ok, _row} =
             %{
               workspace_uri: URI.to_string(@workspace_uri),
               flavor: "curl",
               source_uri: URI.to_string(source_uri),
               set_by: URI.to_string(admin_uri)
             }
             |> WorkspaceSharedSource.changeset()
             |> Repo.insert()

    template_uri = Ezagent.URI.new!("template://team-alpha/agent/curl-worker")

    content = %{
      flavor: "curl",
      project_cwd: "/tmp/curl-cascade",
      provider: "deepseek",
      api_url: "https://api.deepseek.com/chat/completions",
      model: "deepseek-chat"
    }

    assert {:ok, %{workers: [^target_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, target_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: [],
               source_template_uri: template_uri
             )

    wait_for(fn -> Ezagent.ReadyGate.status(target_uri) == :ready end)

    assert {:ok, %{keys: %{"deepseek" => "sk-workspace-key"}}} =
             Ezagent.Kind.get_slice(target_uri, :api_keys)

    assert %GrantRow{} = row = GrantRow.get_for_agent(URI.to_string(target_uri))
    assert row.credential_source_uri == URI.to_string(source_uri)
    assert row.approved_by == URI.to_string(admin_uri)

    Ezagent.Kind.terminate(source_uri)
    Ezagent.Kind.terminate(target_uri)
  end

  test "domain create chokepoint prefers user curl source over workspace-shared source" do
    user_source_uri = agent_uri("curl-user-source")
    workspace_source_uri = agent_uri("curl-workspace-source")
    target_uri = agent_uri("curl-user-wins-target")
    admin_uri = Ezagent.URI.new!("entity://team-alpha/user/admin")

    spawn_curl_source!(user_source_uri, "deepseek", "sk-user-key")
    spawn_curl_source!(workspace_source_uri, "deepseek", "sk-workspace-key")

    assert {:ok, _row} =
             %{
               owner_uri: URI.to_string(@owner_uri),
               workspace_uri: "team-alpha",
               flavor: "curl",
               source_uri: URI.to_string(user_source_uri)
             }
             |> UserDefaultSource.changeset(URI.to_string(@owner_uri))
             |> Repo.insert()

    assert {:ok, _row} =
             %{
               workspace_uri: URI.to_string(@workspace_uri),
               flavor: "curl",
               source_uri: URI.to_string(workspace_source_uri),
               set_by: URI.to_string(admin_uri)
             }
             |> WorkspaceSharedSource.changeset()
             |> Repo.insert()

    content = %{
      flavor: "curl",
      project_cwd: "/tmp/curl-cascade",
      provider: "deepseek",
      api_url: "https://api.deepseek.com/chat/completions",
      model: "deepseek-chat"
    }

    assert {:ok, %{workers: [^target_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, target_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: [GrantCap.read_cap_for(user_source_uri)],
               source_template_uri: Ezagent.URI.new!("template://team-alpha/agent/curl-worker")
             )

    wait_for(fn -> Ezagent.ReadyGate.status(target_uri) == :ready end)

    assert {:ok, %{keys: %{"deepseek" => "sk-user-key"}}} =
             Ezagent.Kind.get_slice(target_uri, :api_keys)

    assert %GrantRow{} = row = GrantRow.get_for_agent(URI.to_string(target_uri))
    assert row.credential_source_uri == URI.to_string(user_source_uri)
    assert row.approved_by == URI.to_string(@owner_uri)

    Ezagent.Kind.terminate(user_source_uri)
    Ezagent.Kind.terminate(workspace_source_uri)
    Ezagent.Kind.terminate(target_uri)
  end

  # PR-6+7 (curl-as-flavor) — curl actions register on the UNIFIED
  # `Ezagent.Entity.Agent` Kind (the standalone curl Kind is deleted).
  defp register_curl_dispatch do
    for action <- Ezagent.ActionSet.CurlAgent.actions() do
      :ok =
        Ezagent.BehaviorRegistry.register(
          Ezagent.Entity.Agent,
          action,
          Ezagent.ActionSet.CurlAgent
        )
    end

    for action <- Ezagent.ActionSet.ApiKeys.actions() do
      :ok =
        Ezagent.BehaviorRegistry.register(
          Ezagent.Entity.Agent,
          action,
          Ezagent.ActionSet.ApiKeys
        )
    end
  end

  # PR-6+7 — a curl source agent is a unified `Entity.Agent` with the curl
  # per-instance behavior set (so its `:curl_agent` + `:api_keys` slices
  # materialize), the same shape the `curl.agent` Template spawns.
  defp spawn_curl_source!(source_uri, provider, key) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: source_uri,
        behaviors: Ezagent.Entity.Agent.curl_behaviors()
      })

    wait_for(fn -> Ezagent.ReadyGate.status(source_uri) == :ready end)

    target = Ezagent.URI.with_action(source_uri, :api_keys, :put_api_key)
    presenter = Ezagent.Entity.User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, presenter)

    assert {:ok, %{ok: true, provider: ^provider}} =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: target,
               mode: :call,
               args: %{provider: provider, key: key},
               ctx: %{
                 caller: presenter,
                 caps: MapSet.new([cap]),
                 reply: {:caller_inbox, self()}
               }
             })

    source_uri
  end

  defp curl_template_data(target_uri, source_uri) do
    %{
      "class" => "curl.agent",
      "agent_uri" => URI.to_string(target_uri),
      "provider" => "deepseek",
      "api_url" => "https://api.deepseek.com/chat/completions",
      "model" => "deepseek-chat",
      "cascade_resolution" => %{
        "owner_uri" => URI.to_string(@owner_uri),
        "workspace_uri" => URI.to_string(@workspace_uri),
        "credential_source_uri" => URI.to_string(source_uri)
      }
    }
  end

  defp agent_uri(suffix) do
    Ezagent.URI.agent("team-alpha", "#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
