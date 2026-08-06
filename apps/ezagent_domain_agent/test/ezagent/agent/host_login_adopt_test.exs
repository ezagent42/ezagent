defmodule Ezagent.Agent.HostLoginAdoptTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.HostLoginAdopt
  alias Ezagent.Credential.UserDefaultSource
  alias Ezagent.Entity.User

  test "registered host login resolves its flavor through the durable sandbox contract" do
    unique = System.unique_integer([:positive])
    workspace_name = "host-login-#{unique}"
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    host_dir = Path.join(System.tmp_dir!(), "ezagent-host-login-#{unique}")
    source_uri = HostLoginAdopt.host_login_source_uri(workspace_name, "cc")

    File.mkdir_p!(host_dir)
    File.write!(Path.join(host_dir, ".credentials.json"), ~s({"accessToken":"test"}))

    previous_config_dir = System.get_env("CLAUDE_CONFIG_DIR")
    System.put_env("CLAUDE_CONFIG_DIR", host_dir)

    on_exit(fn ->
      restore_env("CLAUDE_CONFIG_DIR", previous_config_dir)
      File.rm_rf!(host_dir)
      terminate(source_uri)
    end)

    admin_uri = User.admin_uri()
    ensure_admin_started(admin_uri)

    assert :ok = HostLoginAdopt.ensure_installer_source(admin_uri, workspace_uri, "cc")

    assert {:ok, %{state: state}} = Ezagent.SnapshotStore.latest(source_uri)

    sandbox =
      state
      |> Map.fetch!(:sandbox)
      |> Ezagent.Kind.normalize_slice_view()

    assert sandbox.respawn_template_data == %{"flavor" => "cc"}
    refute Map.has_key?(sandbox, :flavor)
    assert {:ok, "cc"} = Ezagent.AgentFlavorResolver.resolve_flavor_from_sandbox(sandbox)

    # Simulate the cold path: adoption starts the source and primes the volatile
    # flavor attribute/live sandbox, which would otherwise hide a malformed
    # durable sandbox.
    :ok = Ezagent.Kind.terminate(source_uri)
    :ok = Ezagent.AgentFlavorAttributes.delete(source_uri)

    assert {:ok, "cc"} = Ezagent.UriQuery.resolve(:flavor, source_uri)
  end

  test "a concurrent authorized source choice wins over host-login adoption" do
    unique = System.unique_integer([:positive])
    workspace_name = "host-login-race-#{unique}"
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    host_dir = Path.join(System.tmp_dir!(), "ezagent-host-login-race-#{unique}")
    host_source = HostLoginAdopt.host_login_source_uri(workspace_name, "cc")
    external_source = Ezagent.URI.agent(workspace_name, "world-selected-source")
    admin_uri = User.admin_uri()

    File.mkdir_p!(host_dir)
    File.write!(Path.join(host_dir, ".credentials.json"), ~s({"accessToken":"test"}))

    previous_config_dir = System.get_env("CLAUDE_CONFIG_DIR")
    System.put_env("CLAUDE_CONFIG_DIR", host_dir)

    on_exit(fn ->
      restore_env("CLAUDE_CONFIG_DIR", previous_config_dir)
      File.rm_rf!(host_dir)
      terminate(host_source)
      terminate(external_source)
    end)

    ensure_admin_started(admin_uri)
    register_credential_source(external_source, admin_uri, "cc")
    external_write_ctx = default_source_write_ctx(admin_uri)

    previous_fault =
      Application.get_env(:ezagent_domain_agent, :host_login_adopt_before_pointer_write_fault)

    Application.put_env(
      :ezagent_domain_agent,
      :host_login_adopt_before_pointer_write_fault,
      fn ->
        assert {:ok, _} =
                 UserDefaultSource.set_via_dispatch(
                   admin_uri,
                   %{
                     flavor: "cc",
                     source_uri: URI.to_string(external_source),
                     workspace: workspace_name
                   },
                   external_write_ctx
                 )

        :ok
      end
    )

    on_exit(fn ->
      if is_nil(previous_fault) do
        Application.delete_env(
          :ezagent_domain_agent,
          :host_login_adopt_before_pointer_write_fault
        )
      else
        Application.put_env(
          :ezagent_domain_agent,
          :host_login_adopt_before_pointer_write_fault,
          previous_fault
        )
      end
    end)

    assert :ok = HostLoginAdopt.ensure_installer_source(admin_uri, workspace_uri, "cc")

    assert UserDefaultSource.resolve(URI.to_string(admin_uri), workspace_name, "cc") ==
             URI.to_string(external_source)
  end

  defp register_credential_source(source_uri, owner_uri, flavor) do
    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               URI.to_string(source_uri),
               %{
                 sandbox: %{
                   state: %{
                     config_dir_path: nil,
                     template_class: nil,
                     respawn_template_data: %{"flavor" => flavor},
                     pty_phase: nil,
                     passive: true,
                     recipe: nil
                   }
                 }
               },
               kind_type: :agent,
               version: 0
             )

    :ok = Ezagent.AgentLineage.record(source_uri, owner_uri)
  end

  defp default_source_write_ctx(owner_uri) do
    target =
      Ezagent.URI.with_action(
        owner_uri,
        :user_default_credential_source,
        :set_default_credential_source
      )

    assert {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, owner_uri}, owner_uri, target)

    %{
      caller: owner_uri,
      authenticated_principal: owner_uri,
      caps: MapSet.new([cap])
    }
  end

  defp ensure_admin_started(admin_uri) do
    case Ezagent.Kind.spawn(User, %{
           uri: admin_uri,
           initial_caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp terminate(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)

      :error ->
        :ok
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
