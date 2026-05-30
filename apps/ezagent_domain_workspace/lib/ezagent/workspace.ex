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
             :ok <- dispatch_mutation(name, "add_member", %{member: member_uri}, :call),
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
  defp ensure_member_kind_spawned_at_facade(%URI{scheme: "entity", host: "user"} = uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:no_spawn_fn, _scheme}} ->
        :ok

      {:error, reason} ->
        {:error, {:member_user_spawn_failed, uri, reason}}
    end
  end

  defp ensure_member_kind_spawned_at_facade(_other), do: :ok

  @spec remove_member(String.t(), URI.t()) :: :ok | {:error, term()}
  def remove_member(name, %URI{} = member_uri) do
    case Store.get_by_name(name) do
      nil ->
        {:error, :not_found}

      %{members: existing} ->
        new_members = Enum.reject(existing, &(URI.to_string(&1) == URI.to_string(member_uri)))

        with {:ok, _} <- Store.update_members(name, new_members),
             :ok <- dispatch_mutation(name, "remove_member", %{member: member_uri}) do
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
          Ezagent.URI.new!("workspace://#{name}?action=workspace.remove_cross_prefix_members")

        case Router.dispatch(%Cmd{
               target: target,
               action: :remove_cross_prefix_members,
               args: %{},
               ctx: %{
                 mode: :call,
                 caller: Ezagent.SystemPrincipal.uri("workspace-loader"),
                 caps: Ezagent.SystemPrincipal.caps("system://workspace-loader"),
                 reply: {:caller_inbox, self()}
               }
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

  defp list_current_members_for_persist(name) do
    target = Ezagent.URI.new!("workspace://#{name}?action=workspace.list_members")

    case Router.dispatch(%Cmd{
           target: target,
           action: :list_members,
           args: %{},
           ctx: %{
             mode: :call,
             caller: Ezagent.SystemPrincipal.uri("workspace-loader"),
             caps: Ezagent.SystemPrincipal.caps("system://workspace-loader"),
             reply: {:caller_inbox, self()}
           }
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
    workspace_uri = Ezagent.URI.new!("workspace://#{name}")

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
            invoke_validate(class_module, tmpl)
        end
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
  defp dispatch_mutation(name, action_str, args),
    do: dispatch_mutation(name, action_str, args, :cast)

  # Task #55 round-2 codex CRIT-1 — `:call` mode for add_member so the
  # facade can see the Behavior validator's rejection (cross-prefix
  # member) and SKIP the subsequent `Store.update_members/2`. Without
  # `:call`, a `:cast` dispatch silently drops the error and the facade
  # persists the bad URI regardless.
  defp dispatch_mutation(name, action_str, args, mode) when mode in [:cast, :call] do
    target = Ezagent.URI.new!("workspace://#{name}?action=workspace.#{action_str}")
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
           # SPEC caps-cleanup-v1 §4.4 — Workspace mutation runs under
           # `system://workspace-loader` (closed Catalog).
           ctx: %{
             mode: mode,
             caller: Ezagent.SystemPrincipal.uri("workspace-loader"),
             caps: Ezagent.SystemPrincipal.caps("system://workspace-loader"),
             reply: reply
           }
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      err -> err
    end
  end

  # --- listing -------------------------------------------------------

  @doc """
  List all live Workspace URIs (those registered in KindRegistry under
  the `workspace://` scheme).
  """
  @spec list_workspaces() :: [URI.t()]
  def list_workspaces do
    KindRegistry.list_all()
    |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "workspace://") end)
    |> Enum.map(fn {uri_str, _pid} -> Ezagent.URI.new!(uri_str) end)
    |> Enum.sort_by(&URI.to_string/1)
  end

  @doc """
  List all persisted workspaces — SYSTEM-INTERNAL use only
  (Loader rehydration, agent-flavor resolution, audit mix tasks,
  invariant tests).

  SPEC 2026-05-27-workspace-cap-based-visibility §4.2: operator-facing
  surfaces (LiveViews, web auth mounts, plugin-author UIs) MUST use
  `list_workspaces_for/2` — the cap-derived per-caller view. The
  `list_visible/0` field-based filter and the `list_persisted/0`
  alias are both DELETED in this SPEC.
  """
  @spec list_all() :: [map()]
  def list_all, do: Store.list_all()

  @doc """
  Cap-derived per-caller workspace listing — the SINGLE operator-facing
  query (SPEC 2026-05-27-workspace-cap-based-visibility §3.3).

  Returns workspaces the caller can act on, computed as:

      list_workspaces_for(caller_uri, caps) =
        if   admin_shortcut(caller_uri, caps)  -- 4-predicate UNION
        then list_all()
        else union(
               member_of_workspaces(caller_uri),  -- (a) membership
               workspaces_for_caps(caps)          -- (b) cap-scope
             )

  Where `admin_shortcut/2` is the 4-predicate UNION encoded by
  `Ezagent.Identity.AdminAuthority.admin?/2`:

  - bootstrap-wildcard cap (`kind:any/behavior:any/action:any/instance:any/workspace_uri:any`)
  - structural cross-workspace admin cap
    (`kind:workspace/behavior:Workspace/action:any/instance:any/workspace_uri:any`)
  - caller's URI host is `system` (admin-created in `workspace://system`)
  - caller is a member of `workspace://system` (promoted via the LV
    admin flow)

  ## Inputs

  - `caller_uri` — `%URI{}` of the caller (`entity://user/<ws>/<name>`
    typical; `entity://agent/...` accepted). Malformed callers
    return `[]` defensively per SPEC §3.6.
  - `caps` — caller's loaded cap set (`MapSet.t() | [Capability.t()]`).
    Supplied by upstream (`live_auth.ex`, mix tasks, etc.); this
    function does NOT re-fetch from `Identity` slice.

  ## Output

  `[Workspace.Store.decoded()]` sorted by name ASC. Same shape as
  the former `list_visible/0` minus the deleted `:visible` key.

  ## Caps with `workspace_uri: :any` from non-admin callers

  Per SPEC §3.3.b + OQ-5: caps with `workspace_uri: :any` contribute
  NOTHING to the non-admin cap-scope branch. The admin shortcut is
  the legitimate way to surface all workspaces; a non-admin holding
  a session-wildcard cap should not see every workspace in the
  system. This is deliberately NARROWER than
  `Capability.cross_workspace?/2`'s first clause — see SPEC §3.3
  "Relationship" subsection.
  """
  @spec list_workspaces_for(URI.t() | nil, MapSet.t() | [Ezagent.Capability.t()]) :: [map()]
  def list_workspaces_for(caller_uri, caps) do
    if Ezagent.Identity.AdminAuthority.admin?(caller_uri, caps) do
      Store.list_all()
    else
      caller_str = caller_uri_string(caller_uri)
      all = Store.list_all()
      ws_uri_strs = caps_workspace_uri_strs(caps)

      all
      |> Enum.filter(fn ws ->
        member_match?(ws, caller_str) or cap_scope_match?(ws, ws_uri_strs)
      end)
    end
  end

  # `%URI{}` → "entity://...". `nil` / non-URI → `nil` (membership
  # check short-circuits to false). Per SPEC §3.6 defensive contract:
  # malformed callers see no workspaces via the membership branch,
  # cap-scope still applies independently.
  defp caller_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp caller_uri_string(_), do: nil

  defp member_match?(_ws, nil), do: false

  defp member_match?(%{members: members}, caller_str)
       when is_list(members) and is_binary(caller_str) do
    Enum.any?(members, fn m -> URI.to_string(m) == caller_str end)
  end

  defp member_match?(_, _), do: false

  defp cap_scope_match?(%{uri: %URI{} = ws_uri}, ws_uri_strs) when is_list(ws_uri_strs) do
    URI.to_string(ws_uri) in ws_uri_strs
  end

  defp cap_scope_match?(_, _), do: false

  # Extract concrete `%URI{}` `workspace_uri` values from caps, drop
  # `:any` (per SPEC §3.3.b — wildcards do NOT contribute to the
  # non-admin cap-scope branch). Returns the URIs as strings for O(1)
  # `in/2` lookup.
  defp caps_workspace_uri_strs(caps) do
    caps
    |> caps_to_list()
    |> Enum.flat_map(fn
      %Ezagent.Capability{workspace_uri: %URI{} = uri} -> [URI.to_string(uri)]
      %Ezagent.Capability{workspace_uri: _} -> []
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp caps_to_list(caps) when is_list(caps), do: caps
  defp caps_to_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp caps_to_list(_), do: []

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
  defp user_uri?(%URI{scheme: "entity", host: "user"}), do: true
  defp user_uri?(_), do: false

  # --- create_agent (SPEC 2026-05-25-agent-create-cli-gui-parity) -----

  @doc """
  Unified agent-create entry — CLI and LV both call this. Dispatches
  `Behavior.Workspace.:create_agent` against the target workspace's
  Kind, which runs the validate + register-template + Loader.invoke_template
  chain inside the Workspace GenServer.

  ## Args

  - `workspace_uri` — `%URI{scheme: "workspace", host: "<name>"}` of
    the workspace the new agent belongs to.
  - `args` — map with keys:
      - `:flavor` — `"cc" | "echo" | "curl" | <future>`
      - `:name` — entity-name suffix (composed as `<flavor>_<name>`)
      - `:cwd` — working directory (required for cc + echo-with-PTY,
        ignored otherwise)
      - `:with_pty` — boolean (echo opt-in for `/bin/bash -i` sidecar)
  - `ctx` — caller context: `%{caller: caller_uri, caps: caller_caps}`.
    The CapBAC check is enforced at dispatch; caller MUST hold a
    `Behavior.Workspace` cap on this workspace (or admin).

  ## Return

  `{:ok, %{agent_uri: %URI{}, template_name: String.t() | nil}}` on
  success — `template_name` is `nil` for direct-spawn flavors (curl
  and future no-template flavors).

  `{:error, reason}` for shape / validation / cap-denial / spawn
  failures (see `coerce_create_args/1` + `validate_*` in the action body).
  """
  @spec create_agent(URI.t(), map(), map()) ::
          {:ok, %{agent_uri: URI.t(), template_name: String.t() | nil}}
          | {:error, term()}
  def create_agent(%URI{scheme: "workspace"} = workspace_uri, args, ctx)
      when is_map(args) and is_map(ctx) do
    target =
      Ezagent.URI.with_action(workspace_uri, :workspace, :create_agent)

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    Router.dispatch(%Cmd{
      target: target,
      action: :create_agent,
      args: args,
      ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  @doc """
  Dispatch the `:create_session` action on Workspace Kind — the
  unified CLI/LV session-creation entry from SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap C.

  Wraps `EzagentDomainChat.create_session/3` via the
  `Behavior.Workspace.:create_session` action so the CLI
  (`mix ezagent workspace create_session ...`) and the LV "New session"
  form both reach the same code path. The auto-spawned orchestrator
  agent is surfaced in the return map.

  Goes through `Ezagent.Invocation.dispatch/1` so step 5.5 CapBAC,
  audit telemetry, and the action body's workspace check all fire.

  `args` is `%{short_name: String.t(), template_name: String.t()}`.
  `ctx` carries `:caller` + `:caps`.

  Returns `{:ok, %{session_uri: URI.t(), orchestrator_uri: URI.t() | nil,
  orchestrator_status: :ready | :pending | :failed, orchestrator_error:
  String.t() | nil}}` on success; `{:error, reason}` on validation /
  cap denial / facade failure.
  """
  @spec create_session(URI.t(), map(), map()) ::
          {:ok,
           %{
             session_uri: URI.t(),
             orchestrator_uri: URI.t() | nil,
             orchestrator_status: :ready | :pending | :failed,
             orchestrator_error: String.t() | nil
           }}
          | {:error, term()}
  def create_session(%URI{scheme: "workspace"} = workspace_uri, args, ctx)
      when is_map(args) and is_map(ctx) do
    target =
      Ezagent.URI.with_action(workspace_uri, :workspace, :create_session)

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    Router.dispatch(%Cmd{
      target: target,
      action: :create_session,
      args: args,
      ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  @doc """
  Dispatch the `:create_user` action on Workspace Kind — the HIGH-2
  completion entry that replaces the legacy `mix ezagent.user.create`
  task's direct call into `Ezagent.Users.create/3`.

  Goes through `Ezagent.Invocation.dispatch/1` so step 5.5 CapBAC,
  audit telemetry, and the action body's structural cross-workspace
  check on the new user URI all fire.

  `args` is `%{user_uri: String.t(), password: String.t() | nil,
  caps: String.t() | nil}`. `ctx` carries `:caller` + `:caps`.

  Returns `{:ok, %{user_uri: String.t(), caps_granted: integer(),
  password_set: boolean(), spawned: String.t()}}` on success;
  `{:error, reason}` on validation / cap denial / cross-workspace
  refusal / DB insert failure.
  """
  @spec create_user(URI.t(), map(), map()) ::
          {:ok,
           %{
             user_uri: String.t(),
             caps_granted: non_neg_integer(),
             password_set: boolean(),
             spawned: String.t()
           }}
          | {:error, term()}
  def create_user(%URI{scheme: "workspace"} = workspace_uri, args, ctx)
      when is_map(args) and is_map(ctx) do
    # Codex PR #356 r1 CRIT fix: `:create_user` lives on the new
    # `Ezagent.Behavior.WorkspaceUserAdmin` (slice `:workspace_user_admin`),
    # NOT on `Behavior.Workspace` — so the cap subject is distinct.
    # uri-canonical-allow: §3.4 query-target idiom (multi-line)
    target =
      URI.new!("#{URI.to_string(workspace_uri)}?action=workspace_user_admin.create_user")

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    Router.dispatch(%Cmd{
      target: target,
      action: :create_user,
      args: args,
      ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  @doc """
  Loop `identity.grant_cap` dispatches against `agent_uri`, one per cap.
  Uses the CALLER's context (caps + URI) so the cap grants stay
  CapBAC-bound (LV's existing `grant_all/3` pattern, lifted into a
  shared helper so CLI can call it too).

  Returns `:ok` if all grants succeed, `{:error, {:grant_failed, cap,
  reason}}` on the first failure (does not continue past a failure —
  partial provisioning surfaces immediately).
  """
  @spec grant_initial_caps(URI.t(), [Ezagent.Capability.t()], map()) ::
          :ok | {:error, term()}
  def grant_initial_caps(_agent_uri, [], _ctx), do: :ok

  def grant_initial_caps(%URI{} = agent_uri, [cap | rest], ctx) when is_map(ctx) do
    target =
      Ezagent.URI.with_action(agent_uri, :identity, :grant_cap)

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    case Router.dispatch(%Cmd{
           target: target,
           action: :grant_cap,
           args: %{cap: cap},
           ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
         }) do
      {:ok, _} -> grant_initial_caps(agent_uri, rest, ctx)
      {:error, reason} -> {:error, {:grant_failed, cap, reason}}
    end
  end
end
