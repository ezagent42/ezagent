defmodule EzagentDomainInstanceMessage.SessionCreator.Materializer do
  @moduledoc false

  alias Ezagent.Invocation
  alias Ezagent.Entity.Session
  alias Ezagent.Session.OrchestratorBinding
  alias Ezagent.Socialware.DefinitionEditor

  def materialize_template_declaration(
        %URI{} = session_uri,
        %URI{} = session_template_uri,
        template_content
      )
      when is_map(template_content) do
    prior = Session.read_template_working_copy(session_uri)

    working_copy =
      prior
      # `orchestrator_template_uri` is valid SessionTemplate DEFINITION data,
      # but it was never a live working-copy binding. Remove old snapshot
      # residue while preserving the authoritative `:orchestrator_uri` value.
      |> Map.delete(:orchestrator_template_uri)
      |> Map.put(:session_template_uri, session_template_uri)
      |> Map.put(
        :member_declarations,
        member_declarations(template_content, session_template_uri)
      )

    case Ezagent.ActionSet.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  @doc """
  Allocate and durably bind the ACTUAL random orchestrator URI before the
  asynchronous role installer can spawn it and expose its bridge seed.

  No orchestrator declaration means no binding. On repair the prior URI is
  retained while a new materialization epoch is committed, so every outcome
  remains discoverable by the URI the bridge already knows.
  """
  @spec prepare_orchestrator_binding(URI.t(), URI.t()) ::
          {:ok, OrchestratorBinding.t() | nil} | {:error, term()}
  def prepare_orchestrator_binding(%URI{} = session_uri, %URI{} = workspace_uri) do
    working_copy = Session.read_template_working_copy(session_uri)

    if orchestrator_declaration?(Map.get(working_copy, :member_declarations, [])) do
      uri = prior_or_new_orchestrator_uri(working_copy, workspace_uri)
      binding = OrchestratorBinding.active(uri, OrchestratorBinding.new_epoch())

      case store_session_orchestrator_binding(session_uri, binding) do
        :ok -> {:ok, binding}
        {:error, _} = error -> error
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec ensure_orchestrator_binding(URI.t(), URI.t()) ::
          {:ok, OrchestratorBinding.t()} | {:error, term()}
  def ensure_orchestrator_binding(%URI{} = session_uri, %URI{} = orchestrator_uri) do
    working_copy = Session.read_template_working_copy(session_uri)

    case OrchestratorBinding.current(working_copy) do
      {:ok, %{uri: %URI{} = ^orchestrator_uri} = binding} ->
        {:ok, binding}

      _ ->
        binding = OrchestratorBinding.active(orchestrator_uri, OrchestratorBinding.new_epoch())

        case store_session_orchestrator_binding(session_uri, binding) do
          :ok -> {:ok, binding}
          {:error, _} = error -> error
        end
    end
  end

  @doc false
  @spec current_orchestrator_binding(URI.t()) ::
          {:ok, OrchestratorBinding.t()} | {:error, term()}
  def current_orchestrator_binding(%URI{} = session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> OrchestratorBinding.current()
  end

  @doc false
  @spec stored_orchestrator_binding(URI.t()) ::
          {:ok, OrchestratorBinding.t()} | {:error, term()}
  def stored_orchestrator_binding(%URI{} = session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> Map.get(:orchestrator_uri)
    |> OrchestratorBinding.decode()
  end

  @doc false
  @spec tombstone_orchestrator_binding(URI.t(), term()) :: :ok | {:error, term()}
  def tombstone_orchestrator_binding(%URI{} = session_uri, reason) do
    working_copy = Session.read_template_working_copy(session_uri)

    with {:ok, binding} <- OrchestratorBinding.decode(Map.get(working_copy, :orchestrator_uri)) do
      epoch =
        Map.get(working_copy, :orchestrator_materialization_epoch) || binding.epoch ||
          OrchestratorBinding.new_epoch()

      store_session_orchestrator_binding(
        session_uri,
        OrchestratorBinding.tombstone(binding.uri, epoch, reason)
      )
    end
  end

  @doc false
  @spec store_session_orchestrator_binding(URI.t(), OrchestratorBinding.t()) ::
          :ok | {:error, term()}
  def store_session_orchestrator_binding(
        %URI{} = session_uri,
        %OrchestratorBinding{} = binding
      ) do
    prior = Session.read_template_working_copy(session_uri)

    prior_uri =
      case OrchestratorBinding.decode(Map.get(prior, :orchestrator_uri)) do
        {:ok, %{uri: %URI{} = uri}} -> uri
        _ -> nil
      end

    working_copy =
      prior
      |> Map.delete(:orchestrator_template_uri)
      |> Map.put(:orchestrator_uri, binding)
      |> Map.put(:orchestrator_materialization_epoch, binding.epoch)

    case Ezagent.ActionSet.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} ->
        evict_orchestrator_runtime(prior_uri)
        evict_orchestrator_runtime(binding.uri)
        :ok

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  @doc """
  Grant the session OWNER, at create, the membership authority to remove a
  participant from this session (F7 PR-A, SPEC §2.1 / §3.5).

  The cap is `session/Session/:remove_participant/<session_uri>` —
  `granted_by: owner_uri` (the session owner is the #154-clean granter, same
  play as `grant_owner_orchestrator_admin_cap/3`). Concrete instance + concrete
  action → `IdentityAdmin.rule_cap_bounded?/1` is true, so the grant is
  authorized via the `{:rule, …}` branch (Decision #154). Idempotent: a logical
  re-grant on the same session is skipped.

  This is the ENTRY gate on the unified `session.remove_participant` action. It
  is the ONLY new cap PR-A grants — the worker-teardown cap (the
  `{:spawned_by, owner_uri}` cap-model change, SPEC §2.2) is PR-B and is NOT
  granted here.
  """
  @spec grant_owner_remove_participant_cap(URI.t(), URI.t(), URI.t()) ::
          :ok | {:error, term()}
  def grant_owner_remove_participant_cap(
        %URI{} = session_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :remove_participant,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current =
      EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

    if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
      :ok
    else
      result =
        Ezagent.Identity.Grant.grant_cap(
          owner_uri,
          want,
          grant_authorization(owner_uri)
        )

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, {:remove_participant_cap_grant_failed, reason}}
      end
    end
  end

  @doc """
  Grant the session owner authority to assign open human role slots in the session.
  """
  @spec grant_owner_assign_role_cap(URI.t(), URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_owner_assign_role_cap(
        %URI{} = session_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :assign_role,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current =
      EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

    if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
      :ok
    else
      result =
        Ezagent.Identity.Grant.grant_cap(
          owner_uri,
          want,
          grant_authorization(owner_uri)
        )

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, {:assign_role_cap_grant_failed, reason}}
      end
    end
  end

  @doc """
  Grant the session OWNER, at create, the participant-TEARDOWN authority (F7
  PR-B, SPEC §2.2 / §3.5 — the cap-model change).

  Grants two owner-self-rooted, scope-bounded caps:

      cap(:agent, Ezagent.ActionSet.Sandbox,    :destroy,   {:spawned_by, owner_uri}, ws)
      cap(:agent, Ezagent.ActionSet.Terminable, :terminate, {:spawned_by, owner_uri}, ws)

  Both `granted_by: owner_uri` — the owner IS the lineage root, so this is
  self-rooted and #154-clean (no forged/unowned cap). `{:spawned_by, %URI{}}` is
  scope-bounded → `IdentityAdmin.rule_cap_bounded?/1` is true → authorized via
  the `{:rule, …}` branch, the SAME legality class as the orchestrator's cap #2.

  ## Why this is the lever (SPEC §2.2)

  The durable lineage chain is `worker → orchestrator → owner` (the orchestrator
  spawns the worker; the owner spawns the orchestrator). `spawned_in_lineage?`
  walks it transitively, so this owner cap authorizes `sandbox.destroy` on EVERY
  worker spawned into ANY of the owner's sessions WITHOUT the orchestrator's cap
  #2 and WITHOUT re-parenting the lineage (which would break cap #2 + credential
  `validate_source_owner`). The lineage table is durable, so the reap works even
  when the orchestrator has crashed (the F7 headline bug).

  The instance is `{:spawned_by, owner_uri}` (NOT session-scoped), so this is
  the SAME cap for every session of this owner — granted once per owner; the
  re-grant on the owner's second session is a logical-equality no-op (idempotent
  via `Session.cap_equal_ignoring_metadata?/2`).
  """
  @spec grant_owner_participant_teardown_cap(URI.t(), URI.t(), URI.t()) ::
          :ok | {:error, term()}
  def grant_owner_participant_teardown_cap(
        %URI{} = participant_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    wants =
      for {behavior, action} <- [
            {Ezagent.ActionSet.Sandbox, :destroy},
            {Ezagent.ActionSet.Terminable, :terminate}
          ] do
        %Ezagent.Capability{
          kind: :agent,
          behavior: behavior,
          action: action,
          instance: participant_uri,
          workspace_uri: workspace_uri,
          granted_by: owner_uri,
          granted_at: nil
        }
      end

    current =
      EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

    Enum.reduce_while(wants, :ok, fn want, :ok ->
      if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
        {:cont, :ok}
      else
        with :ok <- Ezagent.Identity.TargetAuthority.ensure(owner_uri, want.instance),
             :ok <-
               Ezagent.Identity.Grant.grant_cap(
                 owner_uri,
                 want,
                 grant_authorization(owner_uri)
               ) do
          {:cont, :ok}
        else
          {:error, reason} ->
            {:halt, {:error, {:participant_teardown_cap_grant_failed, reason}}}
        end
      end
    end)
  end

  def grant_owner_orchestrator_admin_cap(
        %URI{} = session_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current =
      EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

    if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
      :ok
    else
      # Grant chokepoint (SPEC 2026-06-17 §4 PR-2, site #6). The cap is
      # `session/OrchestratorAdmin/:restart/<session_uri>` — concrete
      # instance + concrete action, so `IdentityAdmin.rule_cap_bounded?/1`
      # is true → authorized via the `{:rule, …}` branch (Decision #154).
      # `template-materialize` is no longer the authorizer; the configurer
      # of the orchestrator-template-materialization rule is the session
      # OWNER (also the entity `granted_by`).
      result =
        Ezagent.Identity.Grant.grant_cap(
          owner_uri,
          want,
          grant_authorization(owner_uri)
        )

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, {:orchestrator_admin_cap_grant_failed, reason}}
      end
    end
  end

  defp grant_authorization(%URI{} = owner_uri) do
    admin = Ezagent.Entity.User.admin_uri()

    if Ezagent.URI.stable_key(owner_uri) == Ezagent.URI.stable_key(admin),
      do: {:admin, admin},
      else: {:held_by, owner_uri}
  end

  @doc """
  Grant the session owner a `Behavior.Manage :any` cap OVER the orchestrator
  agent (SPEC 2026-06-16 §5, codex P2 prerequisite, Decision #88).

  The orchestrator spawn path (`Session.ensure_orchestrator` →
  `Agent.spawn_from_template_content/5`) does NOT route through `CreatorGrant`
  / `Workspace.grant_creator_manage_cap/4`, so the owner is NOT a manager of
  the orchestrator and could not equip it via the new manager-delegated
  `grant_cap` path. This wires the missing Manage cap, making the owner the
  orchestrator's manager — the same `cap(:agent, Manage, :any, orchestrator_uri,
  ws)` shape every other created Kind grants its creator at create.

  Delegates to `Ezagent.Workspace.grant_creator_manage_cap/4`, which is
  idempotent (skips a logically-equal re-grant) and dispatches under the
  closed bootstrap system principal because `Manage :any` is a
  wildcard-action cap whose target Behavior has no data owner (Identity's
  grant boundary correctly requires admin authority for that shape). The
  issued cap still records `granted_by: owner_uri`.

  > ### ⚠️ READ BEFORE WIRING THIS UP
  >
  > **This function currently has ZERO callers** (repo-wide, including tests).
  > Since 2026-07-14 an agent's `cap(:agent, Manage, :any, <agent>)` also carries
  > its **PTY** — `pty.write` and `pty.restart` are gated on the Manage authority
  > (`Ezagent.ActionSet.Pty.required_caps/0`), and `Ezagent.Domain.Pty.Access` gates
  > terminal *reads* on it too. Allen, 2026-07-14: "the terminal belongs to the
  > creator."
  >
  > So wiring this call in does not just make the owner the orchestrator's
  > *manager* — it hands them **arbitrary command execution inside the
  > orchestrator's sandbox** (typing into a PTY is running commands) and the
  > ability to watch everything that scrolls through it.
  >
  > That may well be intended — a session's orchestrator is materialized for its
  > owner, and the moduledoc above says this grant exists precisely to give the
  > owner the same authority "every other created Kind grants its creator". But it
  > is a **decision**, not a detail: confirm the orchestrator is per-owner and not
  > shared across a workspace before enabling it. If it is shared, every session
  > owner gets a shell in the same agent.
  """
  @spec grant_owner_orchestrator_manage_cap(URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_owner_orchestrator_manage_cap(%URI{} = orchestrator_uri, %URI{} = owner_uri) do
    workspace_uri =
      case Ezagent.WorkspaceRegistry.lookup(orchestrator_uri) do
        {:ok, %URI{} = ws} ->
          ws

        :error ->
          raise "orchestrator #{URI.to_string(orchestrator_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for the owner Manage cap"
      end

    Ezagent.Workspace.grant_creator_manage_cap(
      :agent,
      orchestrator_uri,
      workspace_uri,
      owner_uri
    )
  end

  def join_session_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    Enum.reduce_while(members, :ok, fn %URI{} = member_uri, :ok ->
      _ = Ezagent.Domain.Agent.ensure_declared_member(member_uri)

      admin_uri = Ezagent.Entity.User.admin_uri()

      result =
        with {:ok, signed_cap} <-
               Ezagent.Cap.issue_for_action({:admin, admin_uri}, admin_uri, target) do
          Invocation.dispatch(%Invocation{
            target: target,
            mode: :call,
            args: %{member: member_uri},
            ctx: %{
              caller: admin_uri,
              authenticated_principal: admin_uri,
              caps: MapSet.new([signed_cap]),
              reply: {:caller_inbox, self()}
            },
            origin: :trusted_internal
          })
        end

      case result do
        r when r == :ok or (is_tuple(r) and tuple_size(r) == 2 and elem(r, 0) == :ok) ->
          # D1 join 补发(caller-side —— 本函数运行在 SessionCreator/facade 进程,
          # 非 Session Kind 内,:sync grant 无自死锁):创建期 join 的 user 成员
          # (owner / workspace-facade caller)同样走唯一补发供给点。Agent → no-op。
          _ = Ezagent.Socialware.MemberBackfill.backfill(session_uri, member_uri)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:member_join_failed, member_uri, reason}}}

        other ->
          {:halt, {:error, {:member_join_unexpected, member_uri, other}}}
      end
    end)
  end

  defp member_declarations(content, %URI{} = session_template_uri) when is_map(content) do
    workspace_uri = Ezagent.URI.workspace_of(session_template_uri)

    case DefinitionEditor.member_declarations_for_template(content, workspace_uri) do
      {:ok, members} -> members
      {:error, _} -> []
    end
  end

  defp orchestrator_declaration?(declarations) when is_list(declarations) do
    Enum.any?(declarations, fn
      %{} = declaration ->
        field(declaration, :role_name) == "orchestrator" and
          field(declaration, :recipe) in ["orchestrator", "recipe:orchestrator"] and
          field(declaration, :fill) in [:agent, "agent"]

      _ ->
        false
    end)
  end

  defp orchestrator_declaration?(_), do: false

  defp prior_or_new_orchestrator_uri(working_copy, workspace_uri) do
    case OrchestratorBinding.decode(Map.get(working_copy, :orchestrator_uri)) do
      {:ok, %{uri: %URI{} = uri}} ->
        uri

      _ ->
        workspace_uri
        |> Ezagent.URI.workspace_name!()
        |> Ezagent.URI.agent(Ecto.UUID.generate())
    end
  end

  defp evict_orchestrator_runtime(%URI{} = uri) do
    :ok = Ezagent.Session.OrchestratorContextPort.unregister(uri)
    Ezagent.Session.SessionManager.stop(uri)
  end

  defp evict_orchestrator_runtime(_), do: :ok

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
