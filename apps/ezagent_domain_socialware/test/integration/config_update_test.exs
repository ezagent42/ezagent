defmodule EzagentDomainSocialware.Integration.ConfigUpdateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentLineage, Invocation}
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
    dispatch_as(
      session_uri,
      behavior,
      action,
      args,
      Ezagent.SystemPrincipal.caps("system://bootstrap")
    )
  end

  # Dispatch with an explicit caller cap set (#607 round-2 HIGH — exercise the
  # ordinary session-scoped user path, not the bootstrap wildcard).
  defp dispatch_as(session_uri, behavior, action, args, caps) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: caps,
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
    # #607 codex CRITICAL — apply_delta is object-keyed: write the immutable
    # object, repoint the subject agent's user cascade layer at it, THEN advance
    # the bookkeeping pointer. The agent must be live with a cascade_resolution
    # for the repoint (and thus the config change) to succeed.
    spawn_agent_with_cascade(ctx.agent, ctx.workspace, ctx.session)

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
    # #607 confused-deputy guard — make this session manage the subject so the
    # test exercises the no-cascade failure, not the authority rejection.
    :ok = AgentLineage.record(ctx.agent, ctx.session)

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

  # #607 codex CRITICAL — object-keyed apply_delta is ATOMIC by ordering:
  # write immutable object → repoint agent layer → put_pointer (bookkeeping) LAST.
  # If the repoint fails (here: subject agent has no cascade_resolution → loud
  # error), put_pointer never runs, so the pointer MUST still resolve to the PRIOR
  # object (only an unreferenced orphan object was written — non-harmful).
  test "a failed repoint leaves the config pointer unchanged (atomic)", ctx do
    # Seed a USER-layer pointer (distinct key from the :workspace seed) and an
    # agent with a sandbox but NO cascade_resolution so the repoint fails loud.
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: ctx.agent})
    # #607 confused-deputy guard — make this session manage the subject so the
    # test exercises the repoint-failure ordering, not the authority rejection.
    :ok = AgentLineage.record(ctx.agent, ctx.session)

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

    # The repoint failed (step 2) → put_pointer (step 3) never ran. BOTH durable
    # stores are consistent (no partial):
    #
    #   * ConfigStore — the pointer MUST still resolve to the prior object (the
    #     only residue is an unreferenced immutable orphan object from step 1,
    #     which is non-harmful in an append-only store).
    after_fail = ConfigStore.resolve!(:user, ctx.workspace, ctx.agent, "advisor.behavior")
    assert after_fail.id == before.id
    assert after_fail.body == %{"tone" => "neutral"}
    refute after_fail.body["tone"] == "decisive"

    #   * agent sandbox — the user cascade layer MUST NOT have been advanced
    #     (the agent had no cascade_resolution, so the read failed before any
    #     write; the layer is absent, never pointing at the new object).
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

    refute Map.has_key?(sandbox.respawn_template_data || %{}, "cascade_resolution")
  end

  # #607 codex round-2 HIGH — the legit approved-turn SW-UPD flow must succeed
  # for a NON-admin caller holding only ordinary session-scoped caps. The
  # downstream sandbox read/write on the target agent run under
  # `system://agent-internal`; if CascadeRepoint forwarded the caller's caps the
  # repoint would fail `:unauthorized` because `User.default_caps/1` is
  # session-scoped, NOT Sandbox-on-the-target-agent. Drive the full settle →
  # apply_delta via dispatch with `User.default_caps(workspace)` and assert the
  # live-agent repoint SUCCEEDS (the config actually changes).
  test "apply_delta succeeds under ordinary session-scoped user caps (non-bootstrap)", ctx do
    spawn_agent_with_cascade(ctx.agent, ctx.workspace, ctx.session)
    user_caps = MapSet.new(User.default_caps(ctx.workspace))

    {:ok, %{turn_id: turn_id}} =
      dispatch_as(
        ctx.session,
        :turn,
        :open,
        %{trigger: %{message_id: "ud"}, opened_at: 1},
        user_caps
      )

    {:ok, _} =
      dispatch_as(
        ctx.session,
        :turn,
        :compose,
        %{
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
        },
        user_caps
      )

    {:ok, _} =
      dispatch_as(
        ctx.session,
        :turn,
        :claim,
        %{turn_id: turn_id, by: User.admin_uri()},
        user_caps
      )

    {:ok, _} = dispatch_as(ctx.session, :turn, :settle, %{turn_id: turn_id}, user_caps)

    # Drive apply_delta synchronously under ordinary session-scoped caps. The
    # sandbox repoint (agent-internal effect) MUST succeed — proving the
    # internal-principal path, not the caller's caps.
    assert {:ok, %{config_id: config_id, repoint_status: :repointed}} =
             dispatch_as(
               ctx.session,
               :config_update,
               :apply_delta,
               %{turn_id: turn_id},
               user_caps
             )

    changed = ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior")
    assert changed.id == config_id
    assert changed.body["tone"] == "decisive"
  end

  # #607 codex round-2 HIGH (companion) — widening did NOT happen: an apply_delta
  # whose CALLER holds NO caps for the action is still rejected at the dispatch
  # gate (the action itself is cap-checked; only the downstream agent-internal
  # sandbox effect runs under the system principal).
  test "apply_delta itself is rejected when the caller lacks the action cap", ctx do
    spawn_agent_with_cascade(ctx.agent, ctx.workspace, ctx.session)

    {:ok, %{turn_id: turn_id}} =
      dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "unauth"}, opened_at: 1})

    {:ok, _} =
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

    {:ok, _} = dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})
    {:ok, _} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    # Empty caps → the apply_delta action gate rejects before any effect runs.
    assert {:error, _} =
             dispatch_as(
               ctx.session,
               :config_update,
               :apply_delta,
               %{turn_id: turn_id},
               MapSet.new()
             )
  end

  # #607 codex CRITICAL — confused-deputy: a session-scoped caller settles a
  # delta whose `subject_uri` is an agent in ANOTHER workspace (tenant B). The
  # authoritative workspace is derived from `ctx.self_uri` (this session, in
  # team_alpha), NOT from the caller-supplied delta, so apply_delta MUST reject
  # before any object is written or any repoint occurs — agent B is untouched.
  test "apply_delta rejects a delta whose subject_uri is an agent in another workspace", ctx do
    spawn_agent_with_cascade(ctx.agent, ctx.workspace, ctx.session)

    # An agent + workspace in a DIFFERENT tenant (team_beta).
    foreign_workspace = Ezagent.URI.workspace(:team_beta)

    foreign_agent =
      Ezagent.URI.entity(:team_beta, :agent, "foreign-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: foreign_agent})

    {:ok, foreign_seed} =
      ConfigStore.write_and_point(%{
        layer: :workspace,
        workspace_uri: foreign_workspace,
        subject_uri: foreign_agent,
        key: "advisor.behavior",
        body: %{"tone" => "foreign-original"},
        actor_uri: User.admin_uri(),
        source_turn_id: "foreign-seed"
      })

    {:ok, %{turn_id: turn_id}} =
      dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "xtenant"}, opened_at: 1})

    {:ok, _} =
      dispatch(ctx.session, :turn, :compose, %{
        turn_id: turn_id,
        result_refs: [
          %{
            kind: :config_delta,
            layer: :workspace,
            workspace_uri: foreign_workspace,
            subject_uri: foreign_agent,
            key: "advisor.behavior",
            patch: %{"tone" => "injected"}
          }
        ]
      })

    {:ok, _} = dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})
    {:ok, _} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    assert {:error, {:cross_tenant_target, _}} =
             dispatch(ctx.session, :config_update, :apply_delta, %{turn_id: turn_id})

    # Tenant B's config is unchanged + no new object was written for it.
    assert ConfigStore.resolve!(:workspace, foreign_workspace, foreign_agent, "advisor.behavior").id ==
             foreign_seed.config_id

    assert ConfigStore.resolve!(:workspace, foreign_workspace, foreign_agent, "advisor.behavior").body ==
             %{"tone" => "foreign-original"}
  end

  # #607 codex CRITICAL — the `repoint` action carries caller-supplied
  # workspace_uri/subject_uri/config_id. Same guard: a repoint naming a
  # cross-tenant agent is rejected before the agent-internal repoint runs.
  test "repoint rejects a cross-tenant subject_uri", ctx do
    foreign_workspace = Ezagent.URI.workspace(:team_beta)

    foreign_agent =
      Ezagent.URI.entity(:team_beta, :agent, "foreign-rp-#{System.unique_integer([:positive])}")

    {:ok, foreign_seed} =
      ConfigStore.write_and_point(%{
        layer: :workspace,
        workspace_uri: foreign_workspace,
        subject_uri: foreign_agent,
        key: "advisor.behavior",
        body: %{"tone" => "foreign-original"},
        actor_uri: User.admin_uri(),
        source_turn_id: "foreign-rp-seed"
      })

    assert {:error, {:cross_tenant_target, _}} =
             dispatch(ctx.session, :config_update, :repoint, %{
               layer: :workspace,
               workspace_uri: foreign_workspace,
               subject_uri: foreign_agent,
               key: "advisor.behavior",
               config_id: foreign_seed.config_id
             })
  end

  # #607 codex CRITICAL — a subject agent in THIS session's workspace but NOT
  # managed by this session (no membership, no spawn-lineage) is rejected.
  # Same-workspace co-residence is not authority.
  test "apply_delta rejects an in-workspace agent not managed by this session", ctx do
    # An agent in team_alpha (same workspace) with a live cascade'd sandbox, but
    # NOT spawned by / joined to this session.
    unmanaged = agent_uri()
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: unmanaged})
    # Deliberately NO AgentLineage.record(unmanaged, ctx.session) and no join.

    {:ok, unmanaged_seed} =
      ConfigStore.write_and_point(%{
        layer: :workspace,
        workspace_uri: ctx.workspace,
        subject_uri: unmanaged,
        key: "advisor.behavior",
        body: %{"tone" => "unmanaged-original"},
        actor_uri: User.admin_uri(),
        source_turn_id: "unmanaged-seed"
      })

    {:ok, %{turn_id: turn_id}} =
      dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "unmanaged"}, opened_at: 1})

    {:ok, _} =
      dispatch(ctx.session, :turn, :compose, %{
        turn_id: turn_id,
        result_refs: [
          %{
            kind: :config_delta,
            layer: :workspace,
            workspace_uri: ctx.workspace,
            subject_uri: unmanaged,
            key: "advisor.behavior",
            patch: %{"tone" => "injected"}
          }
        ]
      })

    {:ok, _} = dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})
    {:ok, _} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    assert {:error, {:subject_not_managed_by_session, _}} =
             dispatch(ctx.session, :config_update, :apply_delta, %{turn_id: turn_id})

    # The unmanaged agent's config is unchanged.
    assert ConfigStore.resolve!(:workspace, ctx.workspace, unmanaged, "advisor.behavior").id ==
             unmanaged_seed.config_id
  end

  # #607 codex round-4 HIGH — the `repoint`/rollback path repointed the agent
  # BEFORE validating the caller-supplied `config_id`. A NONEXISTENT config_id
  # must be rejected `{:error, :config_not_found}` with NO side effect: the target
  # agent's sandbox `user_layer_uri` MUST be unchanged (no partial write).
  test "repoint rejects a nonexistent config_id and leaves the sandbox unchanged", ctx do
    spawn_agent_with_cascade(ctx.agent, ctx.workspace, ctx.session)

    before_uri = sandbox_user_layer_uri(ctx.agent)
    # The cascade seed sets user_layer_uri to the admin URI (NOT a config object).
    assert before_uri == URI.to_string(User.admin_uri())

    missing_config_id = Ecto.UUID.generate()

    assert {:error, :config_not_found} =
             dispatch(ctx.session, :config_update, :repoint, %{
               layer: :workspace,
               workspace_uri: ctx.workspace,
               subject_uri: ctx.agent,
               key: "advisor.behavior",
               config_id: missing_config_id
             })

    # No partial write: the sandbox layer was never repointed at the missing object.
    assert sandbox_user_layer_uri(ctx.agent) == before_uri
  end

  # #607 codex round-4 HIGH — a config_id whose object belongs to ANOTHER
  # workspace/subject must be rejected loudly BEFORE any side effect; the target
  # agent's sandbox MUST be unchanged (no mismatched pointer persisted).
  test "repoint rejects a config_id for another workspace/subject and leaves the sandbox unchanged",
       ctx do
    spawn_agent_with_cascade(ctx.agent, ctx.workspace, ctx.session)

    before_uri = sandbox_user_layer_uri(ctx.agent)
    assert before_uri == URI.to_string(User.admin_uri())

    # An immutable object owned by a DIFFERENT tenant (team_beta).
    foreign_workspace = Ezagent.URI.workspace(:team_beta)

    foreign_agent =
      Ezagent.URI.entity(:team_beta, :agent, "foreign-obj-#{System.unique_integer([:positive])}")

    {:ok, foreign_object} =
      ConfigStore.write_config(%{
        workspace_uri: foreign_workspace,
        subject_uri: foreign_agent,
        key: "advisor.behavior",
        body: %{"tone" => "foreign"},
        actor_uri: User.admin_uri(),
        source_turn_id: "foreign-obj-seed"
      })

    # Caller names AUTHORIZED workspace/subject (passes authorize_target) but a
    # config_id whose object is owned by tenant B → loud cross_tenant_target.
    assert {:error, {:cross_tenant_target, %{field: :config_id}}} =
             dispatch(ctx.session, :config_update, :repoint, %{
               layer: :workspace,
               workspace_uri: ctx.workspace,
               subject_uri: ctx.agent,
               key: "advisor.behavior",
               config_id: foreign_object.id
             })

    # No partial write: the sandbox layer was never repointed at the foreign object.
    assert sandbox_user_layer_uri(ctx.agent) == before_uri
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
  #
  # #607 codex CRITICAL — also record agent←session spawn lineage so the
  # confused-deputy guard recognizes this session as managing the subject agent
  # (the production reality: the optimizer's subject agent is one the session
  # spawned/manages). Without this the legit apply_delta is correctly rejected.
  defp spawn_agent_with_cascade(agent_uri, workspace_uri, session_uri) do
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent_uri})
    :ok = AgentLineage.record(agent_uri, session_uri)

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

  # Read the target agent's persisted `cascade_resolution.user_layer_uri` so a
  # test can assert the sandbox was (or was not) repointed. Returns nil when no
  # cascade_resolution / user_layer_uri is present.
  defp sandbox_user_layer_uri(agent_uri) do
    {:ok, sandbox} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    resolution =
      case Map.get(sandbox, :respawn_template_data) do
        %{} = rtd -> rtd["cascade_resolution"] || rtd[:cascade_resolution]
        _ -> nil
      end

    case resolution do
      %{} = res -> res["user_layer_uri"] || res[:user_layer_uri]
      _ -> nil
    end
  end

  defp restart_session(session_uri) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(session_uri)

    :ok =
      DynamicSupervisor.terminate_child(EzagentDomainSocialware.SocialwareSessionSupervisor, pid)

    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session_uri})
    :ok
  end
end
