defmodule EzagentPluginFeishu.Behavior.UserBinding do
  @moduledoc """
  Feishu user-binding Behavior — operator-facing CRUD on the
  `feishu_user_bindings` table (open_id ↔ user URI mappings).

  ## Why a Behavior + Workspace Kind target

  Per `docs/futures/todo.md` HIGH-2 (CLI/LV parity) and codex PR #304
  round-1 HIGH finding: every legacy `mix ezagent.*` task that mutates
  state MUST go via `Ezagent.Invocation.dispatch/1` so the call gets
  CapBAC + audit + cross-workspace-check. Adding a `FacadeRegistry`
  shortcut for `feishu bind` would reproduce the exact bypass HIGH-2
  is meant to retire (FacadeRegistry skips Invocation entirely).

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

  - `:list` — `{:ok, slice, %{bindings: [%{open_id, user_uri, bound_by, bound_at}]}}`.
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

  `mix esr workspace bind --workspace <name> --open-id <oid> --user-uri <uri>`
  `mix esr workspace unbind --workspace <name> --open-id <oid>`
  `mix esr workspace list_feishu_bindings --workspace <name>`

  The legacy `mix ezagent.feishu.bind` / `unbind` / `list` tasks are
  retained pending operator migration (PR-CC-2-v2 ending-state
  carve-out — Allen's "no defer" applies to ARCHITECTURE not UX:
  legacy tasks are now thin wrappers that delegate to dispatch via
  the auto-derived path; the operator-facing command line is
  preserved for muscle memory while the internals go through
  CapBAC + audit). See `@deprecated` annotations on those tasks.
  """

  @behaviour Ezagent.Behavior

  alias EzagentPluginFeishu.{BindingPolicy, UserBinding}

  @impl Ezagent.Behavior
  def actions, do: [:bind, :unbind, :list_feishu_bindings]

  @impl Ezagent.Behavior
  def required_caps do
    %{
      bind: Ezagent.Capability.cap(:workspace, __MODULE__, :bind),
      unbind: Ezagent.Capability.cap(:workspace, __MODULE__, :unbind),
      list_feishu_bindings:
        Ezagent.Capability.cap(:workspace, __MODULE__, :list_feishu_bindings)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:bind,
       "bind a Feishu open_id to a local ESR user URI (also applies " <>
         "BindingPolicy default session-participation cap)"},
      {:unbind, "remove a Feishu open_id binding"},
      {:list_feishu_bindings, "list all open_id → user URI bindings (read-only)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :feishu_user_bindings

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{bind_count: 0}

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
  @impl Ezagent.Behavior
  def workspace_scoped?, do: false

  # PR-OWN-4 data_owner pattern (matching Behavior.Workspace): the
  # workspace itself owns its bindings. `:any` means workspace-admin
  # grantable; bootstrap admin always grants per the IdentityAdmin
  # §5.2 ladder.
  @impl Ezagent.Behavior
  def data_owner(_), do: :any

  # ===================================================================
  # Action bodies
  # ===================================================================

  @impl Ezagent.Behavior
  def invoke(:bind, slice, %{open_id: open_id, user_uri: user_uri}, ctx)
      when is_binary(open_id) and open_id != "" do
    # The `bound_by` attribution is the caller URI from the dispatch
    # ctx — never a CLI-supplied flag. This prevents an admin
    # impersonating "another admin" via `--admin entity://...` (the
    # legacy task accepted such a flag; the dispatched action body
    # uses the authenticated caller).
    bound_by = Map.get(ctx, :caller) || default_admin_uri()
    user_uri_str = uri_to_str(user_uri)

    # Codex r1 P1.2: enforce workspace scope on the user URI BEFORE
    # any side-effect. The table is global (no workspace column) so
    # we structurally derive the user's workspace from their URI and
    # require it to match the dispatch target's workspace — unless
    # the caller holds a bootstrap-admin cap (defence in depth for
    # cross-tenant migrations).
    with :ok <- ensure_same_workspace(user_uri_str, ctx),
         {:ok, _row} <- UserBinding.bind(open_id, user_uri_str, bound_by),
         :ok <- BindingPolicy.apply(user_uri_str, bound_by) do
      # Codex r1 P1.1: the Workspace Kind only initializes the
      # `:workspace` slice in its init_slice/1 — plugin-registered
      # Behavior slices arrive as `%{}` from `Map.get(state, slice_key,
      # %{})` in `Kind.Runtime.handle_dispatch/4`. Lazy-seed
      # `bind_count` so `slice + 1` doesn't crash AFTER side-effects.
      # Same pattern as `Behavior.Routing.bump/1` (its lib/.../routing.ex
      # comments cite the same reason).
      new_slice = Map.update(slice, :bind_count, 1, &(&1 + 1))

      {:ok, new_slice, %{open_id: open_id, user_uri: user_uri_str}}
    else
      {:error, _} = err ->
        err

      other ->
        {:error, {:bind_failed, other}}
    end
  end

  def invoke(:bind, _slice, args, _ctx) do
    {:error, {:bad_args, "bind requires {open_id: String, user_uri: URI|String}", args}}
  end

  def invoke(:unbind, slice, %{open_id: open_id}, ctx)
      when is_binary(open_id) and open_id != "" do
    # Codex r1 P1.2: before unbinding, check that the existing binding
    # row belongs to the dispatch target's workspace. Without this, a
    # caller with cap on workspace://A could unbind any open_id
    # globally. Reads happen pre-mutation; the only side-effect is
    # gated by `ensure_existing_binding_in_workspace/2`.
    with {:ok, _row} <- ensure_existing_binding_in_workspace(open_id, ctx),
         :ok <- UserBinding.unbind(open_id) do
      # Slice's bind_count is incidental — don't decrement (could go
      # negative on a multi-Kind restart race). The DB is the source
      # of truth.
      {:ok, slice, %{unbound: open_id}}
    else
      {:error, :not_found} = err ->
        err

      {:error, _} = err ->
        err

      other ->
        {:error, {:unbind_failed, other}}
    end
  end

  def invoke(:unbind, _slice, args, _ctx) do
    {:error, {:bad_args, "unbind requires {open_id: String}", args}}
  end

  def invoke(:list_feishu_bindings, slice, _args, ctx) do
    # Codex r1 P1.2: filter rows by the dispatch target's workspace
    # so a tenant operator only sees bindings for their workspace's
    # users. Bootstrap admin sees all rows (the :any-instance cap
    # carrier; structurally enforced by `workspace_match?/2` short
    # circuiting on :any).
    target_workspace = target_workspace_uri(ctx)

    bindings =
      UserBinding.list_all()
      |> Enum.filter(fn b -> workspace_match?(b.user_uri, target_workspace) end)
      |> Enum.map(fn b ->
        %{
          open_id: b.open_id,
          user_uri: b.user_uri,
          bound_by: b.bound_by,
          bound_at: b.bound_at
        }
      end)

    {:ok, slice, %{bindings: bindings}}
  end

  # ===================================================================
  # Interface — drives `mix esr` auto-derivation + CmdK help.
  # ===================================================================

  @impl Ezagent.Behavior
  def interface do
    %{
      bind: %{
        description:
          "Bind a Feishu open_id to a local ESR user URI. Also " <>
            "applies the default session-participation cap (idempotent) so " <>
            "the bound user can dispatch chat messages.",
        args: %{open_id: :string, user_uri: :uri},
        returns: %{open_id: :string, user_uri: :string},
        modes: [:call]
      },
      unbind: %{
        description: "Remove a Feishu open_id binding.",
        args: %{open_id: :string},
        returns: %{unbound: :string},
        modes: [:call]
      },
      list_feishu_bindings: %{
        description:
          "List all Feishu open_id → user URI bindings (read-only). " <>
            "Returns a list of %{open_id, user_uri, bound_by, bound_at}.",
        args: %{},
        returns: %{bindings: {:list, :map}},
        modes: [:call]
      }
    }
  end

  # ===================================================================
  # Helpers
  # ===================================================================

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s

  # Fallback `bound_by` attribution. Only reachable in test
  # scenarios that bypass the dispatch caller-resolution path
  # (production CLI + LV both populate ctx.caller).
  defp default_admin_uri do
    if function_exported?(Ezagent.Entity.User, :admin_uri, 0) do
      URI.to_string(Ezagent.Entity.User.admin_uri())
    else
      "entity://user/system/admin"
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
    case UserBinding.resolve(open_id) do
      {:ok, %URI{} = user_uri} ->
        case ensure_same_workspace(URI.to_string(user_uri), ctx) do
          :ok -> {:ok, user_uri}
          err -> err
        end

      :error ->
        {:error, :not_found}
    end
  end

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
    case URI.new(user_uri_str) do
      {:ok, %URI{scheme: "entity"} = user_uri} ->
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
