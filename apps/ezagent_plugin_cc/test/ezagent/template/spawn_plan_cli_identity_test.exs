defmodule Ezagent.PluginCc.Template.SpawnPlanCliIdentityTest do
  @moduledoc """
  Phase 3 ③ T7d — the CLI-identity env a ROLE-agent's `claude` brain needs to act
  through the ezagent CLI (`mix ezagent <verb>`) AS ITSELF.

  Gap#1 (T7b surface): a materialized pm/dev role-agent held its caps + skill but
  could NOT actually drive `mix ezagent kanban.* / github.*`, because the cc
  sidecar's process env carried only the BRIDGE token (`EZAGENT_AGENT_TOKEN`,
  verified by `AgentBridge.TokenStore`) — NOT the `entity_tokens` credential
  (`EZAGENT_USER_TOKEN` + `EZAGENT_ENTITY_URI`) that `EzagentCli.Exec` requires.
  Without it every CLI call fails CLOSED ("CLI calls require authentication").

  This pins the fix at the `SpawnPlan.maybe_put_cli_identity_env/3` seam:

    * a role-agent gets BOTH env vars, and the minted token ACTUALLY
      authenticates as that agent through the SAME `Ezagent.Entity.authenticate/2`
      path the CLI uses — scoped to the agent's own identity (no admin fallback);
    * a role-less legacy cc agent gets neither (no behavior change);
    * the exported `EZAGENT_ENTITY_URI` round-trips through `Ezagent.URI.new!/1`
      (the exact parse `EzagentCli.Exec.resolve_caller/2` runs).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.SpawnPlan

  defp uniq, do: System.unique_integer([:positive])

  defp agent_uri, do: Ezagent.URI.agent("team-alpha", "pm-coordinator-#{uniq()}")

  defp tmpl(role) do
    base = %{"class" => "cc.agent", "cwd" => System.tmp_dir!()}

    case role do
      :__omit__ -> base
      r -> Map.put(base, "role", r)
    end
  end

  describe "maybe_put_cli_identity_env/3 — role-agent gets a working CLI bearer token" do
    test "injects EZAGENT_USER_TOKEN + EZAGENT_ENTITY_URI that authenticate as the agent" do
      uri = agent_uri()

      env = SpawnPlan.maybe_put_cli_identity_env(%{}, uri, tmpl("pm-coordinator"))

      token = env["EZAGENT_USER_TOKEN"]
      entity_uri = env["EZAGENT_ENTITY_URI"]

      assert is_binary(token) and token != ""
      assert entity_uri == Ezagent.URI.stable_key(uri)

      # The token authenticates as THIS agent through the exact path the CLI uses
      # (parse the env URI string → authenticate) — proving it is a usable
      # entity-token credential, not just any string.
      parsed = Ezagent.URI.new!(entity_uri)
      assert {:ok, %{caps: _}} = Ezagent.Entity.authenticate(parsed, token)
    end

    test "the token is scoped to the agent — a DIFFERENT agent's URI rejects it" do
      uri = agent_uri()
      other = agent_uri()

      env = SpawnPlan.maybe_put_cli_identity_env(%{}, uri, tmpl("dev-together"))
      token = env["EZAGENT_USER_TOKEN"]

      # No cross-agent acceptance: the bearer token is bound to its own entity URI.
      assert {:error, _} = Ezagent.Entity.authenticate(other, token)
    end

    test "is generic over any role name (orchestrator too — not a per-role branch)" do
      env = SpawnPlan.maybe_put_cli_identity_env(%{}, agent_uri(), tmpl("orchestrator"))
      assert is_binary(env["EZAGENT_USER_TOKEN"])
      assert is_binary(env["EZAGENT_ENTITY_URI"])
    end
  end

  describe "maybe_put_cli_identity_env/3 — role-less cc agent is untouched" do
    test "no role field → no CLI-identity env" do
      env = SpawnPlan.maybe_put_cli_identity_env(%{"X" => "1"}, agent_uri(), tmpl(:__omit__))
      assert env == %{"X" => "1"}
    end

    test "role \"default\" → no CLI-identity env" do
      env = SpawnPlan.maybe_put_cli_identity_env(%{}, agent_uri(), tmpl("default"))
      refute Map.has_key?(env, "EZAGENT_USER_TOKEN")
      refute Map.has_key?(env, "EZAGENT_ENTITY_URI")
    end
  end
end
