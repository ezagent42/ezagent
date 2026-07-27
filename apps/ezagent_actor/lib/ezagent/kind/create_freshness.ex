defmodule Ezagent.Kind.CreateFreshness do
  @moduledoc """
  #201 PR-1 — per-URI bridge for the Lifecycle-owned create-vs-activate
  verdict (`:created` / `:existed` / `:unknown`).

  `Ezagent.Kind.Server.init/1` computes the verdict from the durable
  `ever_created` marker BEFORE the initial persist writes that marker, and
  records it here. The atomic spawn winner (`:started`) then reads it back
  SYNCHRONOUSLY from the spawning process — via `Ezagent.Kind.create_freshness/1`
  — without a `GenServer.call` to the fresh Kind (whose mailbox may be busy
  for seconds in `post_init`/activate, e.g. a cold subprocess provision;
  queuing the verdict read behind that work would stall the caller).

  ## Why ETS, and why no cleanup

  The write happens inside `init/1`, so it happens-before
  `DynamicSupervisor.start_child` returns `{:ok, pid}` — a winner that reads
  after its winning spawn therefore always reads the verdict of the
  incarnation IT just started (the sole `:started` winner; no two-both-read
  race). Rows are never deleted: they are only ever read immediately after a
  `:started` win, and every fresh `init/1` overwrites the row for its URI,
  so a stale row is never observable by a conforming reader. A destroy →
  recreate cycle rewrites the row on the recreate's init.

  The table is `:ezagent_kind_create_freshness` (set), owned by
  `EzagentActor.EtsOwner`. All state is ephemeral (the durable source of the
  verdict is the `ever_created` marker itself, re-derived at every init).
  """

  @table :ezagent_kind_create_freshness

  @doc "ETS table name — for `EzagentActor.EtsOwner` to create at boot."
  def table, do: @table

  @doc false
  # Framework-internal: called ONLY from `Ezagent.Kind.Server.init/1`.
  @spec record(String.t(), atom()) :: :ok
  def record(uri_str, freshness)
      when is_binary(uri_str) and freshness in [:created, :existed, :unknown] do
    :ets.insert(@table, {uri_str, freshness})
    :ok
  rescue
    # Verdict bookkeeping must never crash a Kind init; a missed record reads
    # back as `:unknown`, which every consumer treats fail-conservatively as
    # NOT-created.
    _ -> :ok
  end

  @doc false
  # Framework-internal read (`Ezagent.Kind.create_freshness/1`). A missing
  # row (never spawned, or spawned before this bridge existed within this
  # BEAM) reads as `:unknown`.
  @spec lookup(String.t()) :: :created | :existed | :unknown
  def lookup(uri_str) when is_binary(uri_str) do
    case :ets.lookup(@table, uri_str) do
      [{^uri_str, freshness}] -> freshness
      [] -> :unknown
    end
  rescue
    _ -> :unknown
  end
end
