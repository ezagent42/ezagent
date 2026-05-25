defmodule Ezagent.Behavior.UserTokens do
  @moduledoc """
  User-token Behavior — operator-facing bearer-token CRUD on the
  `entity_tokens` SQLite table.

  ## Why a separate Behavior

  Per `docs/futures/todo.md` HIGH-2: token operations are
  auth-boundary operations with no bootstrap excuse for skipping
  CapBAC + audit. The legacy `mix ezagent.user.token --mint/list/revoke`
  task bypasses dispatch entirely; this Behavior is the replacement.

  A separate Behavior (rather than extending Identity) gives token
  ops their own cap subject so the LV / CLI / Feishu / future
  surfaces can grant token-mint authority WITHOUT also granting
  cap-grant authority (`Behavior.IdentityAdmin :grant_cap`) or
  password-rotate authority (`Behavior.UserCredentials :set_password`).
  Each is its own structural privilege.

  ## Actions

  - `:mint_token` — args `%{label: String.t() | nil, expires_at: DateTime.t() | nil}` →
    `{:ok, slice, %{token_id: integer(), plain: String.t(), label: String.t() | nil}}`.
    Body wraps `Ezagent.Entity.Token.mint/2`. **The `plain` field is
    returned ONCE — the CLI prints it to operator stdout and it is
    NOT recoverable afterwards** (the table stores only the bcrypt
    hash).
  - `:list_tokens` — args `%{}` → `{:ok, slice, %{tokens: [%{id, label, inserted_at, last_used_at, expires_at}]}}`.
    Read-only; wraps `Ezagent.Entity.Token.list/1`.
  - `:revoke_token` — args `%{token_id: integer()}` →
    `{:ok, slice, %{revoked: integer()}}`. Wraps
    `Ezagent.Entity.Token.revoke/1`. Idempotent (legacy `revoke/1`
    returns `:ok` for unknown ids).

  ## Bootstrap carve-out preserved

  The first-admin-bootstrap mint (chicken-and-egg: admin needs a
  token BEFORE they can dispatch `:mint_token`) STAYS in the legacy
  `mix ezagent.user.token --mint` task per codex PR #304 MED finding.
  All other modes (mint for any non-first user, list, revoke)
  migrate to this Behavior.

  ## Slice

      %{mint_count: integer(), revoke_count: integer()}

  Incidental counters. The durable table is owned by
  `Ezagent.Entity.Token` (the Ecto schema). On Kind restart the
  counters reset but the rows survive.

  ## Cap shape (PR-CC-2-v2 contract)

  Three `required_caps/0` rows — one per action. Each is
  `Capability.cap(:user, __MODULE__, <action>)`. A user can hold an
  instance-scoped cap on their own URI to self-mint / self-list /
  self-revoke; admin holds the `:any`-instance form for cross-user
  ops (matches the LV path where the admin caps subject reads "manage
  any user's tokens").

  ## Auto-derived CLI

      mix esr user mint_token --user <uri> --label <name>
      mix esr user list_tokens --user <uri>
      mix esr user revoke_token --user <uri> --token-id <id>

  The legacy `mix ezagent.user.token` task is retained pending
  operator migration with a deprecation notice; its `--mint` mode is
  the only carve-out (bootstrap) — `--list` + `--revoke` now print
  the deprecation alongside their existing output.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:mint_token, :list_tokens, :revoke_token]

  @impl Ezagent.Behavior
  def required_caps do
    %{
      mint_token: Ezagent.Capability.cap(:user, __MODULE__, :mint_token),
      list_tokens: Ezagent.Capability.cap(:user, __MODULE__, :list_tokens),
      revoke_token: Ezagent.Capability.cap(:user, __MODULE__, :revoke_token)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:mint_token,
       "mint a bearer token for the User (plain token returned ONCE; " <>
         "table stores only the bcrypt hash). Self-scope via instance " <>
         "cap on own URI; admin via :any-instance for cross-user."},
      {:list_tokens,
       "list the User's tokens (does NOT include plain — only id / " <>
         "label / inserted_at / last_used_at / expires_at)"},
      {:revoke_token, "revoke a token by id (idempotent — unknown id returns :ok)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :user_tokens

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{mint_count: 0, revoke_count: 0}

  # PR-OWN-4 / codex PR #356 r1 MED fix: same shape as Identity /
  # ApiKeys / UserCredentials — the User Kind owns its tokens.
  # Concrete URI → self; `:any` → `:any`; otherwise no owner.
  # Admin's cross-user authority is via the bootstrap `:any`-instance
  # cap which short-circuits at step 5.5.
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # =================================================================
  # Action bodies
  # =================================================================

  @impl Ezagent.Behavior
  def invoke(:mint_token, slice, args, ctx) when is_map(args) do
    with {:ok, user_uri} <- target_user_uri(ctx),
         label = Map.get(args, :label),
         {:ok, expires_at} <- coerce_expires_at(Map.get(args, :expires_at)) do
      opts =
        []
        |> maybe_put(:label, label)
        |> maybe_put(:expires_at, expires_at)

      case Ezagent.Entity.Token.mint(user_uri, opts) do
        {plain, row} when is_binary(plain) ->
          new_slice = Map.update(slice, :mint_count, 1, &(&1 + 1))

          {:ok, new_slice,
           %{
             token_id: row.id,
             plain: plain,
             label: row.label
           }}

        {:error, _} = err ->
          err

        other ->
          {:error, {:mint_failed, other}}
      end
    end
  end

  def invoke(:list_tokens, slice, _args, ctx) do
    case target_user_uri(ctx) do
      {:ok, user_uri} ->
        tokens =
          user_uri
          |> Ezagent.Entity.Token.list()
          |> Enum.map(fn row ->
            %{
              id: row.id,
              label: row.label,
              inserted_at: row.inserted_at,
              last_used_at: row.last_used_at,
              expires_at: row.expires_at
            }
          end)

        {:ok, slice, %{tokens: tokens}}

      {:error, _} = err ->
        err
    end
  end

  def invoke(:revoke_token, slice, %{token_id: token_id}, ctx)
      when is_integer(token_id) do
    # Codex PR #356 r1 HIGH fix: `Ezagent.Entity.Token.revoke/1`
    # deletes globally by row id — no entity_uri check. Without
    # pre-validation, Alice (with revoke cap on her own URI) could
    # pass Bob's token_id and delete it. The cap-check at step 5.5
    # only enforces that Alice can call revoke against her OWN
    # User Kind; it doesn't bind to a specific token row.
    #
    # Fix: pre-fetch the row + assert its entity_uri matches the
    # dispatch target's URI (`ctx.self_uri`) BEFORE delete. Unknown
    # row returns :not_found (DISTINCT from "found but doesn't
    # belong to you" which is :cross_entity_token); both fail closed.
    with {:ok, user_uri} <- target_user_uri(ctx),
         :ok <- ensure_token_belongs_to(user_uri, token_id) do
      :ok = Ezagent.Entity.Token.revoke(token_id)
      new_slice = Map.update(slice, :revoke_count, 1, &(&1 + 1))

      {:ok, new_slice, %{revoked: token_id}}
    end
  end

  def invoke(:revoke_token, _slice, args, _ctx) do
    {:error, {:bad_args, "revoke_token requires {token_id: integer}", args}}
  end

  # =================================================================
  # Interface — drives `mix esr` auto-derivation.
  # =================================================================

  @impl Ezagent.Behavior
  def interface do
    %{
      mint_token: %{
        description:
          "Mint a fresh bearer token for the User. The plain token is " <>
            "returned ONCE; record it at the call site (the DB stores " <>
            "only the bcrypt hash). The target User is the dispatch " <>
            "target's URI (`ctx.self_uri`).",
        args: %{
          label: {:option, :string},
          expires_at: {:option, :string}
        },
        returns: %{token_id: :integer, plain: :string, label: :string},
        modes: [:call]
      },
      list_tokens: %{
        description:
          "List the User's non-revoked tokens (does NOT include the " <>
            "plain — only id / label / timestamps). Read-only.",
        args: %{},
        returns: %{tokens: {:list, :map}},
        modes: [:call]
      },
      revoke_token: %{
        description:
          "Revoke a token by id. Idempotent — unknown ids return :ok.",
        args: %{token_id: :integer},
        returns: %{revoked: :integer},
        modes: [:call]
      }
    }
  end

  # =================================================================
  # Helpers
  # =================================================================

  defp target_user_uri(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{scheme: "entity", host: "user"} = uri ->
        {:ok, uri}

      other ->
        {:error, {:bad_target_uri, other}}
    end
  end

  # Codex PR #356 r1 HIGH fix — cross-entity revoke prevention.
  # Pre-fetch the token row and verify its `entity_uri` matches the
  # dispatch target's URI. Returns:
  # - `:ok` — row exists AND belongs to the target user
  # - `{:error, :not_found}` — row doesn't exist (clean idempotent
  #   shape for "revoke something already gone")
  # - `{:error, :cross_entity_token}` — row exists but belongs to a
  #   different entity; refuse with a distinct error atom so the
  #   operator can distinguish "typo" from "auth boundary hit"
  defp ensure_token_belongs_to(%URI{} = user_uri, token_id) when is_integer(token_id) do
    user_uri_str = URI.to_string(user_uri)

    case EzagentCore.Repo.get(Ezagent.Entity.Token, token_id) do
      nil ->
        {:error, :not_found}

      %Ezagent.Entity.Token{entity_uri: ^user_uri_str} ->
        :ok

      %Ezagent.Entity.Token{entity_uri: other_uri} ->
        {:error, {:cross_entity_token, requested_owner: user_uri_str, actual_owner: other_uri}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Codex PR #356 r1 MED fix: `Token.mint/2` expects `%DateTime{}`
  # for `:expires_at`, but `interface/0` advertises `:string`
  # (because argv carries strings — RFC3339 is the natural CLI
  # shape). Parse here so a CLI/JSON caller can pass `"2026-12-31T23:59:59Z"`
  # and a programmatic caller can still pass a `%DateTime{}` directly.
  # `nil` is the no-expiry default (matches the legacy task's option
  # absence).
  defp coerce_expires_at(nil), do: {:ok, nil}

  defp coerce_expires_at(%DateTime{} = dt) do
    # The `entity_tokens.expires_at` column is `:utc_datetime_usec`,
    # so Ecto refuses second-precision values at dump time. Promote
    # to microsecond precision so callers can pass either.
    {:ok, ensure_usec(dt)}
  end

  defp coerce_expires_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, ensure_usec(dt)}
      {:error, reason} -> {:error, {:bad_expires_at, s, reason}}
    end
  end

  defp coerce_expires_at(other), do: {:error, {:bad_expires_at, other}}

  defp ensure_usec(%DateTime{microsecond: {_, 6}} = dt), do: dt

  defp ensure_usec(%DateTime{} = dt) do
    %DateTime{dt | microsecond: {elem(dt.microsecond, 0), 6}}
  end
end
