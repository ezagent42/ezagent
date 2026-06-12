defmodule EzagentCore.Repo.Migrations.UniqueConfigObjectSourceTurn do
  use Ecto.Migration

  # CE-2 (PR-6) — durable guard against CONCURRENT duplicate config-delta
  # dispatch. The ConfigEvolve handler's serial early-return only catches a
  # RE-dispatch after the first apply committed; two concurrent dispatches can
  # both observe "not applied" and both reach `write_and_point/1`. This partial
  # unique index makes the DB reject the second object so exactly one delta per
  # turn ever lands.
  #
  # Column set: (workspace_uri, subject_uri, key, source_turn_id). A settled
  # apply maps ONE turn → ONE delta for ONE (workspace, subject, key) — that
  # tuple identifies the object minted for the turn. `source_turn_id` alone is
  # NOT unique: `repoint_config` stamps a CONSTANT `"repoint:<self_uri>"` on
  # every repoint object, so a bare `[:source_turn_id]` index would wrongly
  # reject the second repoint. (`layer` is not a column on config_objects — it
  # lives on the pointer only.)
  #
  # PARTIAL on `source_turn_id IS NOT NULL`: today the column is NOT NULL, but
  # the partial predicate keeps the index correct if any provenance-free object
  # is ever written, and matches the changeset's intent (the constraint guards
  # turn-stamped objects only).

  def change do
    create unique_index(
             :socialware_config_objects,
             [:workspace_uri, :subject_uri, :key, :source_turn_id],
             where: "source_turn_id IS NOT NULL",
             name: :socialware_config_objects_unique_source_turn
           )
  end
end
