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

  # Workspace Behavior is workspace-scoped by default; bindings
  # operations should follow the workspace iso boundary so a tenant
  # admin can bind only within their workspace unless they hold a
  # cross-workspace cap.
  @impl Ezagent.Behavior
  def workspace_scoped?, do: true

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

    with {:ok, _row} <- UserBinding.bind(open_id, user_uri_str, bound_by),
         :ok <- BindingPolicy.apply(user_uri_str, bound_by) do
      {:ok, %{slice | bind_count: slice.bind_count + 1},
       %{open_id: open_id, user_uri: user_uri_str}}
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

  def invoke(:unbind, slice, %{open_id: open_id}, _ctx)
      when is_binary(open_id) and open_id != "" do
    case UserBinding.unbind(open_id) do
      :ok ->
        # Slice's bind_count is incidental — don't decrement (could go
        # negative on a multi-Kind restart race). The DB is the source
        # of truth.
        {:ok, slice, %{unbound: open_id}}

      {:error, :not_found} = err ->
        err

      other ->
        {:error, {:unbind_failed, other}}
    end
  end

  def invoke(:unbind, _slice, args, _ctx) do
    {:error, {:bad_args, "unbind requires {open_id: String}", args}}
  end

  def invoke(:list_feishu_bindings, slice, _args, _ctx) do
    bindings =
      UserBinding.list_all()
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
end
