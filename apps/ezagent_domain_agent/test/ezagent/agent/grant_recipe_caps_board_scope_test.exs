defmodule Mix.Tasks.Ezagent.Agent.GrantRecipeCapsBoardScopeTest do
  @moduledoc """
  Phase 3 ③ T7g Part A — `GrantRecipeCaps.grant_recipe_caps/4` cap-instance
  SCOPING.

  Closes the act3 gap (`t7b-evidence/README.md` ★core gap★): a role recipe's
  caps were ALWAYS scoped to the grantee's OWN instance, but some caps must
  authorize a dispatch to a DIFFERENT instance (pm's kanban caps gate the BOARD
  agent, not pm itself). The optional 4th arg `instance_overrides` (a
  `%{behavior_module => target_uri}` map, supplied by the caller that knows the
  cross-instance target — e.g. the kanban seed knows the board URI) scopes those
  behaviors' caps to the override target, while every other cap stays
  self-scoped.

  Pure issue/self-store assertions on the landed cap shape (least-priv: a CONCRETE
  board instance, NOT a wildcard) — the dispatch-time positive/越权 proof is the
  kanban e2e (`DispatchVerbKanbanTest`). `async: false` (spawns a live agent +
  absorbs on its identity slice).
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.Delivery
  alias EzagentCore.Repo
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  defmodule PermissiveProposalBehavior do
    @moduledoc false
  end

  defmodule AdminRequiredProposalBehavior do
    @moduledoc false
    def data_owner(_instance), do: :no_owner
  end

  defmodule AuthorityLoaderStub do
    @moduledoc false
    @behaviour Ezagent.Cap.AuthorityLoader

    @impl true
    def read_held_caps(_actor), do: Process.get({__MODULE__, :caps}, MapSet.new())
  end

  @telemetry_prefix [:ezagent, :test, :t7g, :grant]

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp spawn_bare_agent do
    uri = Ezagent.URI.agent(:system, "t7g_grantee_#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    on_exit(fn ->
      _ = Ezagent.PendingDelivery.flush(uri)

      case Ezagent.KindRegistry.lookup(uri) do
        {:ok, pid} when is_pid(pid) ->
          if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)

        _ ->
          :ok
      end
    end)

    wait_ready(uri)
    uri
  end

  defp wait_ready(uri, attempts \\ 200)
  defp wait_ready(_uri, 0), do: flunk("agent never became ready")

  defp wait_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready -> :ok
      _ -> Process.sleep(10) && wait_ready(uri, attempts - 1)
    end
  end

  # A recipe over base behaviors loaded in domain_agent (so the loaded-check
  # passes), one of which we will board-scope and one we will keep self-scoped.
  defp recipe do
    %{
      name: "t7g-role",
      requested_caps: [
        %{behavior: Ezagent.ActionSet.ApiKeys, action: :put_api_key},
        %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
      ]
    }
  end

  defp caps_for(agent_uri), do: Ezagent.Identity.list_caps_for(agent_uri)

  defp cap_for(caps, behavior),
    do: Enum.find(caps, &match?(%Ezagent.Capability{behavior: ^behavior}, &1))

  describe "default (no override) — every cap self-scoped (unchanged)" do
    test "grant_recipe_caps/3 keeps caps scoped to the grantee's own instance" do
      agent_uri = spawn_bare_agent()

      assert :ok = GrantRecipeCaps.grant_recipe_caps(agent_uri, recipe(), @telemetry_prefix)

      caps = caps_for(agent_uri)
      self_instance = Ezagent.URI.instance(agent_uri)

      assert %Ezagent.Capability{instance: ^self_instance} =
               cap_for(caps, Ezagent.ActionSet.ApiKeys)

      assert %Ezagent.Capability{instance: ^self_instance} =
               cap_for(caps, Ezagent.ActionSet.Identity)
    end
  end

  describe "with override — listed behavior board-scoped, others self-scoped" do
    test "grant_recipe_caps/4 scopes the override behavior to the BOARD instance" do
      agent_uri = spawn_bare_agent()
      board_uri = Ezagent.URI.agent(:system, "t7g_board_#{uniq()}")

      assert :ok =
               GrantRecipeCaps.grant_recipe_caps(
                 agent_uri,
                 recipe(),
                 @telemetry_prefix,
                 %{Ezagent.ActionSet.ApiKeys => board_uri}
               )

      caps = caps_for(agent_uri)

      # the overridden behavior's cap is scoped to the BOARD instance + workspace,
      # exactly what dispatch step 5.5 derives for a board-targeted invocation.
      board_instance = Ezagent.URI.instance(board_uri)
      board_ws = Ezagent.Capability.workspace_of(board_uri)

      assert %Ezagent.Capability{instance: ^board_instance, workspace_uri: ^board_ws} =
               cap_for(caps, Ezagent.ActionSet.ApiKeys)

      # least-priv: a CONCRETE board instance, NOT a wildcard (not the (b) :any form).
      refute cap_for(caps, Ezagent.ActionSet.ApiKeys).instance == :any

      # the non-overridden behavior stays scoped to the grantee's OWN instance.
      self_instance = Ezagent.URI.instance(agent_uri)

      assert %Ezagent.Capability{instance: ^self_instance} =
               cap_for(caps, Ezagent.ActionSet.Identity)
    end

    test "same-instance override stays non-blocking and a duplicate identity persists once" do
      agent_uri = spawn_bare_agent()
      {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri)
      :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)
      buffer_size_before = Ezagent.PendingDelivery.buffer_size(agent_uri)

      recipe = %{
        requested_caps: [
          %{behavior: Ezagent.ActionSet.ApiKeys, action: :put_api_key},
          %{behavior: Ezagent.ActionSet.ApiKeys, action: :put_api_key}
        ]
      }

      task =
        Task.async(fn ->
          receive do
            :run ->
              GrantRecipeCaps.grant_recipe_caps(
                agent_uri,
                recipe,
                @telemetry_prefix,
                %{Ezagent.ActionSet.ApiKeys => agent_uri}
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
      send(task.pid, :run)

      assert {:ok, :ok} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
      assert Ezagent.ReadyGate.status(agent_uri) == :not_ready
      assert Ezagent.PendingDelivery.buffer_size(agent_uri) == buffer_size_before

      assert 1 ==
               Repo.aggregate(
                 from(delivery in Delivery,
                   where: delivery.target_uri == ^URI.to_string(agent_uri),
                   where: delivery.op == :absorb_cap,
                   where: delivery.status == :pending
                 ),
                 :count
               )

      assert :ready =
               Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
                 URI.to_string(agent_uri),
                 agent_pid
               )

      assert eventually(fn ->
               with {:ok, slice} <- Ezagent.Kind.get_slice(agent_uri, :identity) do
                 caps = slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)

                 Enum.any?(caps, fn cap ->
                   cap.behavior == Ezagent.ActionSet.ApiKeys and
                     cap.action == :put_api_key and
                     cap.instance == Ezagent.URI.instance(agent_uri)
                 end) and
                   Repo.aggregate(
                     from(delivery in Delivery,
                       where: delivery.target_uri == ^URI.to_string(agent_uri),
                       where: delivery.op == :absorb_cap,
                       where: delivery.status == :applied
                     ),
                     :count
                   ) == 1
               else
                 _ -> false
               end
             end)
    end
  end

  describe "fail-loud resolution" do
    test "an unresolvable later template dispatches none of the earlier caps" do
      agent_uri = spawn_bare_agent()
      caps_before = caps_for(agent_uri)
      missing_behavior = "Ezagent.ActionSet.DoesNotExistForRecipeGrant"

      recipe = %{
        requested_caps: [
          %{behavior: Ezagent.ActionSet.ApiKeys, action: :put_api_key},
          %{behavior: missing_behavior, action: :list_caps}
        ]
      }

      assert {:error, {:behavior_not_loaded, ^missing_behavior}} =
               GrantRecipeCaps.grant_recipe_caps(agent_uri, recipe, @telemetry_prefix)

      assert caps_for(agent_uri) == caps_before
    end

    test "complete ISSUE authorization finishes before any absorb hand-off" do
      agent_uri = spawn_bare_agent()
      caps_before = caps_for(agent_uri)
      previous = Application.fetch_env!(:ezagent_core, Ezagent.Cap)

      on_exit(fn ->
        Application.put_env(:ezagent_core, Ezagent.Cap, previous)
        Process.delete({AuthorityLoaderStub, :caps})
      end)

      Application.put_env(
        :ezagent_core,
        Ezagent.Cap,
        Keyword.put(previous, :authority_loader, AuthorityLoaderStub)
      )

      Process.put({AuthorityLoaderStub, :caps}, MapSet.new())
      buffer_size_before = Ezagent.PendingDelivery.buffer_size(agent_uri)

      permissive_proposal =
        Ezagent.Capability.cap(
          :agent,
          PermissiveProposalBehavior,
          :first,
          Ezagent.URI.instance(agent_uri),
          Ezagent.Capability.workspace_of(agent_uri)
        )

      assert {:ok, %Ezagent.Capability{behavior: PermissiveProposalBehavior}} =
               Ezagent.Cap.issue(
                 {:admin, Ezagent.Entity.User.admin_uri()},
                 agent_uri,
                 permissive_proposal
               )

      recipe = %{
        requested_caps: [
          %{behavior: PermissiveProposalBehavior, action: :first},
          %{behavior: AdminRequiredProposalBehavior, action: :second}
        ]
      }

      assert {:error,
              {:grant_failed, %Ezagent.Capability{behavior: AdminRequiredProposalBehavior},
               :grant_owner_unresolvable}} =
               GrantRecipeCaps.grant_recipe_caps(agent_uri, recipe, @telemetry_prefix)

      assert caps_for(agent_uri) == caps_before
      assert Ezagent.PendingDelivery.buffer_size(agent_uri) == buffer_size_before
    end
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
end
