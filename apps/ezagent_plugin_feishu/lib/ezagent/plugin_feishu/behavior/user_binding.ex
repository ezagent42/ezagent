defmodule EzagentPluginFeishu.Behavior.UserBinding do
  @moduledoc """
  Feishu user-binding Behavior — operator-facing CRUD on the
  `feishu_user_bindings` table (open_id ↔ user URI mappings).

  ## Why a Behavior + Workspace Kind target

  Per `docs/futures/todo.md` HIGH-2 (CLI/LV parity) and codex PR #304
  round-1 HIGH finding: every legacy `mix ezagent.*` task that mutates
  state MUST go through the framework dispatcher so the call gets
  CapBAC + audit + cross-workspace-check. Adding a `FacadeRegistry`
  shortcut for `feishu bind` would reproduce the exact bypass HIGH-2
  is meant to retire (FacadeRegistry skips the dispatcher entirely).

  The natural Kind target is `Ezagent.Entity.Workspace` because:
  - The Feishu binding is a tenant-scoped operation (different
    workspaces could have different bound users from the same Feishu
    open_id, though current schema is global; the cap-check is
    workspace-scoped which is the right granularity for the v1
    plugin-isolation north star).
  - Workspace Kind already serves as the parent for tenant-level
    operations (`:create_agent` per PR #344 case study; this PR adds
    the same shape for Feishu bindings).
  - No new Kind needed — keeps the plugin contract surface tight
    (P1 plugin isolation).

  ## Actions

  - `:bind` — args `%{open_id: String.t(), user_uri: URI.t()}` →
    `{:ok, %{open_id: String.t(), user_uri: String.t()}}`.
    Body wraps `EzagentPluginFeishu.UserBinding.bind/3 +
    EzagentPluginFeishu.BindingPolicy.apply/2` — the same pair the
    legacy `mix ezagent.feishu.bind` task and `FeishuBindingsLive`
    "bind" event call directly. The slice records the binding count
    incidentally.

  - `:unbind` — args `%{open_id: String.t()}` → `{:ok, %{unbound: String.t()}}`.
    Wraps `EzagentPluginFeishu.UserBinding.unbind/1`.

  - `:list_feishu_bindings` — `{:ok, %{bindings: [%{open_id, user_uri, bound_by, bound_at}]}}`.
    Read-only; wraps `EzagentPluginFeishu.UserBinding.list_all/0`.

  ## Slice

      %{bind_count: integer()}

  Per the existing Routing Behavior pattern, the slice is an
  incidental counter — the durable table is owned by
  `EzagentCore.Repo` via `EzagentPluginFeishu.UserBinding` (the
  Ecto schema module). The slice is not persisted (no `state_slice`
  declaration on the snapshot side); on Kind restart the count
  resets but the binding rows survive in the DB.

  ## Cap shape (PR-CC-2-v2 contract)

  Three `required_caps/0` rows — one per action. Each is
  `Capability.cap(:workspace, __MODULE__, <action>)` (kind axis
  `:workspace` because the Behavior is registered on Workspace Kind).
  The dispatch chokepoint at `Kind.Server.runtime.ex` step 5.5 reads
  this map; `:list` is workspace-scoped so a tenant operator can list
  bindings within their workspace.

  Per the existing `Behavior.Workspace`'s `workspace_scoped? = true`
  default, `:bind` / `:unbind` / `:list` all run within the target
  workspace's iso boundary unless the caller holds a cross-workspace
  cap (e.g. system-workspace member).

  ## Auto-derived CLI

  `mix ezagent workspace bind --workspace <name> --open-id <oid> --user-uri <uri>`
  `mix ezagent workspace unbind --workspace <name> --open-id <oid>`
  `mix ezagent workspace list_feishu_bindings --workspace <name>`

  The legacy `mix ezagent.feishu.bind` / `unbind` / `list` tasks are
  now thin wrappers that delegate to formal synchronous dispatch
  (handoff B1 Phase 4, 2026-07-24) — no raw storage, no raw handler,
  no raw policy. They are retained with a deprecation notice for
  operator muscle memory; the canonical authenticated path is
  `mix ezagent workspace <action> --workspace <name> ...`. See the
  task moduledocs for the exact replacement command per action.

  ## Phase B migration (2026-05-29) — Lifecycle API

  Migrated from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle`
  per SPEC `2026-05-29-lifecycle-hooks-design.md` §2.3 (the simple,
  no-transients case). The `:bind_count` slice is durable PERSISTENT
  `state` (an incidental counter; the DB table is the real SSOT) —
  there are NO transients (no PID / ETS / port / subprocess /
  monitor), so `init_slice/1` → `create/1` and `activate/2` is the
  macro-injected no-op default. The `handle_<action>/2` bodies are
  byte-identical.

  The slice key `:feishu_user_bindings` does NOT match the macro's
  auto-derived key (the last module segment `UserBinding` would
  derive `:user_binding`), so the snapshot-compat `state_slice:`
  override is used (SPEC §5 / §7 OQ-7) with the required
  `# lifecycle:state_slice_override` marker comment.

  Earlier (Phase 2-f r3, 2026-05-28) this Behavior was already on the
  declarative `action/3` + per-action `handle_<action>/2` + effects
  contract; handlers return `{:ok, result, [effects]}` where effects
  are `{:set, key, value}` for slice mutations.

  Custom `required_caps/0` is retained (not auto-derived) because
  the cap axis is `:workspace`, not the macro's default `:any`. The
  derived `cap_subjects/0` is also overridden — the existing
  English descriptions are richer than the action's `description:`
  field. The bulk side-effecting helpers (workspace check,
  hijack check, rollback) survive unchanged because they are pure
  Elixir functions called from the handler body (SPEC §4.5.1 allows
  direct calls to pure helpers; what's forbidden is the framework
  dispatcher and the framework PubSub broadcaster from handler
  bodies — this Behavior never had those).
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :feishu_user_bindings

  alias EzagentPluginFeishu.BindingPolicy
  alias EzagentPluginFeishu.UserBinding

  # DI seam: tests inject a fake storage module via
  # `config :ezagent_plugin_feishu, :user_binding_storage_mod`.
  defp storage_mod do
    Application.get_env(:ezagent_plugin_feishu, :user_binding_storage_mod, UserBinding)
  end

  # ===================================================================
  # Action declarations (SPEC §2.2 + §4.3)
  # ===================================================================

  action(:bind,
    args: %{open_id: :string, user_uri: :uri},
    returns: %{open_id: :string, user_uri: :string},
    caps: [:bind],
    description:
      "Bind a Feishu open_id to a local Ezagent user URI. Also " <>
        "applies the default session-participation cap (idempotent) so " <>
        "the bound user can dispatch chat messages.",
    modes: [:call]
  )

  action(:unbind,
    args: %{open_id: :string},
    returns: %{unbound: :string},
    caps: [:unbind],
    description: "Remove a Feishu open_id binding.",
    modes: [:call]
  )

  action(:list_feishu_bindings,
    args: %{},
    returns: %{bindings: {:list, :map}},
    caps: [:list_feishu_bindings],
    description:
      "List all Feishu open_id → user URI bindings (read-only). " <>
        "Returns a list of %{open_id, user_uri, bound_by, bound_at}.",
    modes: [:call]
  )

  # ===================================================================
  # Legacy callbacks retained for framework wiring
  # ===================================================================

  # Custom `required_caps/0` (overrides macro-derived default) — cap
  # axis is `:workspace`, not the macro's `:any` default.
  def required_caps do
    %{
      bind: Ezagent.Capability.cap(:workspace, __MODULE__, :bind),
      unbind: Ezagent.Capability.cap(:workspace, __MODULE__, :unbind),
      list_feishu_bindings: Ezagent.Capability.cap(:workspace, __MODULE__, :list_feishu_bindings)
    }
  end

  # Custom `cap_subjects/0` (overrides macro-derived default) — the
  # pre-migration English is richer than the action's `description:`
  # field. The `:bind` description in particular calls out the
  # BindingPolicy side effect.
  def cap_subjects do
    [
      {:bind,
       "bind a Feishu open_id to a local Ezagent user URI (the bound user " <>
         "participates per-session via join, like every member)"},
      {:unbind, "remove a Feishu open_id binding"},
      {:list_feishu_bindings, "list all open_id → user URI bindings (read-only)"}
    ]
  end

  # `state_slice/0` is macro-emitted from the `state_slice:
  # :feishu_user_bindings` override above (the hand-rolled
  # `def state_slice` is gone). `init_slice/1` → `create/1`: build the
  # initial PERSISTENT `state` once. No transients, so `activate/2` is
  # the macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{bind_count: 0}}

  # Codex r1 P1: `workspace_scoped? = true` would only check that the
  # CALLER and TARGET share a workspace; the action body operates on
  # the GLOBAL `feishu_user_bindings` table (no workspace column).
  # That combination is unsound — a caller with the cap for
  # workspace://A could bind/unbind a workspace://B user.
  #
  # The correct shape until the table grows a workspace column: this
  # is a CROSS-WORKSPACE Behavior. The action body's per-call
  # `workspace_check/2` (below) enforces that the bound user URI
  # lives in the SAME workspace as the dispatch target (extracted
  # structurally from the URI), and the read-side `:list_feishu_bindings`
  # filters rows by the target workspace. A bootstrap-admin holder
  # passes the structural check via `:any`-instance caps.
  #
  # This matches the pattern `Behavior.Routing.workspace_scoped? =
  # false` uses for the global `system://routing/default` shape —
  # cross-workspace by Kind, structurally-enforced inside the action.
  def workspace_scoped?, do: false

  # PR-OWN-4 data_owner pattern (matching Behavior.Workspace): the
  # workspace itself owns its bindings. `:any` means workspace-admin
  # grantable; bootstrap admin always grants per the IdentityAdmin
  # §5.2 ladder.
  def data_owner(_), do: :any

  # ===================================================================
  # Handler bodies (new contract — §6.2 retrofit)
  # ===================================================================
  #
  # Each handler is `(args, ctx) → {:ok, result, [effect]} | {:error, reason}`.
  # `ctx.read.(:key, default)` reads the current slice's field via
  # the framework-managed `read` closure (`Kind.Runtime` step 5.5
  # builds it before calling the handler). Slice mutations are emitted
  # as `{:set, key, value}` effects; the framework applies them and
  # commits the snapshot.
  #
  # Argument-shape validation is done with explicit `is_binary/1`
  # guards at the handler head — the legacy `invoke/4` used clause
  # pattern matching for the same purpose; per SPEC §6.2 step 1 we
  # preserve the structural check inline rather than introducing
  # a separate `validate_args/2`.

  def handle_bind(%{open_id: open_id, user_uri: user_uri}, ctx)
      when is_binary(open_id) and open_id != "" do
    # The `bound_by` attribution is the caller URI from the dispatch
    # ctx — never a CLI-supplied flag. This prevents an admin
    # impersonating "another admin" via `--admin entity://...` (the
    # legacy task accepted such a flag; the dispatched action body
    # uses the authenticated caller).
    bound_by = Map.get(ctx, :caller) || default_admin_uri()
    user_uri_str = uri_to_str(user_uri)

    # B2 review R3: the ActionSet MUST fail-closed on non-entity URIs
    # BEFORE any side-effect.  The old World-UI `valid_entity_uri?/4`
    # check was the only gate and it was removed in B2; this is the
    # authoritative single chokepoint — a template://, session://, or
    # any other non-entity URI is rejected here regardless of caller
    # caps or admin context.
    #
    # Codex r1 P1.2: enforce workspace scope on the NEW user URI BEFORE
    # any side-effect. The table is global (no workspace column) so
    # we structurally derive the user's workspace from their URI and
    # require it to match the dispatch target's workspace — unless
    # the caller holds a bootstrap-admin cap (defence in depth for
    # cross-tenant migrations).
    #
    # Codex r2 P1: ALSO check the EXISTING binding (if any) belongs
    # to the target workspace. Without this, a workspace://team-alpha
    # caller could re-bind an open_id currently held by team-beta to
    # a team-alpha user — hijacking the other tenant's Feishu
    # identity. Two structural checks: the new user_uri AND any
    # existing row both must match the target workspace.
    #
    # Codex r3 P2: snapshot the prior row BEFORE the upsert so the
    # rollback path on `apply_policy_or_rollback` failure can RESTORE
    # the prior binding (legitimate same-workspace rebind that fails
    # mid-policy must not destroy the operator's existing setup).
    prior_row = snapshot_existing_binding(open_id)

    with :ok <- ensure_entity_user_uri(user_uri_str),
         :ok <- ensure_same_workspace(user_uri_str, ctx),
         :ok <- ensure_no_cross_workspace_hijack(open_id, ctx),
         {:ok, _row} <- storage_mod().bind(open_id, user_uri_str, bound_by),
         :ok <- apply_policy_or_rollback(open_id, user_uri_str, bound_by, prior_row) do
      # Codex r1 P1.1: the Workspace Kind only initializes the
      # `:workspace` slice in its init_slice/1 — plugin-registered
      # Behavior slices arrive as `%{}` from `Map.get(state, slice_key,
      # %{})` in `Kind.Runtime.handle_dispatch/4`. Lazy-seed
      # `bind_count` so `slice + 1` doesn't crash AFTER side-effects.
      # Same pattern as `Behavior.Routing.bump/1` (its lib/.../routing.ex
      # comments cite the same reason).
      #
      # New contract: read via `ctx.read`, write via `{:set, :bind_count, ...}`
      # effect; the framework's `apply_effects` builds the new slice.
      cur = ctx[:read].(:bind_count, 0)

      {:ok, %{open_id: open_id, user_uri: user_uri_str}, [{:set, :bind_count, cur + 1}]}
    else
      {:error, _} = err ->
        err

      other ->
        {:error, {:bind_failed, other}}
    end
  end

  def handle_bind(args, _ctx) do
    {:error, {:bad_args, "bind requires {open_id: String, user_uri: URI|String}", args}}
  end

  def handle_unbind(%{open_id: open_id}, ctx)
      when is_binary(open_id) and open_id != "" do
    # Codex r1 P1.2: before unbinding, check that the existing binding
    # row belongs to the dispatch target's workspace. Without this, a
    # caller with cap on workspace://A could unbind any open_id
    # globally. Reads happen pre-mutation; the only side-effect is
    # gated by `ensure_existing_binding_in_workspace/2`.
    with {:ok, _row} <- ensure_existing_binding_in_workspace(open_id, ctx),
         :ok <- storage_mod().unbind(open_id) do
      # Slice's bind_count is incidental — don't decrement (could go
      # negative on a multi-Kind restart race). The DB is the source
      # of truth. Returns no effects (slice unchanged).
      {:ok, %{unbound: open_id}, []}
    else
      {:error, :not_found} = err ->
        err

      {:error, _} = err ->
        err

      other ->
        {:error, {:unbind_failed, other}}
    end
  end

  def handle_unbind(args, _ctx) do
    {:error, {:bad_args, "unbind requires {open_id: String}", args}}
  end

  def handle_list_feishu_bindings(_args, ctx) do
    # Codex r1 P1.2: filter rows by the dispatch target's workspace
    # so a tenant operator only sees bindings for their workspace's
    # users. Bootstrap admin sees all rows (the :any-instance cap
    # carrier; structurally enforced by `workspace_match?/2` short
    # circuiting on :any).
    target_workspace = target_workspace_uri(ctx)

    bindings =
      storage_mod().list_all()
      |> Enum.filter(fn
        %{user_uri: u} -> workspace_match?(u, target_workspace)
        _ -> false
      end)
      |> Enum.map(fn %{open_id: o, user_uri: u, bound_by: by, bound_at: at} ->
        %{open_id: o, user_uri: u, bound_by: by, bound_at: at}
      end)

    # Read-only: no effects. Slice unchanged.
    {:ok, %{bindings: bindings}, []}
  end

  # ===================================================================
  # Helpers
  # ===================================================================

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s

  # B2 review R3: fail-closed gate — only `entity://<ws>/user/<name>` URIs
  # are valid Feishu binding targets. The old World-UI `valid_entity_uri?`
  # check was removed; this is the authoritative single chokepoint.
  defp ensure_entity_user_uri(str) when is_binary(str) do
    case Ezagent.URI.new!(str) do
      %URI{scheme: "entity"} = uri ->
        case Ezagent.URI.type(uri) do
          {:ok, "user"} -> :ok
          _ -> {:error, {:not_user_entity, str}}
        end

      _ ->
        {:error, {:not_entity_uri, str}}
    end
  rescue
    _ -> {:error, {:not_entity_uri, str}}
  end

  # Fallback `bound_by` attribution. Only reachable in test
  # scenarios that bypass the dispatch caller-resolution path
  # (production CLI + LV both populate ctx.caller).
  defp default_admin_uri do
    if function_exported?(Ezagent.Entity.User, :admin_uri, 0) do
      URI.to_string(Ezagent.Entity.User.admin_uri())
    else
      Ezagent.URI.user(:system, :admin) |> URI.to_string()
    end
  end

  # Codex r1 P1.2: structural workspace-match between a bound user
  # URI and the dispatch target's workspace.
  #
  # Bootstrap-admin caps surface as `:any`-instance + `:any`-workspace
  # in their match shape; we treat the absence of a concrete target
  # workspace as "admin bypass" (the cap-check at step 5.5 already
  # validated the caller can dispatch — by this point a non-admin
  # must have had a concrete workspace target). For concrete targets
  # we require the user URI's workspace segment to match.
  defp ensure_same_workspace(user_uri_str, ctx) do
    target_ws = target_workspace_uri(ctx)

    cond do
      # `:any` target = bootstrap admin or test fixture with no
      # self_uri — let step 5.5 cap check stay the gate.
      target_ws == :any ->
        :ok

      workspace_match?(user_uri_str, target_ws) ->
        :ok

      true ->
        {:error,
         {:cross_workspace_user, target_workspace: URI.to_string(target_ws), user: user_uri_str}}
    end
  end

  # For :unbind — the existing row's user_uri tells us whose binding
  # this is. We refuse unless the row's user belongs to the target
  # workspace (or the caller holds an :any target via bootstrap admin).
  defp ensure_existing_binding_in_workspace(open_id, ctx) do
    case storage_mod().resolve(open_id) do
      {:ok, %URI{} = user_uri} ->
        case ensure_same_workspace(URI.to_string(user_uri), ctx) do
          :ok -> {:ok, user_uri}
          err -> err
        end

      :error ->
        {:error, :not_found}
    end
  end

  # Codex r2 P1: rebind check. If `open_id` is already bound to a
  # user in a DIFFERENT workspace, refuse the rebind — that would let
  # workspace://A hijack workspace://B's Feishu identity by upserting
  # against the global primary key. `:ok` returned for both "no
  # existing binding" (clean bind) and "existing binding is in target
  # workspace" (legitimate rebind within the same tenant).
  #
  # Bootstrap admin (target = :any) bypasses — step 5.5 already
  # validated the cap; cross-workspace operator move is intentional.
  defp ensure_no_cross_workspace_hijack(open_id, ctx) do
    case storage_mod().resolve(open_id) do
      :error ->
        # No existing binding — fresh bind path. :ok.
        :ok

      {:ok, %URI{} = existing_user_uri} ->
        case ensure_same_workspace(URI.to_string(existing_user_uri), ctx) do
          :ok ->
            :ok

          {:error, {:cross_workspace_user, _}} ->
            {:error,
             {:cross_workspace_rebind,
              open_id: open_id, existing_user: URI.to_string(existing_user_uri)}}

          err ->
            err
        end
    end
  end

  # Codex r2 P2 + r3 P2: rollback the DB row if BindingPolicy.apply/2
  # fails after UserBinding.bind/3 committed. Without rollback, the
  # inbound Feishu resolution would map the open_id to the user even
  # though the caller saw the operation as failed (caps weren't
  # actually granted).
  #
  # Codex r3 P2: if this was a REBIND (prior_row != nil), restore the
  # prior binding instead of unconditionally deleting — a same-workspace
  # rotation that fails mid-policy must not lose the operator's
  # existing setup. Restore is "rebind to the prior user_uri" (idempotent
  # on the open_id primary key).
  #
  # Rollback failure is distinct from an ordinary policy failure. Callers
  # must not be told the mutation was restored when the compensating write
  # failed and the new binding may still be durable.
  defp apply_policy_or_rollback(open_id, user_uri_str, bound_by, prior_row) do
    case BindingPolicy.apply(user_uri_str, bound_by) do
      :ok ->
        :ok

      {:error, reason} = err ->
        policy_failure_result(open_id, prior_row, reason, err)

      other ->
        reason = {:unexpected_policy_result, other}
        policy_failure_result(open_id, prior_row, reason, {:error, reason})
    end
  end

  defp policy_failure_result(open_id, prior_row, policy_reason, original_err) do
    case rollback_binding(open_id, prior_row, original_err) do
      :ok -> {:error, {:binding_policy_failed, policy_reason}}
      {:error, rollback_reason} -> {:error, {:binding_rollback_failed, rollback_reason}}
    end
  end

  # Snapshot the existing row (if any) BEFORE the upsert so the
  # rollback path can restore it. Reads the full row (not just the
  # user_uri) so `bound_by` + `bound_at` survive the rotation-rollback.
  defp snapshot_existing_binding(open_id) do
    case EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id) do
      nil -> nil
      %EzagentPluginFeishu.UserBinding{} = row -> row
    end
  end

  defp rollback_binding(open_id, nil, original_err) do
    # No prior row — fresh bind that failed. Delete the row we wrote.
    case storage_mod().unbind(open_id) do
      :ok ->
        :ok

      {:error, rollback_reason} ->
        log_rollback_failure(open_id, :delete, rollback_reason, original_err)
        {:error, rollback_reason}

      other ->
        log_rollback_failure(open_id, :delete, other, original_err)
        {:error, other}
    end
  end

  defp rollback_binding(
         open_id,
         %EzagentPluginFeishu.UserBinding{
           user_uri: prior_user,
           bound_by: prior_by,
           bound_at: prior_bound_at
         },
         original_err
       ) do
    # Codex r3 P2 restored + Handoff B1 Phase 3: restore the prior
    # binding including the ORIGINAL bound_at timestamp. `UserBinding.bind/4`
    # accepts an explicit bound_at, so the rollback restores every
    # provenance field — user_uri, bound_by, AND bound_at — precisely.
    case storage_mod().bind(open_id, prior_user, prior_by, prior_bound_at) do
      {:ok, _row} ->
        :ok

      {:error, rollback_reason} ->
        log_rollback_failure(open_id, :restore, rollback_reason, original_err)
        {:error, rollback_reason}

      other ->
        log_rollback_failure(open_id, :restore, other, original_err)
        {:error, other}
    end
  end

  defp log_rollback_failure(open_id, mode, rollback_reason, original_err) do
    require Logger

    alias EzagentPluginFeishu.Redact

    # Only log the error class atoms, never raw error terms that could
    # carry the open_id or user_uri from the failed operation.
    rollback_class = error_class(rollback_reason)
    original_class = error_class(original_err)

    Logger.error(
      "EzagentPluginFeishu.Behavior.UserBinding.:bind: BindingPolicy failed + " <>
        "rollback (#{mode}) failed: open_id=#{Redact.fingerprint(open_id)} " <>
        "rollback_error=#{rollback_class} original_error=#{original_class}"
    )
  end

  defp error_class({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(_other), do: "unexpected"

  # Pull the target Workspace URI out of dispatch ctx. `self_uri` is
  # injected by Kind.Runtime step 5 — for `workspace://X?action=...`
  # it is `workspace://X`. Test scenarios that build ctx manually may
  # pass it directly.
  defp target_workspace_uri(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{scheme: "workspace"} = uri -> uri
      _ -> :any
    end
  end

  # Does the user URI's workspace segment match the target workspace?
  # Entity URIs are `entity://<type>/<workspace>/<name>` per SPEC v3
  # §3 — extract the workspace via Ezagent.URI.entity_workspace_uri/1
  # and compare.
  defp workspace_match?(_user_uri_str, :any), do: true

  defp workspace_match?(user_uri_str, %URI{} = target_ws) when is_binary(user_uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint;
    # outer rescue already collapses every failure path to `false`.
    case Ezagent.URI.new!(user_uri_str) do
      %URI{scheme: "entity"} = user_uri ->
        case Ezagent.URI.entity_workspace_uri(user_uri) do
          %URI{} = user_ws -> URI.to_string(user_ws) == URI.to_string(target_ws)
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp workspace_match?(_, _), do: false
end
