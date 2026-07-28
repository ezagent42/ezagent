defmodule Ezagent.Entity.AgentTemplateSpawnCredentialRaceTest do
  @moduledoc """
  #201-cred — spawn-path regression tests for codex re-review findings 1
  and 3:

    * F1 (HIGH) — a duplicate-create-with-source whose provisioning RAISES
      must leave NO durable grant (pre-fix the grant was minted BEFORE the
      creation receipt and the `{:raised, ...}` arm reraised without
      compensating — the cold pre-existing agent kept the duplicate's grant).
      The deferred mint dissolves this: the mint happens only at the
      created-winner's materialization boundary, after the receipt.
    * F3 (HIGH) — fresh-spawn rollback must NEVER fall back to a URI-wide
      grant delete: a concurrent reapproval (G2) landing during rollback
      survives; only the exact receipt incarnation would be compensated.

  Both tests fail on the pre-#201-cred branch tip.
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3]

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Credential.{GrantCap, GrantRow}
  alias Ezagent.Entity.Agent.TemplateSpawn

  # A working capture Template Class (no credential adapter): spawns the
  # unified Agent Kind through the #201 spawn receipt.
  defmodule RaceWorkingTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.race_working_agent"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))

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
  end

  # F1 — a credential-carrying Template Class whose instantiate RAISES (the
  # codex trigger: provision_and_instantiate raises after the pre-fix mint).
  defmodule RaceRaisingTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.race_raising_agent"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, _data, _workspace_uri) do
      raise "provision exploded"
    end

    @behaviour Ezagent.Agent.CredentialAdapter

    @impl Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "RACE_RAISING_HOME"

    @impl Ezagent.Agent.CredentialAdapter
    def credential_relpaths, do: ["token.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def secret_relpaths, do: ["token.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def auth_failure_signals, do: ["race raising auth failed"]
  end

  # F3 — a Template Class that mints its own grant G1 mid-instantiate but (as
  # a pre-#201-cred writer) returns NO incarnation receipt in its meta.
  defmodule RaceSelfMintingTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.race_self_minting_agent"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
      workspace = Ezagent.URI.workspace_name!(agent_uri)
      source_uri = Ezagent.URI.agent(workspace, "race-self-source")

      case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, %{
             uri: agent_uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors()
           }) do
        {:ok, :started, _pid, %{created?: true}} ->
          {:ok, _g1} =
            GrantRow.insert(%{
              agent_uri: URI.to_string(agent_uri),
              credential_source_uri: URI.to_string(source_uri),
              approved_by: URI.to_string(Ezagent.Entity.User.admin_uri()),
              approved_scope: URI.to_string(source_uri),
              version: 1
            })

          # NOTE: deliberately NO :grant_incarnation_id receipt — the pre-fix
          # writer shape the URI-delete fallback pretended to cover.
          {:ok, [agent_uri], %{fresh?: true, created?: true}}

        {:ok, :started, _pid, %{created?: false}} ->
          {:ok, [agent_uri], %{fresh?: true, created?: false}}

        {:ok, :already_started, _pid, _receipt} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    unique = System.unique_integer([:positive])
    workspace_name = "cred-race-#{unique}"

    %{
      unique: unique,
      workspace_name: workspace_name,
      workspace_uri: Ezagent.URI.workspace(workspace_name),
      owner_uri: Ezagent.URI.user(workspace_name, "owner"),
      agent_uri: Ezagent.URI.agent(workspace_name, "raced-#{unique}")
    }
  end

  defp uniq, do: System.unique_integer([:positive])

  defp register(flavor, template_class) do
    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: template_class
      })

    flavor
  end

  defp authorized_source(workspace_name, label) do
    source_uri = Ezagent.URI.agent(workspace_name, "source-#{label}-#{uniq()}")
    {:ok, _} = Ezagent.SnapshotStore.write(URI.to_string(source_uri), %{}, kind_type: :agent)

    caller = Ezagent.URI.user(workspace_name, "creator-#{label}-#{uniq()}")
    {:ok, _} = Ezagent.Users.create(caller, "pw-not-secret", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)
    {:ok, authority} = Ezagent.Cap.Authority.open(source_uri, :agent)
    cap = authority_signed_cap!(authority, caller, GrantCap.read_cap_for(source_uri))

    {source_uri, caller, [cap]}
  end

  defp credentialed_content(fixture, flavor, source_uri) do
    %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      cascade_resolution: %{
        owner_uri: fixture.owner_uri,
        workspace_uri: fixture.workspace_uri,
        explicit_source: source_uri,
        layer_dir_for: fn _ -> :skip end,
        source_dir_for: fn _source -> {:ok, System.tmp_dir!()} end
      }
    }
  end

  defp cold_the_kind(uri) do
    _ = Ezagent.Kind.terminate(uri)

    Ezagent.LifecycleCase.wait_until(fn ->
      Ezagent.KindRegistry.lookup(uri) == :error
    end)
  end

  test "F1: provision raise on a cold no-credential agent leaves NO durable grant", fixture do
    working_flavor = register("race-working-#{fixture.unique}", RaceWorkingTemplate)
    raising_flavor = register("race-raising-#{fixture.unique}", RaceRaisingTemplate)

    # A cold, durable agent exists WITHOUT a credential grant.
    assert {:ok, %{fresh?: true}} =
             TemplateSpawn.spawn_from_template_content(
               %{flavor: working_flavor, project_cwd: System.tmp_dir!()},
               fixture.agent_uri,
               fixture.owner_uri,
               fixture.workspace_uri
             )

    assert GrantRow.get_for_agent(URI.to_string(fixture.agent_uri)) == nil
    cold_the_kind(fixture.agent_uri)

    # A duplicate-create-with-source hits the cold agent and provisioning
    # RAISES. On the pre-fix branch tip the grant was minted BEFORE the
    # creation receipt and the raise propagated without compensation — the
    # cold pre-existing agent kept the duplicate attempt's grant.
    {source, caller, caps} = authorized_source(fixture.workspace_name, "raise")

    assert_raise RuntimeError, "provision exploded", fn ->
      TemplateSpawn.spawn_from_template_content(
        credentialed_content(fixture, raising_flavor, source),
        fixture.agent_uri,
        fixture.owner_uri,
        fixture.workspace_uri,
        caller: caller,
        authenticated_principal: caller,
        caps: caps
      )
    end

    assert GrantRow.get_for_agent(URI.to_string(fixture.agent_uri)) == nil,
           "a raising duplicate-create must leave no durable grant behind"
  end

  test "F3: rollback never URI-deletes — a concurrent reapproval (G2) survives", fixture do
    flavor = register("race-self-minting-#{fixture.unique}", RaceSelfMintingTemplate)

    Ezagent.Agent.TestTemplateSpawn.inject(:fail_after_display_profile_gated, self())

    on_exit(fn ->
      Ezagent.Agent.TestTemplateSpawn.clear()
      _ = Ezagent.Kind.terminate(fixture.agent_uri)
      _ = GrantRow.delete(URI.to_string(fixture.agent_uri))
      :ok
    end)

    spawn_task =
      Task.async(fn ->
        TemplateSpawn.spawn_from_template_content(
          %{
            name: "race-gated-profile",
            flavor: flavor,
            project_cwd: System.tmp_dir!()
          },
          fixture.agent_uri,
          fixture.owner_uri,
          fixture.workspace_uri
        )
      end)

    # The spawn is paused INSIDE the post-spawn obligations — G1 was minted by
    # the Template Class, the rollback has NOT run yet. Land the concurrent
    # reapproval (G2) now.
    assert_receive {:template_spawn_after_display_profile_gated, agent_uri, :inserted, hook_pid}
    assert agent_uri == fixture.agent_uri

    g1 = GrantRow.get_for_agent(URI.to_string(fixture.agent_uri))
    assert %GrantRow{} = g1

    workspace = fixture.workspace_name

    {:ok, g2} =
      GrantRow.reapprove(%{
        agent_uri: URI.to_string(fixture.agent_uri),
        credential_source_uri: URI.to_string(Ezagent.URI.agent(workspace, "race-reapproved-source")),
        approved_by: URI.to_string(Ezagent.Entity.User.admin_uri()),
        approved_scope: URI.to_string(Ezagent.URI.agent(workspace, "race-reapproved-source"))
      })

    refute g2.incarnation_id == g1.incarnation_id

    send(hook_pid, :release_display_profile_gate)

    # The spawn fails (injected post-profile failure) and rolls back.
    assert {:error, :injected_post_profile_failure} = Task.await(spawn_task, 30_000)

    # On the pre-fix branch tip the rollback's `minted_grant == nil ∧ created?`
    # arm ran a URI-WIDE delete — wiping G2 (the ABA victim). Now rollback
    # requires the exact incarnation receipt; with no receipt it deletes
    # NOTHING, and the current row is the reapproved G2.
    current = GrantRow.get_for_agent(URI.to_string(fixture.agent_uri))
    assert %GrantRow{} = current, "the concurrent reapproval G2 must survive the rollback"
    assert current.incarnation_id == g2.incarnation_id
  end
end
