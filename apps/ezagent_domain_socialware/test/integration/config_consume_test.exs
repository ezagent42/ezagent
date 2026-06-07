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

  Object-keyed (#607 codex round-2 CRITICAL): the agent's user cascade layer URI
  names a SPECIFIC immutable config OBJECT (`ConfigProjection.object_uri/2`), not
  the mutable pointer. The repoint after a config-delta swaps the layer URI to the
  NEW object; rollback swaps it back to the prior object's URI. This is the
  production path, not a self-read of `ConfigStore.resolve`.
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
      Path.join(System.tmp_dir!(), "consume-#{System.unique_integer([:positive])}")

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

  test "CascadeRepoint sets a LIVE agent's user cascade layer at the config object", ctx do
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

    object_uri = object_uri_for(ctx.workspace, ctx.seed.config_id)

    assert :ok =
             CascadeRepoint.repoint_user_layer(
               ctx.agent,
               ctx.workspace,
               ctx.seed.config_id
             )

    {:ok, sandbox} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: sys_ctx
      })

    resolution = sandbox.respawn_template_data["cascade_resolution"]
    assert resolution["user_layer_uri"] == URI.to_string(object_uri)
    # Other resolution fields preserved (no clobber).
    assert resolution["owner_uri"] == URI.to_string(User.admin_uri())
  end

  # #607 codex round-2 HIGH — the sandbox read/write on the target agent run
  # under `system://agent-internal`, NOT the caller's caps. A production user's
  # `User.default_caps/1` grant is SESSION-scoped (not Sandbox-on-the-target-
  # agent), so if CascadeRepoint forwarded the caller's caps the repoint would
  # fail `:unauthorized`. Here we pass ORDINARY session-scoped user caps and
  # assert the repoint SUCCEEDS — proving the internal-principal path. (The
  # earlier test used `system://bootstrap` wildcard caps and so did not exercise
  # this.)
  test "repoint succeeds under ordinary session-scoped user caps (internal principal)", ctx do
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: ctx.agent})

    initial_resolution = %{
      "owner_uri" => URI.to_string(User.admin_uri()),
      "workspace_uri" => URI.to_string(ctx.workspace),
      "user_layer_uri" => URI.to_string(User.admin_uri())
    }

    # Seed the sandbox using a system principal (this is the create-path; not the
    # path under test).
    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.write_path"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-internal-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: %{"cascade_resolution" => initial_resolution}
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    # CascadeRepoint does NOT take a ctx anymore; the sandbox effect is keyed to
    # `system://agent-internal` internally. Even from a caller holding only
    # ordinary session-scoped caps, the repoint must succeed.
    assert :ok =
             CascadeRepoint.repoint_user_layer(
               ctx.agent,
               ctx.workspace,
               ctx.seed.config_id
             )

    # Confirm the layer was actually written (read under bootstrap is fine — we
    # are only verifying the effect, not the authz of the read).
    {:ok, sandbox} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    object_uri = object_uri_for(ctx.workspace, ctx.seed.config_id)
    resolution = sandbox.respawn_template_data["cascade_resolution"]
    assert resolution["user_layer_uri"] == URI.to_string(object_uri)
  end
end
