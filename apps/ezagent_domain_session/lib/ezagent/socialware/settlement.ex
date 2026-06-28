defmodule Ezagent.Socialware.Settlement do
  @moduledoc """
  Durable socialware settlement record and replay helpers.
  """

  import Ecto.Query

  alias Ezagent.MessageStore
  alias Ezagent.Session.ExternalDelivery
  alias Ezagent.Socialware.{DeliveryOutbox, SettlementMessage, SettlementRecord}
  alias EzagentCore.Repo

  @visibility_flipped "visibility_flipped"
  @pointer_advanced "pointer_advanced"
  @outbox_emitted "outbox_emitted"

  @spec begin(map()) :: {:ok, SettlementRecord.t()} | {:error, term()}
  def begin(attrs) when is_map(attrs) do
    turn_id = Map.fetch!(attrs, :turn_id)
    message_ids = Map.fetch!(attrs, :target_message_ids)

    record = %SettlementRecord{
      turn_id: turn_id,
      session_uri: uri_to_string(Map.fetch!(attrs, :session_uri)),
      workspace_uri: uri_to_string(Map.fetch!(attrs, :workspace_uri)),
      target_surface_version: Map.get(attrs, :target_surface_version),
      expected_prior_approved: Map.get(attrs, :expected_prior_approved),
      subwrites_done: [],
      status: :pending
    }

    Repo.transaction(fn ->
      case Repo.insert(record, on_conflict: :nothing, conflict_target: :turn_id) do
        {:ok, _} ->
          Enum.each(message_ids, fn message_id ->
            %SettlementMessage{
              turn_id: turn_id,
              message_id: message_id,
              workspace_uri: record.workspace_uri
            }
            |> Repo.insert!(
              on_conflict: :nothing,
              conflict_target: [:turn_id, :message_id]
            )
          end)

          Repo.get!(SettlementRecord, turn_id)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @spec get(String.t()) :: {:ok, SettlementRecord.t()} | :error
  def get(turn_id) when is_binary(turn_id) do
    case Repo.get(SettlementRecord, turn_id) do
      %SettlementRecord{} = settlement -> {:ok, settlement}
      nil -> :error
    end
  end

  @spec flip_visibility(String.t()) :: {:ok, SettlementRecord.t()} | {:error, term()}
  def flip_visibility(turn_id) when is_binary(turn_id) do
    with {:ok, settlement} <- get(turn_id),
         message_ids <- message_ids(turn_id),
         {:ok, _count} <- MessageStore.mark_visibility(message_ids, :external_visible) do
      mark_subwrite(settlement, @visibility_flipped)
    end
  end

  @spec hold_visibility(String.t()) :: {:ok, non_neg_integer()} | :error
  def hold_visibility(turn_id) when is_binary(turn_id) do
    case get(turn_id) do
      {:ok, _settlement} ->
        MessageStore.mark_visibility(message_ids(turn_id), :internal)

      :error ->
        :error
    end
  end

  @spec mark_pointer_advanced(String.t(), integer() | nil) ::
          {:ok, SettlementRecord.t()}
          | {:error, :approved_pointer_conflict | :target_version_mismatch}
  def mark_pointer_advanced(turn_id, approved_version) when is_binary(turn_id) do
    with {:ok, settlement} <- get(turn_id),
         :ok <- prior_matches?(settlement, approved_version) do
      mark_subwrite(settlement, @pointer_advanced)
    else
      {:error, reason} ->
        record_conflict(turn_id, reason)
        {:error, reason}
    end
  end

  @spec commit_after_pointer(String.t(), integer() | nil) ::
          {:ok, map()} | {:error, term()}
  def commit_after_pointer(turn_id, approved_version) do
    case get(turn_id) do
      {:ok, %SettlementRecord{status: :committed}} ->
        # Already committed — FULL no-op (codex P2.5b HIGH). Preserve committed_at
        # + committed_seq so the durable cursor order and the page projection
        # never disagree; a delayed re-commit of an older turn must NOT bump its
        # commit metadata. No re-broadcast.
        {:ok, %{status: :committed, message_ids: message_ids(turn_id), emitted?: false}}

      _ ->
        commit_pending_after_pointer(turn_id, approved_version)
    end
  end

  defp commit_pending_after_pointer(turn_id, approved_version) do
    with {:ok, settlement} <- confirm_pointer_advanced(turn_id, approved_version),
         {:ok, emitted?} <- emit_outbox_once(settlement),
         {:ok, settlement} <- get(turn_id),
         true <- committed_ready?(settlement) do
      committed_at = DateTime.utc_now()
      message_ids = message_ids(turn_id)

      {:ok, _} =
        Repo.transaction(fn ->
          # `settlement` carries target_surface_version; assign the commit-order
          # cursor + surface_version atomically with the status flip.
          assign_committed_seq(settlement)

          {1, _} =
            from(s in SettlementRecord, where: s.turn_id == ^turn_id)
            |> Repo.update_all(set: [status: :committed, committed_at: committed_at])
        end)

      if emitted? do
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          ExternalDelivery.topic(Ezagent.URI.new!(settlement.session_uri)),
          {:external_delivery, %{message_ids: message_ids}}
        )
      end

      {:ok,
       %{
         status: :committed,
         message_ids: message_ids,
         emitted?: emitted?
       }}
    else
      false -> {:error, :incomplete_settlement}
      :error -> {:error, :unknown_settlement}
      {:error, _reason} = err -> err
    end
  end

  @doc false
  def mark_committed_for_test(turn_id) do
    with {:ok, settlement} <- get(turn_id),
         {:ok, settlement} <- mark_subwrite(settlement, @visibility_flipped),
         {:ok, settlement} <- mark_subwrite(settlement, @pointer_advanced),
         {:ok, settlement} <- mark_subwrite(settlement, @outbox_emitted) do
      # P2.5b — faithful to the real commit boundary: assign the commit-order
      # cursor + surface_version (if an outbox row exists) alongside the status
      # flip. Tolerates settlements with no outbox row.
      assign_committed_seq(settlement)

      {1, _} =
        from(s in SettlementRecord, where: s.turn_id == ^turn_id)
        |> Repo.update_all(set: [status: :committed, committed_at: DateTime.utc_now()])

      get(turn_id)
    end
  end

  # P2.5b — assign the per-session monotonic COMMIT-ORDER cursor to this turn's
  # outbox row, IF not already assigned (idempotent re-commit). ALSO (re)writes
  # surface_version from the settlement — covers an UPGRADE-pending row inserted
  # before this migration with surface_version == NULL. Runs inside the
  # session GenServer (per-session serialized), so max+1 has no
  # concurrent writer; the (session_uri, committed_seq) unique index is a
  # let-it-crash backstop. Tolerates a missing outbox row (no MatchError).
  defp assign_committed_seq(
         %SettlementRecord{turn_id: turn_id, session_uri: session_uri} = settlement
       ) do
    case Repo.get_by(DeliveryOutbox, turn_id: turn_id) do
      nil ->
        :ok

      %DeliveryOutbox{committed_seq: seq} when is_integer(seq) ->
        :ok

      %DeliveryOutbox{} ->
        next =
          (Repo.one(
             from(o in DeliveryOutbox,
               where: o.session_uri == ^session_uri and not is_nil(o.committed_seq),
               select: max(o.committed_seq)
             )
           ) || 0) + 1

        {1, _} =
          from(o in DeliveryOutbox, where: o.turn_id == ^turn_id)
          |> Repo.update_all(
            set: [committed_seq: next, surface_version: settlement.target_surface_version]
          )

        :ok
    end
  end

  @doc """
  P2.5b — idempotent backfill: assign committed_seq + surface_version to EXISTING
  committed outbox rows whose committed_seq IS NULL. Per session, numbers rows in
  commit order: committed_at, then `target_surface_version` (page-version order —
  a tied committed_at resolves so the HIGHER version gets the HIGHER seq, so the
  committed_seq page read picks it), then turn_id. Continues from any committed_seq
  already present. Safe to re-run (touches only NULL-seq committed rows).

  RUNTIME/TEST helper. The actual deploy backfill is a SELF-CONTAINED copy inside
  migration `20260618000600` (an `ezagent_core` migration must not call up-layer
  `Ezagent.Socialware.*`; codex P2.5b impl HIGH). This function mirrors that
  algorithm for unit tests / ad-hoc repair via the app runtime.
  """
  @spec backfill_committed_seq!() :: :ok
  def backfill_committed_seq! do
    rows =
      from(o in DeliveryOutbox,
        join: s in SettlementRecord,
        on: s.turn_id == o.turn_id,
        where: s.status == :committed and is_nil(o.committed_seq),
        order_by: [
          asc: o.session_uri,
          asc: s.committed_at,
          asc: coalesce(s.target_surface_version, 0),
          asc: o.turn_id
        ],
        select: %{
          turn_id: o.turn_id,
          session_uri: o.session_uri,
          target_surface_version: s.target_surface_version
        }
      )
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.session_uri)
    |> Enum.each(fn {session_uri, session_rows} ->
      start =
        Repo.one(
          from(o in DeliveryOutbox,
            where: o.session_uri == ^session_uri and not is_nil(o.committed_seq),
            select: max(o.committed_seq)
          )
        ) || 0

      session_rows
      |> Enum.with_index(start + 1)
      |> Enum.each(fn {row, seq} ->
        {1, _} =
          from(o in DeliveryOutbox, where: o.turn_id == ^row.turn_id)
          |> Repo.update_all(
            set: [committed_seq: seq, surface_version: row.target_surface_version]
          )
      end)
    end)

    :ok
  end

  defp mark_subwrite(%SettlementRecord{} = settlement, subwrite) do
    done = MapSet.new(settlement.subwrites_done || [])

    subwrites_done =
      done
      |> MapSet.put(subwrite)
      |> MapSet.to_list()
      |> Enum.sort()

    {1, _} =
      from(s in SettlementRecord, where: s.turn_id == ^settlement.turn_id)
      |> Repo.update_all(set: [subwrites_done: subwrites_done])

    get(settlement.turn_id)
  end

  defp emit_outbox_once(%SettlementRecord{} = settlement) do
    message_ids = message_ids(settlement.turn_id)

    {inserted, _} =
      Repo.insert_all(
        DeliveryOutbox,
        [
          %{
            turn_id: settlement.turn_id,
            session_uri: settlement.session_uri,
            workspace_uri: settlement.workspace_uri,
            message_ids: message_ids,
            surface_version: settlement.target_surface_version,
            emitted_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: :turn_id
      )

    case inserted do
      1 ->
        {:ok, _settlement} = mark_subwrite(settlement, @outbox_emitted)

        {:ok, true}

      0 ->
        {:ok, _settlement} = mark_subwrite(settlement, @outbox_emitted)
        {:ok, false}
    end
  end

  defp committed_ready?(%SettlementRecord{subwrites_done: subwrites_done}) do
    done = MapSet.new(subwrites_done || [])

    Enum.all?([@visibility_flipped, @pointer_advanced, @outbox_emitted], fn subwrite ->
      MapSet.member?(done, subwrite)
    end)
  end

  defp pointer_matches?(%SettlementRecord{target_surface_version: nil}, _approved_version),
    do: :ok

  defp pointer_matches?(%SettlementRecord{target_surface_version: version}, version), do: :ok

  defp pointer_matches?(_settlement, _approved_version), do: {:error, :target_version_mismatch}

  defp confirm_pointer_advanced(turn_id, approved_version) do
    with {:ok, settlement} <- get(turn_id),
         :ok <- pointer_matches?(settlement, approved_version) do
      mark_subwrite(settlement, @pointer_advanced)
    end
  end

  defp prior_matches?(%SettlementRecord{expected_prior_approved: nil}, nil), do: :ok

  defp prior_matches?(%SettlementRecord{expected_prior_approved: expected}, approved_version)
       when expected == approved_version,
       do: :ok

  defp prior_matches?(_settlement, _approved_version), do: {:error, :approved_pointer_conflict}

  defp record_conflict(turn_id, reason) do
    from(s in SettlementRecord, where: s.turn_id == ^turn_id)
    |> Repo.update_all(set: [conflict_reason: Atom.to_string(reason)])
  end

  defp message_ids(turn_id) do
    from(sm in SettlementMessage,
      where: sm.turn_id == ^turn_id,
      select: sm.message_id,
      order_by: [asc: sm.message_id]
    )
    |> Repo.all()
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(uri) when is_binary(uri), do: uri
end
