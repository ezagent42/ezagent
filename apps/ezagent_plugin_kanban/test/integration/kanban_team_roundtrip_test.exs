defmodule EzagentPluginKanban.Integration.KanbanTeamRoundtripTest do
  @moduledoc """
  Round-trip gate (load-bearing — the concrete advantage of the content-triggered
  relay over a sender-lock, spec §4.4). Proves that after the relay rule is
  materialized into a live session (members spawned at RANDOM UUID URIs, #1180),
  the live rule PROJECTS BACK into the SHIPPED kanban-team Definition body and
  `Definition.new/1` accepts it WITHOUT tripping
  `reject_participant_instance_uris`.

  How the projection mirrors a real snapshot: the routing_rules are read from the
  LIVE `RuleStore` post-materialize and decoded back to the shape a snapshot would
  emit (matcher map + role_name receivers), then substituted into the REAL
  `KanbanTeam.definition_body/0` (whose role slots already carry only
  role_name/recipe/flavor — never the spawned UUID, exactly what
  `DefinitionEditor.live_role_slots` produces). If the relay were a sender-lock,
  the live matcher would embed the dev's spawned UUID and both the URI-guard
  assertion and `Definition.new/1` would fail here.

  Fixture note: the same as `kanban_team_relay_back_test` — a bare-spawn stub
  flavor materializes pm/dev (the cc-headless SDK spawn + passive kanban-manager
  join are S6 e2e concerns), but the routing rule under test is the REAL relay
  rule, and the body it snapshots INTO is the REAL shipped kanban-team body.

  Self-containment (spec §11): kanban test tree, `EzagentCore.DataCase`, domain
  started at setup — same rationale as the relay-back test.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Routing.{Receiver, Resolver, RuleStore}
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam
  alias EzagentPluginKanban.{Application, KanbanTeam}

  @workspace Ezagent.URI.workspace(:system)
  @stub_flavor "kanban-roundtrip-itest-bare"
  @itest_definition "kanban-team-roundtrip-itest"

  defmodule StubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "kanban_roundtrip_itest.stub"

    @impl Ezagent.Kind.Template
    def validate(%{
          "class" => "kanban_roundtrip_itest.stub",
          "agent_uri" => agent_uri,
          "cwd" => cwd
        })
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_kanban_roundtrip_itest_stub_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(data["agent_uri"])

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors(),
             role: data["role"]
           }) do
        {:ok, _pid} -> {:ok, [uri], %{fresh?: true, config_dir_path: nil}}
        {:error, {:already_started, _pid}} -> {:ok, [uri], %{fresh?: false}}
        {:error, {:already_registered, _}} -> {:ok, [uri], %{fresh?: false}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  setup do
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_plugin_kanban)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @stub_flavor,
        kind: Ezagent.Entity.Agent,
        template_class: StubTemplate
      })

    Enum.each(Application.roles(), fn recipe ->
      assert {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = Ezagent.Agent.RecipeRegistry.flush_cache()

    assert {:ok, _} =
             DefinitionRegistry.seed_definition_if_absent(
               itest_definition_body(),
               workspace_uri: @workspace,
               actor_uri: Ezagent.URI.user(:system, :admin)
             )

    session_uri =
      Ezagent.URI.session("system", "kanban", "roundtrip-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.behaviors()})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace)
    on_exit(fn -> terminate(session_uri) end)

    {:ok, session_uri: session_uri}
  end

  test "the materialized relay rule snapshots back into the shipped Definition (no instance URI)",
       %{session_uri: session_uri} do
    granted_by = User.admin_uri()

    assert :ok =
             TemplateTeam.materialize_template_team(
               session_uri,
               @workspace,
               granted_by,
               %{installs: [@itest_definition]}
             )

    pm_uri = member_uri_for_role(session_uri, "pm-coordinator")
    dev_uri = member_uri_for_role(session_uri, "dev-together")
    on_exit(fn -> Enum.each([pm_uri, dev_uri], &terminate/1) end)
    assert %URI{} = pm_uri
    assert %URI{} = dev_uri

    # Read the LIVE rules from the RuleStore and project them back into the
    # Definition-body shape (matcher map + role_name receivers) a snapshot emits.
    live_rules = projected_live_rules(session_uri)
    assert live_rules != [], "expected the materialized relay-back rule in the live store"

    # Substitute the LIVE-projected rules into the REAL shipped kanban-team body —
    # the round-trip: does the shipped Definition, carrying the rules as they live
    # after materialize, still validate with zero instance URI?
    snapshot_body = Map.put(KanbanTeam.definition_body(), :routing_rules, live_rules)

    # (a) re-validating the snapshotted body does NOT trip #1180's instance-URI
    # guard (the round-trip closes).
    assert {:ok, %Definition{}} = Definition.new(snapshot_body)

    # (b) structural: the spawned pm/dev UUIDs appear NOWHERE in the projected
    # routing config — the anti-sender-lock evidence.
    projected = inspect(live_rules)
    refute projected =~ URI.to_string(pm_uri)
    refute projected =~ URI.to_string(dev_uri)
    refute projected =~ ~r{entity://[^/]+/(agent|user)/}
  end

  # --- fixture ----------------------------------------------------------------

  defp itest_definition_body do
    base = KanbanTeam.definition_body()

    %{
      base
      | name: @itest_definition,
        roles: [
          %{
            role_name: "pm-coordinator",
            fill: :agent,
            recipe: "pm-coordinator",
            flavor: @stub_flavor
          },
          %{role_name: "dev-together", fill: :agent, recipe: "dev-together", flavor: @stub_flavor}
        ]
    }
  end

  # --- helpers ----------------------------------------------------------------

  defp projected_live_rules(session_uri) do
    table = Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    RuleStore.list(table)
    |> Enum.filter(&(&1.created_by == session_str))
    |> Enum.map(fn r ->
      %{
        "matcher" => r.matcher_data,
        "receivers" => Enum.map(r.receivers, &decode_receiver_to_role_name/1),
        "rule_set" => r.rule_set,
        "position" => r.position
      }
    end)
  end

  defp decode_receiver_to_role_name(stored) do
    case Receiver.decode_from_store(stored) do
      {:role, name} -> name
      other -> other
    end
  end

  defp member_uri_for_role(session_uri, role_name) do
    case Ezagent.UriQuery.resolve(:member_by_role, {session_uri, role_name}) do
      {:ok, %URI{} = uri} -> uri
      _ -> nil
    end
  end

  defp terminate(nil), do: :ok

  defp terminate(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end
end
