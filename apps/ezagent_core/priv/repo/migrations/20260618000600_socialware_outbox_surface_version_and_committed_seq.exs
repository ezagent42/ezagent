defmodule EzagentCore.Repo.Migrations.SocialwareOutboxSurfaceVersionAndCommittedSeq do
  use Ecto.Migration
  import Ecto.Query

  # P2.5b — durable commit-order delivery cursor + committed page version on the
  # customer outbox. `committed_seq` is the per-session monotonic COMMIT-ORDER
  # cursor (NULL until the settlement commits; assigned at the commit boundary).
  # `surface_version` is the committed page version (mirrors
  # SettlementRecord.target_surface_version) carried on the durable delivery row
  # for the P3 ExternalAdapter and read by the committed-page projection.
  # Non-destructive adds + a one-time backfill of existing committed rows so the
  # cursor is dense from deploy (else legacy committed pages would vanish — the
  # page read is committed_seq based).
  #
  # SELF-CONTAINED backfill (codex P2.5b impl HIGH): this `ezagent_core` migration
  # must NOT call into `Ezagent.Socialware.*` (core does not depend on socialware;
  # a core-only/release migration context may not have those modules loaded, and
  # historical replay must not depend on current app shape). The backfill below
  # uses migration-local Ecto queries over raw table names. It mirrors the
  # algorithm of `Ezagent.Socialware.Settlement.backfill_committed_seq!/0` (kept
  # as a unit-tested runtime helper) but is frozen here.
  def up do
    alter table(:socialware_customer_outbox) do
      add :surface_version, :integer
      add :committed_seq, :integer
    end

    flush()
    backfill_committed_seq()

    # A per-session unique index — a backstop against a committed_seq collision
    # (per-session commits are serialized by the single SocialwareSession
    # GenServer, so a collision would be a real bug → fail loudly, not corrupt).
    create unique_index(:socialware_customer_outbox, [:session_uri, :committed_seq],
             name: :socialware_customer_outbox_session_committed_seq_index
           )
  end

  # Number existing committed outbox rows (committed_seq IS NULL) per session in
  # commit order — committed_at, then target_surface_version (page-version order
  # so a tied committed_at gives the higher version the higher seq), then turn_id
  # — and copy surface_version from the settlement. Raw table names; no app deps.
  defp backfill_committed_seq do
    repo = repo()

    rows =
      from(o in "socialware_customer_outbox",
        join: s in "socialware_settlements",
        on: s.turn_id == o.turn_id,
        where: s.status == "committed" and is_nil(o.committed_seq),
        order_by: [
          asc: o.session_uri,
          asc: s.committed_at,
          asc: coalesce(s.target_surface_version, 0),
          asc: o.turn_id
        ],
        select: %{
          turn_id: o.turn_id,
          session_uri: o.session_uri,
          tsv: s.target_surface_version
        }
      )
      |> repo.all()

    rows
    |> Enum.group_by(& &1.session_uri)
    |> Enum.each(fn {session_uri, session_rows} ->
      start =
        repo.one(
          from(o in "socialware_customer_outbox",
            where: o.session_uri == ^session_uri and not is_nil(o.committed_seq),
            select: max(o.committed_seq)
          )
        ) || 0

      session_rows
      |> Enum.with_index(start + 1)
      |> Enum.each(fn {row, seq} ->
        from(o in "socialware_customer_outbox", where: o.turn_id == ^row.turn_id)
        |> repo.update_all(set: [committed_seq: seq, surface_version: row.tsv])
      end)
    end)
  end

  def down do
    drop index(:socialware_customer_outbox, [:session_uri, :committed_seq],
           name: :socialware_customer_outbox_session_committed_seq_index
         )

    alter table(:socialware_customer_outbox) do
      remove :committed_seq
      remove :surface_version
    end
  end
end
