defmodule Ezagent.Kind.CreateFreshness do
  @moduledoc """
  #201 PR-1 — per-incarnation bridge for the Lifecycle-owned
  create-vs-activate verdict (`:created` / `:existed` / `:unknown`).

  `Ezagent.Kind.Server.init/1` computes the verdict from the durable
  `ever_created` marker BEFORE the initial persist writes that marker, and
  records it here. The atomic spawn winner (`:started`) then reads it back
  SYNCHRONOUSLY from the spawning process — via
  `Ezagent.Kind.create_freshness/2` — without a `GenServer.call` to the
  fresh Kind (whose mailbox may be busy for seconds in `post_init`/activate,
  e.g. a cold subprocess provision; queuing the verdict read behind that
  work would stall the caller).

  ## #201-cred (codex r2 MEDIUM-6) — bound to the PROCESS INCARNATION

  Rows are keyed by `{uri_str, pid}` — the EXACT started process — never by
  URI alone. The pre-fix URI-keyed row was MUTABLE across incarnations: the
  winning creator P1 could record `:created`, die before the winner read the
  row, and its supervisor's restart P2 would then overwrite the same
  URI-keyed row with `:existed` — the winner read the WRONG verdict
  (`created?: false`) and the create-only credential grant of the genuine
  creator was wrongfully deleted. With the pid in the key, P2's record is a
  DIFFERENT row: the winner's read of `{uri, P1}` always returns P1's own
  verdict, and a restarted process can never overwrite the winning
  incarnation's verdict.

  The write happens inside `init/1`, so it happens-before
  `DynamicSupervisor.start_child` returns `{:ok, pid}` — a winner that reads
  after its winning spawn therefore always reads the verdict of the
  incarnation IT just started. Rows are deleted on the Kind's `terminate/2`;
  a row leaked by a brutal kill is unreadable (its pid never recurs), never
  consulted, and never misread.

  The table is `:ezagent_kind_create_freshness` (set), owned by
  `EzagentActor.EtsOwner`. All state is ephemeral (the durable source of the
  verdict is the `ever_created` marker itself, re-derived at every init).
  """

  @table :ezagent_kind_create_freshness

  @doc "ETS table name — for `EzagentActor.EtsOwner` to create at boot."
  def table, do: @table

  @doc false
  # Framework-internal: called ONLY from `Ezagent.Kind.Server.init/1`. The
  # recording process's OWN pid is part of the key (see the moduledoc).
  @spec record(String.t(), atom()) :: :ok
  def record(uri_str, freshness)
      when is_binary(uri_str) and freshness in [:created, :existed, :unknown] do
    :ets.insert(@table, {{uri_str, self()}, freshness})
    :ok
  rescue
    # Verdict bookkeeping must never crash a Kind init; a missed record reads
    # back as `:unknown`, which every consumer treats fail-conservatively as
    # NOT-created.
    _ -> :ok
  end

  @doc false
  # Framework-internal read (`Ezagent.Kind.create_freshness/2`). Returns the
  # verdict recorded by the EXACT process incarnation `pid` — a missing row
  # (never spawned, already terminated, or a verdict recorded by a DIFFERENT
  # incarnation) reads as `:unknown` (fail-conservative: never `:created`).
  @spec lookup(String.t(), pid()) :: :created | :existed | :unknown
  def lookup(uri_str, pid) when is_binary(uri_str) and is_pid(pid) do
    case :ets.lookup(@table, {uri_str, pid}) do
      [{{^uri_str, ^pid}, freshness}] -> freshness
      [] -> :unknown
    end
  rescue
    _ -> :unknown
  end

  @doc false
  # Framework-internal cleanup: called from `Ezagent.Kind.Server.terminate/2`
  # so a graceful shutdown frees this incarnation's row. Best-effort by
  # design — a leaked row is never consulted (its pid never recurs).
  @spec delete(String.t(), pid()) :: :ok
  def delete(uri_str, pid) when is_binary(uri_str) and is_pid(pid) do
    :ets.delete(@table, {uri_str, pid})
    :ok
  rescue
    _ -> :ok
  end
end
