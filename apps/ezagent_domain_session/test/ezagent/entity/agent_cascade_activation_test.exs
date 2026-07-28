defmodule Ezagent.Entity.AgentCascadeActivationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Credential.{GrantCap, GrantRow, WorkspaceSharedSource}
  alias Ezagent.Entity.Agent
  alias EzagentCore.Repo
  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3]

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
      uri = Ezagent.URI.new!(data["agent_uri"])

      # Represent a GENUINE fresh spawn: create the live Entity.Agent Kind so the
      # post-spawn obligations run against a real worker. `fresh?: false` (adopt)
      # is now correctly rejected as `:agent_uri_already_live` by
      # `spawn_from_template_content` (#1570 reject-double-spawn contract), so a
      # capture-only fake that never spawns must report the fresh spawn it stands in for.
      case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors()
           }) do
        {:ok, :started, _pid, %{created?: created?}} ->
          {:ok, [uri], %{fresh?: true, created?: created?}}

        {:ok, :already_started, _pid, _receipt} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
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

  defp authorized_source_ctx do
    caller = Ezagent.URI.new!("entity://team-alpha/user/cascade-owner-#{uniq()}")
    {:ok, _} = Ezagent.Users.create(caller, "pw-not-secret", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)
    {:ok, authority} = Ezagent.Cap.Authority.open(@source_uri, :agent)
    cap = authority_signed_cap!(authority, caller, GrantCap.read_cap_for(@source_uri))
    on_exit(fn -> Ezagent.Kind.terminate(caller) end)
    {caller, [cap]}
  end

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

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
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

  # #201 defer-writes — the domain RESOLVES + AUTHORIZES the credential source
  # into a plain-data pending-grant descriptor and threads it to the Template
  # Class, but does NOT itself MINT: the durable grant is minted ONLY by the
  # created-winner arm inside the plugin (`GrantMint.mint/3`, after the `:started
  # ∧ created?` receipt). `CaptureTemplate` is a capture-only fake with no such
  # arm, so it correctly mints nothing. (A REAL plugin does mint from this exact
  # descriptor — proven by `curl_cascade_activation_test`.)
  test "spawn_from_template_content authorizes the credential source into a pending-grant descriptor but does NOT speculatively mint" do
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
    {caller, caps} = authorized_source_ctx()

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: caller,
               authenticated_principal: caller,
               caps: caps
             )

    # The domain DID resolve + authorize the source: a pending-grant descriptor
    # (source + approver) was threaded to the Template Class — the plain data a
    # real plugin's created-winner arm mints from.
    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})

    assert %{kind: :authorized, source: source, approved_by: approved_by} =
             data["cascade"][:pending_grant]

    assert Ezagent.URI.stable_key(source) == Ezagent.URI.stable_key(@source_uri)
    assert Ezagent.URI.stable_key(approved_by) == Ezagent.URI.stable_key(caller)

    # TEETH: NO durable grant was minted by the domain — minting is confined to
    # the plugin created-winner arm, which `CaptureTemplate` does not have. This
    # FAILS if the domain ever speculatively mints again.
    refute GrantRow.get_for_agent(URI.to_string(agent_uri)),
           "the domain must NOT speculatively mint; the grant is deferred to the created-winner arm"
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
    {caller, caps} = authorized_source_ctx()

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, agent_uri, caller, @workspace_uri,
               caller: caller,
               authenticated_principal: caller,
               caps: caps,
               source_template_uri: template_uri,
               explicit_source: @source_uri
             )

    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    assert [%{dir: "/tmp/workspace-default"}] = data["cascade"].layer_dirs
    assert {:ok, "/tmp/source-default"} = data["cascade"].source_dir_for.(@source_uri)

    # #201 defer-writes — the default cascade also resolves + authorizes the
    # source into a pending-grant descriptor threaded to the Template Class, but
    # the domain does NOT itself mint (deferred to the created-winner plugin arm).
    assert %{kind: :authorized, source: source} = data["cascade"][:pending_grant]
    assert Ezagent.URI.stable_key(source) == Ezagent.URI.stable_key(@source_uri)

    # TEETH: no speculative domain mint (`CaptureTemplate` has no created-winner arm).
    refute GrantRow.get_for_agent(URI.to_string(agent_uri)),
           "the domain must NOT speculatively mint; the grant is deferred to the created-winner arm"
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

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               authenticated_principal: @owner_uri,
               caps: [],
               source_template_uri: template_uri
             )

    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    refute Map.has_key?(data, "cascade")
    refute GrantRow.get_for_agent(URI.to_string(agent_uri))
  end

  # #201 defer-writes — the no-cap workspace-shared fallback: the domain resolves
  # the shared source into a `:workspace_shared` pending-grant descriptor (its
  # `set_by` approver is re-resolved at mint time), but does NOT itself mint.
  # `CaptureTemplate` has no created-winner arm, so no grant is minted here; a
  # real plugin mints the member grant from this descriptor.
  test "workspace-shared approval resolves a member-grant descriptor when caller lacks source read cap, without speculatively minting" do
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

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, agent_uri, @owner_uri, @workspace_uri,
               caller: @owner_uri,
               authenticated_principal: @owner_uri,
               caps: [],
               source_template_uri: template_uri
             )

    # The domain resolved the shared source into a `:workspace_shared` descriptor
    # (the approver is re-resolved from the shared registration's `set_by` at MINT
    # time inside the plugin), threaded to the Template Class.
    assert %{} = data = Process.get({CaptureTemplate, :received_template_data})
    assert %{kind: :workspace_shared, source: source} = data["cascade"][:pending_grant]
    assert Ezagent.URI.stable_key(source) == Ezagent.URI.stable_key(@source_uri)

    # TEETH: no speculative domain mint (`CaptureTemplate` has no created-winner arm).
    refute GrantRow.get_for_agent(URI.to_string(agent_uri)),
           "the domain must NOT speculatively mint the member grant; it is deferred to the created-winner arm"
  end

  defmodule FailingInstantiateTemplate do
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "cascade.failing"

    @impl Ezagent.Kind.Template
    def validate(_), do: :ok

    # Instantiate FAILS immediately. Under #201 defer-writes the durable grant is
    # minted ONLY by a created-winner plugin arm (which this fake does not
    # implement) — the domain builds only a pending-grant descriptor and never
    # mints — so no grant is minted upstream. These tests therefore assert the
    # DOMAIN-level invariants: an instantiate failure leaves NO grant, and never
    # deletes a PRE-EXISTING one. (The mint+compensation round-trip itself is a
    # plugin concern, covered by the flavor cascade-materialize tests.)
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

  test "a spawn whose Template Class fails at instantiate leaves NO grant (no speculative domain mint, codex r5)" do
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
    {caller, caps} = authorized_source_ctx()

    # The spawn fails at instantiate (before any created-winner mint arm runs).
    assert {:error, :boom_after_grant} =
             Agent.spawn_from_template_content(content, agent_uri, caller, @workspace_uri,
               caller: caller,
               authenticated_principal: caller,
               caps: caps
             )

    # TEETH: no grant exists — the domain never speculatively minted (and this
    # fake never reached a created-winner mint arm), so a retry's GrantRow.insert
    # won't conflict. FAILS if the domain speculatively mints again.
    refute GrantRow.get_for_agent(URI.to_string(agent_uri)),
           "a failed spawn must leave no credential grant (no speculative domain mint)"

    assert :none = Ezagent.AgentFlavorAttributes.get(agent_uri),
           "a failed spawn must not leave a cross-candidate flavor attribute"
  end

  test "a losing spawn (Template Class instantiate fails) does NOT delete a PRE-EXISTING grant for the same agent_uri (codex r6)" do
    flavor = "cascade_conflict_#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FailingInstantiateTemplate
      })

    {:ok, _} = Ezagent.SnapshotStore.write(URI.to_string(@source_uri), %{}, kind_type: :agent)

    agent_uri = Ezagent.URI.agent("team-alpha", "cascade-conflict-#{uniq()}")

    # A PRE-EXISTING grant for this agent_uri (e.g. a concurrent winner already
    # minted it via its created-winner arm).
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

    {caller, caps} = authorized_source_ctx()

    # The LOSER's spawn fails (its Template Class instantiate errors). Its
    # failure/rollback must key off ITS OWN mint receipt only (nil here — it
    # minted nothing) and must NOT touch the pre-existing grant.
    assert {:error, _} =
             Agent.spawn_from_template_content(content, agent_uri, caller, @workspace_uri,
               caller: caller,
               authenticated_principal: caller,
               caps: caps
             )

    # TEETH: the pre-existing grant SURVIVES the loser's failed spawn — the loser
    # never owned it. FAILS if a losing spawn deletes a grant it did not mint.
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
    {caller, caps} = authorized_source_ctx()

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             Agent.spawn_from_template_content(content, agent_uri, caller, @workspace_uri,
               caller: caller,
               authenticated_principal: caller,
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
