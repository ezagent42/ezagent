defmodule Ezagent.ActionSet.UserTokens do
  @moduledoc """
  User-token Behavior — operator-facing bearer-token CRUD on the
  `entity_tokens` Postgres table.

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
    `%{token_id: integer(), plain: String.t(), label: String.t() | nil}`.
    Body wraps `Ezagent.Entity.Token.mint/2`. **The `plain` field is
    returned ONCE — the CLI prints it to operator stdout and it is
    NOT recoverable afterwards** (the table stores only the bcrypt
    hash).
  - `:list_tokens` — args `%{}` → `%{tokens: [%{id, label, inserted_at, last_used_at, expires_at}]}`.
    Read-only; wraps `Ezagent.Entity.Token.list/1`.
  - `:revoke_token` — args `%{token_id: integer()}` →
    `%{revoked: integer()}`. Wraps
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

  Three per-action cap entries — one per action. Each is
  `Capability.cap(:user, __MODULE__, <action>)`. A user can hold an
  instance-scoped cap on their own URI to self-mint / self-list /
  self-revoke; admin holds the `:any`-instance form for cross-user
  ops (matches the LV path where the admin caps subject reads "manage
  any user's tokens").

  ## Auto-derived CLI

      mix ezagent user mint_token --user <uri> --label <name>
      mix ezagent user list_tokens --user <uri>
      mix ezagent user revoke_token --user <uri> --token-id <id>

  The legacy `mix ezagent.user.token` task is retained pending
  operator migration with a deprecation notice; its `--mint` mode is
  the only carve-out (bootstrap) — `--list` + `--revoke` now print
  the deprecation alongside their existing output.

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.ActionSet` action/handler contract
  per SPEC #445 §4 + §6.2. Legacy `invoke/4` replaced by
  `handle_mint_token/2` / `handle_list_tokens/2` / `handle_revoke_token/2`
  returning effects. DB writes (`Token.mint/2`, `Token.revoke/1`) and
  reads (`Token.list/1`, `Repo.get`) are wrapped in `:effect_returning`
  so the result can be referenced via `{:ref, ...}` in downstream
  effects (counter `:set` + audit `:emit`).

  ## Phase B migration (2026-05-29) — `use Ezagent.Lifecycle`

  Converted to the Lifecycle developer API per SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5.
  STATE-ONLY: the slice is the incidental `mint_count` / `revoke_count`
  counters (durable tokens are owned by the `entity_tokens` table via
  `Ezagent.Entity.Token`); no transients. `init_slice/1` → `create/1`;
  `activate/2` is the macro no-op (omitted). Auto-derived `state_slice`
  is `:user_tokens` (matches the old explicit one). Handler bodies
  byte-identical. `required_caps/0` + `data_owner/1` pass through.
  """

  use Ezagent.Lifecycle

  action(:mint_token,
    args: %{
      label: {:option, :string},
      expires_at: {:option, :string}
    },
    returns: %{token_id: :integer, plain: :string, label: :string},
    caps: [{:mint_token, kind: :user}],
    description:
      "Mint a fresh bearer token for the User. The plain token is " <>
        "returned ONCE; record it at the call site (the DB stores " <>
        "only the bcrypt hash). The target User is the dispatch " <>
        "target's URI (`ctx.self_uri`).",
    data_owner: :self,
    modes: [:call]
  )

  action(:list_tokens,
    args: %{},
    returns: %{tokens: {:list, :map}},
    caps: [{:list_tokens, kind: :user}],
    description:
      "List the User's non-revoked tokens (does NOT include the " <>
        "plain — only id / label / timestamps). Read-only.",
    data_owner: :self,
    modes: [:call]
  )

  action(:revoke_token,
    args: %{token_id: :integer},
    returns: %{revoked: :integer},
    caps: [{:revoke_token, kind: :user}],
    description: "Revoke a token by id. Idempotent — unknown ids return :ok.",
    data_owner: :self,
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — preserves `kind: :user` axis (the
  # macro auto-derivation hardcodes `:any`; see UserCredentials.ex
  # for the rationale).
  # =================================================================
  def required_caps do
    %{
      mint_token: Ezagent.Capability.cap(:user, __MODULE__, :mint_token),
      list_tokens: Ezagent.Capability.cap(:user, __MODULE__, :list_tokens),
      revoke_token: Ezagent.Capability.cap(:user, __MODULE__, :revoke_token)
    }
  end

  # =================================================================
  # Lifecycle state — `create/1` builds the PERSISTENT counters once
  # (Phase B; was `init_slice/1`). No transients → `activate/2` is the
  # macro no-op. `state_slice` auto-derives to `:user_tokens`.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{mint_count: 0, revoke_count: 0}}

  # PR-OWN-4 / codex PR #356 r1 MED fix: same shape as Identity /
  # ApiKeys / UserCredentials — the User Kind owns its tokens.
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # =================================================================
  # New-contract action handlers (§6.2 — replace invoke/4)
  # =================================================================

  def handle_mint_token(args, ctx) when is_map(args) do
    with {:ok, user_uri} <- target_user_uri(ctx),
         {:ok, expires_at} <- coerce_expires_at(Map.get(args, :expires_at)) do
      label = Map.get(args, :label)

      opts =
        []
        |> maybe_put(:label, label)
        |> maybe_put(:expires_at, expires_at)

      case Ezagent.Entity.Token.mint(user_uri, opts) do
        {plain, row} when is_binary(plain) ->
          cur = ctx[:read].(:mint_count, 0)

          {:ok,
           %{
             token_id: row.id,
             plain: plain,
             label: row.label
           },
           [
             {:set, :mint_count, cur + 1},
             {:emit, :token_minted,
              %{
                user_uri: URI.to_string(user_uri),
                token_id: row.id,
                label: row.label,
                at: DateTime.utc_now()
              }}
           ]}

        {:error, _} = err ->
          err

        other ->
          {:error, {:mint_failed, other}}
      end
    end
  end

  def handle_list_tokens(_args, ctx) do
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

        # Read-only — no slice mutation, no effects.
        {:ok, %{tokens: tokens}, []}

      {:error, _} = err ->
        err
    end
  end

  def handle_revoke_token(%{token_id: token_id}, ctx) when is_integer(token_id) do
    # Codex PR #356 r1 HIGH fix: pre-validate cross-entity ownership
    # before delete (Token.revoke/1 deletes globally by row id).
    with {:ok, user_uri} <- target_user_uri(ctx),
         :ok <- ensure_token_belongs_to(user_uri, token_id) do
      :ok = Ezagent.Entity.Token.revoke(token_id)
      cur = ctx[:read].(:revoke_count, 0)

      {:ok, %{revoked: token_id},
       [
         {:set, :revoke_count, cur + 1},
         {:emit, :token_revoked,
          %{
            user_uri: URI.to_string(user_uri),
            token_id: token_id,
            at: DateTime.utc_now()
          }}
       ]}
    end
  end

  def handle_revoke_token(args, _ctx) do
    {:error, {:bad_args, "revoke_token requires {token_id: integer}", args}}
  end

  # =================================================================
  # Helpers
  # =================================================================

  defp target_user_uri(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{scheme: "entity"} = uri ->
        if Ezagent.URI.type?(uri, :user), do: {:ok, uri}, else: {:error, {:bad_target_uri, uri}}

      other ->
        {:error, {:bad_target_uri, other}}
    end
  end

  # Codex PR #356 r1 HIGH fix — cross-entity revoke prevention.
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

  # Codex PR #356 r1 MED fix: coerce string / DateTime / nil for
  # `:expires_at`. RFC3339 string for CLI, %DateTime{} for programmatic.
  defp coerce_expires_at(nil), do: {:ok, nil}

  defp coerce_expires_at(%DateTime{} = dt) do
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
