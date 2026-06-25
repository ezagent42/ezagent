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

    admin_caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: admin_caps
    }

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
    test "state has 'cascade' with 'keys' including 'advisor.behavior'",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_curl_agent(workspace_uri, admin_ctx)

      state =
        build_config_state(agent_uri, admin_ctx.caller, admin_ctx.caps, workspace_uri)

      # Must have a cascade map, not a config_error.
      refute Map.has_key?(state, "config_error"),
             "expected no config_error for manage-cap caller; got: #{inspect(state["config_error"])}"

      assert is_map(state["cascade"]),
             "state must have a 'cascade' map; got: #{inspect(state["cascade"])}"

      # The cascade must include a 'keys' list.
      assert is_list(state["cascade"]["keys"]),
             "cascade must have a 'keys' list; got: #{inspect(state["cascade"]["keys"])}"

      # The default key 'advisor.behavior' must always be present.
      key_names = Enum.map(state["cascade"]["keys"], & &1["key"])

      assert "advisor.behavior" in key_names,
             "cascade 'keys' must include 'advisor.behavior'; got keys: #{inspect(key_names)}"

      # The state must carry the agent_uri string.
      assert is_binary(state["agent_uri"]),
             "state must carry agent_uri string; got: #{inspect(state["agent_uri"])}"
    end

    @tag :integration
    test "state cascade reflects a patched value (proves real read, not a stub)",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_curl_agent(workspace_uri, admin_ctx)

      # Apply a delta first — this writes to the user layer.
      assert {:ok, _} =
               Config.apply_delta(agent_uri, admin_ctx.caller, admin_ctx.caps, %{
                 layer: "user",
                 key: "advisor.behavior",
                 patch: %{"tone" => "decisive"}
               })

      # Now build the component state and assert the patched value is reflected.
      state =
        build_config_state(agent_uri, admin_ctx.caller, admin_ctx.caps, workspace_uri)

      refute Map.has_key?(state, "config_error"),
             "expected no config_error after patching; got: #{inspect(state["config_error"])}"

      cascade = state["cascade"]
      assert is_map(cascade)

      advisor_key =
        cascade["keys"]
        |> Enum.find(&(&1["key"] == "advisor.behavior"))

      assert advisor_key != nil,
             "advisor.behavior key missing from cascade after patch"

      # The effective body (user layer) must contain the patched field.
      # Check both top-level effective_body and within the user layer entry.
      effective_body = advisor_key["effective_body"]
      user_layer_body = get_in(advisor_key, ["layers", "user", "body"])

      assert (is_map(effective_body) and effective_body["tone"] == "decisive") or
               (is_map(user_layer_body) and user_layer_body["tone"] == "decisive"),
             "patched tone='decisive' must appear in effective_body or user layer; " <>
               "advisor_key: #{inspect(advisor_key)}"
    end
  end

  # ── (b) no-cap caller: state carries config_error, no crash ──────────────────

  describe "agent_config state — no-cap caller" do
    @tag :integration
    test "caller without manage-cap gets config_error, not a crash",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_uri = create_curl_agent(workspace_uri, admin_ctx)

      # Use a different caller (still admin URI but empty caps — no manage-cap).
      no_cap_caller = User.admin_uri()
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
