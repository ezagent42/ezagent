defmodule Ezagent.ActionSet.WorkspaceUserAdmin do
  @moduledoc """
  Workspace-scoped user-admin Behavior — provisions new Ezagent users
  in a workspace via dispatch.

  ## Why a separate Behavior (not on `Behavior.Workspace`)

  Per codex PR #356 r1 CRIT finding: the Capability struct does NOT
  carry an action axis (`Capability.cap/3` ignores the action arg,
  and `Capability.matches?/2` only compares kind/behavior/instance/
  workspace_uri). So every action under one Behavior shares the
  same cap subject.

  Folding `:create_user` into `Behavior.Workspace` would mean any
  holder of e.g. `(:workspace, Behavior.Workspace, :add_member)` on
  `workspace://X` would ALSO be authorized to call `:create_user` —
  minting arbitrary new users with arbitrary caps. That's a
  structural escalation surface this Behavior closes by carving
  user-admin into its OWN cap subject:

      Capability.cap(:workspace, Ezagent.ActionSet.WorkspaceUserAdmin, :create_user)

  An operator who needs workspace member management but NOT new-user
  provisioning is granted the Workspace cap only; the user-admin
  privilege is the additional structural grant. Until the broader
  cap-action-axis SPEC lands (deferred — needs whole-codebase sweep),
  this Behavior-per-privileged-action pattern is the structural
  carve-out.

  ## Why Workspace Kind, not User Kind

  The User Kind doesn't exist at creation time — it's spawned as a
  SIDE EFFECT of `:create_user`. Dispatching on a not-yet-existing
  Kind is impossible. The Workspace Kind is the natural parent
  (matches the `:create_agent` pattern from PR #344 case study).

  ## Action

  - `:create_user` — args `%{user_uri: String.t(), password: String.t() | nil,
    caps: String.t() | nil}` → `%{user_uri, caps_granted, password_set, spawned}`.

    Wraps `Ezagent.Users.create/3` + opportunistic
    `SpawnRegistry.spawn`. Enforces a structural cross-workspace
    check: the new user URI's workspace segment MUST match the
    dispatch target's workspace. Bootstrap admin (`:any` target) is
    exempt because step 5.5 already validated cross-workspace
    authority.

  ## Slice

      %{create_count: integer()}

  Incidental counter; durable storage is the `users` table owned by
  `Ezagent.Users` (the Ecto schema).

  ## Cap shape (PR-CC-2-v2 contract)

  One cap entry — `Capability.cap(:workspace, __MODULE__,
  :create_user)`. Kind axis is `:workspace` because the Behavior is
  registered on Workspace Kind. The cap is its OWN subject — no
  overlap with `Behavior.Workspace`'s 10 actions.

  ## Auto-derived CLI

      mix ezagent workspace create_user \\
          --workspace <name> \\
          --user-uri entity://user/<workspace>/<handle> \\
          --password <pw> \\
          --caps '<cap1,cap2,...>'

  Legacy `mix ezagent.user.create` is retained for muscle memory
  with a deprecation notice (PR #355 pattern).

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.ActionSet` action/handler contract
  per SPEC #445 §4 + §6.2. Legacy `invoke/4` replaced by
  `handle_create_user/2`. The DB side effect (`Users.create/3` + the
  opportunistic `SpawnRegistry.spawn`) runs inline in the handler —
  per §4.5 inline idempotent Repo writes are permitted; the
  `:set`/`:emit` effects then record the slice counter bump + audit
  event after the row is durably inserted.

  ## Phase B migration (2026-05-29) — `use Ezagent.Lifecycle`

  Converted to the Lifecycle developer API per SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5.
  STATE-ONLY: the slice is the incidental `create_count` counter (the
  durable `users` rows are owned by `Ezagent.Users`); no transients.
  `init_slice/1` → `create/1`; `activate/2` is the macro no-op
  (omitted). Auto-derived `state_slice` is `:workspace_user_admin`
  (matches the old explicit one). Handler body byte-identical.
  `required_caps/0` + `data_owner/1` pass through.
  """

  use Ezagent.Lifecycle

  action(:create_user,
    args: %{
      user_uri: :string,
      password: {:option, :string},
      caps: {:option, :string}
    },
    returns: %{
      user_uri: :string,
      caps_granted: :integer,
      password_set: :boolean,
      spawned: :string
    },
    caps: [{:create_user, kind: :workspace}],
    description:
      "Provision a new Ezagent user in this workspace. Inserts a row in " <>
        "the `users` table (password bcrypt-hashed) and " <>
        "opportunistically spawns the User Kind. Distinct cap " <>
        "subject from `Behavior.Workspace`'s member-management " <>
        "actions (codex PR #356 r1 CRIT fix).",
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — preserves `kind: :workspace` axis.
  # =================================================================
  def required_caps do
    %{
      create_user: Ezagent.Capability.cap(:workspace, __MODULE__, :create_user)
    }
  end

  # =================================================================
  # Lifecycle state — `create/1` builds the PERSISTENT counter once
  # (Phase B; was `init_slice/1`). No transients → `activate/2` is the
  # macro no-op. `state_slice` auto-derives to `:workspace_user_admin`.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{create_count: 0}}

  # PR-OWN-4: workspace-scoped, workspace-admin grantable.
  def data_owner(_), do: :any

  # =================================================================
  # New-contract action handler (§6.2 — replaces invoke/4)
  # =================================================================

  def handle_create_user(args, ctx) when is_map(args) do
    raw_target_uri = Map.get(ctx, :self_uri)

    with {:ok, user_uri_str, password, caps_str} <- coerce_create_user_args(args),
         {:ok, user_uri} <- parse_user_uri(user_uri_str),
         {:ok, target_ws} <- require_workspace_uri(raw_target_uri),
         :ok <- ensure_user_in_target_workspace(user_uri, target_ws),
         {:ok, caps} <- issue_requested_caps(caps_str, user_uri, ctx),
         {:ok, decoded} <- Ezagent.Users.create(user_uri, password, caps) do
      spawn_result = maybe_spawn_user_kind(user_uri)
      cur = ctx[:read].(:create_count, 0)

      result = %{
        user_uri: URI.to_string(decoded.uri),
        caps_granted: length(caps),
        password_set: is_binary(password) and password != "",
        spawned: spawn_result
      }

      {:ok, result,
       [
         {:set, :create_count, cur + 1},
         {:emit, :user_created,
          %{
            user_uri: URI.to_string(decoded.uri),
            workspace_uri: URI.to_string(target_ws),
            caps_granted: length(caps),
            password_set: is_binary(password) and password != "",
            at: DateTime.utc_now()
          }}
       ]}
    end
  end

  def handle_create_user(args, _ctx) do
    {:error, {:bad_args, "create_user requires {user_uri, password?, caps?}", args}}
  end

  # =================================================================
  # Helpers
  # =================================================================

  # -----------------------------------------------------------------
  # The ISSUE chokepoint (Decision #162: ISSUE → STORE → VERIFY)
  # -----------------------------------------------------------------
  #
  # Before this, `create_user` did:
  #
  #     Parser.parse(caps_str, Ezagent.Entity.User.admin_uri())
  #     Ezagent.Users.create(user_uri, password, caps)
  #
  # — it parsed ARBITRARY caller-supplied cap text, stamped it
  # `granted_by: admin` regardless of who was actually calling, and wrote it
  # straight into `users.caps_json`. `Ezagent.Cap.issue/3` was never called, so
  # `CapabilityRegistry.authorize_grant/3` never ran: neither the
  # wildcard-action guard nor the owner/delegation guard could fire. A holder of
  # `workspace_user_admin.create_user` could therefore conjure a user holding
  # ANY capability — including `agent.manage` over somebody else's agent, which
  # since 2026-07-14 (Decision #163, "the terminal belongs to the creator")
  # carries that agent's PTY: arbitrary command execution in its sandbox.
  #
  # Codex PR #356 r1 already narrowed WHO can reach this action (it split
  # `:create_user` onto its own Behavior so a `Behavior.Workspace` cap no longer
  # implies it). That fixed the door. This fixes the room: what you may hand out
  # is now bounded by what you actually hold.
  #
  # `{:held_by, caller}` loads the CALLER's real held caps and runs
  # `authorize_grant` against them, then stamps `granted_by: caller` — an
  # accountable granter, not a laundered admin.
  #
  # Fail-closed and all-or-nothing: the first cap the caller may not grant
  # aborts the whole create. A partially-capped user is worse than no user.
  #
  # Creating a user with NO caps needs no granter and stays open to system /
  # registration callers — only HANDING OUT authority requires an accountable
  # entity granter (`Cap.issue/3` refuses a non-`entity://` granter outright).
  defp issue_requested_caps(caps_str, %URI{} = user_uri, ctx) do
    case String.trim(caps_str || "") do
      "" ->
        {:ok, []}

      trimmed ->
        with {:ok, %URI{} = caller} <- require_entity_caller(Map.get(ctx, :caller)),
             {:ok, requested} <- Ezagent.Capability.Parser.parse(trimmed, caller) do
          issue_each(requested, user_uri, caller)
        end
    end
  end

  defp issue_each(requested, %URI{} = user_uri, %URI{} = caller) when is_list(requested) do
    requested
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, acc} ->
      case Ezagent.Cap.issue({:held_by, caller}, user_uri, cap) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, reason} -> {:halt, {:error, {:cap_grant_refused, describe_cap(cap), reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _} = error -> error
    end
  end

  defp require_entity_caller(%URI{scheme: "entity"} = caller), do: {:ok, caller}

  defp require_entity_caller(other),
    do: {:error, {:granting_caps_requires_entity_caller, other}}

  defp describe_cap(%Ezagent.Capability{} = cap) do
    %{
      kind: cap.kind,
      behavior: cap.behavior,
      action: Ezagent.Capability.action_of(cap),
      instance: cap.instance
    }
  end

  defp coerce_create_user_args(args) do
    user_uri = Map.get(args, :user_uri)
    password = Map.get(args, :password)
    caps = Map.get(args, :caps)

    cond do
      not is_binary(user_uri) or user_uri == "" ->
        {:error, :user_uri_required}

      not (is_nil(password) or is_binary(password)) ->
        {:error, {:bad_password, password}}

      not (is_nil(caps) or is_binary(caps)) ->
        {:error, {:bad_caps, caps}}

      true ->
        {:ok, user_uri, password, caps}
    end
  end

  defp parse_user_uri(s) when is_binary(s) do
    try do
      case Ezagent.URI.new!(s) do
        %URI{scheme: "entity"} = uri ->
          if Ezagent.URI.type?(uri, :user) and match?({:ok, _name}, Ezagent.URI.name(uri)) do
            {:ok, uri}
          else
            {:error, {:bad_user_uri, s, "expected entity user URI"}}
          end

        _ ->
          {:error, {:bad_user_uri, s, "expected entity user URI"}}
      end
    rescue
      e in ArgumentError ->
        {:error, {:bad_user_uri, s, Exception.message(e)}}
    end
  end

  defp require_workspace_uri(%URI{scheme: "workspace"} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, _name} ->
        {:ok, uri}

      :error ->
        {:error, {:bad_workspace_uri, uri}}
    end
  end

  defp require_workspace_uri(other), do: {:error, {:bad_workspace_uri, other}}

  defp ensure_user_in_target_workspace(%URI{} = user_uri, %URI{scheme: "workspace"} = target_ws) do
    case Ezagent.URI.entity_workspace_uri(user_uri) do
      %URI{} = user_ws ->
        if URI.to_string(user_ws) == URI.to_string(target_ws) do
          :ok
        else
          {:error,
           {:cross_workspace_user,
            target_workspace: URI.to_string(target_ws), user_workspace: URI.to_string(user_ws)}}
        end

      _ ->
        {:error, {:bad_user_uri_no_workspace, URI.to_string(user_uri)}}
    end
  end

  defp maybe_spawn_user_kind(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
      case Ezagent.SpawnRegistry.spawn(uri) do
        {:ok, _pid} ->
          "spawned"

        {:error, {:already_started, _pid}} ->
          "already_running"

        {:error, reason} ->
          "spawn_deferred:#{inspect(reason)}"
      end
    else
      "spawn_registry_unavailable"
    end
  end
end
