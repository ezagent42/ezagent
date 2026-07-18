defmodule Ezagent.World.AgentDetailLiveStatusTest do
  @moduledoc """
  Regression gate: agent detail Phase reflects live KindRegistry status.

  Observed bug: an agent present in KindRegistry shows `Status: live` in the
  agents list (`list_entities/2` → `alive: true`) but `Phase: unknown` on the
  detail page (`agent_detail` state → `agent_status.phase`).

  Root cause: `jsonable/1` in `identity_data.ex` calls `Map.from_struct/1` on
  the plain map returned by `Domain.Agent.lifecycle_status/1`.
  `Map.from_struct/1` raises `FunctionClauseError` on a plain map (it only
  accepts `%struct{}`), the `rescue` clause returns `inspect(value)` — a plain
  string. The React receives a string instead of an object, so `status.phase`
  is `undefined`, which `|| "unknown"` maps to "unknown".

  Fix: the `jsonable/1` map clause must handle plain maps (no `__struct__`)
  without calling `Map.from_struct/1`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.World.IdentityData

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered after starting :ezagent_domain_session"

    ws_name = "world-live-status-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "agent detail Phase consistency with list alive" do
    @tag :integration
    test "live agent: detail agent_status.phase is a live value (not 'unknown'/nil), consistent with list alive=true",
         %{ws_name: _ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_name = "live-status-probe-#{System.unique_integer([:positive])}"

      # Create a live agent (curl — direct-spawn, no cwd, always starts)
      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      agent_uri_str = URI.to_string(agent_uri)

      # --- LIST: alive must be true for a just-spawned agent ---
      agent_rows = IdentityData.list_entities(workspace_uri, "agents")
      row = Enum.find(agent_rows, &(&1["uri"] == agent_uri_str))

      assert row != nil, "created agent must appear in list_entities"
      assert row["alive"] == true, "list must show alive=true for a live agent in KindRegistry"

      # --- DETAIL: agent_status must be a MAP with a live phase string ---
      detail_state =
        IdentityData.state_for(
          %{
            component: "agent_detail",
            title: "Agent detail",
            path: "/identities/agents/#{URI.encode_www_form(agent_uri_str)}",
            entity_uri: agent_uri
          },
          %{
            workspace_uri: workspace_uri,
            caller_uri: User.admin_uri(),
            caller_caps: admin_ctx.caps
          }
        )

      agent_status = detail_state["agent_status"]

      # Before the fix, jsonable/1 would return inspect(plain_map) — a string —
      # so agent_status would be a String.t(), not a map. The React then sees
      # status.phase as undefined and renders "unknown".
      assert is_map(agent_status),
             "agent_status must be a map (was: #{inspect(agent_status)}); " <>
               "if it's a string, jsonable/1 is falling through to its rescue clause " <>
               "because Map.from_struct/1 rejected the plain map"

      phase = Map.get(agent_status, "phase")

      assert is_binary(phase),
             "agent_status[\"phase\"] must be a string (was: #{inspect(phase)})"

      refute phase in ["unknown", nil],
             "live agent detail phase must not be 'unknown'/nil; got: #{inspect(phase)}"

      # The canonical live phases from Domain.Agent are :alive/:registered
      # (both map to a non-unknown string after jsonable/1).
      assert phase in ["alive", "registered"],
             "expected a live phase ('alive' or 'registered'), got: #{inspect(phase)}"

      # --- CONSISTENCY: list alive=true ⟺ detail phase != unknown ---
      # The two reads must agree: a live agent shows alive in the list AND
      # a live (non-unknown) phase in the detail.
      assert row["alive"] == true and phase in ["alive", "registered"],
             "list shows alive=#{row["alive"]} but detail phase=#{inspect(phase)} — inconsistent"
    end

    @tag :integration
    test "not-found agent: list omits it, detail renders a clean not-found (F2), not a shell",
         %{workspace_uri: _workspace_uri, admin_ctx: _admin_ctx} do
      # A URI that was never registered (no live process AND no snapshot) — F2:
      # the detail builder signals `agent_not_found` so the React detail renders
      # a not-found empty state instead of a hollow shell of "—"/"unknown" rows
      # (which is what a `agent_status.phase == "not_found"` shell used to be).
      ghost_uri = Ezagent.URI.agent("acme", "ghost-agent-never-registered")

      detail_state =
        IdentityData.state_for(
          %{
            component: "agent_detail",
            title: "Agent detail",
            path: "/identities/agents/ghost",
            entity_uri: ghost_uri
          },
          %{workspace_uri: nil, caller_uri: nil, caller_caps: MapSet.new()}
        )

      assert detail_state["agent_not_found"] == true
      assert detail_state["agent_uri"] == URI.to_string(ghost_uri)
      # No hollow shell: the status/caps fields are not emitted for a ghost.
      refute Map.has_key?(detail_state, "agent_status")
      refute Map.has_key?(detail_state, "granted_caps")
    end
  end
end
