defmodule Ezagent.Behavior.UserCredentials do
  @moduledoc """
  User-credential Behavior — operator-facing password mutation on the
  `users` SQLite table.

  ## Why a separate Behavior, not on `Identity`

  Per `docs/futures/todo.md` HIGH-2: password mutation cannot live on
  `Behavior.Identity` because the cap shape would conflate
  self-mutation rights with admin password reset — granting a user
  `(:user, Identity, :set_password)` to let them rotate their OWN
  password would simultaneously grant them admin's password-rotation
  authority on every OTHER user (Identity's cap shape is class-wide).

  A separate Behavior carves out `:set_password` so:

  - A user can hold `(:user, UserCredentials, :set_password)` against
    THEIR OWN URI (instance = their entity URI) to self-rotate.
  - Admin holds `(:user, UserCredentials, :set_password, :any)` to
    reset any user's password.
  - The cap-check at step 5.5 + step 5.6 (cross-workspace iso)
    enforces both shapes structurally.

  ## Actions

  - `:set_password` — args `%{password: String.t()}` →
    `{:ok, slice, %{user_uri: String.t(), password_set: true}}`.
    Body wraps `Ezagent.Users.set_password/2` — the same call the
    legacy `mix ezagent.user.set_password` task makes — but routes
    through dispatch so step 5.5 cap-check, step 5.6 cross-workspace
    iso, and audit telemetry all apply.

  ## Slice

      %{set_password_count: integer()}

  Per the existing Routing / Feishu UserBinding pattern, the slice is
  an incidental counter — the durable table is owned by
  `Ezagent.Users` (the Ecto schema). The slice is not persisted; on
  Kind restart the count resets but the password hash survives.

  ## Cap shape (PR-CC-2-v2 contract)

  One `required_caps/0` entry:
  `Capability.cap(:user, __MODULE__, :set_password)`. Kind axis is
  `:user` because the Behavior is registered on the User Kind. The
  default `workspace_scoped? = true` is correct here — a user URI
  carries its workspace structurally, and admin's bootstrap cap is
  `:any`-workspace which bypasses iso at step 5.6.

  ## Auto-derived CLI

      mix esr user set_password \\
          --user entity://user/<workspace>/<name> \\
          --password <new-pw>

  The legacy `mix ezagent.user.set_password` task is retained pending
  operator migration with a deprecation notice (PR #355 muscle-memory
  pattern).
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:set_password]

  @impl Ezagent.Behavior
  def required_caps do
    %{
      set_password: Ezagent.Capability.cap(:user, __MODULE__, :set_password)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:set_password,
       "set or rotate the User's password (bcrypt-hashed). Holders " <>
         "with an instance-scoped cap on their own URI can self-rotate; " <>
         "admin holds the `:any`-instance form for cross-user reset."}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :user_credentials

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{set_password_count: 0}

  # PR-OWN-4 data_owner pattern: mirrors `Behavior.Identity` /
  # `Behavior.ApiKeys` — the user (the Kind instance) owns its
  # credentials. Concrete user URIs map to themselves (self-owned;
  # the user holds the instance-scoped cap on their own URI for
  # self-rotation); `:any` matches `:any`; everything else has no
  # owner (no default grant). Admin's cross-user reset is via the
  # bootstrap `:any`-instance cap which short-circuits at step 5.5.
  #
  # Codex PR #356 r1 MED fix (2026-05-26): `:self` was NOT a valid
  # `data_owner/1` return shape per `Ezagent.Behavior` callback spec
  # (URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}). The
  # original intent ("self-owned") IS expressed by returning the
  # entity URI itself — that's exactly what Identity does.
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # =================================================================
  # Action body
  # =================================================================

  @impl Ezagent.Behavior
  def invoke(:set_password, slice, %{password: password}, ctx)
      when is_binary(password) and password != "" do
    case target_user_uri(ctx) do
      {:ok, user_uri} ->
        case Ezagent.Users.set_password(user_uri, password) do
          {:ok, _decoded} ->
            new_slice = Map.update(slice, :set_password_count, 1, &(&1 + 1))

            {:ok, new_slice,
             %{user_uri: URI.to_string(user_uri), password_set: true}}

          {:error, :not_found} = err ->
            err

          {:error, _} = err ->
            err

          other ->
            {:error, {:set_password_failed, other}}
        end

      {:error, _} = err ->
        err
    end
  end

  def invoke(:set_password, _slice, args, _ctx) do
    {:error, {:bad_args, "set_password requires {password: non-empty String}", args}}
  end

  # =================================================================
  # Interface — drives `mix esr` auto-derivation.
  # =================================================================

  @impl Ezagent.Behavior
  def interface do
    %{
      set_password: %{
        description:
          "Set or rotate the User's password. Hashed via bcrypt before " <>
            "insert. The target user is the dispatch target's URI " <>
            "(`ctx.self_uri`); CLI passes it via `--user <entity-uri>`.",
        args: %{password: :string},
        returns: %{user_uri: :string, password_set: :boolean},
        modes: [:call]
      }
    }
  end

  # =================================================================
  # Helpers
  # =================================================================

  # The User Kind's `ctx.self_uri` is the user URI we're operating on.
  # Test scenarios that build ctx manually may pass it directly.
  defp target_user_uri(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{scheme: "entity", host: "user"} = uri ->
        {:ok, uri}

      other ->
        {:error, {:bad_target_uri, other}}
    end
  end
end
