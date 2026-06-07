defmodule EzagentDomainSocialware.Integration.ConfigUpdateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Entity.{Agent, SocialwareSession, User}
  alias Ezagent.Socialware.ConfigStore

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "config-update-#{System.unique_integer([:positive])}"
    )
  end

  defp agent_uri do
    Ezagent.URI.entity(
      :team_alpha,
      :agent,
      "advisor-config-#{System.unique_integer([:positive])}"
    )
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    agent = agent_uri()
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    {:ok, seed} =
      ConfigStore.write_and_point(%{
        layer: :workspace,
        workspace_uri: workspace,
        subject_uri: agent,
        key: "advisor.behavior",
        body: %{"tone" => "neutral", "cta" => "compare"},
        actor_uri: User.admin_uri(),
        source_turn_id: "seed"
      })

    %{session: session, workspace: workspace, agent: agent, seed: seed}
  end

  test "immutable config changes via settled turn and rollback repoints deterministically", ctx do
    # #607 codex CRITICAL — apply_delta repoints the subject agent's user
    # cascade layer BEFORE advancing the config pointer, so the agent must be
    # live with a cascade_resolution for the repoint (and thus the config
    # change) to succeed.
    spawn_agent_with_cascade(ctx.agent, ctx.workspace)

    before = ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior")

    assert before.id == ctx.seed.config_id
    assert before.body == %{"tone" => "neutral", "cta" => "compare"}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{
                   kind: :config_delta,
                   layer: :workspace,
                   workspace_uri: ctx.workspace,
                   subject_uri: ctx.agent,
                   key: "advisor.behavior",
                   patch: %{"tone" => "decisive"}
                 }
               ]
             })

    assert {:ok, %{status: :awaiting_human}} =
             dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    changed =
      wait_for_config(ctx.workspace, ctx.agent, "advisor.behavior", fn config ->
        config.body["tone"] == "decisive"
      end)

    assert changed.id != before.id
    assert changed.body == %{"tone" => "decisive", "cta" => "compare"}
    assert ConfigStore.get!(before.id).body == before.body

    assert {:ok, %{config_id: prior_id}} =
             dispatch(ctx.session, :config_update, :repoint, %{
               layer: :workspace,
               workspace_uri: ctx.workspace,
               subject_uri: ctx.agent,
               key: "advisor.behavior",
               config_id: before.id
             })

    assert prior_id == before.id

    assert ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior").body ==
             before.body

    restart_session(ctx.session)

    assert ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior").body ==
             before.body
  end

  # #607 codex HIGH — a config-delta whose subject agent has a sandbox but NO
  # `cascade_resolution` (a pre-cascade / non-credentialled agent) cannot
  # consume a `user_layer_uri`: nothing durably records the pointer in the
  # agent's spawn source, so a cold next-spawn would NEVER resolve it. Reporting
  # success/`:deferred` would be a silent no-op falsely claiming the config was
  # applied. apply_delta MUST fail loud in this case.
  test "apply_delta fails loud when the subject agent has no cascade_resolution", ctx do
    # A subject agent with a live sandbox but no cascade_resolution.
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: ctx.agent})

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.write_path"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-no-cascade-#{System.unique_integer([:positive])}",
          template_class: nil,
          # respawn_template_data present but WITHOUT cascade_resolution.
          respawn_template_data: %{"flavor" => "cc"}
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    {:ok, %{turn_id: turn_id}} =
      dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "no-cascade"}, opened_at: 1})

    {:ok, _} =
      dispatch(ctx.session, :turn, :compose, %{
        turn_id: turn_id,
        result_refs: [
          %{
            kind: :config_delta,
            layer: :user,
            workspace_uri: ctx.workspace,
            subject_uri: ctx.agent,
            key: "advisor.behavior",
            patch: %{"tone" => "decisive"}
          }
        ]
      })

    {:ok, _} = dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})
    {:ok, _} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    # Drive apply_delta directly (synchronous :call) so we observe its outcome,
    # not the fire-and-forget effect settle already issued.
    assert {:error, reason} =
             dispatch(ctx.session, :config_update, :apply_delta, %{turn_id: turn_id})

    assert reason in [:no_cascade_resolution] or
             match?({:no_cascade_resolution, _}, reason) or
             (is_tuple(reason) and elem(reason, 0) == :no_cascade_resolution)
  end

  # #607 codex CRITICAL — pointer-advance and cascade-repoint must be ATOMIC.
  # `write_and_point` advances the mutable pointer; if the subsequent repoint
  # fails (here: subject agent has no cascade_resolution → loud error), the
  # action returns error but the pointer MUST NOT be left advanced — otherwise a
  # later spawn consumes a config the repoint rejected. Assert the pointer still
  # resolves to the PRIOR object after a failed repoint.
  test "a failed repoint leaves the config pointer unchanged (atomic)", ctx do
    # Seed a USER-layer pointer (distinct key from the :workspace seed) and an
    # agent with a sandbox but NO cascade_resolution so the repoint fails loud.
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: ctx.agent})

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(ctx.agent)}?action=sandbox.write_path"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-atomic-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: %{"flavor" => "cc"}
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    {:ok, user_seed} =
      ConfigStore.write_and_point(%{
        layer: :user,
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: "advisor.behavior",
        body: %{"tone" => "neutral"},
        actor_uri: User.admin_uri(),
        source_turn_id: "user-seed"
      })

    before = ConfigStore.resolve!(:user, ctx.workspace, ctx.agent, "advisor.behavior")
    assert before.id == user_seed.config_id

    {:ok, %{turn_id: turn_id}} =
      dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "atomic"}, opened_at: 1})

    {:ok, _} =
      dispatch(ctx.session, :turn, :compose, %{
        turn_id: turn_id,
        result_refs: [
          %{
            kind: :config_delta,
            layer: :user,
            workspace_uri: ctx.workspace,
            subject_uri: ctx.agent,
            key: "advisor.behavior",
            patch: %{"tone" => "decisive"}
          }
        ]
      })

    {:ok, _} = dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})
    {:ok, _} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    assert {:error, _} = dispatch(ctx.session, :config_update, :apply_delta, %{turn_id: turn_id})

    # The repoint failed — the pointer MUST still resolve to the prior object.
    after_fail = ConfigStore.resolve!(:user, ctx.workspace, ctx.agent, "advisor.behavior")
    assert after_fail.id == before.id
    assert after_fail.body == %{"tone" => "neutral"}
    refute after_fail.body["tone"] == "decisive"
  end

  test "two writes retain two distinct immutable config objects", ctx do
    {:ok, first} =
      ConfigStore.write_config(%{
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: "advisor.behavior",
        body: %{"tone" => "first"},
        actor_uri: User.admin_uri(),
        source_turn_id: "manual-1"
      })

    {:ok, second} =
      ConfigStore.write_config(%{
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: "advisor.behavior",
        body: %{"tone" => "second"},
        actor_uri: User.admin_uri(),
        source_turn_id: "manual-2"
      })

    assert first.id != second.id
    assert ConfigStore.get!(first.id).body == %{"tone" => "first"}
    assert ConfigStore.get!(second.id).body == %{"tone" => "second"}
  end

  defp wait_for_config(workspace_uri, subject_uri, key, predicate, attempts \\ 100)

  defp wait_for_config(_workspace_uri, _subject_uri, _key, _predicate, 0),
    do: flunk("config never changed")

  defp wait_for_config(workspace_uri, subject_uri, key, predicate, attempts) do
    config = ConfigStore.resolve!(:workspace, workspace_uri, subject_uri, key)

    if predicate.(config) do
      config
    else
      Process.sleep(20)
      wait_for_config(workspace_uri, subject_uri, key, predicate, attempts - 1)
    end
  end

  # Spawn the subject Agent Kind and seed its sandbox with a cascade_resolution
  # (the shape #17 stores at create) so CascadeRepoint can read + rewrite the
  # user layer — the precondition the atomic apply_delta now enforces.
  defp spawn_agent_with_cascade(agent_uri, workspace_uri) do
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent_uri})

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=sandbox.write_path"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-cascade-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: %{
            "flavor" => "cc",
            "cascade_resolution" => %{
              "owner_uri" => URI.to_string(User.admin_uri()),
              "workspace_uri" => URI.to_string(workspace_uri),
              "user_layer_uri" => URI.to_string(User.admin_uri())
            }
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  defp restart_session(session_uri) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(session_uri)

    :ok =
      DynamicSupervisor.terminate_child(EzagentDomainSocialware.SocialwareSessionSupervisor, pid)

    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session_uri})
    :ok
  end
end
