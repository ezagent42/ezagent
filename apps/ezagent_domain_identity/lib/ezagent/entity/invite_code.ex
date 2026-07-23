defmodule Ezagent.Entity.InviteCode do
  @moduledoc """
  Login email+password (task #87) Decision 10 — invite codes that gate early
  self-registration.

  A code carries an **authoritative** target `workspace_uri` (+ optional `role`),
  a quota (`max_uses`), and an optional expiry. `consume/1` is the race gate: a
  single atomic conditional `UPDATE ... WHERE used_count < max_uses AND not revoked
  AND not expired`. That atomic UPDATE is the concurrency guard: Postgres takes a
  row lock, so concurrent consumers serialise and only ONE sees `used_count <
  max_uses` still satisfied; the affected-row count is the accept/reject signal. Do
  NOT weaken it to a read-then-write — the atomic UPDATE, not any single-writer
  property of the store, is what prevents the double-spend race. Registration calls
  `consume/1` INSIDE the same
  `Repo.transaction` as user creation, so a use is never burned without a user and
  a user is never created without consuming a use (Codex plan-review #2).

  `role` is stored for forward-compat but currently maps to the standard member
  cap set (there is no elevated-role model in ezagent_domain_workspace yet —
  Codex plan-review #4). Schema + facade in one module, matching the
  `Ezagent.Users` / `Ezagent.Entity.Profile` / `Ezagent.Entity.MagicLinkToken`
  pattern.
  """

  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias EzagentCore.Repo

  schema "invite_codes" do
    field(:code, :string)
    field(:workspace_uri, :string)
    field(:role, :string)
    field(:max_uses, :integer, default: 1)
    field(:used_count, :integer, default: 0)
    field(:expires_at, :utc_datetime_usec)
    field(:created_by, :string)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type reason :: :invalid | :revoked | :expired | :exhausted

  @doc """
  Mint a new invite code. `attrs` must include `:workspace_uri` and `:created_by`;
  optional `:role`, `:max_uses` (default 1), `:expires_at`. The random code is
  generated here. Returns `{:ok, {raw_code, row}}` or `{:error, changeset}`.
  """
  @spec mint(map()) :: {:ok, {String.t(), t()}} | {:error, Ecto.Changeset.t()}
  def mint(attrs) when is_map(attrs) do
    raw = "esr_inv_" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))

    %__MODULE__{}
    |> cast(stringly(attrs), [:workspace_uri, :role, :max_uses, :expires_at, :created_by])
    |> put_change(:code, raw)
    |> validate_required([:code, :workspace_uri, :created_by])
    |> validate_number(:max_uses, greater_than_or_equal_to: 1)
    |> unique_constraint(:code, name: :invite_codes_code_index)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, {raw, row}}
      err -> err
    end
  end

  @doc """
  Validate a code WITHOUT consuming it. Returns `{:ok, row}` or `{:error, reason}`
  (`:invalid` | `:revoked` | `:expired` | `:exhausted`).
  """
  @spec validate(String.t()) :: {:ok, t()} | {:error, reason()}
  def validate(code) when is_binary(code) do
    case Repo.get_by(__MODULE__, code: code) do
      nil ->
        {:error, :invalid}

      %__MODULE__{revoked_at: %DateTime{}} ->
        {:error, :revoked}

      %__MODULE__{} = row ->
        cond do
          expired?(row) -> {:error, :expired}
          row.used_count >= row.max_uses -> {:error, :exhausted}
          true -> {:ok, row}
        end
    end
  end

  def validate(_), do: {:error, :invalid}

  @doc """
  Atomically consume one use of `code`. Returns `{:ok, row}` (the post-consume
  row, carrying `workspace_uri`/`role`) or `{:error, reason}`. Race-safe via a
  single conditional UPDATE. Call this inside the registration transaction.
  """
  @spec consume(String.t()) :: {:ok, t()} | {:error, reason()}
  def consume(code) when is_binary(code) do
    now = DateTime.utc_now()

    query =
      from(c in __MODULE__,
        where:
          c.code == ^code and is_nil(c.revoked_at) and c.used_count < c.max_uses and
            (is_nil(c.expires_at) or c.expires_at > ^now)
      )

    case Repo.update_all(query, inc: [used_count: 1], set: [updated_at: now]) do
      {1, _} -> {:ok, Repo.get_by(__MODULE__, code: code)}
      # Nothing updated — surface the specific reason (invalid/revoked/expired/exhausted).
      {0, _} -> validate(code)
    end
  end

  def consume(_), do: {:error, :invalid}

  @doc "Revoke a code: stops FUTURE consumes; existing (even unconfirmed) users are unaffected."
  @spec revoke(String.t()) :: {:ok, t()} | {:error, :not_found}
  def revoke(code) when is_binary(code) do
    case Repo.get_by(__MODULE__, code: code) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> change(%{revoked_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc "List all invite codes (admin). Pass a workspace URI string to scope."
  @spec list(String.t() | nil) :: [t()]
  def list(workspace_uri \\ nil)
  def list(nil), do: Repo.all(from(c in __MODULE__, order_by: [desc: c.inserted_at]))

  def list(workspace_uri) when is_binary(workspace_uri) do
    Repo.all(
      from(c in __MODULE__,
        where: c.workspace_uri == ^workspace_uri,
        order_by: [desc: c.inserted_at]
      )
    )
  end

  defp expired?(%{expires_at: nil}), do: false
  defp expired?(%{expires_at: exp}), do: DateTime.compare(DateTime.utc_now(), exp) == :gt

  # Accept atom- or string-keyed attrs.
  defp stringly(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
