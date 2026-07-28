defmodule Ezagent.EntityCaps.UserStore do
  @moduledoc """
  The legacy user cap store (`users.caps_json`).

  #189 PR-1 dual-write: every write here ALSO upserts the unified
  identity-caps store (`Ezagent.EntityCaps.Store`). The authoritative
  `caps_json` write commits FIRST in its own transaction; the store mirror
  then runs OUTSIDE that transaction (a WRITE-SHADOW), so a shadow-write
  failure — including a Postgres error that aborts a transaction — can NEVER
  roll back the committed `caps_json` write. `caps_json` stays authoritative,
  and a mirror failure is logged at `:error`, never silently dropped
  (codex review F1/F2).
  """

  import Ecto.Query

  require Logger

  alias EzagentCore.Repo

  @doc false
  @spec exists?(URI.t()) :: boolean()
  def exists?(%URI{} = uri), do: not is_nil(Ezagent.Users.get_by_uri(uri))

  @doc false
  @spec load(URI.t()) :: [Ezagent.Capability.t()]
  def load(%URI{} = uri) do
    case Ezagent.Users.get_by_uri(uri) do
      %{caps: caps} when is_list(caps) -> caps
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc false
  @spec persist(URI.t(), [Ezagent.Capability.t()]) :: :ok | {:error, term()}
  def persist(%URI{} = uri, caps) when is_list(caps) do
    __MODULE__.update(uri, fn _current -> {:ok, caps} end)
  end

  @doc false
  @spec update(URI.t(), ([Ezagent.Capability.t()] ->
                           {:ok, [Ezagent.Capability.t()]} | {:error, term()})) ::
          :ok | {:error, term()}
  def update(%URI{} = uri, fun) when is_function(fun, 1) do
    # Commit the AUTHORITATIVE `caps_json` write in its own transaction FIRST,
    # then mirror to the write-shadow store OUTSIDE the transaction. A shadow
    # DB error must NEVER abort/roll back the legacy write: Postgres aborts the
    # whole transaction on any statement error, and an Elixir-layer rescue
    # cannot recover an aborted transaction (codex F2). Reads are
    # legacy-authoritative in PR-1, so a momentarily-stale shadow is harmless.
    case Repo.transaction(fn -> update_locked(uri, fun) end) do
      {:ok, {:ok, caps}} ->
        mirror_identity_caps(uri, caps)
        :ok

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_locked(uri, fun) do
    row =
      from(user in Ezagent.Users,
        where: user.uri == ^URI.to_string(uri),
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case row do
      nil ->
        {:error, :not_found}

      row ->
        with {:ok, caps} <- fun.(decode_caps(row.caps_json)),
             encoded <- caps |> Enum.map(&Ezagent.Capability.to_map/1) |> Jason.encode!(),
             {:ok, _row} <-
               row |> Ecto.Changeset.change(caps_json: encoded) |> Repo.update() do
          # Return the committed cap set; the write-shadow mirror runs in
          # `update/2` AFTER this transaction commits, so a shadow failure
          # cannot roll back the authoritative `caps_json` write (codex F2).
          {:ok, caps}
        end
    end
  end

  defp mirror_identity_caps(uri, caps) do
    case Ezagent.EntityCaps.Store.persist(uri, caps) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "EntityCaps.UserStore: identity-caps shadow write FAILED for " <>
            "#{URI.to_string(uri)} (reason=#{inspect(reason)}) — caps_json committed; " <>
            "shadow row diverges until the next mirrored write or the migration backfill"
        )

        :ok
    end
  rescue
    e ->
      Logger.error(
        "EntityCaps.UserStore: identity-caps shadow write RAISED for " <>
          "#{URI.to_string(uri)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp decode_caps(nil), do: []
  defp decode_caps(""), do: []

  defp decode_caps(json) do
    case Jason.decode(json) do
      {:ok, caps} when is_list(caps) -> Enum.map(caps, &Ezagent.Capability.from_map/1)
      _ -> []
    end
  rescue
    _ -> []
  end
end
