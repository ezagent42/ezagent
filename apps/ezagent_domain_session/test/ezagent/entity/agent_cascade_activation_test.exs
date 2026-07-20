defmodule Ezagent.Entity.AgentCascadeActivationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Credential.{GrantCap, GrantRow, WorkspaceSharedSource}
  alias Ezagent.Entity.Agent
  alias EzagentCore.Repo

  defmodule CaptureTemplate do
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "cascade.capture"

    # Same convention as the other spawn tests (support/fake_cc_custom_template):
    # the registered "cc-agents" fs type lets a config_dir-carrying content
    # allocate its per-agent target in the F2 self-resolution test.
    @impl Ezagent.Kind.Template
    def config_dir_namespace, do: "cc"

    @impl Ezagent.Kind.Template
    def validate(%{"class" => "cascade.capture", "agent_uri" => agent_uri, "cwd" => cwd})
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_capture_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      Process.put({__MODULE__, :received_template_data}, data)
      {:ok, [Ezagent.URI.new!(data["agent_uri"])], %{fresh?: false}}
    end

    @behaviour Ezagent.Agent.CredentialAdapter

    @impl Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "CAPTURE_HOME"

    @impl Ezagent.Agent.CredentialAdapter
    def credential_relpaths, do: ["token.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def secret_relpaths, do: ["token.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def auth_failure_signals, do: ["capture auth failed"]
  end

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")
  @owner_uri Ezagent.URI.new!("entity://team-alpha/user/alice")
  @source_uri Ezagent.URI.new!("entity://team-alpha/agent/alice-source")

  defp uniq, do: System.unique_integer([:positive])

  test "spawn_from_template_content resolves cascade inputs before invoking the Template Class" do
    flavor = "cascade_capture_#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: CaptureTemplate
      })

    workspace_layer = %{
      dir: "/tmp/workspace-layer",
      protected: ["hooks/policy.sh"],
      mandatory: []
    }

    user_layer = %{dir: "/tmp/user-layer", protected: [], mandatory: []}

    content = %{
      flavor: flavor,
      project_cwd: "/tmp/project",
      cascade_resolution: %{
        owner_uri: @owner_uri,
        workspace_uri: @workspace_uri,
        credential_required?: false,
        layer_dir_for: fn
          %{layer: :workspace, source: @workspace_uri} -> {:ok, workspace_layer}
          %{layer: :user, source: @owner_uri} -> {:ok, user_layer}
          _other -> :skip
        end,
        source_dir_for: fn _source_uri -> {:error, :not_used_in_this_test} end
      }
    }

    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-capture-#{uniq()}")

    assert {:ok, %{workers: [^agent_uri], fresh?: false}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri)

    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    assert %{} = cascade = data["cascade"]
    assert cascade.layer_dirs == [workspace_layer, user_layer]
    assert is_function(cascade.source_dir_for, 1)
  end

  test "respawn_template_data keeps cascade resolution inputs, not runtime cascade functions" do
    respawn_data = %{
      "cwd" => "/tmp/project",
      "cascade" => %{
        layer_dirs: [%{dir: "/tmp/workspace-layer", protected: [], mandatory: []}],
        source_dir_for: fn _ -> {:ok, "/tmp/source"} end
      }
    }

    template_content = %{
      cascade_resolution: %{
        owner_uri: @owner_uri,
        workspace_uri: @workspace_uri,
        credential_source_uri: URI.new!("entity://team-alpha/agent/alice-source"),
        layer_dir_for: fn _ -> :skip end,
        source_dir_for: fn _ -> {:ok, "/tmp/source"} end
      }
    }

    sanitized = Agent.sanitize_respawn_template_data(respawn_data, template_content)

    refute Map.has_key?(sanitized, "cascade")

    assert sanitized["cascade_resolution"] == %{
             "owner_uri" => URI.to_string(@owner_uri),
             "workspace_uri" => URI.to_string(@workspace_uri),
             "credential_source_uri" => "entity://team-alpha/agent/alice-source"
           }
  end

  test "spawn_from_template_content mints a grant for the resolved credential source" do
    flavor = "cascade_grant_#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: CaptureTemplate
      })

    {:ok, _} = Ezagent.SnapshotStore.write(URI.to_string(@source_uri), %{}, kind_type: :agent)

    content = %{
      flavor: flavor,
      project_cwd: "/tmp/project",
      cascade_resolution: %{
        owner_uri: @owner_uri,
        workspace_uri: @workspace_uri,
        explicit_source: @source_uri,
        layer_dir_for: fn _ -> :skip end,
        source_dir_for: fn _source_uri -> {:ok, "/tmp/source"} end
      }
    }

    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-grant-#{uniq()}")
    caller = @owner_uri
    caps = [GrantCap.read_cap_for(@source_uri)]

    assert {:ok, %{workers: [^agent_uri], fresh?: false}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: caller,
               caps: caps
             )

    assert %GrantRow{} = row = GrantRow.get_for_agent(URI.to_string(agent_uri))
    assert row.credential_source_uri == URI.to_string(@source_uri)
    assert row.approved_by == URI.to_string(caller)
  end

  test "spawn_from_template_content builds default cascade inputs from source_template_uri" do
    flavor = "cascade_default_#{uniq()}"
    template_uri = URI.new!("template://team-alpha/agent/ws-capture")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: CaptureTemplate
      })

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               template_uri,
               %{template: %{state: %{content: %{config_dir: "/tmp/workspace-default"}}}},
               kind_type: :agent_template
             )

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               @source_uri,
               %{sandbox: %{state: %{config_dir_path: "/tmp/source-default"}}},
               kind_type: :agent
             )

    content = %{flavor: flavor, project_cwd: "/tmp/project"}
    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-default-#{uniq()}")
    caps = [GrantCap.read_cap_for(@source_uri)]

    assert {:ok, %{workers: [^agent_uri], fresh?: false}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: caps,
               source_template_uri: template_uri,
               explicit_source: @source_uri
             )

    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    assert [%{dir: "/tmp/workspace-default"}] = data["cascade"].layer_dirs
    assert {:ok, "/tmp/source-default"} = data["cascade"].source_dir_for.(@source_uri)
    assert %GrantRow{} = GrantRow.get_for_agent(URI.to_string(agent_uri))
  end

  test "default cascade is skipped for legacy source templates without config_dir" do
    flavor = "cascade_legacy_#{uniq()}"
    template_uri = URI.new!("template://team-alpha/agent/legacy-capture")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: CaptureTemplate
      })

    content = %{flavor: flavor, project_cwd: "/tmp/project"}
    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-legacy-#{uniq()}")

    assert {:ok, %{workers: [^agent_uri], fresh?: false}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: [],
               source_template_uri: template_uri
             )

    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    refute Map.has_key?(data, "cascade")
    refute GrantRow.get_for_agent(URI.to_string(agent_uri))
  end

  test "workspace-shared approval mints a member grant when caller lacks source read cap" do
    flavor = "cascade_ws_shared_#{uniq()}"
    template_uri = URI.new!("template://team-alpha/agent/ws-capture")
    admin_uri = URI.new!("entity://team-alpha/user/admin")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: CaptureTemplate
      })

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               template_uri,
               %{template: %{state: %{content: %{config_dir: "/tmp/workspace-shared"}}}},
               kind_type: :agent_template
             )

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               @source_uri,
               %{sandbox: %{state: %{config_dir_path: "/tmp/workspace-shared-source"}}},
               kind_type: :agent
             )

    assert {:ok, _row} =
             %{
               workspace_uri: URI.to_string(@workspace_uri),
               flavor: flavor,
               source_uri: URI.to_string(@source_uri),
               set_by: URI.to_string(admin_uri)
             }
             |> WorkspaceSharedSource.changeset()
             |> Repo.insert()

    content = %{flavor: flavor, project_cwd: "/tmp/project"}
    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-ws-shared-#{uniq()}")

    assert {:ok, %{workers: [^agent_uri], fresh?: false}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: [],
               source_template_uri: template_uri
             )

    assert %GrantRow{} = row = GrantRow.get_for_agent(URI.to_string(agent_uri))
    assert row.credential_source_uri == URI.to_string(@source_uri)
    assert row.approved_by == URI.to_string(admin_uri)
  end

  defmodule FailingInstantiateTemplate do
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "cascade.failing"

    @impl Ezagent.Kind.Template
    def validate(_), do: :ok

    # Fail AFTER the cascade grant has already been minted upstream, so the
    # compensating grant-delete is exercised.
    @impl Ezagent.Kind.Template
    def instantiate(_name, _data, _workspace_uri), do: {:error, :boom_after_grant}

    @behaviour Ezagent.Agent.CredentialAdapter
    @impl Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "CAPTURE_HOME"
    @impl Ezagent.Agent.CredentialAdapter
    def credential_relpaths, do: ["token.json"]
    @impl Ezagent.Agent.CredentialAdapter
    def secret_relpaths, do: ["token.json"]
    @impl Ezagent.Agent.CredentialAdapter
    def auth_failure_signals, do: ["capture auth failed"]
  end

  test "a spawn that mints a grant then fails at instantiate leaves NO orphaned grant (codex r5)" do
    flavor = "cascade_orphan_#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FailingInstantiateTemplate
      })

    {:ok, _} = Ezagent.SnapshotStore.write(URI.to_string(@source_uri), %{}, kind_type: :agent)

    content = %{
      flavor: flavor,
      project_cwd: "/tmp/project",
      cascade_resolution: %{
        owner_uri: @owner_uri,
        workspace_uri: @workspace_uri,
        explicit_source: @source_uri,
        layer_dir_for: fn _ -> :skip end,
        source_dir_for: fn _ -> {:ok, "/tmp/source"} end
      }
    }

    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-orphan-#{uniq()}")
    caps = [GrantCap.read_cap_for(@source_uri)]

    # The spawn fails at instantiate (AFTER the grant was minted).
    assert {:error, :boom_after_grant} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: caps
             )

    # The compensating cleanup HARD-deleted the grant — no orphan, so a retry's
    # GrantRow.insert won't conflict.
    refute GrantRow.get_for_agent(URI.to_string(agent_uri)),
           "a failed spawn must leave no orphaned credential grant"

    assert :none = Ezagent.AgentFlavorAttributes.get(agent_uri),
           "a failed spawn must not leave a cross-candidate flavor attribute"
  end

  test "a mint-conflict (concurrent duplicate) does NOT delete the winner's existing grant (codex r6)" do
    flavor = "cascade_conflict_#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FailingInstantiateTemplate
      })

    {:ok, _} = Ezagent.SnapshotStore.write(URI.to_string(@source_uri), %{}, kind_type: :agent)

    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-conflict-#{uniq()}")

    # Simulate the WINNER having already minted the grant for this agent_uri.
    {:ok, _winner} =
      GrantRow.insert(%{
        agent_uri: URI.to_string(agent_uri),
        credential_source_uri: URI.to_string(@source_uri),
        approved_by: URI.to_string(@owner_uri),
        approved_scope: URI.to_string(@source_uri),
        version: 1
      })

    content = %{
      flavor: flavor,
      project_cwd: "/tmp/project",
      cascade_resolution: %{
        owner_uri: @owner_uri,
        workspace_uri: @workspace_uri,
        explicit_source: @source_uri,
        layer_dir_for: fn _ -> :skip end,
        source_dir_for: fn _ -> {:ok, "/tmp/source"} end
      }
    }

    caps = [GrantCap.read_cap_for(@source_uri)]

    # The LOSER's spawn: its grant mint conflicts on the unique agent_uri (the
    # winner already inserted), so resolve_cascade_content fails BEFORE
    # spawn_after_cascade — the loser must NOT delete the winner's grant.
    assert {:error, _} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: caps
             )

    # The winner's grant survives the loser's failed spawn.
    assert %GrantRow{approved_by: approved_by} = GrantRow.get_for_agent(URI.to_string(agent_uri))
    assert approved_by == URI.to_string(@owner_uri)
  end

  test "rehydrate_respawn_data re-resolves layer dirs from durable URI inputs" do
    template_uri = URI.new!("template://team-alpha/agent/ws-cc")
    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-restart-#{uniq()}")

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               template_uri,
               %{template: %{state: %{content: %{config_dir: "/tmp/workspace-v2"}}}},
               kind_type: :agent_template
             )

    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               @source_uri,
               %{sandbox: %{state: %{config_dir_path: "/tmp/source-v2"}}},
               kind_type: :agent
             )

    respawn_data = %{
      "cwd" => "/tmp/project",
      "cascade" => %{
        layer_dirs: [%{dir: "/tmp/workspace-v1", protected: [], mandatory: []}]
      },
      "cascade_resolution" => %{
        "owner_uri" => URI.to_string(@owner_uri),
        "workspace_uri" => URI.to_string(@workspace_uri),
        "workspace_layer_uri" => URI.to_string(template_uri),
        "credential_source_uri" => URI.to_string(@source_uri)
      },
      "flavor" => "cc"
    }

    assert {:ok, rehydrated} =
             Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data(agent_uri, respawn_data)

    assert [%{dir: "/tmp/workspace-v2"}] = rehydrated["cascade"].layer_dirs
    assert {:ok, "/tmp/source-v2"} = rehydrated["cascade"].source_dir_for.(@source_uri)
  end

  test "F2/#1460 — a source template resolved from INSIDE its own dispatch is served from in-hand content, never a self-call" do
    flavor = "cascade_self_#{uniq()}"
    template_uri = URI.new!("template://team-alpha/agent/self-capture-#{uniq()}")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: CaptureTemplate
      })

    # `template.instantiate` runs IN-PROCESS in the template Kind's own
    # dispatch (Behavior.Template.handle_instantiate — it never dispatches
    # :read back to itself). Simulate that: the source template URI is owned
    # by THIS process, so the default UriQuery → Kind.get_slice resolution of
    # the workspace layer would self-GenServer.call and exit
    # {:calling_self} — the F2 crash (`{:cascade_layer_dir_failed, ...,
    # {:get_slice_exit, {:calling_self, ...}}}`). The fix serves a
    # self-referencing layer from the in-hand content's own config_dir.
    :ok = Ezagent.KindRegistry.put_new(template_uri)

    # A credential source keeps the resolved cascade IN the content (a
    # source-less spawn legitimately drops it after layer resolution — the
    # config home then materializes via the single-reference path), letting
    # us assert the self layer was served from in-hand content.
    assert {:ok, _} =
             Ezagent.SnapshotStore.write(
               @source_uri,
               %{sandbox: %{state: %{config_dir_path: "/tmp/source-default"}}},
               kind_type: :agent
             )

    content = %{flavor: flavor, project_cwd: "/tmp/project", config_dir: "/tmp/self-home"}
    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-self-#{uniq()}")
    caps = [GrantCap.read_cap_for(@source_uri)]

    assert {:ok, %{workers: [^agent_uri], fresh?: false}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               caps: caps,
               source_template_uri: template_uri,
               explicit_source: @source_uri
             )

    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    assert [%{dir: "/tmp/self-home"}] = data["cascade"].layer_dirs
    # Non-self sources still flow through the default UriQuery/snapshot path.
    assert {:ok, "/tmp/source-default"} = data["cascade"].source_dir_for.(@source_uri)
  end
end
