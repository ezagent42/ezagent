defmodule Ezagent.World.AgentConfigStateTest do
  @moduledoc """
  Anti-stub gate for the `agent_config` component state builder (Task C2).

  Verifies that `IdentityData.state_for/2` for the `agent_config` route calls
  `Ezagent.Config.read_cascade/4` (cap-gated) and surfaces the real cascade
  state, NOT a stub. Also verifies that a caller WITHOUT the manage-cap gets a
  `"config_error"` key instead of a crash.

  Invariant P14: all reads go through the facade (which dispatches internally).
  Invariant #9: no silent drops — auth failures surface as `config_error`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.World.IdentityData
  alias Ezagent.Agent.Config

  # ── bootstrap ────────────────────────────────────────────────────────────────

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered — bootstrap is incomplete"

    ws_name = "agent-config-state-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp create_curl_agent(workspace_uri, admin_ctx) do
    agent_name = "config-probe-#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
               admin_ctx
             )

    agent_uri
  end

  defp build_config_state(agent_uri, caller_uri, caps, workspace_uri) do
    agent_uri_str = URI.to_string(agent_uri)

    IdentityData.state_for(
      %{
        component: "agent_config",
        title: "Agent Config",
        path: "/identities/agents/#{URI.encode_www_form(agent_uri_str)}/config",
        entity_uri: agent_uri
      },
      %{workspace_uri: workspace_uri, caller_uri: caller_uri, caller_caps: caps}
    )
  end

  # ── (a) happy path: manage-cap caller gets real cascade state ─────────────────

  describe "agent_config state — manage-cap caller" do
    @tag :integration
    test "state has 'cascade' with 'keys' including 'agent.soul'",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_curl_agent(workspace_uri, admin_ctx)
      read_target = Ezagent.URI.with_action(agent_uri, :config_evolve, :read_cascade)

      read_caps =
        MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(read_target, admin_ctx.caller)])

      state =
        build_config_state(agent_uri, admin_ctx.caller, read_caps, workspace_uri)

      # Must have a cascade map, not a config_error.
      refute Map.has_key?(state, "config_error"),
             "expected no config_error for manage-cap caller; got: #{inspect(state["config_error"])}"

      assert is_map(state["cascade"]),
             "state must have a 'cascade' map; got: #{inspect(state["cascade"])}"

      # The cascade must include a 'keys' list.
      assert is_list(state["cascade"]["keys"]),
             "cascade must have a 'keys' list; got: #{inspect(state["cascade"]["keys"])}"

      # The default key 'agent.soul' must always be present.
      key_names = Enum.map(state["cascade"]["keys"], & &1["key"])

      assert "agent.soul" in key_names,
             "cascade 'keys' must include 'agent.soul'; got keys: #{inspect(key_names)}"

      # The state must carry the agent_uri string.
      assert is_binary(state["agent_uri"]),
             "state must carry agent_uri string; got: #{inspect(state["agent_uri"])}"
    end

    @tag :integration
    test "state cascade reflects a patched value (proves real read, not a stub)",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_curl_agent(workspace_uri, admin_ctx)
      apply_target = Ezagent.URI.with_action(agent_uri, :config_evolve, :apply_config_delta)
      read_target = Ezagent.URI.with_action(agent_uri, :config_evolve, :read_cascade)

      apply_caps =
        MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(apply_target, admin_ctx.caller)])

      read_caps =
        MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(read_target, admin_ctx.caller)])

      # Apply a delta first — this writes to the user layer.
      assert {:ok, _} =
               Config.apply_delta(agent_uri, admin_ctx.caller, apply_caps, %{
                 layer: "user",
                 key: "agent.soul",
                 patch: %{"tone" => "decisive"}
               })

      # Now build the component state and assert the patched value is reflected.
      state =
        build_config_state(agent_uri, admin_ctx.caller, read_caps, workspace_uri)

      refute Map.has_key?(state, "config_error"),
             "expected no config_error after patching; got: #{inspect(state["config_error"])}"

      cascade = state["cascade"]
      assert is_map(cascade)

      soul_key =
        cascade["keys"]
        |> Enum.find(&(&1["key"] == "agent.soul"))

      assert soul_key != nil,
             "agent.soul key missing from cascade after patch"

      # The effective body (user layer) must contain the patched field.
      # Check both top-level effective_body and within the user layer entry.
      effective_body = soul_key["effective_body"]
      user_layer_body = get_in(soul_key, ["layers", "user", "body"])

      assert (is_map(effective_body) and effective_body["tone"] == "decisive") or
               (is_map(user_layer_body) and user_layer_body["tone"] == "decisive"),
             "patched tone='decisive' must appear in effective_body or user layer; " <>
               "soul_key: #{inspect(soul_key)}"
    end
  end

  # ── (b) no-cap caller: state carries config_error, no crash ──────────────────

  describe "agent_config state — no-cap caller" do
    @tag :integration
    test "caller without manage-cap gets config_error, not a crash",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_curl_agent(workspace_uri, admin_ctx)

      # A GENUINE no-cap caller: a non-admin user with no inline caps AND no
      # persisted slice/snapshot caps, so it fails BOTH authz routes (§3.2):
      #   route 1 (inline ctx.caps) — empty
      #   route 2 (the caller's slice/snapshot caps) — none seeded
      # NOTE: the previous proxy `User.admin_uri()` + empty inline caps is no
      # longer "no-cap" — the unified two-route reader (Domain.Agent.read_config)
      # now authorizes via route 2 from the admin's persisted genesis cap, which
      # is the SAME authority the live `config_evolve.read_cascade` dispatch
      # always had (its slice route). The #1028 route-1-only per-site reader was
      # the outlier that wrongly denied the admin; this test encoded that outlier.
      no_cap_caller =
        Ezagent.URI.entity(
          Ezagent.URI.workspace_name!(workspace_uri),
          :user,
          "stranger-#{System.unique_integer([:positive])}"
        )

      no_caps = MapSet.new()

      state = build_config_state(agent_uri, no_cap_caller, no_caps, workspace_uri)

      # Must carry config_error, not a cascade.
      assert is_binary(state["config_error"]),
             "state must carry config_error string for no-cap caller; got: #{inspect(state)}"

      # Must NOT carry a cascade (unauthorized caller should not see config data).
      refute Map.has_key?(state, "cascade") and not is_nil(state["cascade"]),
             "state must not carry cascade for no-cap caller"
    end
  end
end
