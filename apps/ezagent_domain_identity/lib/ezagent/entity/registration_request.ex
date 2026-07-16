defmodule Ezagent.Entity.RegistrationRequest do
  @moduledoc """
  A self-service registration request submitted while public registration is closed.

  Requests are idempotent by normalized email: submitting the same address again
  refreshes its timestamp without disclosing whether it was already pending.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias EzagentCore.Repo

  schema "registration_requests" do
    field(:email, :string)
    field(:status, :string, default: "pending")
    field(:requested_from_ip, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Create or refresh a pending request without exposing duplicate state."
  @spec request(String.t(), String.t() | nil) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def request(email, ip \\ nil) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    now = DateTime.utc_now()

    %__MODULE__{}
    |> changeset(%{email: email, requested_from_ip: ip, status: "pending"})
    |> Repo.insert(
      on_conflict: [set: [status: "pending", requested_from_ip: ip, updated_at: now]],
      conflict_target: [:email],
      returning: true
    )
  end

  @doc "List requests for the admin registration-settings surface."
  @spec list_pending() :: [t()]
  def list_pending do
    Repo.all(
      from(r in __MODULE__,
        where: r.status == "pending",
        order_by: [desc: r.updated_at]
      )
    )
  end

  defp changeset(request, attrs) do
    request
    |> cast(attrs, [:email, :status, :requested_from_ip])
    |> validate_required([:email, :status])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> unique_constraint(:email)
  end
end
