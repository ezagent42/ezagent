defmodule Ezagent.World.AgentConfigDispatchTest do
  @moduledoc """
  Anti-stub gate for the 3 `agents.config.*` dispatch paths in WorldLive (Task C3).

  Tests call the facade DIRECTLY (not through the LiveView socket) to verify the
  backend contract — the same backend `WorldLive` wires up. This mirrors the
  pattern in `agent_delete_dispatch_test.exs`.

  Coverage:
    (a) update happy path — apply_delta + re-read via read_cascade confirms durable write
    (b) update cap-denial — empty caps → :unauthorized (or :cross_workspace_denied);
        value unchanged
    (c) delete_path happy path — apply_delta a field, then delete_path, re-read shows it gone
    (d) delete_path cap-denial — test against an EXISTING field (auth-ordering caveat:
        nonexistent field may return :path_not_found before :unauthorized)
    (e) invalid_patch reason code — non-map patch value
    (f) path_not_found reason code — delete a nonexistent path from a real config object

  Auth-ordering caveat (per spec):
    `delete_path/4` reads the config body BEFORE the manage-cap-gated dispatch,
    so a caller WITHOUT caps on a MISSING key may get :config_not_found before
    :unauthorized. Tests (c)/(d) create the field first to avoid this leak.

  Invariant P14: all mutations go through Ezagent.Agent.Config facade (which
  dispatches internally). No silent drops.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
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

    ws_name = "agent-config-dispatch-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp create_curl_agent(workspace_uri, admin_ctx) do
    agent_name = "cfg-dispatch-#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
               admin_ctx
             )

    {agent_uri, config_ctx(agent_uri, admin_ctx.caller)}
  end

  defp config_ctx(agent_uri, caller) do
    requested =
      Ezagent.Capability.cap(
        :agent,
        Ezagent.ActionSet.Manage,
        :any,
        Ezagent.URI.instance(agent_uri),
        Ezagent.Capability.workspace_of(agent_uri)
      )

    cap = Ezagent.Test.CapHelper.signed_cap!(agent_uri, caller, requested)
    %{caller: caller, caps: MapSet.new([cap])}
  end

  # Read the cascade for a key and return the user-layer body (or nil).
  defp user_layer_body(agent_uri, key, admin_ctx) do
    case Config.read_cascade(agent_uri, admin_ctx.caller, admin_ctx.caps) do
      {:ok, %{keys: keys}} ->
        case Enum.find(keys, &(&1.key == key || &1["key"] == key)) do
          nil ->
            nil

          key_entry ->
            layers = Map.get(key_entry, :layers) || Map.get(key_entry, "layers") || %{}
            user = Map.get(layers, "user") || Map.get(layers, :user)
            (user && (Map.get(user, :body) || Map.get(user, "body"))) || %{}
        end

      _ ->
        nil
    end
  end

  # ── (a) update happy path ────────────────────────────────────────────────────

  describe "agents.config.update — happy path" do
    @tag :integration
    test "apply_delta with manage-cap writes to user layer; re-read confirms durable write",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {agent_uri, manage_ctx} = create_curl_agent(workspace_uri, admin_ctx)

      # Dispatch the update via the facade (same call WorldLive will make).
      result =
        Config.apply_delta(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
          layer: "user",
          key: "agent.soul",
          patch: %{"tone" => "decisive"}
        })

      assert match?({:ok, _}, result),
             "apply_delta with manage-cap must succeed; got: #{inspect(result)}"

      # Re-read via facade (not an in-form echo) — the patched value must be durable.
      body = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      assert is_map(body),
             "user-layer body must be a map after apply_delta; got: #{inspect(body)}"

      assert body["tone"] == "decisive",
             "user-layer body must contain tone='decisive'; got: #{inspect(body)}"
    end
  end

  # ── (b) update cap-denial ────────────────────────────────────────────────────

  describe "agents.config.update — cap-denial" do
    @tag :integration
    test "apply_delta with empty caps returns error; value unchanged",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {agent_uri, manage_ctx} = create_curl_agent(workspace_uri, admin_ctx)

      # First confirm the key starts empty.
      body_before = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      # Attempt the update without caps.
      result =
        Config.apply_delta(agent_uri, manage_ctx.caller, MapSet.new(), %{
          layer: "user",
          key: "agent.soul",
          patch: %{"tone" => "assertive"}
        })

      assert match?({:error, _}, result),
             "apply_delta with empty caps must fail; got: #{inspect(result)}"

      {:error, reason} = result

      assert reason in [:missing_cap, :unauthorized, :cross_workspace_denied],
             "cap-denial must be :unauthorized or :cross_workspace_denied; got: #{inspect(reason)}"

      # Value must be unchanged.
      body_after = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      assert body_before == body_after,
             "value must be unchanged after cap-denied update; before=#{inspect(body_before)}, after=#{inspect(body_after)}"
    end
  end

  # ── (c) delete_path happy path ───────────────────────────────────────────────

  describe "agents.config.delete_path — happy path" do
    @tag :integration
    test "delete_path removes an existing field; re-read confirms it is gone",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {agent_uri, manage_ctx} = create_curl_agent(workspace_uri, admin_ctx)

      # Write the field first so it exists.
      assert {:ok, _} =
               Config.apply_delta(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
                 layer: "user",
                 key: "agent.soul",
                 patch: %{"to_delete" => "yes"}
               })

      # Confirm it was written.
      body_before = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      assert is_map(body_before) and Map.has_key?(body_before, "to_delete"),
             "setup: to_delete field must exist before delete_path; body: #{inspect(body_before)}"

      # Now delete the field.
      result =
        Config.delete_path(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
          layer: "user",
          key: "agent.soul",
          path: ["to_delete"]
        })

      assert match?({:ok, _}, result),
             "delete_path with manage-cap must succeed; got: #{inspect(result)}"

      # Re-read — field must be gone.
      body_after = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      refute is_map(body_after) and Map.has_key?(body_after, "to_delete"),
             "to_delete field must be gone after delete_path; body: #{inspect(body_after)}"
    end
  end

  # ── (d) delete_path cap-denial — against an EXISTING field ──────────────────

  describe "agents.config.delete_path — cap-denial" do
    @tag :integration
    test "delete_path with empty caps on an EXISTING field returns error; field unchanged",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {agent_uri, manage_ctx} = create_curl_agent(workspace_uri, admin_ctx)

      # Write the field first (with manage-cap) so it EXISTS before the cap-denied attempt.
      # This avoids the auth-ordering caveat where a missing key returns
      # :config_not_found before :unauthorized.
      assert {:ok, _} =
               Config.apply_delta(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
                 layer: "user",
                 key: "agent.soul",
                 patch: %{"cap_denial_probe" => "present"}
               })

      body_before = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      assert is_map(body_before) and Map.has_key?(body_before, "cap_denial_probe"),
             "setup: cap_denial_probe field must exist for the cap-denial test; body: #{inspect(body_before)}"

      # Attempt delete_path with empty caps.
      result =
        Config.delete_path(agent_uri, manage_ctx.caller, MapSet.new(), %{
          layer: "user",
          key: "agent.soul",
          path: ["cap_denial_probe"]
        })

      assert match?({:error, _}, result),
             "delete_path with empty caps must fail; got: #{inspect(result)}"

      # The field EXISTS, so the body-read succeeds and the auth gate MUST fire.
      # Pin the reason: we expect :unauthorized or :cross_workspace_denied.
      # If instead we see :config_not_found/:path_not_found, auth-ordering is broken
      # (the gate did not fire on an existing field) — that is a real bug, not a
      # test fudge.
      {:error, reason} = result

      assert reason in [:missing_cap, :unauthorized, :cross_workspace_denied],
             "cap-denial on an existing field must be :unauthorized or :cross_workspace_denied; got: #{inspect(reason)}"

      body_after = user_layer_body(agent_uri, "agent.soul", manage_ctx)

      assert is_map(body_after) and Map.has_key?(body_after, "cap_denial_probe"),
             "field must still exist after cap-denied delete_path; body_after: #{inspect(body_after)}"
    end
  end

  # ── (e) invalid_patch reason code ───────────────────────────────────────────

  describe "agents.config reason codes — invalid_patch" do
    @tag :integration
    test "apply_delta with non-map patch returns {:error, :invalid_patch}",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {agent_uri, manage_ctx} = create_curl_agent(workspace_uri, admin_ctx)

      result =
        Config.apply_delta(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
          layer: "user",
          key: "agent.soul",
          patch: "not-a-map"
        })

      assert result == {:error, :invalid_patch},
             "non-map patch must return {:error, :invalid_patch}; got: #{inspect(result)}"
    end
  end

  # ── (f) path_not_found reason code ──────────────────────────────────────────

  describe "agents.config reason codes — path_not_found" do
    @tag :integration
    test "delete_path on a nonexistent key in an existing config returns path_not_found or config_not_found",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {agent_uri, manage_ctx} = create_curl_agent(workspace_uri, admin_ctx)

      # Write an initial body so the config object EXISTS (otherwise we'd get config_not_found
      # from layer_objects_for_key returning nil — that's a different code).
      assert {:ok, _} =
               Config.apply_delta(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
                 layer: "user",
                 key: "agent.soul",
                 patch: %{"some_field" => "value"}
               })

      # Now delete a path that does NOT exist in that config body.
      result =
        Config.delete_path(agent_uri, manage_ctx.caller, manage_ctx.caps, %{
          layer: "user",
          key: "agent.soul",
          path: ["nonexistent_field"]
        })

      assert result == {:error, :path_not_found},
             "delete_path on nonexistent field must return {:error, :path_not_found}; got: #{inspect(result)}"
    end
  end
end
