defmodule EzagentPluginFeishu.UserBinding do
  @moduledoc """
  Phase 6 PR 15 — Feishu open_id ↔ local user URI binding store.

  **Pure data module.** Doesn't know about capabilities, policies, or
  webhook/WS plumbing. Read by `SenderResolver` (transport → identity)
  and written by `BindingPolicy` + the admin CLI / LV.

  ## Why separate from caps

  Per Allen 2026-05-17 "代码要和其它功能分离开，以便未来添加更多功能":
  - This module: storage + lookup. Stable surface.
  - `BindingPolicy`: bind-time side-effects (cap grant). Composable —
    you could swap policies without touching the store.
  - `SenderResolver`: transport-level open_id → local URI rewriting.
    Webhook + WS both use it without duplicating logic.

  ## Schema

      open_id        string  primary key  — Feishu user open_id
      user_uri       string  not null     — bound Ezagent User URI
      bound_by       string  not null     — admin URI that authorized
      bound_at       utc_datetime_usec    — when bound
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:open_id, :string, autogenerate: false}
  schema "feishu_user_bindings" do
    field(:user_uri, :string)
    field(:bound_by, :string)
    field(:bound_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          open_id: String.t(),
          user_uri: String.t(),
          bound_by: String.t(),
          bound_at: DateTime.t()
        }

  @doc """
  Bind `open_id` to `user_uri`, recording who did it and when.

  Upserts: rebinding replaces the prior user_uri. Idempotent if
  same (open_id, user_uri) pair.

  An explicit `bound_at` (4-arity) is used by the rollback path so a
  rebind-rollback restores the original timestamp precisely.
  """
  @spec bind(String.t(), URI.t() | String.t(), URI.t() | String.t()) ::
          {:ok, t()} | {:error, term()}
  def bind(open_id, user_uri, bound_by)
      when is_binary(open_id) and open_id != "" do
    bind(open_id, user_uri, bound_by, DateTime.utc_now())
  end

  @doc false
  @spec bind(String.t(), URI.t() | String.t(), URI.t() | String.t(), DateTime.t()) ::
          {:ok, t()} | {:error, term()}
  def bind(open_id, user_uri, bound_by, %DateTime{} = bound_at)
      when is_binary(open_id) and open_id != "" do
    row = %__MODULE__{
      open_id: open_id,
      user_uri: to_str(user_uri),
      bound_by: to_str(bound_by),
      bound_at: bound_at
    }

    Repo.insert(row,
      on_conflict: {:replace_all_except, [:open_id]},
      conflict_target: :open_id,
      returning: true
    )
  end

  @doc "Remove a binding. Returns :ok or {:error, :not_found}."
  @spec unbind(String.t()) :: :ok | {:error, :not_found}
  def unbind(open_id) when is_binary(open_id) do
    case Repo.get(__MODULE__, open_id) do
      nil ->
        {:error, :not_found}

      row ->
        Repo.delete(row)
        :ok
    end
  end

  @doc """
  Resolve a Feishu open_id to its bound local user URI.
  Returns `{:ok, URI.t()}` for bound, `:error` for unbound.
  """
  @spec resolve(String.t()) :: {:ok, URI.t()} | :error
  def resolve(open_id) when is_binary(open_id) and open_id != "" do
    case Repo.get(__MODULE__, open_id) do
      nil -> :error
      %__MODULE__{user_uri: uri_str} -> {:ok, Ezagent.URI.new!(uri_str)}
    end
  end

  def resolve(_), do: :error

  @doc """
  Reverse: list all Feishu open_ids bound to `user_uri`. Returns `[]`
  if none. (One user can have many Feishu open_ids across brands/apps.)
  """
  @spec open_ids_for(URI.t() | String.t()) :: [String.t()]
  def open_ids_for(user_uri) do
    uri_str = to_str(user_uri)

    Repo.all(
      from(b in __MODULE__,
        where: field(b, :user_uri) == ^uri_str,
        select: field(b, :open_id)
      )
    )
  end

  @doc "List every binding (admin LV / debug)."
  @spec list_all() :: [t()]
  def list_all do
    Repo.all(from(b in __MODULE__, order_by: field(b, :bound_at)))
  end

  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
