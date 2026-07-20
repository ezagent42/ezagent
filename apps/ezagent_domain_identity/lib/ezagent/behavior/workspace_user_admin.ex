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

  ## Actions

  - `:create_user` — args `%{user_uri: String.t(), password: String.t() | nil,
    caps: String.t() | nil}` → `%{user_uri, caps_granted, password_set, spawned}`.

    Wraps `Ezagent.Users.create/3` + opportunistic
    `SpawnRegistry.spawn`. Enforces a structural cross-workspace
    check: the new user URI's workspace segment MUST match the
    dispatch target's workspace. Bootstrap admin (`:any` target) is
    exempt because step 5.5 already validated cross-workspace
    authority.

  - `:disable_user` — args `%{user_uri: String.t(), reason: String.t() | nil}`
    → `%{user_uri, disabled_at, disabled_by}`. Operator offboarding (task
    #180): REVERSIBLE soft-disable via `Ezagent.Users.disable/3`. Cuts access
    (login gate fails closed + active-session eviction at the web auth
    chokepoint) while preserving identity/history/attribution; `enable`
    reverses it. Own cap subject; `disabled_by` is the authenticated caller.

    (The HARD, irreversible `delete_user` counterpart is split to a separate
    task — branch `feat/delete-user-atomic-revocation`.)

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

  action(:mint_invite,
    args: %{
      max_uses: :integer,
      expires_in_hours: {:option, :integer}
    },
    returns: %{invite: :map},
    caps: [{:mint_invite, kind: :workspace}],
    description: "Mint a registration invite for this workspace.",
    modes: [:call]
  )

  action(:list_invites,
    args: %{},
    returns: %{invites: {:list, :map}},
    caps: [{:list_invites, kind: :workspace}],
    description: "List registration invites for this workspace.",
    modes: [:call]
  )

  action(:revoke_invite,
    args: %{code: :string},
    returns: %{invite: :map},
    caps: [{:revoke_invite, kind: :workspace}],
    description: "Revoke a registration invite for this workspace.",
    modes: [:call]
  )

  action(:disable_user,
    args: %{
      user_uri: :string,
      reason: {:option, :string}
    },
    returns: %{
      user_uri: :string,
      disabled_at: :string,
      disabled_by: :string
    },
    caps: [{:disable_user, kind: :workspace}],
    description:
      "Operator offboarding (task #180) — REVERSIBLE soft-disable of a user " <>
        "in this workspace. Cuts access (the login gate fails closed and any " <>
        "live session is evicted on next request/mount) while preserving " <>
        "identity, history, and attribution; `enable` reverses it. Wraps " <>
        "`Ezagent.Users.disable/3` with the AUTHENTICATED caller as " <>
        "`disabled_by` (attribution is never a caller-supplied arg). Its OWN " <>
        "cap subject, distinct from `create_user`.",
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — preserves `kind: :workspace` axis. Each
  # action carves its OWN cap subject (distinct action axis), so a holder of
  # one is NOT authorized for another.
  # =================================================================
  def required_caps do
    %{
      create_user: Ezagent.Capability.cap(:workspace, __MODULE__, :create_user),
      mint_invite: Ezagent.Capability.cap(:workspace, __MODULE__, :mint_invite),
      list_invites: Ezagent.Capability.cap(:workspace, __MODULE__, :list_invites),
      revoke_invite: Ezagent.Capability.cap(:workspace, __MODULE__, :revoke_invite),
      disable_user: Ezagent.Capability.cap(:workspace, __MODULE__, :disable_user)
    }
  end

  # =================================================================
  # Lifecycle state — `create/1` builds the PERSISTENT counter once
  # (Phase B; was `init_slice/1`). No transients → `activate/2` is the
  # macro no-op. `state_slice` auto-derives to `:workspace_user_admin`.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{create_count: 0, invite_mutation_count: 0}}

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

  @doc "Mint a registration invite for the current workspace."
  def handle_mint_invite(args, ctx) when is_map(args) do
    max_uses = Map.get(args, :max_uses, 1)
    expires_in_hours = Map.get(args, :expires_in_hours)

    with {:ok, workspace_uri} <- require_workspace_uri(Map.get(ctx, :self_uri)),
         {:ok, caller} <- require_entity_caller(Map.get(ctx, :caller)),
         :ok <- validate_invite_options(max_uses, expires_in_hours),
         {:ok, {raw, row}} <-
           Ezagent.Entity.InviteCode.mint(%{
             workspace_uri: URI.to_string(workspace_uri),
             created_by: URI.to_string(caller),
             max_uses: max_uses,
             expires_at: invite_expiry(expires_in_hours)
           }) do
      cur = ctx[:read].(:invite_mutation_count, 0)
      invite = invite_view(row, raw)

      {:ok, %{invite: invite},
       [
         {:set, :invite_mutation_count, cur + 1},
         {:emit, :workspace_invite_minted, Map.drop(invite, [:code])}
       ]}
    end
  end

  def handle_mint_invite(args, _ctx),
    do: {:error, {:bad_args, "mint_invite requires a map", args}}

  @doc "List registration invites belonging to the current workspace."
  def handle_list_invites(_args, ctx) do
    with {:ok, workspace_uri} <- require_workspace_uri(Map.get(ctx, :self_uri)) do
      invites =
        workspace_uri
        |> URI.to_string()
        |> Ezagent.Entity.InviteCode.list()
        |> Enum.map(&invite_view/1)

      {:ok, %{invites: invites}}
    end
  end

  @doc "Revoke a registration invite after verifying workspace ownership."
  def handle_revoke_invite(%{code: code}, ctx) when is_binary(code) and code != "" do
    with {:ok, workspace_uri} <- require_workspace_uri(Map.get(ctx, :self_uri)),
         {:ok, row} <- Ezagent.Entity.InviteCode.validate(code),
         :ok <- ensure_invite_in_workspace(row, workspace_uri),
         {:ok, revoked} <- Ezagent.Entity.InviteCode.revoke(code) do
      cur = ctx[:read].(:invite_mutation_count, 0)
      invite = invite_view(revoked)

      {:ok, %{invite: invite},
       [
         {:set, :invite_mutation_count, cur + 1},
         {:emit, :workspace_invite_revoked, Map.drop(invite, [:code])}
       ]}
    end
  end

  def handle_revoke_invite(args, _ctx),
    do: {:error, {:bad_args, "revoke_invite requires {code}", args}}

  # =================================================================
  # disable_user — reversible soft-disable (task #180)
  # =================================================================

  @doc """
  Handle `:disable_user` — reversible soft-disable (task #180). Validates the
  target user URI is in the dispatch target's workspace, then wraps
  `Ezagent.Users.disable/3` with the AUTHENTICATED `ctx.caller` as the
  `disabled_by` actor and emits a `:user_disabled` audit event.
  """
  def handle_disable_user(args, ctx) when is_map(args) do
    with {:ok, user_uri_str, reason} <- coerce_user_action_args(args),
         {:ok, user_uri} <- parse_user_uri(user_uri_str),
         {:ok, target_ws} <- require_workspace_uri(Map.get(ctx, :self_uri)),
         :ok <- ensure_user_in_target_workspace(user_uri, target_ws),
         {:ok, actor} <- require_actor(ctx),
         :ok <- refute_self(actor, user_uri),
         {:ok, decoded} <- Ezagent.Users.disable(user_uri, actor, reason) do
      result = %{
        user_uri: URI.to_string(decoded.uri),
        disabled_at: to_iso8601(decoded.disabled_at),
        disabled_by: decoded.disabled_by || URI.to_string(actor)
      }

      {:ok, result,
       [
         {:emit, :user_disabled,
          %{
            user_uri: URI.to_string(decoded.uri),
            workspace_uri: URI.to_string(target_ws),
            disabled_by: URI.to_string(actor),
            reason: reason,
            at: decoded.disabled_at || DateTime.utc_now()
          }}
       ]}
    end
  end

  def handle_disable_user(args, _ctx) do
    {:error, {:bad_args, "disable_user requires {user_uri, reason?}", args}}
  end

  # =================================================================
  # Helpers
  # =================================================================

  # Arg coercion for disable_user: a required `user_uri` string + an optional
  # `reason` string.
  defp coerce_user_action_args(args) do
    user_uri = Map.get(args, :user_uri)
    reason = Map.get(args, :reason)

    cond do
      not is_binary(user_uri) or user_uri == "" ->
        {:error, :user_uri_required}

      not (is_nil(reason) or is_binary(reason)) ->
        {:error, {:bad_reason, reason}}

      true ->
        {:ok, user_uri, reason}
    end
  end

  # The actor (`disabled_by`) is the AUTHENTICATED caller from the dispatch ctx
  # — NEVER a caller-supplied arg (attribution forgery vector). Step 5.5 has
  # already authorized this caller.
  defp require_actor(%{caller: %URI{} = caller}), do: {:ok, caller}
  defp require_actor(_), do: {:error, :missing_actor}

  # An operator MUST NOT disable their OWN account — an immediate self-lockout
  # footgun. Mirrors the world admin UI's `ensure_not_self` guard.
  defp refute_self(%URI{} = actor, %URI{} = user_uri) do
    if Ezagent.URI.stable_key(actor) == Ezagent.URI.stable_key(user_uri) do
      {:error, :self_offboard_denied}
    else
      :ok
    end
  end

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(_), do: nil

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
      case Ezagent.Cap.issue(grant_authorization(caller), user_uri, cap) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, reason} -> {:halt, {:error, {:cap_grant_refused, describe_cap(cap), reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _} = error -> error
    end
  end

  defp grant_authorization(%URI{} = caller) do
    admin = Ezagent.Entity.User.admin_uri()

    if Ezagent.URI.stable_key(caller) == Ezagent.URI.stable_key(admin),
      do: {:admin, caller},
      else: {:held_by, caller}
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

  defp validate_invite_options(max_uses, expires_in_hours) do
    cond do
      not is_integer(max_uses) or max_uses < 1 or max_uses > 10_000 ->
        {:error, {:bad_max_uses, max_uses}}

      not is_nil(expires_in_hours) and
          (not is_integer(expires_in_hours) or expires_in_hours < 1 or
             expires_in_hours > 24 * 365) ->
        {:error, {:bad_expires_in_hours, expires_in_hours}}

      true ->
        :ok
    end
  end

  defp invite_expiry(nil), do: nil

  defp invite_expiry(hours) do
    DateTime.add(DateTime.utc_now(), hours * 60 * 60, :second)
  end

  defp ensure_invite_in_workspace(row, workspace_uri) do
    if row.workspace_uri == URI.to_string(workspace_uri) do
      :ok
    else
      {:error, :invite_not_in_workspace}
    end
  end

  defp invite_view(row, raw_code \\ nil) do
    %{
      id: row.id,
      code: raw_code || row.code,
      status: invite_status(row),
      max_uses: row.max_uses,
      used_count: row.used_count,
      expires_at: row.expires_at,
      created_by: row.created_by,
      inserted_at: row.inserted_at,
      revoked_at: row.revoked_at
    }
  end

  defp invite_status(%{revoked_at: %DateTime{}}), do: "revoked"

  defp invite_status(row) do
    cond do
      row.used_count >= row.max_uses -> "exhausted"
      row.expires_at && DateTime.compare(DateTime.utc_now(), row.expires_at) == :gt -> "expired"
      true -> "active"
    end
  end

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
