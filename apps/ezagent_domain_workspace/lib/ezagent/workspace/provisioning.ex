defmodule Ezagent.Workspace.Provisioning do
  @moduledoc """
  Workspace provisioning entries — the unified CLI/LV create paths for
  agents, sessions, and users. Extracted verbatim from `Ezagent.Workspace`
  (2026-07-10) to keep the facade under the `oversized_modules_gt_1000`
  arch ratchet; the facade keeps `create_agent/3`, `create_session/3`,
  `create_user/3` as `defdelegate`s into this module so every caller
  (CLI, LiveView, mix tasks, integration tests) is unchanged.

  Each entry dispatches the relevant `Behavior.*` action against the
  target Workspace Kind via `Ezagent.Invocation.dispatch/1` (step 5.5
  CapBAC + audit telemetry + the action body's own checks). Shared
  facade helpers (`Ezagent.Workspace.spawn_workspace/2`,
  `Ezagent.Workspace.add_member/2`) are called back into the facade at
  runtime — no compile-time cycle (plain remote calls, not aliases/macros).
  """

  alias Ezagent.{Cmd, KindRegistry, Router}
  alias Ezagent.Workspace
  alias Ezagent.Workspace.Store

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

    dispatch_ctx =
      %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
      |> maybe_put_deadline_ms(ctx)

    Router.dispatch(%Cmd{
      target: target,
      action: :create_agent,
      args: args,
      ctx: dispatch_ctx,
      origin: :trusted_internal
    })
  end

  defp maybe_put_deadline_ms(dispatch_ctx, %{deadline_ms: deadline_ms})
       when is_integer(deadline_ms) and deadline_ms > 0 do
    Map.put(dispatch_ctx, :deadline_ms, deadline_ms)
  end

  defp maybe_put_deadline_ms(dispatch_ctx, _ctx), do: dispatch_ctx

  @doc """
  Dispatch the `:create_session` action on Workspace Kind — the
  unified CLI/LV session-creation entry from SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap C.

  Wraps `EzagentDomainInstanceMessage.SessionCreator.create_session/3` via the
  `Behavior.Workspace.:create_session` action so the CLI
  (`mix ezagent workspace create_session ...`) and the LV "New session"
  form both reach the same code path.

  Goes through `Ezagent.Invocation.dispatch/1` so step 5.5 CapBAC,
  audit telemetry, and the action body's workspace check all fire.

  `args` is `%{short_name: String.t(), template_name: String.t()}`.
  `ctx` carries `:caller` + `:caps`.

  Returns `{:ok, %{session_uri: URI.t()}}` on success; `{:error, reason}`
  on validation / cap denial / facade failure.
  """
  @spec create_session(URI.t(), map(), map()) ::
          {:ok, %{session_uri: URI.t()}}
          | {:error, term()}
  def create_session(%URI{scheme: "workspace"} = workspace_uri, args, ctx)
      when is_map(args) and is_map(ctx) do
    target =
      Ezagent.URI.with_action(workspace_uri, :workspace, :create_session)

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    with :ok <- ensure_workspace_live(workspace_uri) do
      Router.dispatch(%Cmd{
        target: target,
        action: :create_session,
        args: args,
        ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}},
        origin: :trusted_internal
      })
    end
  end

  defp ensure_workspace_live(%URI{scheme: "workspace"} = workspace_uri) do
    name = Ezagent.URI.name!(workspace_uri)

    case KindRegistry.lookup(workspace_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Store.get_by_name(name) do
          nil ->
            {:error, :workspace_not_found}

          %{members: members, session_templates: templates, routing_rules: rules} ->
            case Workspace.spawn_workspace(name, %{
                   members: members,
                   session_templates: templates,
                   routing_rules: rules
                 }) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
              {:error, reason} -> {:error, {:workspace_spawn_failed, reason}}
            end
        end
    end
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
    # `Ezagent.ActionSet.WorkspaceUserAdmin` (slice `:workspace_user_admin`),
    # NOT on `Behavior.Workspace` — so the cap subject is distinct.
    target = Ezagent.URI.with_action(workspace_uri, :workspace_user_admin, :create_user)

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    # 2026-07-10 golive gap (twin of the operator `mix ezagent.user.create`
    # fix): the `:create_user` action body inserts the `users` row (assigning
    # `workspace_uri`) but does NOT add the new user to `member_uris`. The
    # "my workspaces" view filters by MEMBERSHIP (a non-admin caller's
    # wildcard `workspace_uri: :any` caps contribute nothing — SPEC §3.3.b),
    # so a user created via this dispatch-backed path (the RECOMMENDED
    # replacement for the deprecated mix task) could not see their assigned
    # workspace.
    #
    # Add membership at the FACADE, AFTER the create_user dispatch has
    # returned — a SEPARATE, sequential dispatch, NOT re-entrant. Doing it
    # inside `Behavior.WorkspaceUserAdmin.handle_create_user/2`'s action body
    # would re-enter the SAME Workspace Kind (`add_member` dispatches
    # `:add_member` back to it while it is still handling `:create_user`) —
    # the deadlock we avoid by staying at the facade. The action body already
    # validated the user's URI is in the target workspace, so the concrete
    # workspace to join is exactly `workspace_uri`.
    #
    # Trusted `Workspace.add_member/2` (workspace self-authority): membership
    # is a STRUCTURAL consequence of a successful create, not a
    # separately-authorized caller action — the caller already passed the
    # `:create_user` CapBAC. The cap-checked `/3` would wrongly FAIL for a
    # holder of `create_user` but not `add_member`, re-opening the gap. This
    # mirrors `Ezagent.Registration.founder_join/2` and the operator mix
    # task. Idempotent (`add_member/2` dedups). `create_user`'s OWN errors
    # (cross_workspace_user / bad_user_uri / changeset) pass through the
    # `other` clause UNWRAPPED so existing dispatch-test error shapes hold.
    case Router.dispatch(%Cmd{
           target: target,
           action: :create_user,
           args: args,
           ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}},
           origin: :trusted_internal
         }) do
      {:ok, %{user_uri: uri_str} = result} when is_binary(uri_str) ->
        case Workspace.add_member(
               Ezagent.URI.workspace_name!(workspace_uri),
               Ezagent.URI.new!(uri_str)
             ) do
          :ok -> {:ok, result}
          {:error, reason} -> {:error, {:create_user_add_member_failed, reason}}
        end

      other ->
        other
    end
  end

  @doc """
  Dispatch the `:disable_user` action on Workspace Kind — the operator
  offboarding entry (task #180) for a REVERSIBLE soft-disable.

  The unified CLI (`mix ezagent workspace disable_user ...`), the world admin
  UI, and any programmatic caller all reach the same dispatch-backed path, so
  step 5.5 CapBAC + audit telemetry + the action body's cross-workspace check
  on the target user all fire. The `disabled_by` attribution is the
  authenticated `ctx.caller`, NOT a caller-supplied arg. No post-dispatch step
  (unlike `create_user`'s membership add) — the dispatch result passes through.

  `args` is `%{user_uri: String.t(), reason: String.t() | nil}`. `ctx` carries
  `:caller` + `:caps`. Returns `{:ok, %{user_uri, disabled_at, disabled_by}}`
  on success; `{:error, reason}` on validation / cap denial / cross-workspace
  refusal / unknown user.
  """
  @spec disable_user(URI.t(), map(), map()) ::
          {:ok, %{user_uri: String.t(), disabled_at: String.t(), disabled_by: String.t()}}
          | {:error, term()}
  def disable_user(%URI{scheme: "workspace"} = workspace_uri, args, ctx)
      when is_map(args) and is_map(ctx) do
    dispatch_user_admin(workspace_uri, :disable_user, args, ctx)
  end

  @doc """
  Dispatch the `:delete_user` action on Workspace Kind — the operator
  offboarding entry (task #180) for a HARD, admin-only tombstone delete.

  Same dispatch-backed path (CapBAC + audit + cross-workspace check) as
  `disable_user/3`. `delete_user` carries its OWN cap subject, withheld
  from workspace owners so only the admin wildcard authorizes it by
  default. The action tears down the live User Kind and tombstones the
  provisioning row (`Ezagent.Users.tombstone/3`) — the URI is NOT reclaimed
  and the `:user_deleted` EventLog event preserves the audit trail.

  `args` is `%{user_uri: String.t(), reason: String.t() | nil}`. `ctx`
  carries `:caller` + `:caps`.

  Returns `{:ok, %{user_uri, deleted_at, deleted_by}}` on success;
  `{:error, reason}` on validation / cap denial / cross-workspace refusal /
  unknown user.
  """
  @spec delete_user(URI.t(), map(), map()) ::
          {:ok, %{user_uri: String.t(), deleted_at: String.t(), deleted_by: String.t()}}
          | {:error, term()}
  def delete_user(%URI{scheme: "workspace"} = workspace_uri, args, ctx)
      when is_map(args) and is_map(ctx) do
    dispatch_user_admin(workspace_uri, :delete_user, args, ctx)
  end

  # Shared dispatch for the WorkspaceUserAdmin offboarding actions. Unlike
  # `create_user/3` these need NO post-dispatch facade step (no membership
  # to add), so the dispatch result passes straight through. Targets the
  # `:workspace_user_admin` slice (distinct cap subject from Behavior.Workspace).
  defp dispatch_user_admin(%URI{scheme: "workspace"} = workspace_uri, action, args, ctx)
       when action in [:disable_user, :delete_user] do
    target = Ezagent.URI.with_action(workspace_uri, :workspace_user_admin, action)
    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    Router.dispatch(%Cmd{
      origin: :trusted_internal,
      target: target,
      action: action,
      args: args,
      ctx: %{mode: :call, caller: caller, caps: caps, reply: {:caller_inbox, self()}}
    })
  end
end
