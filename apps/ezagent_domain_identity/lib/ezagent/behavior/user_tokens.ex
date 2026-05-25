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

  # PR-OWN-4: same shape as UserCredentials — the User Kind owns its
  # tokens; admin's :any-instance cap is the cross-user override.
  @impl Ezagent.Behavior
  def data_owner(_), do: :self

  # =================================================================
  # Action bodies
  # =================================================================

  @impl Ezagent.Behavior
  def invoke(:mint_token, slice, args, ctx) when is_map(args) do
    case target_user_uri(ctx) do
      {:ok, user_uri} ->
        label = Map.get(args, :label)
        expires_at = Map.get(args, :expires_at)

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

      {:error, _} = err ->
        err
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

  def invoke(:revoke_token, slice, %{token_id: token_id}, _ctx)
      when is_integer(token_id) do
    :ok = Ezagent.Entity.Token.revoke(token_id)
    new_slice = Map.update(slice, :revoke_count, 1, &(&1 + 1))

    {:ok, new_slice, %{revoked: token_id}}
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
