defmodule Mix.Tasks.Ezagent.Snapshot.Clear do
  @shortdoc "Delete a Kind snapshot row (next spawn → init_fresh)"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — TRACKED BYPASS DEBT
  > (codex PR #304 round-2 MED).**
  >
  > NOT Category A. Round-1 labelled this as "DB maintenance —
  > Category A" but the audit (Finding 2 carve-out + Section 5
  > Finding 5) itself flags `snapshot.clear` as "should arguably
  > be a Behavior so caps gate it". This is a DESTRUCTIVE
  > unaudited operation that deletes stored Kind state; mis-using
  > a Category A label here would let an invariant test based on
  > the Category A allowlist silently bless it forever.
  >
  > Correct classification: BYPASS DEBT — temporary CLI-only
  > until a `system://snapshots` Kind + `Behavior.Snapshots` with
  > `:clear` action + cap subject lands. Then this task should
  > be deprecated using the PR #302 stub pattern, and `mix ezagent
  > snapshots clear --uri …` will auto-derive from the Behavior's
  > `interface/0`.
  >
  > Until that Kind exists, operators can still use this task —
  > but `docs/notes/2026-05-24-cli-gui-parity-audit.md` Finding 5
  > tracks the debt + the invariant test that will gate the
  > eventual Behavior migration. Do NOT extend the Category A
  > allowlist to include `snapshot.clear`.

  Phase 5 PR 3:

      mix ezagent.snapshot.clear <uri>

  Removes the snapshot row. The next time the Kind is spawned, it will
  init_fresh (granted caps / runtime state lost).
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)

    case args do
      [uri] when is_binary(uri) ->
        case Ezagent.Ecto.KindSnapshot.get(uri) do
          nil ->
            Mix.shell().info("no snapshot at #{uri} (nothing to clear)")

          _row ->
            :ok = Ezagent.Ecto.KindSnapshot.clear_state_preserving_marker(uri)
            Mix.shell().info("✓ cleared snapshot at #{uri}")
        end

      _ ->
        Mix.raise("usage: mix ezagent.snapshot.clear <uri>")
    end
  end
end
