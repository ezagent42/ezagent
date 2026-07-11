defmodule Ezagent.Workspace do
  @moduledoc """
  Workspace facade — spawn + query + durable mutation helpers.

  Phase 4b: `spawn_workspace/2` for in-memory Workspace Kinds.
  Phase 4c: `create/2` (persist + spawn), `add_member/2` etc. (persist
  + dispatch), `Loader` at app start.

  ## Durable mutation contract

  Mutation helpers (`add_member`, `remove_member`, `add_template`,
  `remove_template`, `set_routing_rules`) perform two writes:
  1. `Ezagent.Workspace.Store.update_*` — durable
  2. `Router.dispatch(%Cmd{action: :<action>, ...})` — live Kind

  Both succeed atomically per call (no transaction across them yet —
  Phase 5 may wrap in a single transactional path). The DB write is
  first so a crash between (1) and (2) at most leaves a Workspace in
  DB that doesn't match the live Kind for one boot — Loader resyncs on
  next start.

  Read paths (`list_members`, `list_templates`, etc.) go through the
  live Kind only; the DB is the recovery snapshot, not the read source.
  """

  alias Ezagent.Entity.Workspace, as: WK
  alias Ezagent.{Cmd, KindRegistry, Router, Workspace.Loader, Workspace.Store}

  # --- spawn ---------------------------------------------------------

  @doc """
  Spawn a Workspace Kind at `workspace://<name>` with the given
  initial slice args. In-memory only — use `create/2` for durable.
  """
  @spec spawn_workspace(String.t(), map()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_workspace(name, args \\ %{}) when is_binary(name) do
    uri = WK.uri_for(name)

    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        {:error, {:already_started, pid}}

      :error ->
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # Workspace Kind declares `Ezagent.Workspace.Supervisor` via its
        # supervisor/0 callback so the destination is preserved.
        Ezagent.Kind.spawn(WK, Map.put(args, :uri, uri))
    end
  end

  # --- durable create -----------------------------------------------

  @doc """
  Persist a new Workspace + spawn its Kind. Use this from mix tasks /
  LV — `spawn_workspace/2` alone gives an ephemeral Workspace that
  vanishes on restart.

  `attrs` shape matches `Ezagent.Workspace.Store.create/2`.
  """
  @spec create(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def create(name, attrs \\ %{}) when is_binary(name) and name != "" do
    with {:ok, _decoded} <- Store.create(name, attrs),
         {:ok, pid} <- spawn_workspace(name, attrs) do
      {:ok, pid}
    else
      # #533 5a — Store.create now signals an existing workspace as
      # {:exists, decoded} (the ephemeral freshness signal). This facade is
      # NOT the adopt path (that arrives with the create-entry in 5d), and a
      # create on an existing workspace must FAIL — see the onboarding
      # "cannot hijack an existing workspace" security test. Map it to a
      # clear error; preserve every other {:error, _} (incl. spawn's
      # {:already_started, pid}) unchanged.
      {:exists, _decoded} -> {:error, :workspace_exists}
      {:error, _} = err -> err
    end
  end

  # --- durable mutations --------------------------------------------

  @doc """
  Add `member_uri` to Workspace `name`.

  ## Order (Task #55 round-2 codex CRIT-1 fix, 2026-05-27)

  Dispatch FIRST, persist on success. The Behavior validator
  (`:add_member` action body) is the SOLE gate for the workspace
  prefix invariant — facade is a thin pass-through. Before this
  fix the facade persisted to `Store.update_members/2` BEFORE
  dispatching, so a cross-prefix member URI hit the DB even when
  the validator rejected it (`workspaces.member_uris` carried a
  permanent stale violator until operator restart + cleanup task).

  Sequence:
  1. `dispatch_mutation(:call)` → Workspace Kind runs validator +
     mutates slice. Returns `{:error, ...}` on validator failure
     WITHOUT touching slice. `:call` mode (not `:cast`) so the
     facade can see the error.
  2. Persist via `Store.update_members/2` with the new full member
     list — only after dispatch succeeded.
  3. Side-effects (cap grant + notification).

  Drift property: a crash between (1) and (2) leaves the live
  Workspace Kind's slice with the new member but the DB without
  it. On next boot, `Loader` rehydrates the slice from the DB,
  dropping the orphan member. The drift window is one process
  lifetime, same magnitude as the pre-fix order's one-boot drift
  (inverse direction). This is the closest single-call-site fix
  to a transactional `dispatch ∧ persist` (Phase 5 may add a
  two-phase commit / transaction).
  """
  @spec add_member(String.t(), URI.t()) :: :ok | {:error, term()}
  def add_member(name, %URI{} = member_uri) do
    do_add_member(name, member_uri, workspace_self_ctx(name, :add_member))
  end

  @doc """
  Cap-checked variant of `add_member/2`: dispatches `:add_member` under
  the CALLER's caps (`ctx` is `%{caller: URI.t(), caps: Enumerable.t()}`)
  so step 5.5 CapBAC runs against the logged-in entity, NOT the
  workspace's own self-authority. Web surfaces (LiveView) MUST use this; the
  `/2` variant is for trusted in-VM CLI / mix-task / Loader callers.
  SPEC 2026-05-27-capability-action-axis §7. Mirrors `create_user/3`.
  """
  @spec add_member(String.t(), URI.t(), map()) :: :ok | {:error, term()}
  def add_member(name, %URI{} = member_uri, ctx) when is_map(ctx) do
    with {:ok, dispatch_ctx} <- caller_ctx(ctx) do
      do_add_member(name, member_uri, dispatch_ctx)
    end
  end

  defp do_add_member(name, %URI{} = member_uri, dispatch_ctx) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{members: existing} ->
        new_members = Enum.uniq([member_uri | existing])

        # Composed PR #419 task #46 (facade pre-spawn) + PR #417 task #55
        # CRIT-1 (dispatch-first persistence):
        #
        #   1. Pre-spawn the user Kind at the facade so the Behavior's
        #      cap-grant doesn't race `KindRegistry`. Idempotent.
        #   2. Dispatch :add_member through `:call` so the Behavior
        #      validator can REJECT cross-prefix URIs synchronously.
        #      On rejection the facade exits WITHOUT touching the
        #      Store (the CRIT-1 invariant: the Behavior is sole gate
        #      for the workspace prefix invariant).
        #   3. Persist via `Store.update_members/2` ONLY after dispatch
        #      succeeded. A crash here leaves the slice mutated but
        #      the DB stale; Loader rehydrates from DB on next boot
        #      and drops the orphan member (same one-process-lifetime
        #      drift magnitude as the pre-CRIT-1 order, inverse
        #      direction).
        #
        # The Behavior action body itself does the cap-grant + ALSO
        # pre-spawns (idempotent — already-alive returns
        # `{:ok, _pid}`); the facade pre-spawn just narrows the
        # divergence window for paths where the Behavior would
        # otherwise be the only pre-spawner.
        with :ok <- ensure_member_kind_spawned_at_facade(member_uri),
             :ok <-
               dispatch_mutation(name, "add_member", %{member: member_uri}, :call, dispatch_ctx),
             {:ok, _} <- Store.update_members(name, new_members) do
          # Task #46 (Allen 2026-05-27) — the facade-local
          # `grant_member_create_session_cap/2` call was REMOVED. The
          # Behavior path (reached via the `dispatch_mutation` above)
          # now pre-spawns the user Kind + grants the cap via a
          # buffered `:cast`-mode `identity.grant_cap` so it lands on
          # the ready transition. The facade-side duplicate was a
          # synchronous `:call` that fail-fasted with
          # `:no_such_actor` or `:not_ready` for any user not yet in
          # `KindRegistry` — the empirical Allen-observed bug,
          # defeating PR #408's UX promise that workspace members can
          # dispatch `workspace.create_session` without admin
          # intervention.

          # Notifier/flash audit 2026-05-24 — surface to the affected
          # user's notification stream. Pre-fix only `Chat.receive`
          # called notify/3; cap/membership actions were silent.
          # Skip for agent members (Notifications is user-only by
          # design — agents don't have inboxes).
          if user_uri?(member_uri) do
            _ =
              Ezagent.Notifications.notify(member_uri, %{
                type: :workspace_member_added,
                body: %{
                  text: "You were added to workspace #{name}.",
                  workspace_name: name
                },
                source: __MODULE__
              })
          end

          :ok
        end
    end
  end

  # Task #46 (Allen 2026-05-27) — the facade-local
  # `grant_member_create_session_cap/2` helpers were deleted. The
  # grant now lives exclusively on the `Behavior.Workspace.:add_member`
  # action body, where it can pre-spawn the user Kind + use a buffered
  # `:cast` so the cap lands on the User Kind's ready transition. The
  # facade's `dispatch_mutation` reaches that single chokepoint, so
  # the facade path is covered by construction (single-path invariant).

  # Codex review #419 round-1 MEDIUM-3 — facade-level pre-spawn so a
  # user-Kind spawn failure bubbles out BEFORE Store.update_members /
  # Notifications.notify fire. Mirrors the Behavior's
  # `ensure_member_kind_spawned/1` (idempotent on already-alive,
  # tolerant of `:no_spawn_fn` for unit tests) — they converge on
  # the same `SpawnRegistry.spawn/1` chokepoint so a fresh-user
  # add lands the Kind exactly once.
  defp ensure_member_kind_spawned_at_facade(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :user) do
      case Ezagent.SpawnRegistry.spawn(uri) do
        {:ok, _pid} ->
          :ok

        {:error, {:no_spawn_fn, _scheme}} ->
          :ok

        {:error, reason} ->
          {:error, {:member_user_spawn_failed, uri, reason}}
      end
    else
      :ok
    end
  end

  defp ensure_member_kind_spawned_at_facade(_other), do: :ok

  @spec remove_member(String.t(), URI.t()) :: :ok | {:error, term()}
  def remove_member(name, %URI{} = member_uri) do
    do_remove_member(name, member_uri, workspace_self_ctx(name, :remove_member))
  end

  @doc """
  Cap-checked variant of `remove_member/2`: dispatches `:remove_member`
  under the CALLER's caps (step 5.5 CapBAC against the logged-in entity).
  Web surfaces MUST use this; see `add_member/3`. SPEC §7.
  """
  @spec remove_member(String.t(), URI.t(), map()) :: :ok | {:error, term()}
  def remove_member(name, %URI{} = member_uri, ctx) when is_map(ctx) do
    with {:ok, dispatch_ctx} <- caller_ctx(ctx) do
      do_remove_member(name, member_uri, dispatch_ctx)
    end
  end

  defp do_remove_member(name, %URI{} = member_uri, dispatch_ctx) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{members: existing} ->
        new_members = Enum.reject(existing, &(URI.to_string(&1) == URI.to_string(member_uri)))

        # SPEC §7 Part B: dispatch FIRST (mirroring `add_member`) so an
        # unauthorized caller is rejected BEFORE the DB write, and the
        # action body's `revoke_cap` effect sweeps the `:create_session`
        # cap `:add_member` granted on this workspace (no dangling cap on
        # demotion).
        #
        # codex MEDIUM (drift window, fail-SAFE direction): the synchronous
        # revoke commits in the action body before `Store.update_members/2`.
        # If that DB write then fails, the member can reappear from the DB
        # on next boot WITHOUT the create_session cap — strictly LESS
        # privilege than intended, never more (the dangerous direction —
        # cap surviving without membership — is exactly what Part B closes).
        # This is the same one-process-lifetime dispatch∧persist drift the
        # `add_member/2` moduledoc documents; a true atomic fix needs the
        # Phase 5 cross-DB transaction/saga (tracked in docs/futures/todo.md
        # "Workspace dispatch∧persist atomicity"). NOT a security regression.
        with :ok <-
               dispatch_mutation(
                 name,
                 "remove_member",
                 %{member: member_uri},
                 :call,
                 dispatch_ctx
               ),
             {:ok, _} <- Store.update_members(name, new_members) do
          # Skip for agent members (Notifications is user-only by design —
          # agents don't have inboxes); mirrors the `add_member` guard.
          if user_uri?(member_uri) do
            _ =
              Ezagent.Notifications.notify(member_uri, %{
                type: :workspace_member_removed,
                body: %{
                  text: "You were removed from workspace #{name}.",
                  workspace_name: name
                },
                source: __MODULE__
              })
          end

          :ok
        end
    end
  end

  @doc """
  Atomically remove cross-prefix members from workspace `name`.

  Task #55 round-2 codex HIGH-2 (2026-05-27). Replaces the direct-store
  cleanup the mix task `ezagent.workspace.cleanup_cross_prefix_members`
  used to do — that pattern was race-prone (concurrent `add_member`
  between the scan + update would be lost) AND left the live Workspace
  Kind's slice stale until restart.

  Dispatches `Behavior.Workspace.:remove_cross_prefix_members` against
  the workspace's Kind. The action body classifies the slice's members
  against the same canonicalization rules `:add_member` uses, returns
  `{:ok, slice', %{removed: [URI], kept_count: integer}}` atomically.
  The facade then persists the kept set via `Store.update_members/2`
  so DB + slice stay aligned.

  Returns `{:ok, %{removed: [URI], kept_count: integer}}` on success;
  `{:error, reason}` on dispatch / persistence failure. An empty
  `removed` list means the workspace had no violators.

  Mirrors `add_member/2`'s dispatch-first persistence pattern (CRIT-1).
  """
  @spec remove_cross_prefix_members(String.t()) ::
          {:ok, %{removed: [URI.t()], kept_count: non_neg_integer()}} | {:error, term()}
  def remove_cross_prefix_members(name) when is_binary(name) and name != "" do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      _persisted ->
        target =
          name
          |> Ezagent.URI.workspace()
          |> Ezagent.URI.with_action(:workspace, :remove_cross_prefix_members)

        case Router.dispatch(%Cmd{
               target: target,
               action: :remove_cross_prefix_members,
               args: %{},
               ctx:
                 Map.merge(
                   workspace_self_ctx(name, :remove_cross_prefix_members),
                   %{mode: :call, reply: {:caller_inbox, self()}}
                 )
             }) do
          {:ok, %{removed: removed, kept_count: kept_count}} when is_list(removed) ->
            # Mutation already committed in slice. Persist the kept
            # set so the DB matches. Read current members from the
            # live Kind via `:list_members` dispatch to get the
            # post-mutation set (the action body returns the removed
            # list separately for audit, not the kept URIs).
            with {:ok, kept_uris} <- list_current_members_for_persist(name) do
              case Store.update_members(name, kept_uris) do
                {:ok, _} ->
                  {:ok, %{removed: removed, kept_count: kept_count}}

                {:error, reason} ->
                  {:error, {:persist_failed, reason}}
              end
            end

          {:error, _reason} = err ->
            err

          other ->
            {:error, {:unexpected_dispatch_return, other}}
        end
    end
  end

  @doc "See `Ezagent.Workspace.ResponsibilityAssignments.assign_role/5`."
  defdelegate assign_role(workspace_uri, responsibility, holder, config, ctx),
    to: Ezagent.Workspace.ResponsibilityAssignments

  @doc "See `Ezagent.Workspace.ResponsibilityAssignments.unassign_role/4`."
  defdelegate unassign_role(workspace_uri, responsibility, holder, ctx),
    to: Ezagent.Workspace.ResponsibilityAssignments

  defp list_current_members_for_persist(name) do
    target =
      name
      |> Ezagent.URI.workspace()
      |> Ezagent.URI.with_action(:workspace, :list_members)

    case Router.dispatch(%Cmd{
           target: target,
           action: :list_members,
           args: %{},
           ctx:
             Map.merge(
               workspace_self_ctx(name, :list_members),
               %{mode: :call, reply: {:caller_inbox, self()}}
             )
         }) do
      {:ok, %{members: members}} when is_list(members) -> {:ok, members}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_dispatch_return, other}}
    end
  end

  @doc """
  Add a template to a Workspace. Fail-fast structural validation:
  - template map must carry a `"class"` field referencing a registered
    `Ezagent.Kind.Template` Class
  - Class's `validate/1` (if defined) is called before persistence

  Per Phase 4-completion Spec 01 Q2-(b): `"class"` field is the source
  of truth for template Class binding. Multiple instances per Class are
  fine — they're distinguished by the Workspace-local `tmpl_name` key.

  ## V1 acceptance fix (2026-05-21)

  The full chain is now:
  1. DB JSON updated (`Store.update_templates`)
  2. Live Workspace Kind notified (`dispatch_mutation`)
  3. **Template Class instantiated** (`Loader.invoke_template`) — runs
     `Class.instantiate/3`, brings the spawned Kinds (PtyServer for
     cc.agent, Session for session.generic, etc.) to life immediately
     so any caller (`AgentNewLive`, CLI, future API) gets a running
     agent without needing a phx restart.

  An instantiate `{:error, {:already_started, _}}` is treated as
  success (idempotent w.r.t. step 3 — re-running on an already-alive
  Kind is a no-op). Any other instantiate error is returned to the
  caller (per `feedback_let_it_crash_no_workarounds` — no silent
  swallow).
  """
  @spec add_template(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def add_template(name, tmpl_name, tmpl) when is_binary(tmpl_name) and is_map(tmpl) do
    with :ok <- validate_template(tmpl),
         %{session_templates: tmpls} <- get_or_not_found(name),
         new_tmpls = Map.put(tmpls, tmpl_name, tmpl),
         {:ok, _} <- Store.update_templates(name, new_tmpls),
         :ok <-
           dispatch_mutation(name, "add_template", %{name: tmpl_name, template: tmpl}),
         :ok <- invoke_template_now(name, tmpl_name) do
      :ok
    end
  end

  defp invoke_template_now(name, tmpl_name) do
    workspace_uri = Ezagent.URI.workspace(name)

    case Loader.invoke_template(workspace_uri, tmpl_name) do
      {:ok, _uris} -> :ok
      # Idempotent — already running. cc.agent.instantiate already
      # short-circuits, but defensive in case other templates return
      # this shape.
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp get_or_not_found(name) do
    case Store.get_by_name(name) do
      nil -> {:error, :not_found}
      decoded -> decoded
    end
  end

  defp validate_template(tmpl) do
    case extract_class_name(tmpl) do
      nil ->
        {:error, :missing_class_field}

      class_name ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          :error ->
            {:error, {:no_template_class, class_name}}

          {:ok, class_module} ->
            with :ok <- validate_file_flavor_config_dir(class_module, tmpl) do
              invoke_validate(class_module, tmpl)
            end
        end
    end
  end

  # 2026-06-07 file-flavor-create-cascade — a credentialled file-flavor (cc/codex)
  # template MUST carry a non-empty `config_dir` reference. Validated BEFORE the
  # Store write (this `add_template/3` path has no post-instantiate rollback), so
  # a config-dir-less file-flavor template never persists + poisons every boot.
  # Mirrors the Loader's `file_flavor_to_data/2` fail-loud guard (no-silent
  # operator-home fallback). echo/np/curl have no credential home → exempt.
  defp validate_file_flavor_config_dir(class_module, tmpl) do
    if Ezagent.Agent.CredentialAdapter.credentialled?(class_module) do
      case Map.get(tmpl, "config_dir") || Map.get(tmpl, :config_dir) do
        dir when is_binary(dir) and dir != "" ->
          :ok

        _ ->
          {:error, {:file_flavor_missing_config_dir, Map.get(tmpl, "class")}}
      end
    else
      :ok
    end
  end

  defp invoke_validate(class_module, tmpl) do
    if function_exported?(class_module, :validate, 1) do
      class_module.validate(tmpl)
    else
      :ok
    end
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil

  @spec remove_template(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_template(name, tmpl_name) when is_binary(tmpl_name) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{session_templates: tmpls} ->
        new_tmpls = Map.delete(tmpls, tmpl_name)

        with {:ok, _} <- Store.update_templates(name, new_tmpls),
             :ok <- dispatch_mutation(name, "remove_template", %{name: tmpl_name}) do
          :ok
        end
    end
  end

  @spec set_routing_rules(String.t(), [map()]) :: :ok | {:error, term()}
  def set_routing_rules(name, rules) when is_list(rules) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      _ ->
        with {:ok, _} <- Store.update_routing_rules(name, rules),
             :ok <- dispatch_mutation(name, "set_routing_rules", %{rules: rules}) do
          :ok
        end
    end
  end

  # Default `:cast` mode preserves existing call sites (add_template,
  # remove_template, remove_member, set_routing_rules) that are
  # validator-free and don't need synchronous error propagation.
  #
  # System-principal elimination (#154, 2026-06-19) — the self-cap is
  # scoped to the SPECIFIC action being dispatched (`action_str` is in
  # scope here), so each programmatic mutation runs under the workspace's
  # own least-privilege `cap(:workspace, Workspace, <action>)`.
  defp dispatch_mutation(name, action_str, args),
    do:
      dispatch_mutation(
        name,
        action_str,
        args,
        :cast,
        workspace_self_ctx(name, String.to_existing_atom(action_str))
      )

  # Task #55 round-2 codex CRIT-1 — `:call` mode for add_member so the
  # facade can see the Behavior validator's rejection (cross-prefix
  # member) and SKIP the subsequent `Store.update_members/2`. Without
  # `:call`, a `:cast` dispatch silently drops the error and the facade
  # persists the bad URI regardless.
  #
  # SPEC §7 — `auth_ctx` carries the `:caller` + `:caps` step 5.5 CapBAC
  # checks against: `system_loader_ctx/0` for the `/2` programmatic
  # variants, the logged-in caller's caps for the `/3` cap-checked ones.
  defp dispatch_mutation(name, action_str, args, mode, auth_ctx)
       when mode in [:cast, :call] and is_map(auth_ctx) do
    target =
      name
      |> Ezagent.URI.workspace()
      |> Ezagent.URI.with_action(:workspace, action_str)

    # The action verb already lives in the URI's `?action=workspace.<verb>`
    # query (Router preserves a pre-baked `action=` and the registry
    # resolves `{kind_module, action}` from it). `Cmd.action` carries the
    # same atom for the EventLog audit row Router injects. `to_existing_atom`
    # is safe: every `action_str` is a compile-time-known Workspace action.
    action = String.to_existing_atom(action_str)

    reply =
      case mode do
        :call -> {:caller_inbox, self()}
        :cast -> :ignore
      end

    case Router.dispatch(%Cmd{
           target: target,
           action: action,
           args: args,
           ctx: Map.merge(auth_ctx, %{mode: mode, reply: reply})
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      err -> err
    end
  end

  # SPEC §7 (codex review HIGH — fail-closed caller ctx). The cap-checked
  # `/3` path carries the caller's fresh caps. REQUIRE a concrete
  # `%URI{}` caller + a list/MapSet of caps; REJECT the ambient-authority
  # shapes (`:vm_internal`, nil, atom, string) so a programmatic caller that
  # accidentally reaches `/3` cannot slip past step 5.5 via Runtime's
  # `default_holds_cap?(:vm_internal)` all-caps bypass. Trusted ambient callers
  # MUST use the explicit `/2` path.
  defp caller_ctx(%{caller: %URI{} = caller, caps: caps}) when is_list(caps),
    do: {:ok, %{caller: caller, caps: caps}}

  defp caller_ctx(%{caller: %URI{} = caller, caps: %MapSet{} = caps}),
    do: {:ok, %{caller: caller, caps: caps}}

  defp caller_ctx(_other), do: {:error, :invalid_caller_ctx}

  # System-principal elimination (#154 north star, 2026-06-19) — the
  # programmatic `/2` mutations + the boot-time self-maintenance dispatches
  # (`remove_cross_prefix_members` / `list_members`) are the WORKSPACE acting
  # on its OWN slice (member set / templates / routing rules). That is GENUINE
  # self-authority (capbac.md §7 "actor-self"), NOT an ambient
  # `system://workspace-loader` borrow. So the dispatch runs under the
  # workspace's OWN entity URI as `caller`, carrying its OWN
  # `cap(:workspace, Workspace, <action>)` INLINE in `ctx.caps` — the step-5.5
  # authorizer (`granted_via_ctx_caps?`, checked first), which ALSO avoids the
  # `granted_via_holds_cap?` self-call deadlock. Replaces the deleted
  # `system://workspace-loader` Catalog principal (same play as the eliminated
  # `system://worker-publish` / `system://agent-internal`).
  defp workspace_self_ctx(name, action) when is_binary(name) and is_atom(action) do
    workspace_uri = Ezagent.URI.workspace(name)

    %{
      caller: workspace_uri,
      caps: [workspace_self_cap(workspace_uri, action)]
    }
  end

  # The workspace's OWN self-authority cap for the dispatched Workspace
  # Behavior `action`, the step-5.5 authorizer for `workspace_self_ctx/2`.
  # Shape mirrors `Ezagent.ActionSet.Workspace.required_caps/0[action]` =
  # `cap(:workspace, Workspace, action)` but SCOPED to the concrete workspace
  # (`instance`/`workspace_uri` derived from `workspace_uri`) for tightest
  # least-privilege — the runtime substitutes the same concrete instance from
  # the dispatch target, so concrete==concrete matches. `granted_by` =
  # `workspace_uri` (genuine self-authority: a real entity per #154); it is
  # provenance only (`matches?/2`/`identity_key/1` ignore it) on an INLINE
  # authorizer cap that is never granted/persisted through
  # `Ezagent.Identity.Grant`, so no grant-chokepoint route applies.
  defp workspace_self_cap(%URI{} = workspace_uri, action) when is_atom(action) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        action,
        Ezagent.URI.instance(workspace_uri),
        Ezagent.Capability.workspace_of(workspace_uri)
      )
      | granted_by: workspace_uri,
        granted_at: DateTime.utc_now()
    }
  end

  # --- listing -------------------------------------------------------
  #
  # Listing + cap-derived per-caller visibility queries live in
  # `Ezagent.Workspace.Listing` (#25 Phase-3 PR-3U). Kept as defdelegates
  # so all callers (live_auth, mix tasks, invariant tests) + the
  # workspace_sot invariant (`Ezagent.Workspace.list_workspaces_for/2`)
  # resolve unchanged.
  @doc "See `Ezagent.Workspace.Listing.list_workspaces/0`."
  defdelegate list_workspaces(), to: Ezagent.Workspace.Listing

  @doc "See `Ezagent.Workspace.Listing.list_all/0`."
  defdelegate list_all(), to: Ezagent.Workspace.Listing

  @doc "See `Ezagent.Workspace.Listing.list_workspaces_for/2`."
  defdelegate list_workspaces_for(caller_uri, caps), to: Ezagent.Workspace.Listing

  # --- magic-link rules (SPEC 2026-05-24 v2 PR-A) ----------------------

  alias Ezagent.Workspace.MagicLinkRule

  @doc """
  Does any workspace's magic-link rule accept `email`?

  This is the SEND-side gate (OQ-V2-3): when an operator clicks
  "send magic link" for an email, we OR across all workspaces and
  reject if no rule matches. Pre-PR-A this was a flat global
  `registration_domains` AppSetting; now it's per-workspace rules.
  """
  @spec any_workspace_accepts?(String.t()) :: boolean()
  def any_workspace_accepts?(email) when is_binary(email) do
    MagicLinkRule.workspaces_accepting(email) != []
  end

  def any_workspace_accepts?(_), do: false

  @doc """
  Does a specific workspace accept `email`? Used by the CLICK-side
  gate (OQ-V2-3) after the token is verified, AND by the onboarding
  LV (PR-B) when the user tries to join workspace X by name.
  """
  @spec accepts_email?(URI.t() | String.t(), String.t()) :: boolean()
  def accepts_email?(workspace_uri, email),
    do: MagicLinkRule.accepts_email?(workspace_uri, email)

  @doc """
  List workspaces that would accept `email` — for the onboarding LV
  (PR-B) to suggest "you can join any of these existing workspaces."
  Returns workspace URIs as strings.
  """
  @spec workspaces_accepting(String.t()) :: [String.t()]
  def workspaces_accepting(email), do: MagicLinkRule.workspaces_accepting(email)

  @doc "Add a magic-link rule to a workspace. See `MagicLinkRule.add/3`."
  defdelegate add_magic_link_rule(workspace_uri, rule_type, rule_value),
    to: MagicLinkRule,
    as: :add

  @doc "List magic-link rules for a workspace. See `MagicLinkRule.list_for/1`."
  defdelegate list_magic_link_rules(workspace_uri), to: MagicLinkRule, as: :list_for

  @doc "Delete a magic-link rule by id. See `MagicLinkRule.delete/1`."
  defdelegate delete_magic_link_rule(id), to: MagicLinkRule, as: :delete

  # Notifier/flash audit 2026-05-24 — `Ezagent.Notifications.notify/3`
  # only accepts `entity://user/...` URIs (agents don't have inboxes
  # by design). Use this guard at notify call sites where a member
  # URI may be either user or agent.
  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_), do: false

  # --- provisioning (create_agent / create_session / create_user) -----
  #
  # Extracted verbatim into `Ezagent.Workspace.Provisioning` (2026-07-10)
  # to keep this facade under the `oversized_modules_gt_1000` arch ratchet.
  # The public API is unchanged — callers still use
  # `Ezagent.Workspace.create_{agent,session,user}/3` via these delegates
  # (same pattern as `Workspace.Listing` / `Workspace.MagicLinkRule`). The
  # golive-gap post-dispatch `add_member` for `create_user/3` lives in the
  # submodule (still at the facade layer, NOT the action body — re-entrancy).

  @doc "See `Ezagent.Workspace.Provisioning.create_agent/3`."
  defdelegate create_agent(workspace_uri, args, ctx), to: Ezagent.Workspace.Provisioning

  @doc "See `Ezagent.Workspace.Provisioning.create_session/3`."
  defdelegate create_session(workspace_uri, args, ctx), to: Ezagent.Workspace.Provisioning

  @doc "See `Ezagent.Workspace.Provisioning.create_user/3`."
  defdelegate create_user(workspace_uri, args, ctx), to: Ezagent.Workspace.Provisioning

  @doc """
  Issue every requested capability from the CALLER's durable held authority,
  then hand the complete issued set to `agent_uri` for self-storage.

  `ctx.caps` is intentionally ignored: `Ezagent.Cap.issue/3` reloads the
  caller's real held caps through the configured authority loader. ISSUE for
  the whole batch completes before the first non-blocking ABSORB handoff.

  Returns `:ok` if all grants succeed, `{:error, {:grant_failed, cap,
  reason}}` on the first failure (does not continue past a failure —
  partial provisioning surfaces immediately).
  """
  @spec grant_initial_caps(URI.t(), [Ezagent.Capability.t()], map()) ::
          :ok | {:error, term()}
  def grant_initial_caps(_agent_uri, [], _ctx), do: :ok

  def grant_initial_caps(%URI{} = agent_uri, caps, ctx) when is_list(caps) and is_map(ctx) do
    case issue_and_absorb_initial_caps(agent_uri, caps, ctx) do
      {:ok, _issued} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec issue_and_absorb_initial_caps(URI.t(), [Ezagent.Capability.t()], map()) ::
          {:ok, [Ezagent.Capability.t()]} | {:error, term()}
  def issue_and_absorb_initial_caps(%URI{} = agent_uri, caps, ctx)
      when is_list(caps) and is_map(ctx) do
    caller = Map.fetch!(ctx, :caller)

    with {:ok, issued_pairs} <- issue_initial_caps(agent_uri, caps, caller),
         stored_pairs = canonicalize_issued_pairs(issued_pairs),
         :ok <- absorb_initial_caps(agent_uri, stored_pairs) do
      {:ok, Enum.map(stored_pairs, &elem(&1, 1))}
    end
  end

  defp issue_initial_caps(agent_uri, caps, caller) do
    target = Ezagent.URI.instance(agent_uri)

    caps
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, issued} ->
      case Ezagent.Cap.issue({:held_by, caller}, target, cap) do
        {:ok, artifact} -> {:cont, {:ok, [{cap, artifact} | issued]}}
        {:error, reason} -> {:halt, {:error, {:grant_failed, cap, reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _reason} = error -> error
    end
  end

  defp absorb_initial_caps(agent_uri, issued) do
    Enum.reduce_while(issued, :ok, fn {proposal, artifact}, :ok ->
      case Ezagent.Identity.absorb_cap(agent_uri, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_failed, proposal, reason}}}
      end
    end)
  end

  # The Identity slice replaces artifacts by logical identity key. Mirror that
  # rule before hand-off so a short-lived CLI can await the exact final structs
  # instead of waiting forever for an earlier metadata variant that cannot
  # coexist with the last one.
  defp canonicalize_issued_pairs(issued_pairs) do
    issued_pairs
    |> Enum.reverse()
    |> Enum.uniq_by(fn {_proposal, artifact} ->
      Ezagent.Capability.identity_key(artifact)
    end)
    |> Enum.reverse()
  end

  @doc """
  Grant the creator the abstract `Behavior.Manage :any` cap for a newly
  created Kind instance.

  The creation path injects the concrete `kind` axis (`:session`, `:agent`,
  ...). The cap itself is built by `Ezagent.CreatorGrant`; this facade only
  performs the Identity dispatch under the closed bootstrap system principal
  because `Manage :any` is a wildcard-action cap whose target Behavior has
  no data owner; Identity's grant boundary correctly requires admin authority
  for that shape. The issued cap still records `granted_by: creator_uri`
  because the business authority comes from the successful create operation,
  not from the system principal.
  """
  @spec grant_creator_manage_cap(atom(), URI.t(), URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_creator_manage_cap(
        kind,
        %URI{} = instance_uri,
        %URI{} = workspace_uri,
        %URI{} = creator_uri
      )
      when is_atom(kind) do
    cap = Ezagent.CreatorGrant.manage_cap(kind, instance_uri, workspace_uri, creator_uri)
    current = Ezagent.Identity.list_caps_for(creator_uri)

    if Enum.any?(current, &Ezagent.CreatorGrant.same_authority?(&1, cap)) do
      :ok
    else
      # Grant chokepoint (SPEC 2026-06-17 §3.5 site #3). `Manage :any` is
      # a wildcard-action cap whose target Behavior has no data owner, so
      # the grant boundary requires GENESIS authority — supplied by the
      # `{:genesis, …}` tag (loads the canonical admin-granted genesis
      # wildcard as `ctx.caps`). The entity `granted_by` is the CREATOR: the
      # business authority comes from the successful create operation; the
      # genesis cap only satisfies dispatch step 5.5. (#154 genesis collapse,
      # 2026-06-20 — replaces the eliminated `{:system, bootstrap, …}` tag.)
      #
      # `:sync` (NOT the default `:async`): the base site dispatched with
      # `mode: :call`, and the create operation gates its success on this
      # grant (`with :ok <- grant_creator_manage_cap/4`). `:cast` would
      # silently swallow a grant failure — reporting a successful create
      # while the creator does NOT hold the Manage cap. Force synchronous,
      # error-propagating `:call` mode.
      case Ezagent.Identity.Grant.grant_cap_via_router(
             creator_uri,
             cap,
             {:genesis, creator_uri},
             :sync
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:creator_manage_cap_grant_failed, reason}}
      end
    end
  end
end
