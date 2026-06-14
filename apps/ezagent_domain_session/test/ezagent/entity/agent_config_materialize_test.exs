defmodule Ezagent.Entity.AgentConfigMaterializeTest do
  @moduledoc """
  #607 — the CONSUME half of self-evolve, ported (PR-4) from the deleted
  socialware `config_consume_test.exs` to the Agent domain, where the
  `:config_dir` UriQuery resolver lives (`EzagentDomainInstanceMessage`) and
  the #17 respawn/materialize seam is genuinely exercised.

  Asserts the config-delta is MATERIALIZED through the real #17 respawn seam
  (`Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data/2` →
  `Ezagent.UriQuery.resolve(:config_dir, _)` → `Ezagent.Agent.Materializer.merge_layers/2`),
  so a respawned agent's resolved soul (`CLAUDE.md`) CHANGES on a config-delta,
  and rollback (repoint to the prior immutable object) REVERTS it.

  Object-keyed (#607 codex round-2 CRITICAL): the agent's user cascade layer URI
  names a SPECIFIC immutable config OBJECT (`ConfigProjection.object_uri/2`), not
  the mutable pointer. This is the spawn/respawn READ path — demoted to a cache
  but still LIVE (the agent-owned config-evolve move did not touch it).

  WHY HERE (not identity, where ConfigStore/ConfigProjection now live): the
  `:config_dir` resolver this roundtrip drives is owned by
  `EzagentDomainInstanceMessage` and is NOT registered in identity's test env
  (identity does not depend on instance_message). The two obsolete
  `CascadeRepoint` cases from the original file (direct-consume +
  internal-principal escalation) were DROPPED with the deleted code; only this
  materialization roundtrip is preserved.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Materializer
  alias Ezagent.Credential.CascadeRuntime
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{ConfigProjection, ConfigStore}

  @key "advisor.behavior"

  defp agent_uri do
    Ezagent.URI.entity(
      :team_alpha,
      :agent,
      "advisor-materialize-#{System.unique_integer([:positive])}"
    )
  end

  # A real, available credential source so the #17 cascade resolves through its
  # normal credential path (mirrors a production cc agent's approved source); the
  # soul materialization we assert on is independent of the credential.
  defp seed_source(workspace) do
    source = Ezagent.URI.resource(Ezagent.URI.name!(workspace), "credential-src", "cc-test")
    {:ok, _} = Ezagent.SnapshotStore.write(URI.to_string(source), %{}, kind_type: :agent)
    source
  end

  # Drive the REAL #17 respawn + materialize path for an agent whose `user`
  # cascade layer points at the immutable config OBJECT's resource URI, and
  # return the merged config_dir's resolved soul (CLAUDE.md contents).
  defp materialized_soul(agent, workspace, object_uri, source) do
    resolution = %{
      owner_uri: User.admin_uri() |> URI.to_string(),
      workspace_uri: URI.to_string(workspace),
      # The high cascade layer (user) names the immutable config OBJECT directly.
      user_layer_uri: URI.to_string(object_uri),
      # Approved credential source (the normal cc respawn shape).
      credential_source_uri: URI.to_string(source),
      explicit_source: URI.to_string(source)
    }

    respawn_data = %{"flavor" => "cc", "cascade_resolution" => resolution}

    {:ok, rehydrated} = CascadeRuntime.rehydrate_respawn_data(agent, respawn_data)
    cascade = Map.fetch!(rehydrated, "cascade")
    layers = Map.fetch!(cascade, :layer_dirs)

    staging =
      Path.join(System.tmp_dir!(), "materialize-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(staging) end)
    :ok = Materializer.merge_layers(staging, layers)

    File.read!(Path.join(staging, "CLAUDE.md"))
  end

  defp object_uri_for(workspace, config_id), do: ConfigProjection.object_uri(workspace, config_id)

  setup do
    agent = agent_uri()
    workspace = Ezagent.Capability.workspace_of(agent)

    {:ok, seed} =
      ConfigStore.write_and_point(%{
        layer: :user,
        workspace_uri: workspace,
        subject_uri: agent,
        key: @key,
        body: %{"tone" => "neutral", "cta" => "compare"},
        actor_uri: User.admin_uri(),
        source_turn_id: "seed"
      })

    source = seed_source(workspace)

    %{agent: agent, workspace: workspace, seed: seed, source: source}
  end

  test "a repointed config-delta re-materializes on next spawn and a rollback reverts it", ctx do
    seed_object_uri = object_uri_for(ctx.workspace, ctx.seed.config_id)
    before_soul = materialized_soul(ctx.agent, ctx.workspace, seed_object_uri, ctx.source)
    assert before_soul =~ "neutral"
    assert before_soul =~ "compare"

    # ── config-delta: write a NEW immutable object + repoint the pointer ──
    body = ConfigStore.merge_delta(:user, ctx.workspace, ctx.agent, @key, %{"tone" => "decisive"})

    {:ok, changed} =
      ConfigStore.write_and_point(%{
        layer: :user,
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: @key,
        body: body,
        actor_uri: User.admin_uri(),
        source_turn_id: "delta-1"
      })

    assert changed.config_id != ctx.seed.config_id

    # ── next spawn re-materializes the NEW object (the consume seam) ──
    changed_object_uri = object_uri_for(ctx.workspace, changed.config_id)
    changed_soul = materialized_soul(ctx.agent, ctx.workspace, changed_object_uri, ctx.source)
    assert changed_soul =~ "decisive"
    refute changed_soul =~ "neutral"
    assert changed_soul != before_soul

    # ── rollback = repoint the layer back to the PRIOR immutable object ──
    reverted_soul = materialized_soul(ctx.agent, ctx.workspace, seed_object_uri, ctx.source)
    assert reverted_soul == before_soul
    assert reverted_soul =~ "neutral"
    refute reverted_soul =~ "decisive"
  end
end
