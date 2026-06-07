defmodule EzagentDomainSocialware.Integration.ConfigConsumeTest do
  @moduledoc """
  #607 — the CONSUME half of P6 self-evolve (spec §7 steps 4–5, plan P6.4).

  PR #606 made the config write-only: `ConfigStore` wrote immutable objects + a
  pointer but NOTHING read them into the #17 cascade. These tests assert the
  config-delta is actually MATERIALIZED through the real #17 respawn seam
  (`Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data/2` →
  `Ezagent.UriQuery.resolve(:config_dir, _)` → `Ezagent.Agent.Materializer.merge_layers/2`),
  so a respawned agent's resolved soul (`CLAUDE.md`) CHANGES, and rollback
  (repoint to the prior immutable object) REVERTS it.

  This is the production path, not a self-read of `ConfigStore.resolve`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Materializer
  alias Ezagent.Credential.CascadeRuntime
  alias Ezagent.Entity.User
  alias Ezagent.Invocation
  alias Ezagent.Socialware.{CascadeRepoint, ConfigProjection, ConfigStore}

  @key "advisor.behavior"

  defp agent_uri do
    Ezagent.URI.entity(
      :team_alpha,
      :agent,
      "advisor-consume-#{System.unique_integer([:positive])}"
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
  # cascade layer points at the socialware config pointer's resource URI, and
  # return the merged config_dir's resolved soul (CLAUDE.md contents).
  defp materialized_soul(agent, workspace, pointer_uri, source) do
    resolution = %{
      owner_uri: User.admin_uri() |> URI.to_string(),
      workspace_uri: URI.to_string(workspace),
      # The high cascade layer (user) is repointed at the immutable config object
      # via the socialware pointer's resource URI.
      user_layer_uri: URI.to_string(pointer_uri),
      # Approved credential source (the normal cc respawn shape).
      credential_source_uri: URI.to_string(source),
      explicit_source: URI.to_string(source)
    }

    respawn_data = %{"flavor" => "cc", "cascade_resolution" => resolution}

    {:ok, rehydrated} = CascadeRuntime.rehydrate_respawn_data(agent, respawn_data)
    cascade = Map.fetch!(rehydrated, "cascade")
    layers = Map.fetch!(cascade, :layer_dirs)

    staging =
      Path.join(System.tmp_dir!(), "consume-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(staging) end)
    :ok = Materializer.merge_layers(staging, layers)

    File.read!(Path.join(staging, "CLAUDE.md"))
  end

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

    pointer_uri = ConfigProjection.pointer_uri(:user, workspace, agent, @key)
    source = seed_source(workspace)

    %{agent: agent, workspace: workspace, seed: seed, pointer_uri: pointer_uri, source: source}
  end

  test "a repointed config-delta re-materializes on next spawn and a rollback reverts it", ctx do
    before_soul = materialized_soul(ctx.agent, ctx.workspace, ctx.pointer_uri, ctx.source)
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

    # ── next spawn re-materializes the pointed-at config (the consume seam) ──
    changed_soul = materialized_soul(ctx.agent, ctx.workspace, ctx.pointer_uri, ctx.source)
    assert changed_soul =~ "decisive"
    refute changed_soul =~ "neutral"
    assert changed_soul != before_soul

    # ── rollback = repoint to the prior immutable object ──
    {:ok, _} =
      ConfigStore.put_pointer(%{
        layer: :user,
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: @key,
        config_id: ctx.seed.config_id,
        actor_uri: User.admin_uri(),
        source_turn_id: "rollback"
      })

    reverted_soul = materialized_soul(ctx.agent, ctx.workspace, ctx.pointer_uri, ctx.source)
    assert reverted_soul == before_soul
    assert reverted_soul =~ "neutral"
    refute reverted_soul =~ "decisive"
  end

  test "CascadeRepoint sets a LIVE agent's user cascade layer at the config pointer", ctx do
    # Spawn a real Agent Kind and seed its sandbox with a cascade_resolution
    # (the shape #17 stores at create), so the repoint can read + rewrite it.
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: ctx.agent})

    initial_resolution = %{
      "owner_uri" => URI.to_string(User.admin_uri()),
      "workspace_uri" => URI.to_string(ctx.workspace),
      "user_layer_uri" => URI.to_string(User.admin_uri())
    }

    sys_ctx = %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.write_path"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-config-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: %{"cascade_resolution" => initial_resolution}
        },
        ctx: sys_ctx
      })

    assert :ok =
             CascadeRepoint.repoint_user_layer(
               ctx.agent,
               :user,
               ctx.workspace,
               ctx.agent,
               @key,
               sys_ctx
             )

    {:ok, sandbox} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: sys_ctx
      })

    resolution = sandbox.respawn_template_data["cascade_resolution"]
    assert resolution["user_layer_uri"] == URI.to_string(ctx.pointer_uri)
    # Other resolution fields preserved (no clobber).
    assert resolution["owner_uri"] == URI.to_string(User.admin_uri())
  end
end
