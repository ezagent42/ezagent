defmodule Ezagent.Email.InboundBinding do
  @moduledoc """
  Durable, email-OWNED per-binding inbound metadata for the email
  ExternalMirror adapter (#88 PR-2 / SPEC §3/§4.4/§6 / plan D4).

  Pure data module. Keyed by `binding_row_id` (the
  `Ezagent.ExternalMirror.BindingRow.row_id/3` value); FK CASCADE to
  `external_mirror_bindings(id)` so an `:unbind` clears it (no orphan,
  rebind starts fresh). One row per email binding.

  This table is the authority for:

  - **Inbound reverse lookup** — `local_address` (UNIQUE) maps an inbound
    `To:` to exactly one binding → `(session_uri, target_id)`
    (spec §3/§6; no parsing).
  - **The verification gate** — `verification_status` is SERVER-OWNED and
    durable, so the web confirm path (which can't reach a possibly-cold
    Worker) is authoritative, and both the outbound `Binding.publish/2`
    gate and the inbound poller read it without a live Worker
    (spec §4.4). Flipped to `:verified` ONLY via `mark_verified/1` on the
    token-confirm path — NEVER from caller opts (forgery-safe, plan D1).

  ## Why a binding-scoped token (not `Ezagent.Entity.MagicLinkToken`)

  `MagicLinkToken` keys by EMAIL and `consume/2` returns the email — but a
  human may bind the SAME address to multiple sessions, so the confirm
  must be BINDING-scoped (it flips one binding's status, not "this email
  is confirmed"). We reuse MagicLinkToken's hash/TTL/single-use SHAPE
  (SHA-256 of a raw token; raw goes in the link only) on this table.
  """

  use Ecto.Schema

  import Ecto.Query

  alias EzagentCore.Repo

  @ttl_seconds 24 * 60 * 60

  @primary_key {:binding_row_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "email_inbound_binding" do
    field(:local_address, :string)
    field(:session_uri, :string)
    field(:target_id, :string)
    field(:verification_status, :string, default: "pending_verification")
    field(:verification_token_hash, :binary)
    field(:verification_expires_at, :utc_datetime_usec)
    field(:workspace_uri, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          binding_row_id: String.t(),
          local_address: String.t(),
          session_uri: String.t(),
          target_id: String.t(),
          verification_status: String.t(),
          verification_token_hash: binary() | nil,
          verification_expires_at: DateTime.t() | nil,
          workspace_uri: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Record the inbound metadata for a binding, minting a fresh verification
  token. Returns `{:ok, {row, raw_token}}` — the RAW token (for the
  confirm link) is returned but only its SHA-256 is persisted. Status
  starts `"pending_verification"` (NEVER `:verified` — server-owned gate).

  `attrs` must carry `:binding_row_id`, `:local_address`, `:session_uri`,
  `:target_id`, `:workspace_uri`. Optional `:ttl_seconds` (default 24h;
  negative → already-expired, for tests).

  On `local_address` (or `session_uri`) unique collision returns
  `{:error, changeset}` — the bind wrapper regenerates the alias + retries.
  """
  @spec record(map()) :: {:ok, {t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    raw = mint_raw_token()
    ttl = Map.get(attrs, :ttl_seconds, @ttl_seconds)

    params =
      attrs
      |> Map.take([:binding_row_id, :local_address, :session_uri, :target_id, :workspace_uri])
      |> Map.merge(%{
        verification_status: "pending_verification",
        verification_token_hash: hash_token(raw),
        verification_expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)
      })

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(params, [
        :binding_row_id,
        :local_address,
        :session_uri,
        :target_id,
        :verification_status,
        :verification_token_hash,
        :verification_expires_at,
        :workspace_uri
      ])
      |> Ecto.Changeset.validate_required([
        :binding_row_id,
        :local_address,
        :session_uri,
        :target_id,
        :workspace_uri
      ])
      |> Ecto.Changeset.unique_constraint(:local_address,
        name: :email_inbound_binding_local_address_index
      )
      |> Ecto.Changeset.unique_constraint(:session_uri,
        name: :email_inbound_binding_session_uri_index
      )

    case Repo.insert(changeset) do
      {:ok, row} -> {:ok, {row, raw}}
      {:error, _cs} = err -> err
    end
  end

  @doc "Reverse lookup by `local_address` (the inbound `To:`). `nil` on no match."
  @spec by_local_address(String.t()) :: t() | nil
  def by_local_address(local_address) when is_binary(local_address) do
    Repo.get_by(__MODULE__, local_address: local_address)
  end

  @doc "Load by `binding_row_id`. `nil` when no inbound-meta row exists yet."
  @spec by_binding_row_id(String.t()) :: t() | nil
  def by_binding_row_id(binding_row_id) when is_binary(binding_row_id) do
    Repo.get(__MODULE__, binding_row_id)
  end

  @doc """
  Is the binding identified by `binding_row_id` verified? Fail-closed:
  a missing row (no inbound meta recorded) reads as `false`.
  """
  @spec verified?(String.t()) :: boolean()
  def verified?(binding_row_id) when is_binary(binding_row_id) do
    case by_binding_row_id(binding_row_id) do
      %__MODULE__{verification_status: "verified"} -> true
      _ -> false
    end
  end

  @doc """
  Consume a raw verification token: flip the matching, unexpired binding to
  `"verified"` and clear the token (single-use). Returns
  `{:ok, row}` | `{:error, :invalid | :expired}`.

  Token is matched by SHA-256(raw) so the raw never has to be stored. An
  already-consumed token (hash cleared) → `:invalid`.
  """
  @spec confirm(String.t()) :: {:ok, t()} | {:error, :invalid | :expired}
  def confirm(raw_token) when is_binary(raw_token) do
    hash = hash_token(raw_token)

    case Repo.one(from(r in __MODULE__, where: r.verification_token_hash == ^hash)) do
      nil ->
        {:error, :invalid}

      %__MODULE__{verification_expires_at: exp} = row ->
        if expired?(exp) do
          {:error, :expired}
        else
          row
          |> Ecto.Changeset.change(%{
            verification_status: "verified",
            verification_token_hash: nil,
            verification_expires_at: nil
          })
          |> Repo.update()
        end
    end
  end

  @doc """
  Mark a binding verified directly by `binding_row_id` (no token). For the
  E2E/admin path; the normal flow is `confirm/1`. Returns
  `{:ok, row} | {:error, :not_found | Ecto.Changeset.t()}`.
  """
  @spec mark_verified(String.t()) :: {:ok, t()} | {:error, :not_found | Ecto.Changeset.t()}
  def mark_verified(binding_row_id) when is_binary(binding_row_id) do
    case by_binding_row_id(binding_row_id) do
      nil ->
        {:error, :not_found}

      %__MODULE__{} = row ->
        row
        |> Ecto.Changeset.change(%{
          verification_status: "verified",
          verification_token_hash: nil,
          verification_expires_at: nil
        })
        |> Repo.update()
    end
  end

  # ----- token helpers (MagicLinkToken shape) --------------------------------

  defp mint_raw_token do
    "esr_ev_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  defp hash_token(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

  defp expired?(nil), do: true
  defp expired?(%DateTime{} = exp), do: DateTime.compare(DateTime.utc_now(), exp) == :gt
end
