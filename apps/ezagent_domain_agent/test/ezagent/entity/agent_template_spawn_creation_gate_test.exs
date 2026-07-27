defmodule Ezagent.Entity.AgentTemplateSpawnCreationGateTest do
  @moduledoc """
  #201 PR-3 — the creation-state WRITE GATE at the spawn chokepoint:

    * flavor → gated on the `:started` winner signal only (a cold rehydrate
      re-writes the SAME flavor idempotently — benign self-heal);
    * credential grant (mint + keep) → gated on `:started ∧ created?`
      (grant-mint is a create-only, non-idempotent side effect);
    * a loser (`:already_started`) or a rehydrating winner
      (`:started ∧ ¬created?`) keeps NOTHING — exactly its own minted grant
      incarnation is deleted (R4 ABA-safe), never a bare URI delete.

  Each test in this file fails on the pre-#201 baseline: the speculative
  writes it pins down were exactly the clobber source.
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3]

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.AgentFlavorAttributes
  alias Ezagent.Credential.{GrantCap, GrantRow}
  alias Ezagent.Entity.Agent.TemplateSpawn

  # A credential-carrying capture Template Class (mirrors the codex file-flavor
  # shape): spawns the unified Agent Kind through the #201 spawn receipt and
  # threads the core `created?` verdict into its meta. Declares the
  # CredentialAdapter behaviour so the cascade treats it as a file flavor.
  defmodule GateCaptureTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.gate_capture_agent"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))

      case spawn_agent(uri) do
        {:ok, :started, _pid, created?} ->
          {:ok, [uri], %{fresh?: true, created?: created?}}

        {:ok, :already_started, _pid, _created?} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # #201 PR-1 — through the spawn receipt when available (this branch), so the
    # chokepoint gates on the core `created?` verdict; the plain-spawn fallback
    # keeps this fixture loadable against the pre-#201 baseline for fail-on-base
    # evidence (there the receipt does not exist and `created?` is unknown → the
    # speculative writes this suite pins down occur).
    if function_exported?(Ezagent.Kind, :spawn_receipt, 3) do
      defp spawn_agent(uri) do
        case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, %{
               uri: uri,
               behaviors: Ezagent.Entity.Agent.base_behaviors()
             }) do
          {:ok, :started, pid, %{created?: created?}} -> {:ok, :started, pid, created?}
          {:ok, :already_started, pid, _receipt} -> {:ok, :already_started, pid, false}
          {:error, _} = err -> err
        end
      end
    else
      defp spawn_agent(uri) do
        case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: uri,
               behaviors: Ezagent.Entity.Agent.base_behaviors()
             }) do
          {:ok, pid} -> {:ok, :started, pid, true}
          {:error, {:already_started, pid}} -> {:ok, :already_started, pid, false}
          {:error, _} = err -> err
        end
      end
    end

    @behaviour Ezagent.Agent.CredentialAdapter

    @impl Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "GATE_CAPTURE_HOME"

    @impl Ezagent.Agent.CredentialAdapter
    def credential_relpaths, do: ["token.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def secret_relpaths, do: ["token.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def auth_failure_signals, do: ["gate capture auth failed"]
  end

  setup do
    # The Session domain owns the Agent Kind's supervisor + the production
    # `entity://` resolver.
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    unique = System.unique_integer([:positive])
    workspace_name = "gate-#{unique}"
    flavor = "gate-capture-#{unique}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: GateCaptureTemplate
      })

    %{
      unique: unique,
      workspace_name: workspace_name,
      flavor: flavor,
      workspace_uri: Ezagent.URI.workspace(workspace_name),
      owner_uri: Ezagent.URI.user(workspace_name, "owner"),
      agent_uri: Ezagent.URI.agent(workspace_name, "gated-#{unique}")
    }
  end

  defp uniq, do: System.unique_integer([:positive])

  # A credential source agent URI in the same workspace + a caller authorized
  # to approve it (`sandbox.read` cap signed by the source's own authority).
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

  defp credentialed_content(fixture, source_uri) do
    %{
      flavor: fixture.flavor,
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

  defp plain_content(fixture) do
    %{flavor: fixture.flavor, project_cwd: System.tmp_dir!()}
  end

  defp spawn(fixture, content, caller, caps, uri \\ nil) do
    TemplateSpawn.spawn_from_template_content(
      content,
      uri || fixture.agent_uri,
      fixture.owner_uri,
      fixture.workspace_uri,
      caller: caller,
      authenticated_principal: caller,
      caps: caps
    )
  end

  defp grant_for(uri), do: GrantRow.get_for_agent(URI.to_string(uri))

  defp cold_the_kind(uri) do
    _ = Ezagent.Kind.terminate(uri)

    Ezagent.LifecycleCase.wait_until(fn ->
      Ezagent.KindRegistry.lookup(uri) == :error
    end)
  end

  describe "winner gate — flavor vs credential" do
    test "two concurrent creators: exactly one writes; the loser writes nothing", fixture do
      # Two flavors, TWO capture classes, same target URI. The creator that
      # loses the spawn must leave the WINNER's creation-state untouched —
      # on the pre-#201 baseline the loser's SPECULATIVE pre-spawn flavor
      # store (template.ex / plugin instantiate) clobbers the winner's row
      # with the LOSER's flavor (that is what this test fails on there).
      unique = System.unique_integer([:positive])

      {flavor_a, flavor_b} =
        {"gate-race-a-#{unique}", "gate-race-b-#{unique}"}

      for flavor <- [flavor_a, flavor_b] do
        :ok =
          AgentFlavorRegistry.register(%{
            flavor: flavor,
            kind: Ezagent.Entity.Agent,
            template_class: GateCaptureTemplate
          })
      end

      attempt = fn flavor ->
        Task.async(fn ->
          TemplateSpawn.spawn_from_template_content(
            %{flavor: flavor, project_cwd: System.tmp_dir!()},
            fixture.agent_uri,
            fixture.owner_uri,
            fixture.workspace_uri,
            []
          )
        end)
      end

      results =
        [{flavor_a, attempt.(flavor_a)}, {flavor_b, attempt.(flavor_b)}]
        |> Enum.map(fn {flavor, task} -> {flavor, Task.await(task, 30_000)} end)

      {winners, losers} = Enum.split_with(results, fn {_flavor, r} -> match?({:ok, _}, r) end)

      assert [{winning_flavor, {:ok, %{fresh?: true}}}] = winners,
             "exactly one concurrent creator may win the spawn: #{inspect(results)}"

      assert [{_losing_flavor, {:error, :agent_uri_already_live}}] = losers

      # The flavor row is the WINNER's — the loser's attempt wrote nothing.
      assert {:ok, flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
      assert flavor == winning_flavor
    end

    test "adopt-of-live: the loser keeps nothing — its minted grant is deleted", fixture do
      # Live agent with NO grant row (its "key-A" is its pre-existing
      # flavor/lineage/profile state, created credential-free).
      assert {:ok, %{fresh?: true}} =
               spawn(fixture, plain_content(fixture), fixture.owner_uri, [])

      assert grant_for(fixture.agent_uri) == nil
      assert {:ok, flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
      assert flavor == fixture.flavor

      # An adopt attempt against the LIVE agent carrying a credential source:
      # its mint SUCCEEDS (no prior row to conflict with) before it loses the
      # spawn. The loser's minted grant must be deleted by incarnation-scoped
      # compensation — on the pre-#201 baseline it SURVIVES as injected residue
      # (that is the clobber this test fails on).
      {source_b, caller_b, caps_b} = authorized_source(fixture.workspace_name, "b")

      assert {:error, :agent_uri_already_live} =
               spawn(fixture, credentialed_content(fixture, source_b), caller_b, caps_b)

      assert grant_for(fixture.agent_uri) == nil,
             "the losing attempt's minted grant must be deleted, not left on the live owner"

      # The live owner's state is untouched.
      assert {:ok, ^flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(fixture.agent_uri)
    end

    test "duplicate-create against a live CREDENTIALED agent fails at the mint boundary without touching the owner's grant",
         fixture do
      {source_a, caller_a, caps_a} = authorized_source(fixture.workspace_name, "a")
      {source_b, caller_b, caps_b} = authorized_source(fixture.workspace_name, "b")

      assert {:ok, %{fresh?: true}} =
               spawn(fixture, credentialed_content(fixture, source_a), caller_a, caps_a)

      assert %GrantRow{} = original = grant_for(fixture.agent_uri)
      assert original.credential_source_uri == URI.to_string(source_a)

      # A duplicate create against the LIVE agent carrying a different
      # source: its mint collides with the live owner's row (unique
      # agent_uri) — the attempt fails at the mint boundary and the live
      # owner's grant is left byte-identical (same incarnation + version).
      assert {:error, %Ecto.Changeset{}} =
               spawn(fixture, credentialed_content(fixture, source_b), caller_b, caps_b)

      assert grant_for(fixture.agent_uri) == original
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(fixture.agent_uri)
    end

    test "duplicate-create against a COLD pre-existing no-credential agent injects no credential",
         fixture do
      # First create: NO credential source (no grant ever minted).
      assert {:ok, %{fresh?: true}} =
               spawn(fixture, plain_content(fixture), fixture.owner_uri, [])

      assert grant_for(fixture.agent_uri) == nil
      assert {:ok, flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
      assert flavor == fixture.flavor

      # Go cold: the process dies but the durable snapshot + ever_created
      # marker survive — the codex case. A duplicate-create now WINS the
      # atomic `:started` but is NOT a logical create.
      cold_the_kind(fixture.agent_uri)

      {source, caller, caps} = authorized_source(fixture.workspace_name, "dup")

      assert {:ok, %{fresh?: true}} =
               spawn(fixture, credentialed_content(fixture, source), caller, caps)

      # The attempt's minted grant was deleted by incarnation-scoped
      # compensation: grant-mint is a create-only side effect and this
      # attempt did NOT logically create the agent.
      assert grant_for(fixture.agent_uri) == nil,
             "a rehydrating winner must not keep an injected credential grant"

      # The agent is live again (legitimate rehydrate) and its flavor is intact.
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(fixture.agent_uri)
      assert {:ok, ^flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
    end

    test "destroy then recreate DOES write a fresh credential", fixture do
      {source_a, caller_a, caps_a} = authorized_source(fixture.workspace_name, "a")

      assert {:ok, %{fresh?: true}} =
               spawn(fixture, credentialed_content(fixture, source_a), caller_a, caps_a)

      assert %GrantRow{} = original = grant_for(fixture.agent_uri)

      # Destroy clears the durable state + the ever_created marker; the
      # credential de-provision removes the old grant (a destroyed agent's
      # grant must not linger for the URI's next incarnation).
      assert :ok = Ezagent.Lifecycle.destroy(fixture.agent_uri, :test_destroy)
      _ = GrantRow.delete(URI.to_string(fixture.agent_uri))
      cold_the_kind(fixture.agent_uri)

      {source_b, caller_b, caps_b} = authorized_source(fixture.workspace_name, "b")

      assert {:ok, %{fresh?: true}} =
               spawn(fixture, credentialed_content(fixture, source_b), caller_b, caps_b)

      # The marker was cleared → this IS a genuine logical create → the
      # fresh grant is minted AND kept.
      assert %GrantRow{} = recreated = grant_for(fixture.agent_uri)
      assert recreated.credential_source_uri == URI.to_string(source_b)
      assert recreated.version == 1
      refute recreated.incarnation_id == original.incarnation_id
    end

    test "rehydration re-writes the volatile flavor row idempotently (no clobber)", fixture do
      assert {:ok, %{fresh?: true}} =
               spawn(fixture, plain_content(fixture), fixture.owner_uri, [])

      assert {:ok, flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
      assert flavor == fixture.flavor

      # Simulate a phx restart: the VOLATILE ETS flavor row is lost; the
      # durable agent survives in its snapshot.
      :ok = AgentFlavorAttributes.delete(fixture.agent_uri)
      assert :none = AgentFlavorAttributes.get(fixture.agent_uri)
      cold_the_kind(fixture.agent_uri)

      assert {:ok, %{fresh?: true}} =
               spawn(fixture, plain_content(fixture), fixture.owner_uri, [])

      # `:started ∧ ¬created?` — the rehydrating winner re-writes the SAME
      # flavor idempotently (gated on `:started` alone).
      assert {:ok, ^flavor} = AgentFlavorAttributes.get(fixture.agent_uri)
      assert grant_for(fixture.agent_uri) == nil
    end
  end
end
