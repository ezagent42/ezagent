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
    case load_checked(uri) do
      {:ok, caps} -> caps
      {:error, _reason} -> []
    end
  end

  @doc false
  @spec load_checked(URI.t()) :: {:ok, [Ezagent.Capability.t()]} | {:error, term()}
  def load_checked(%URI{} = uri) do
    case Repo.get_by(Ezagent.Users, uri: URI.to_string(uri)) do
      nil -> {:ok, []}
      %Ezagent.Users{} = user -> decode_caps_checked(user.caps_json)
    end
  rescue
    error -> {:error, {:user_caps_read_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:user_caps_read_failed, kind, reason}}
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
    # NB: `__MODULE__.` qualification is REQUIRED — the bare local call would
    # be macro-expanded by the imported `Ecto.Query.update/3` before the
    # local 3-arity clause below is registered.
    __MODULE__.update(uri, fun, [])
  end

  @doc """
  `update/2` with explicit durability options (② P2(c), codex must-fix #2).

  Options (POST-epoch only; pre-epoch `caps_json` is inherently authoritative
  and both options are no-ops):

    * `:source` — `:projection` (default; the stateless-fun mutation path's
      historical behavior: the fun receives the `caps_json`-decoded set) or
      `:store` (the fun receives the AUTHORITATIVE identity-caps Store set —
      required for REVOKE, where a lagging projection must never decide what
      survives).
    * `:projection` — `:best_effort` (default; a `caps_json` projection
      failure is logged and swallowed) or `:authoritative` (a projection
      failure propagates as `{:error, {:caps_json_projection_failed, _}}` —
      required for REVOKE: the `Identity.activate/2` invariant-20 union
      reads `caps_json`, so a failed projection delete must fail the revoke
      rather than let the union resurrect the cap on the next cold boot).
  """
  @spec update(
          URI.t(),
          ([Ezagent.Capability.t()] ->
             {:ok, [Ezagent.Capability.t()]} | {:error, term()}),
          keyword()
        ) ::
          :ok | {:error, term()}
  def update(%URI{} = uri, fun, opts) when is_function(fun, 1) and is_list(opts) do
    # #189 PR-3 FIX 1 — the identity store is AUTHORITATIVE only POST-epoch.
    # #189 PR-3 FINAL — an UNREADABLE epoch (`:unknown`) REJECTS the mutation
    # (fail-closed): a post-cutover node whose epoch read errors must not perform
    # a legacy-authoritative write that a subsequent definitive-epoch read would
    # treat as a stale projection. Only a DEFINITIVE `:inactive` takes the legacy
    # path.
    case Ezagent.Identity.Cutover.status() do
      :active -> update_store_authoritative(uri, fun, opts)
      :inactive -> update_legacy_authoritative(uri, fun)
      :unknown -> {:error, :identity_epoch_unreadable}
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
  defp update_store_authoritative(uri, fun, opts) do
    source = Keyword.get(opts, :source, :projection)
    projection = Keyword.get(opts, :projection, :best_effort)

    with {:ok, current} <- read_current_caps(uri, source),
         {:ok, new_caps} <- fun.(current) do
      case Ezagent.EntityCaps.Store.persist(uri, new_caps) do
        :ok ->
          project_caps_json(uri, new_caps, projection)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # `{:error, :not_found}` when there is no `users` row — preserving the
  # mutation contract (`EntityCaps.grant` on a user without a row is not_found).
  # `:projection` (default) decodes the legacy `caps_json` column; `:store`
  # (② P2(c) revoke path) reads the AUTHORITATIVE identity-caps Store — a
  # lagging projection must never decide which caps survive a revoke.
  defp read_current_caps(%URI{} = uri, source) do
    case Ezagent.Users.get_by_uri(uri) do
      nil -> {:error, :not_found}
      %{caps: caps} when is_list(caps) -> source_caps(uri, source, caps)
      _ -> source_caps(uri, source, [])
    end
  end

  defp source_caps(_uri, :projection, projected), do: {:ok, projected}

  # `:store` — the authoritative read for revoke. A store READ ERROR is
  # fail-closed (never silently fall back to the projection the revoke is
  # supposed to correct); a SUCCESSFULLY-absent store row falls back to the
  # projection (the `load_persisted_cutover_checked` dual-read precedent —
  # an un-backfilled user keeps its legacy semantics).
  defp source_caps(uri, :store, projected) do
    case Ezagent.EntityCaps.Store.fetch_durable_caps(uri) do
      {:ok, store_caps} -> {:ok, store_caps}
      :absent -> {:ok, projected}
      {:error, reason} -> {:error, {:identity_store_read_failed, reason}}
    end
  end

  # Best-effort POST-epoch legacy PROJECTION of the authoritative store caps into
  # `users.caps_json`. A projection failure is logged, never surfaced — post-epoch
  # reads are store-authoritative (the store row is present), so a lagging
  # projection changes no authorization outcome and is reconciled on the next
  # mutation or by the parity barrier.
  #
  # ② P2(c) (must-fix #2) — `:authoritative` mode for REVOKE: the projection
  # write MUST commit, because `Identity.activate/2`'s invariant-20 union reads
  # `caps_json` on every cold boot; a failed projection delete there would
  # resurrect the revoked cap. A failure propagates as
  # `{:error, {:caps_json_projection_failed, _}}` (the revoke reports failure
  # and can be retried — the revocation tombstone recorded before the deletes
  # keeps the partial state fail-safe).
  # TEST-ONLY forced-projection-failure seam (the
  # `@p1_forced_shadow_failure_seam` precedent): compiled IN only for
  # `MIX_ENV=test`, provably unreachable in a dev/prod/release build.
  # Consulted ONLY when `:ezagent_domain_identity,
  # :p4_forced_caps_json_failure_uris` is set — never set outside the ② P2(c)
  # stale-`caps_json` regression — so the regression can force the `caps_json`
  # PROJECTION write to fail after the authoritative Store delete committed
  # (a real projection outage is not reproducible in the sandbox).
  @p4_forced_projection_failure_seam Mix.env() == :test

  if @p4_forced_projection_failure_seam do
    defp forced_projection_failure(%URI{} = uri) do
      case Application.get_env(:ezagent_domain_identity, :p4_forced_caps_json_failure_uris) do
        nil ->
          :proceed

        uris ->
          if URI.to_string(uri) in uris,
            do: {:error, {:p4_forced_projection_failure, URI.to_string(uri)}},
            else: :proceed
      end
    end
  else
    defp forced_projection_failure(_uri), do: :proceed
  end

  defp project_caps_json(%URI{} = uri, caps, mode) do
    outcome =
      case forced_projection_failure(uri) do
        :proceed ->
          try do
            Repo.transaction(fn -> write_caps_json_locked(uri, caps) end)
          rescue
            e -> {:raised, e}
          end

        {:error, _reason} = forced ->
          forced
      end

    case {outcome, mode} do
      {{:ok, :ok}, _mode} ->
        :ok

      {{:raised, e}, :authoritative} ->
        {:error, {:caps_json_projection_failed, Exception.message(e)}}

      {{:raised, e}, _best_effort} ->
        Logger.error(
          "EntityCaps.UserStore: post-epoch caps_json projection RAISED for " <>
            "#{inspect(uri)}: #{Exception.message(e)}"
        )

        :ok

      {other, :authoritative} ->
        {:error, {:caps_json_projection_failed, other}}

      {other, _best_effort} ->
        Logger.error(
          "EntityCaps.UserStore: post-epoch caps_json projection FAILED for " <>
            "#{inspect(uri)} (#{inspect(other)}) — store row is authoritative; " <>
            "projection reconciles on the next mutation / parity barrier"
        )

        :ok
    end
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
    case decode_caps_checked(json) do
      {:ok, caps} -> caps
      {:error, :invalid_caps_json} -> []
    end
  end

  defp decode_caps_checked(nil), do: {:ok, []}
  defp decode_caps_checked(""), do: {:ok, []}

  defp decode_caps_checked(json) do
    case Jason.decode(json) do
      {:ok, nil} -> {:ok, []}
      {:ok, caps} when is_list(caps) -> {:ok, Enum.map(caps, &Ezagent.Capability.from_map/1)}
      _ -> {:error, :invalid_caps_json}
    end
  rescue
    _ -> {:error, :invalid_caps_json}
  end
end
