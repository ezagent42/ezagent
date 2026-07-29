defmodule Ezagent.EntityCaps.UserStore do
  @moduledoc """
  The legacy user cap store (`users.caps_json`).

  Every write here ALSO writes the unified identity-caps store
  (`Ezagent.EntityCaps.Store`). Which of the two is AUTHORITATIVE is gated on
  the cutover epoch (`Ezagent.Identity.Cutover`):

    * **Pre-epoch** (#189 PR-1 F2 contract) — `caps_json` is authoritative and
      commits FIRST in its own transaction; the store mirror runs OUTSIDE that
      transaction as a best-effort WRITE-SHADOW, so a shadow-write failure can
      NEVER roll back the committed `caps_json` write (logged, never silent).
    * **Post-epoch** (#189 PR-3 FIX 1) — the store is authoritative and commits
      FIRST (Store-first); `caps_json` becomes a best-effort follow-on
      projection. The caller receives `:ok` ONLY when the store commit
      succeeded, so a cap mutation never reports success on a failed store write
      and a revoke never leaves a stale cap in the authoritative read plane.
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
    # #189 PR-3 FIX 1 — the identity store is AUTHORITATIVE only POST-epoch.
    if Ezagent.Identity.Cutover.active?() do
      update_store_authoritative(uri, fun)
    else
      update_legacy_authoritative(uri, fun)
    end
  end

  # PRE-EPOCH (PR-1 F2 contract): `caps_json` is AUTHORITATIVE. Commit it in its
  # own transaction FIRST, then mirror to the write-shadow store OUTSIDE the
  # transaction. A shadow DB error must NEVER abort/roll back the legacy write
  # (Postgres aborts the whole transaction on any statement error, and an
  # Elixir-layer rescue cannot recover an aborted transaction — codex F2). Reads
  # are legacy-authoritative pre-epoch, so a momentarily-stale shadow is harmless.
  defp update_legacy_authoritative(uri, fun) do
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

  # POST-EPOCH: the unified store is AUTHORITATIVE. Compute the new cap set, then
  # make the STORE write the GATING authoritative commit (Store-FIRST), and
  # project into `users.caps_json` as a best-effort follow-on. Store-first (vs
  # caps_json-first) is what closes the revoke hole: a cap removal reaches the
  # authoritative store BEFORE the legacy projection, so a projection failure can
  # never leave a stale cap in the authoritative read plane. The caller receives
  # `:ok` ONLY when the store commit succeeded.
  #
  # The mutation path (`EntityCaps.grant/revoke/persist` -> IdentityAdmin ->
  # `persist_entity_caps` -> `persist/2`) supplies a STATELESS fun (the new caps
  # are already computed from the live slice), so the current-caps read is only
  # consulted by the rare stateful callers (e.g. `clear_self_license_persisted`);
  # the authoritative store write is serialized by `Store.persist`'s own row +
  # authority locks.
  defp update_store_authoritative(uri, fun) do
    with {:ok, current} <- read_current_caps(uri),
         {:ok, new_caps} <- fun.(current) do
      case Ezagent.EntityCaps.Store.persist(uri, new_caps) do
        :ok ->
          project_caps_json(uri, new_caps)
          :ok

        {:error, _reason} = error ->
          error
      end
    end
  end

  # `{:error, :not_found}` when there is no `users` row — preserving the
  # mutation contract (`EntityCaps.grant` on a user without a row is not_found).
  defp read_current_caps(%URI{} = uri) do
    case Ezagent.Users.get_by_uri(uri) do
      nil -> {:error, :not_found}
      %{caps: caps} when is_list(caps) -> {:ok, caps}
      _ -> {:ok, []}
    end
  end

  # Best-effort POST-epoch legacy PROJECTION of the authoritative store caps into
  # `users.caps_json`. A projection failure is logged, never surfaced — post-epoch
  # reads are store-authoritative (the store row is present), so a lagging
  # projection changes no authorization outcome and is reconciled on the next
  # mutation or by the parity barrier.
  defp project_caps_json(%URI{} = uri, caps) do
    case Repo.transaction(fn -> write_caps_json_locked(uri, caps) end) do
      {:ok, :ok} ->
        :ok

      other ->
        Logger.error(
          "EntityCaps.UserStore: post-epoch caps_json projection FAILED for " <>
            "#{inspect(uri)} (#{inspect(other)}) — store row is authoritative; " <>
            "projection reconciles on the next mutation / parity barrier"
        )

        :ok
    end
  rescue
    e ->
      Logger.error(
        "EntityCaps.UserStore: post-epoch caps_json projection RAISED for " <>
          "#{inspect(uri)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp write_caps_json_locked(uri, caps) do
    row =
      from(user in Ezagent.Users,
        where: user.uri == ^URI.to_string(uri),
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case row do
      nil ->
        :ok

      row ->
        encoded = caps |> Enum.map(&Ezagent.Capability.to_map/1) |> Jason.encode!()
        {:ok, _row} = row |> Ecto.Changeset.change(caps_json: encoded) |> Repo.update()
        :ok
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
            "#{inspect(uri)} (reason=#{inspect(reason)}) — caps_json committed; " <>
            "shadow row diverges until the next mirrored write or the migration backfill"
        )

        :ok
    end
  rescue
    e ->
      Logger.error(
        "EntityCaps.UserStore: identity-caps shadow write RAISED for " <>
          "#{inspect(uri)}: #{Exception.message(e)}"
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
