defmodule Ezagent.AppSettings do
  @moduledoc """
  Username & Auth M2 — key-value runtime config facade over the
  `app_settings` table. JSON-encodes values.

  Keys in use:
  - `"smtp_config"` — the outbound-mail transport config. Holds EITHER shape:
    - SMTP relay: `%{"host","port","username","password","from_address","tls"}`
    - `email.ezagent.chat` REST API: `%{"from_address","base_url","api_key"}`
    (The key name is historical; it is the single "mail config" slot. Which
    shape is required depends on the compile-pinned Swoosh adapter — see
    `EzagentWeb.Mailer`.)
  - `"registration_domains"` — list of allowed email domains for new registration

  Both keys are written by the admin SMTP-settings UI (Phase 8). This
  module is the backend interface that UI calls.
  """

  use Ecto.Schema
  alias EzagentCore.Repo

  @primary_key {:key, :string, autogenerate: false}
  schema "app_settings" do
    field(:value, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @smtp_required ~w(host port username password from_address)
  @mail_api_required ~w(base_url api_key)

  @doc "Decoded value for `key`, or `nil` if unset / unparseable."
  @spec get(String.t()) :: term() | nil
  def get(key) when is_binary(key) do
    case Repo.get(__MODULE__, key) do
      %__MODULE__{value: json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, term} -> term
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Upsert `key` with a JSON-encodable `term`. Returns `:ok`."
  @spec put(String.t(), term()) :: :ok
  def put(key, term) when is_binary(key) do
    json = Jason.encode!(term)

    %__MODULE__{}
    |> Ecto.Changeset.change(%{key: key, value: json})
    |> Repo.insert!(
      on_conflict: [set: [value: json, updated_at: DateTime.utc_now()]],
      conflict_target: :key
    )

    :ok
  end

  @doc "True only when `smtp_config` has every SMTP-relay field non-empty."
  @spec smtp_configured?() :: boolean()
  def smtp_configured? do
    case get("smtp_config") do
      %{} = cfg -> Enum.all?(@smtp_required, &present?(Map.get(cfg, &1)))
      _ -> false
    end
  end

  @doc """
  True when `smtp_config` has the `email.ezagent.chat` REST-API fields
  (`base_url` + `api_key`) non-empty. This is the readiness check for the
  `Ezagent.Mail.EzagentChatAdapter` prod transport.
  """
  @spec mail_api_configured?() :: boolean()
  def mail_api_configured? do
    case get("smtp_config") do
      %{} = cfg -> Enum.all?(@mail_api_required, &present?(Map.get(cfg, &1)))
      _ -> false
    end
  end

  @doc """
  Transport-agnostic mail readiness: true when a usable outbound-mail transport
  is configured — EITHER a complete SMTP relay OR the REST API. Use this for
  gates that only ask "can we send auth email at all?" (login form visibility,
  magic-link send, boot-seed idempotency), independent of which adapter is
  compile-pinned.
  """
  @spec mail_configured?() :: boolean()
  def mail_configured?, do: smtp_configured?() or mail_api_configured?()

  @doc """
  task #87 Decision 10 — is self-registration open? Default **false** (closed):
  only admin provisioning creates users until an operator flips this on.
  """
  @spec registration_open?() :: boolean()
  def registration_open?, do: get("registration_open") == true

  @doc """
  task #87 Decision 10 — when registration is open, does it require a valid
  invite code? Default **false**. Only meaningful when `registration_open?` is
  true.
  """
  @spec registration_require_invite?() :: boolean()
  def registration_require_invite?, do: get("registration_require_invite") == true

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(v) when is_integer(v), do: true
  defp present?(_), do: false
end
